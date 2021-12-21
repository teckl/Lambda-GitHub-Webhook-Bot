package GitHub::Webhook::Bot::Web;
use 5.032;
use strict;
use warnings;
use utf8;
use Kossy;
use Data::Dumper;
use Encode;
use File::Basename qw/basename/;
use File::Copy 'move';
use File::Find 'find';
use File::Path;
use File::Slurp;
use File::Temp qw/tempfile/;
use File::Type;
use JSON qw(encode_json decode_json);
use Path::Class;
use WebService::Slack::WebApi;
use YAML::Tiny;

use GitHub::Webhook::Bot::Chatwork;

sub config {
    state $conf = {
        debug                   => $ENV{DEBUG} // 1,
        enable_chatwork         => $ENV{ENABLE_CHATWORK} // 0,
        enable_chatwork_upload  => $ENV{ENABLE_CHATWORK_UPLOAD} // 1,  # LGTM upload
        enable_slack            => $ENV{ENABLE_SLACK} // 1,
        chatwork_token          => $ENV{CHATWORK_TOKEN},
        slack_token             => $ENV{SLACK_TOKEN},
    };
    my $key = shift;
    my $v = $conf->{$key};
    unless (defined $v) {
        die "config value of $key undefined";
    }
    return $v;
}

sub chatwork_api {
    my ($self, $c) = @_;
    return GitHub::Webhook::Bot::Chatwork->new(config('chatwork_token'));
}

sub slack_api {
    my ($self, $c) = @_;
    return WebService::Slack::WebApi->new(token => config('slack_token'));
}

sub github_payload {
    my ($self, $c) = @_;

    my $payload = $c->req->param('payload') || $c->req->content;
    $payload = eval { decode_json $payload };
    return $payload;
}

sub ghe_login_to_chatwork_id {
    my ($self, $login) = @_;
    my $login_id_map_yaml = YAML::Tiny->read(Path::Class::file( $ENV{'LAMBDA_TASK_ROOT'}, 'etc', 'login_id_map.yml'));

    if ($login) {
        return $login_id_map_yaml->[0]->{$login}->{chatwork};
    }
}

sub ghe_login_to_slack_id {
    my ($self, $login) = @_;
    my $login_id_map_yaml = YAML::Tiny->read(Path::Class::file( $ENV{'LAMBDA_TASK_ROOT'}, 'etc', 'login_id_map.yml'));

    if ($login) {
        return $login_id_map_yaml->[0]->{$login}->{slack};
    }
}

sub repository_name_to_room_id {
    my ($self, $payload, $opt) = @_;
    my $chat_type = $opt && $opt->{slack} ? 'slack' : 'chatwork';
    my $repository_map_yaml = YAML::Tiny->read(Path::Class::file( $ENV{'LAMBDA_TASK_ROOT'}, 'etc', 'repository_map.yml'));

    my $repository_name = $payload->{repository}->{name};

    if (my $room_id = $repository_map_yaml->[0]->{$repository_name}->{$chat_type}) {
        return $room_id;
    }
    # リポジトリ設定が無い場合はデフォルトのroom_idとする
    return $repository_map_yaml->[0]->{default}->{$chat_type};
}

sub github_login_to_chatwork {
    my ($self, $assignees) = @_;

    my $text;
    my @assignees = ();
    if (ref $assignees eq 'ARRAY') {
        for (@{$assignees}) {
            if (ref $_ && exists $_->{login}) {
                # webbook経由
                push @assignees, $_->{login};
            } else {
                # bodyの@記法パース経由
                push @assignees, $_;
            }
        }
    } else {
        push @assignees , $assignees if $assignees;
    }

    for my $assignee (@assignees) {
        my $chatwork_id = $self->ghe_login_to_chatwork_id($assignee);

        $text .= sprintf('[To:%d] @%s ', $chatwork_id, $assignee) if $chatwork_id;
    }
    return $text;
}

