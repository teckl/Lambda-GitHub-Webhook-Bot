build: psgi.zip
psgi.zip: handler.pl cpanfile app.psgi lib/GitHub/Webhook/Bot/Web.pm etc/*
	docker run --rm -v $(PWD):/var/task shogo82148/p5-aws-lambda:build-5.32.al2 \
		cpanm --notest -L extlocal --installdeps .
	zip -r psgi.zip . -x '*.zip'

test:
	docker run --rm -v $(PWD):/var/task shogo82148/p5-aws-lambda:5.32.al2 \
		handler.handle '{"httpMethod": "POST", "path":"/lambda-perl-psgi-test/payload", "headers": {"Content-Type": "application/json"}, "headers": {"X-GitHub-Event": "pull_request"}, "body":"{\"action\":\"closed\", \"sample\":\"xxxx\"}"}'

clean:
	rm -f psgi.zip
	rm -rf local
	rm -rf extlocal

.PHONY: build test clean
