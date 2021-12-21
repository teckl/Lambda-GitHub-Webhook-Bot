
# NAME

AWS Lambda + API GatewayでGitHubのwebhookをいい感じにSlackやChatworkに通知してくれる君

# DESCRIPTION

[p5-GitHub-Webhook-Bot](https://github.com/teckl/p5-GitHub-Webhook-Bot) をAWS Lambdaでサーバレスに使えるようにしたサンプルコードです。

https://github.com/shogo82148/p5-aws-lambda のカスタムランタイムを利用させていただいております。

## 初期設定

詳しくは[AWS LambdaでCGIを蘇らせる](https://shogo82148.github.io/blog/2018/12/16/run-cgi-in-aws-lambda/) を参照ください。


### 環境変数について `.env`

SLACK_TOKENなどの環境変数は、 `.env` の代わりに各自のLambda側の環境変数で設定ください。

## SEE ALSO

[PerlでGitHub webhookを受けるbotを作ってみた話](https://qiita.com/teckl/items/c3bff1419e06f2972949)

## License
MIT