# https://qiita.com/gimKondo/items/99ba9b05d14a6b49df68
sub github_login_to_slack {
    my ($self, $assignees) = @_;

    my $text;
    my @assignees = ();
    if (ref $assignees eq 'ARRAY') {
        for (@{$assignees}) {
            if (ref $_ && exists $_->{login}) {
                # webbook経由
                push @assignees, $_->{login};
            } else {
                # bodyの@記法パース経由
                push @assignees, $_;
            }
        }
    } else {
        push @assignees , $assignees if $assignees;
    }

    for my $assignee (@assignees) {
        my $slack_id = $self->ghe_login_to_slack_id($assignee);

        $text .= sprintf('<@%s>', $slack_id) if $slack_id;
    }
    return $text;
}

# 本文中から @login アカウントを抽出
sub parse_body_to_user {
    my ($self, $body) = @_;
    my @ghe_login = ();
    for my $login ( map { $_ =~ /@([_a-zA-Z0-9-]+)/ } split /\s/, $body) {
        push @ghe_login, $login;
    }
    return \@ghe_login;
}

# 本文の置換
sub body_filter {
    my ($self, $body) = @_;
    if (config('enable_chatwork')) {
        return $self->body_filter_chatwork($body);
    } elsif (config('enable_slack')) {
        return $self->body_filter_slack($body);
    } else {
        return $body;
    }
}

# 本文の置換 for chatwork
sub body_filter_chatwork {
    my ($self, $body) = @_;
    # Chatworkの場合はコード記法のみサポート
    # http://blog-ja.chatwork.com/2015/01/codetag-release.html
    $body =~ s,(?:``+)(?:\w+)?(\s+)(.+?)(\s+)(?:``+),\[code\]$1$2$3\[/code\],sg;

    $body = $self->filter_chatwork_emoticons($body);

    if (config('enable_chatwork_upload')) {
        $self->find_upload_image_url($body);
    }
    return $body;
}

sub filter_chatwork_emoticons {
    my ($self, $body) = @_;

    my $chatwork_emoticon_list = read_file(Path::Class::file( $ENV{'LAMBDA_TASK_ROOT'}, 'etc', 'chatwork_emoticon_list.txt'));
    my @chatwork_emoticon_map = split(/\r\n|\n/, $chatwork_emoticon_list);
    for my $emoticon (@chatwork_emoticon_map) {
        my $quotemeta_emoticon = quotemeta($emoticon);
        $quotemeta_emoticon = sprintf('(?!\[code\](\s+?)?(\S+?)?)%s(?!(\S+?)?(\s+?)?\[/code\])', $quotemeta_emoticon);
        my $emoticon_regex = qr/$quotemeta_emoticon/;
        # `:D` -> `:\D`
        # `(sweat)` -> `(\sweat)`
        my $replace_str = substr($emoticon, 0, 1) . '\\' . substr($emoticon, 1);
        $body =~ s/$emoticon_regex/$replace_str/gs;
    }
    return $body;
}

# 画像URLの抽出 for LGTM
sub find_upload_image_url {
    my ($self, $body) = @_;
    # ![text](https://cdn.perl.org/perlweb/images/icons/header_camel.png)
    # [![LGTM](https://lgtm.in/p/GTJNU0x9q)](https://lgtm.in/i/GTJNU0x9q)
    # ![LGTM](https://cdn.lgtmoon.dev/images/110629)
    if ($body =~ m{
                   (?:\[)?
                   \!                  # Images start with !
                   \[(\w+)\]           # link text
                   \(                  # Opening paren for url
                   (?:<?)(\S+?)(?:>?)  # The url
                   \).?
                   (?:\])?
                   (?:
                        \(
                            (?:<?)(\S+?)(?:>?)  # The link url
                        \)
                   )?
               }sgx) {
        if ($2) {
            push (@{$self->{_upload_image_text}}, $1);
            push (@{$self->{_upload_image_url}}, $2);
            push (@{$self->{_upload_image_link}}, $3);
            return 1;
        }
    } else {
        # not match.
    }
    return 0;
}

