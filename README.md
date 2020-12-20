
# NAME

GitHub::Webhook::Bot - GitHubのwebhookをいい感じにSlackやChatworkに通知してくれる君

# DESCRIPTION

複数人でのチーム開発において、GitHubのプルリクエスト・レビュー・issue管理などをチャットツールでやり取りしやすくするPerl製WEBアプリケーションです。

詳しくは [PerlでGitHub webhookを受けるbotを作ってみた話](https://qiita.com/teckl/items/c3bff1419e06f2972949) で書いています。

## 必要な環境
- Slack or Chatwork
- Docker
- グローバルIP配下でリクエストを受けられるサーバ環境、もしくは[ngrok](https://ngrok.com/) など

## 初期設定

Slackのみでも使用可能です。Chatworkと共存させることもできます。

### `login_id_map.yml`

Slack/ChatworkのアカウントID、チャンネル一覧IDをyamlに設定します。
チャンネル内で個人宛に `@xxxx` したい場合は個人のIDを入れてください。

```
teckl:
  chatwork: 0000000
  slack: U0XXXXXXXX
foo:
  chatwork: 0000001
  slack: U0XXXXXXXB
bar:
  chatwork: 0000002
  slack: U0XXXXXXXC
```

### `repository_map.yml`

リポジトリ単位で通知したいチャンネルを設定します。
リポジトリ数・チャンネル数が少ない場合は `default` だけでも問題ありません。

```
default:
  chatwork : 000000000
  slack : DEFAULT_CHANNEL_ID
Plack:
  slack : C0XXXXXXX1
p5-GitHub-Webhook-Bot:
  chatwork : 000000001
  slack : C0XXXXXXX2
ojichat.pl:
  slack : C0XXXXXXX3
..
```

### `.env`

Slack/Chatworkのbotのトークンを `.env` ファイルに記述してください。

```
$ cd p5-GitHub-Webhook-Bot
$ cat .env
DEBUG=0
ENABLE_CHATWORK=0
ENABLE_SLACK=1
CHATWORK_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxx
SLACK_TOKEN=xoxb-xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
```

## 実行

```
$ cd p5-GitHub-Webhook-Bot
$ docker-compose up
```

## SEE ALSO

[PerlでGitHub webhookを受けるbotを作ってみた話](https://qiita.com/teckl/items/c3bff1419e06f2972949)

## License
MIT
