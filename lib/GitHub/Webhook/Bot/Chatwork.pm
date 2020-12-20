package GitHub::Webhook::Bot::Chatwork;

use strict;
use warnings;
use utf8;

use Data::Dumper;
use File::Slurp;
use LWP::UserAgent;
use JSON;

our $base_url = "https://api.chatwork.com/v2/";

sub new {
    my $class = shift;
    my $token = shift;
    bless {
        token => $token,
    }, $class;
}

sub ua {
    my $self = shift;

    my $ua = LWP::UserAgent->new;
    $ua->default_header( "X-ChatWorkToken" => $self->{token} );
    return $ua;
}

sub retrieve_room_id {
    my $self    = shift;
    my $room_name = shift;

    my $url = URI->new_abs("rooms", $base_url );

    my $res = $self->ua->get($url);
    if ($res->is_success) {
        my @data = grep { $_->{name} eq $room_name } @{from_json $res->decoded_content};
        return $data[0]->{room_id} if defined $data[0];
    }
    return;
}

sub post_message {
    my $self    = shift;
    my $room_id = shift;
    my $body    = shift;

    my $uri = sprintf "rooms/%d/messages", $room_id;

    my $url = URI->new_abs( $uri, $base_url );

    $self->ua->post( $url, { body => $body } );
}

sub upload {
    my $self     = shift;
    my $room_id  = shift;
    my $body     = shift;
    my $filename = shift;

    my $uri = sprintf "rooms/%d/files", $room_id;

    my $url = URI->new_abs( $uri, $base_url );

    $self->ua->post( $url,
                     'Content-Type' => 'form-data',
                     Content => [
                         message => $body,
                         file => [ "$filename" ],
                     ]
                 );

}

1;