# 抽出画像URLのアップロード
sub upload_image_url_chatwork {
    my ($self, $target_chatwork_room_id) = @_;

    if (my $upload_image_url = shift @{$self->{_upload_image_url}}) {

        my $upload_image_text = shift @{$self->{_upload_image_text}};
        my $upload_image_link = shift @{$self->{_upload_image_link}};

        my (undef, $filename) = tempfile();
        my $upload_res = $self->chatwork_api->ua->get(
            $upload_image_url,
            ":content_file" => $filename,
        );
        if ($upload_res->is_success) {
            my $uri = $upload_res->request->uri;
            my $chatwork_filename = $self->filename_chatwork(basename($uri->as_string), $filename);
            move($filename, $chatwork_filename);

            $self->chatwork_api->upload($target_chatwork_room_id, $upload_image_url, $chatwork_filename);
            unlink $chatwork_filename;
        }
    }
}

# 拡張子の無い画像の場合、Chatwork用に拡張子を付与
sub filename_chatwork {
    my ($self, $chatwork_filename, $filename) = @_;
    if ($chatwork_filename !~ /\.(jpe?g|png|gif|ico|bmp)/i) {
        my $ft = File::Type->new;
        my $image_type =  $ft->mime_type($filename);
        $image_type =~ s/^image\///;
        $image_type = 'jpg' if $image_type =~ /(jpg|jpeg|pjpeg)/;
        $image_type = 'png' if $image_type =~ /x-png/;
        $chatwork_filename .= '.' . $image_type;
    }
    return $chatwork_filename;
}

# 本文の置換 for slack
sub body_filter_slack {
    my ($self, $body) = @_;

    # do something if you need to.
    #$body =~ s,,,sg;
    return $body;
}

# https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#create
sub on_create {
    my ($self, $payload) = @_;
    # do nothing.
    return;
}

# https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#commit_comment
sub on_commit_comment {
    my ($self, $payload, $opt) = @_;
    my ($to_user);
    # デフォルトの通知先が不明なため、@記法パースから宛先設定
    if (! $to_user || (ref $to_user eq 'ARRAY' && ! @{$to_user})) {
        $to_user = $self->parse_body_to_user($payload->{comment}->{body});
    }
    # @記法も無い場合、commit 元のユーザに通知したいところだが、
    # commit_comment は commit ユーザの情報が payload に無い模様なので誰にも通知しない…a

    # 通常のコメントでは、 `#commitcomment-数字` フォーマットになるが、
    # インラインコメント内の場合は、URLの末尾が `#r数字` になる模様。 おそらくGitHub 側のバグっぽい
    my $html_url = $payload->{comment}->{html_url};
    if (defined $payload->{comment}->{line}) {
        $html_url =~ s/#commitcomment-(\d+)/#r$1/;
    }

    my $text = sprintf("%s[info][title][commit_comment] %s[/title]From: %s\n%s \n%s [/info]",
                       $self->github_login_to_chatwork($to_user),
                       $payload->{comment}->{commit_id},
                       $payload->{comment}->{user}->{login},
                       $self->body_filter($payload->{comment}->{body}),
                       $html_url,
        );
    return $text;
}

# https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#deletea
sub on_delete {
    my ($self, $payload) = @_;
    # do nothing.
    return;
}

# https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#fork
sub on_fork {
    my ($self, $payload) = @_;
    # do nothing.
    return;
}

# https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#gollum
sub on_gollum {
    my ($self, $payload, $opt) = @_;
    my ($add_text);

    my $pages_array = $payload->{pages};
    my $pages = @{$pages_array}[0];

    my $action_text =
        $pages->{action} eq 'created' ? '作成' :
        $pages->{action} eq 'edited' ? '編集' :
        '';
    if ($action_text) {
        $add_text = sprintf('が %s されました。 : ', $action_text);
    }

    my $text;
    if ($opt->{slack}) {
        $text = sprintf("*[wiki] %s %s* \n>>>From: %s\n%s ",
                        $add_text,
                        $pages->{title},
                        $self->github_login_to_slack($payload->{sender}->{login}),
                        $pages->{html_url},
                    );
    } else {
        $text = sprintf("[info][title][wiki]%s %s[/title]From: %s \n%s [/info]",
                        $add_text,
                        $pages->{title},
                        $payload->{sender}->{login},
                        $pages->{html_url},
                    );
    }
    return $text;
}

