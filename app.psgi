use FindBin;
use lib "$ENV{'LAMBDA_TASK_ROOT'}/lib";
use File::Basename;
use Plack::Builder;
use Kossy::Request;
use GitHub::Webhook::Bot::Web;

my $root_dir = File::Basename::dirname(__FILE__);

my $app = GitHub::Webhook::Bot::Web->psgi($root_dir);
return builder {
    enable "Plack::Middleware::Log::Minimal", autodump => 1;
    enable 'ReverseProxy';
#    enable "Plack::Middleware::HubSignature",
#        secret => 'please_set_signature_secret';
    $app;
};
