use FindBin;
use lib "$FindBin::Bin/extlib/lib/perl5";
use lib "$FindBin::Bin/lib";
use File::Basename;
use Plack::Builder;
use Kossy::Request;
use GitHub::Webhook::Bot::Web;

my $root_dir = File::Basename::dirname(__FILE__);

my $app = GitHub::Webhook::Bot::Web->psgi($root_dir);
builder {
    enable "Plack::Middleware::Log::Minimal", autodump => 1;
    enable 'ReverseProxy';
    enable "Plack::Middleware::HubSignature",
        secret => 'please_set_signature_secret';
    $app;
};