# https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#member
sub on_member {
    my ($self, $payload) = @_;
    # do nothing.
    return;
}

# https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#team
sub on_team {
    my ($self, $payload) = @_;
    # do nothing.
    return;
}


# https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#push
sub on_push {
    my ($self, $payload) = @_;
    my $text = sprintf("[info][title][push] %s[/title]From: %s\n%s \n%s [/info]",
                       $payload->{repository}->{full_name},
                       $payload->{sender}->{login},
                       $payload->{head_commit}->{message},
                       $payload->{head_commit}->{url},
        );
    return $text;
}

# https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#issues
sub on_issues {
    my ($self, $payload, $opt) = @_;
    my ($to_user, $add_text);
    $to_user = $payload->{issue}->{assignees};
    if ($payload->{action} eq 'closed') {
        $add_text = 'がクローズされました。 : ';
    }

    my $text;
    if ($opt->{slack}) {
        $text = sprintf("%s\n *[issues] %s* \n>>>From: %s\n%s \n%s ",
                        $self->github_login_to_slack($to_user),
                        $payload->{issue}->{title},
                        $self->github_login_to_slack($payload->{issue}->{user}->{login}),
                        $self->body_filter_slack($payload->{issue}->{body}),
                        $payload->{issue}->{html_url},
                    );
    } else {
        $text = sprintf("%s[info][title][issues]%s %s[/title]From: %s\n%s \n%s [/info]",
                        $self->github_login_to_chatwork($to_user),
                        $add_text,
                        $payload->{issue}->{title},
                        $payload->{issue}->{user}->{login},
                        $self->body_filter($payload->{issue}->{body}),
                        $payload->{issue}->{html_url},
                    );
    }
    return $text;
}

# https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#issue_comment
sub on_issue_comment {
    my ($self, $payload, $opt) = @_;

    my ($to_user);

    # issueのアサイン者がいても、＠記法を最優先にしたいケースが多いはず
    $to_user = $self->parse_body_to_user($payload->{comment}->{body});

    # @記法が無い場合、アサイン者がいればそちらを優先
    if (! $to_user || (ref $to_user eq 'ARRAY' && ! @{$to_user})) {
        $to_user = $payload->{issue}->{assignees};
    }
    # @記法もアサイン者も無い場合、issue元のuserに通知
    if (! $to_user || (ref $to_user eq 'ARRAY' && ! @{$to_user})) {
        $to_user = $payload->{issue}->{user}->{login};
    }

    my $text;
    if ($opt->{slack}) {
        $text = sprintf("%s\n *[issue_comment] %s* \n>>>From: %s\n%s \n%s ",
                        $self->github_login_to_slack($to_user),
                        $payload->{issue}->{title},
                        $self->github_login_to_slack($payload->{comment}->{user}->{login}),
                        $self->body_filter_slack($payload->{comment}->{body}),
                        $payload->{comment}->{html_url},
        );
    } else {
        $text = sprintf("%s[info][title][issue_comment] %s[/title]From: %s\n%s \n%s [/info]",
                        $self->github_login_to_chatwork($to_user),
                        $payload->{issue}->{title},
                        $payload->{comment}->{user}->{login},
                        $self->body_filter($payload->{comment}->{body}),
                        $payload->{comment}->{html_url},
        );
    }
    return $text;
}

