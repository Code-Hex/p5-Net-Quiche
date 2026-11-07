use strict;
use warnings;
use Test::More;
use Config ();
use File::Spec ();

BEGIN {
    eval {
        require Future;
        require IO::Async::Loop;
        require PAGI::Server::HTTP3;
        1;
    } or plan skip_all => 'Future and IO::Async are required for curl integration';
}

use Net::Quiche;

my $curl = $ENV{NET_QUICHE_CURL} // do {
    my @candidates = map { File::Spec->catfile($_, 'curl') } File::Spec->path;
    (grep { -f $_ && -x $_ } @candidates)[0] // '';
};
my $host = $ENV{NET_QUICHE_TEST_HOST} // '127.0.0.1';
my $url_host = index($host, ':') >= 0 ? "[$host]" : $host;
plan skip_all => 'an HTTP/3 curl is not available' unless -x $curl;
open my $curl_version, '-|', $curl, '--version'
    or plan skip_all => 'curl version could not be inspected';
my $features = do { local $/; <$curl_version> };
close $curl_version;
plan skip_all => 'curl was built without HTTP/3' unless $features =~ /^Features:.*\bHTTP3\b/m;

my $cert = 't/fixtures/cert.crt';
my $key  = 't/fixtures/cert.key';
BAIL_OUT('bundled TLS fixtures are missing from t/fixtures')
    unless -f $cert && -f $key;
plan skip_all => 'fork is required for curl integration' unless $Config::Config{d_fork};

pipe my $port_reader, my $port_writer or die "pipe failed: $!";
my $pid = fork;
die "fork failed: $!" unless defined $pid;

if ($pid == 0) {
    close $port_reader;
    my $loop = IO::Async::Loop->new;
    my $app = sub {
        my ($scope, $receive, $send) = @_;
        my $body = '';
        my $read_body;
        $read_body = sub {
            return $receive->()->then(sub {
                my ($event) = @_;
                return Future->done if $event->{type} ne 'http.request';
                $body .= $event->{body} // '';
                return $event->{more} ? $read_body->() : Future->done;
            });
        };
        return $read_body->()->then(sub {
            return $send->({
                type => 'http.response.start', status => 200,
                headers => [['content-type', 'text/plain']],
            });
        })->then(sub {
            return $send->({
                type => 'http.response.body',
                body => "Hello from PAGI over HTTP/3\n"
                    . "scope-client=$scope->{client}[0]\n"
                    . "scope-server=$scope->{server}[0]\n"
                    . "request-method=$scope->{method}\n"
                    . 'request-body-length=' . length($body) . "\n"
                    . (length($body) ? "request-body=$body\n" : ''),
                more => 0,
            });
        });
    };
    my $server = eval {
        PAGI::Server::HTTP3->new(
            app => $app,
            config => Net::Quiche->config(
                certificate_chain => $cert, private_key => $key,
                max_idle_timeout => 10_000,
                max_recv_udp_payload_size => 1_350,
                max_send_udp_payload_size => 1_350,
                initial_max_data => 10_000_000,
                initial_max_stream_data_bidi_local => 1_000_000,
                initial_max_stream_data_bidi_remote => 1_000_000,
                initial_max_stream_data_uni => 1_000_000,
                initial_max_streams_bidi => 100,
                initial_max_streams_uni => 100,
                disable_active_migration => 1,
            ),
            host => $host, port => 0,
        );
    };
    if (!$server) {
        print {$port_writer} "ERROR:$@\n";
        close $port_writer;
        exit 1;
    }
    $loop->add($server);
    my $started = eval { $server->listen->get; 1 };
    if (!$started) {
        print {$port_writer} "ERROR:$@\n";
        close $port_writer;
        exit 1;
    }
    print {$port_writer} $server->bound_port, "\n";
    close $port_writer;
    $SIG{TERM} = sub {
        $server->stop;
        $loop->stop;
    };
    $loop->run;
    exit 0;
}

close $port_writer;
my $port;
eval {
    local $SIG{ALRM} = sub { die "server startup timed out\n" };
    alarm 5;
    $port = <$port_reader>;
    alarm 0;
    1;
} or do {
    my $error = $@;
    kill 'TERM', $pid;
    waitpid $pid, 0;
    die $error;
};
close $port_reader;
chomp $port if defined $port;
if (!defined($port) || $port !~ /\A[0-9]+\z/) {
    kill 'TERM', $pid;
    waitpid $pid, 0;
    die "HTTP/3 child failed to start: " . ($port // 'no status') . "\n";
}

sub curl_request {
    my (@arguments) = @_;
    open my $curl_output, '-|', $curl,
        '-k', '--http3-only', '--connect-timeout', '5', '--max-time', '10',
        '--noproxy', '*',
        '--silent', '--show-error',
        '--write-out', "http-version=%{http_version}\nstatus=%{response_code}\n",
        @arguments,
        "https://$url_host:$port/"
        or die "cannot execute curl: $!";
    my $output = do { local $/; <$curl_output> };
    close $curl_output;
    return ($? >> 8, $output);
}

my ($curl_status, $output) = curl_request();
my $post_body = 'post-body-' x 2_000;
my $post_length = length $post_body;
my ($post_status, $post_output) = curl_request(
    '--request', 'POST',
    '--header', 'content-type: application/octet-stream',
    '--data-binary', $post_body,
);

kill 'TERM', $pid;
waitpid $pid, 0;

is($curl_status, 0, 'curl --http3-only completes successfully');
like($output, qr/\AHello from PAGI over HTTP\/3\n/, 'curl receives the PAGI body');
like($output, qr/^scope-client=\Q$host\E$/m,
    'PAGI scope contains the client IP address');
like($output, qr/^scope-server=\Q$host\E$/m,
    'PAGI scope contains the server IP address');
like($output, qr/^http-version=3$/m, 'curl negotiated HTTP/3');
like($output, qr/^status=200$/m, 'curl receives status 200');
like($output, qr/^request-method=GET$/m, 'curl GET reaches the PAGI scope');
like($output, qr/^request-body-length=0$/m, 'bodyless curl GET terminates cleanly');

is($post_status, 0, 'curl HTTP/3 POST completes successfully');
like($post_output, qr/^request-method=POST$/m,
    'curl POST reaches the PAGI scope');
like($post_output, qr/^request-body-length=\Q$post_length\E$/m,
    'PAGI app receives the complete curl POST body length');
like($post_output, qr/^request-body=\Q$post_body\E$/m,
    'PAGI app receives and echoes the exact curl POST bytes');
like($post_output, qr/^http-version=3$/m, 'curl POST negotiated HTTP/3');
like($post_output, qr/^status=200$/m, 'curl POST receives status 200');

done_testing;