# https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#pull_request
sub on_pull_request {
    my ($self, $payload, $opt) = @_;
    my ($to_user, $add_text);
    if ($payload->{requested_reviewer}) {
        # when action "review_requested"
        $to_user = $payload->{requested_reviewer}->{login};
    }
    # アサインされた時
    if ($payload->{action} eq 'assigned' && $payload->{assignee}) {
        # when action "review_requested"
        $to_user = $payload->{assignee}->{login};
    }
    if ($payload->{action} eq 'closed' && $payload->{pull_request}->{merged_at}) {
        # マージされた時
        $to_user = $payload->{pull_request}->{user}->{login};
        $add_text = 'がマージされました。 : ';
    } elsif ($payload->{action} eq 'closed') {
        # マージせずにそのままクローズした時
        $to_user = $payload->{pull_request}->{user}->{login};
        $add_text = 'がクローズされました。 : ';
    }
    # 宛先が無い場合、@記法パースから宛先設定
    if (! $to_user) {
        $to_user = $self->parse_body_to_user($payload->{pull_request}->{body});
    }

    my $text;
    if ($opt->{slack}) {
        $text = sprintf("%s\n *[pull_request]%s %s* \n>>>From: %s\n%s %s \n%s ",
                        $self->github_login_to_slack($to_user),
                        $add_text,
                        $payload->{pull_request}->{title},
                        $self->github_login_to_slack($payload->{pull_request}->{user}->{login}),
                        $payload->{merged} eq 'true' ? '[merged]' : '',
                        $self->body_filter_slack($payload->{pull_request}->{body}),
                        $payload->{pull_request}->{html_url},
                    );
    } else {
        $text = sprintf("%s[info][title][pull_request]%s %s[/title]From: %s\n%s %s \n%s [/info]",
                        $self->github_login_to_chatwork($to_user),
                        $add_text,
                        $payload->{pull_request}->{title},
                        $payload->{pull_request}->{user}->{login},
                        $payload->{merged} eq 'true' ? '[merged]' : '',
                        $self->body_filter($payload->{pull_request}->{body}),
                        $payload->{pull_request}->{html_url},
                    );
    }
    return $text;
}

# https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#pull_request_review
sub on_pull_request_review {
    my ($self, $payload, $opt) = @_;
    my ($to_user, $add_text);
    $to_user = $payload->{pull_request}->{assignees};
    # アサイン者が無い場合、@記法パースから宛先設定
    if (! $to_user || (ref $to_user eq 'ARRAY' && ! @{$to_user})) {
        $to_user = $self->parse_body_to_user($payload->{review}->{body});
    }
    # @記法も無い場合、PR元のuserに通知
    if (! $to_user || (ref $to_user eq 'ARRAY' && ! @{$to_user})) {
        $to_user = $payload->{pull_request}->{user}->{login};
    }
    # when approved
    if ($payload->{review}->{state} eq 'approved') {
        $add_text = 'が承認されました。 : ';
    }

    my $text;
    if ($opt->{slack}) {
        $text = sprintf("%s\n *[pull_request_review] %s* \n>>>From: %s\n%s \n%s ",
                        $self->github_login_to_slack($to_user),
                        $payload->{pull_request}->{title},
                        $self->github_login_to_slack($payload->{review}->{user}->{login}),
                        $self->body_filter_slack($payload->{review}->{body}),
                        $payload->{review}->{html_url},
                    );
    } else {
        $text = sprintf("%s[info][title][pull_request_review]%s %s[/title]From: %s\n%s \n%s [/info]",
                        $self->github_login_to_chatwork($to_user),
                        $add_text,
                        $payload->{pull_request}->{title},
                        $payload->{review}->{user}->{login},
                        $self->body_filter($payload->{review}->{body}),
                        $payload->{review}->{html_url},
                    );
    }
    return $text;
}

# https://docs.github.com/en/free-pro-team@latest/developers/webhooks-and-events/webhook-events-and-payloads#pull_request_review_comment
sub on_pull_request_review_comment {
    my ($self, $payload, $opt) = @_;
    my ($to_user);
    $to_user = $payload->{pull_request}->{assignees};
    # アサイン者が無い場合、@記法パースから宛先設定
    if (! $to_user || (ref $to_user eq 'ARRAY' && ! @{$to_user})) {
        $to_user = $self->parse_body_to_user($payload->{comment}->{body});
    }
    # @記法も無い場合、PR元のuserに通知
    if (! $to_user || (ref $to_user eq 'ARRAY' && ! @{$to_user})) {
        # 自分自身にTOしても意味が無いので、コメント者とPR主が違う場合だけ宛先に入れる
        if ($payload->{comment}->{user}->{login} ne $payload->{pull_request}->{user}->{login}) {
            $to_user = $payload->{pull_request}->{user}->{login};
        }
    }

    my $text;
    if ($opt->{slack}) {
        $text = sprintf("%s\n *[pull_request_review_comment] %s* \n>>>From: %s\n%s \n%s ",
                        $self->github_login_to_slack($to_user),
                        $payload->{pull_request}->{title},
                        $self->github_login_to_slack($payload->{comment}->{user}->{login}),
                        $self->body_filter_slack($payload->{comment}->{body}),
                        $payload->{comment}->{html_url},
                    );
    } else {
        $text = sprintf("%s[info][title][pull_request_review_comment] %s[/title]From: %s\n%s \n%s [/info]",
                        $self->github_login_to_chatwork($to_user),
                        $payload->{pull_request}->{title},
                        $payload->{comment}->{user}->{login},
                        $self->body_filter($payload->{comment}->{body}),
                        $payload->{comment}->{html_url},
                    );
    }
    return $text;
}


sub is_notification_action {
    my ($self, $payload) = @_;
    # 以下のactionのみ通知
    if ($payload->{action} =~ /^(created|opened|submitted|review_requested|assigned|closed)$/) {
        return 1;
    }
    # wiki更新時はactionが存在しないが通知
    if ($payload->{pages}) {
        return 1;
    }
    warn sprintf("is_notification_action : skip [%s] ", $payload->{action}) if (config('debug'));
    return 0;
}

post '/*/payload' => sub {
    my ($self, $c) = @_;

    my $event_name = $c->req->header('X-GitHub-Event');

    my $payload = $self->github_payload($c);
    if (!$payload) {
        return [400,['Content-Type'=>'text/plain','Content-Length'=>11],['Bad Request']];
    }

    if (config('debug')) {
        warn sprintf('event_name[%s] action[%s] ', $event_name, $payload->{action});
        warn Dumper('payload', $payload);
        warn "\n\n";
    }
    my $method = sprintf('on_%s', $event_name);
    # 予め登録されたアクションではないか、もしくは通知対象のアクションではない場合は終了
    if (! $self->can($method) || ! $self->is_notification_action($payload)) {
        return [400,['Content-Type'=>'text/plain','Content-Length'=>11],['Bad Request']];
    }
    my $text = $self->$method($payload);
    warn "text : " . encode_utf8($text) if (config('debug'));

    return [204,['Content-Type'=>'text/plain','Content-Length'=>11],['No Content']] unless ($text);

    my $is_success = 0;
    if (config('enable_chatwork')) {
        if (my $target_chatwork_room_id = $self->repository_name_to_room_id($payload)) {
            my $response = $self->chatwork_api->post_message($target_chatwork_room_id, $text);
            $is_success = 1 if ($response->is_success);

            # LGTM画像をアップロードしたければ使用する
            if (config('enable_chatwork_upload')) {
                $self->upload_image_url_chatwork($target_chatwork_room_id);
            }
        }
    }

    if (config('enable_slack')) {
        my $slack_text = $self->$method($payload, { slack => 1 });
        warn "slack_text : " . encode_utf8($slack_text) if (config('debug'));;

        if (my $target_slack_channel_id = $self->repository_name_to_room_id($payload, { slack => 1 })) {
            my $slack_api = $self->slack_api;
            my $response_slack = $slack_api->chat->post_message(
                channel => $target_slack_channel_id,
                text => $slack_text,
            );
            warn Dumper('response_slack', $response_slack) if (config('debug'));;
            $is_success = 1 if ($response_slack);
        }
    }

    return $c->render_json({
         success  => $is_success,
    });
};

1;
