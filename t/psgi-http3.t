use strict;
use warnings;
use Test::More;

BEGIN {
    eval {
        require Future;
        require Future::AsyncAwait;
        require IO::Async::Loop;
        require PAGI::App::WrapPSGI;
        1;
    } or plan skip_all => 'PAGI::App::WrapPSGI, Future, and IO::Async are required';
}

use Net::Quiche;
use PAGI::Server::HTTP3;
use PAGI::Test::HTTP3Client;

my $cert = 't/fixtures/cert.crt';
my $key  = 't/fixtures/cert.key';
BAIL_OUT('bundled TLS fixtures are missing from t/fixtures')
    unless -f $cert && -f $key;

sub server_config {
    return Net::Quiche->config(
        certificate_chain => $cert,
        private_key => $key,
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
    );
}

my @seen;
my $psgi_app = sub {
    my ($env) = @_;
    local $/;
    my $body = readline $env->{'psgi.input'};
    $body = '' unless defined $body;
    push @seen, {
        method => $env->{REQUEST_METHOD},
        path => $env->{PATH_INFO},
        query => $env->{QUERY_STRING},
        protocol => $env->{SERVER_PROTOCOL},
        scheme => $env->{'psgi.url_scheme'},
        host => $env->{HTTP_HOST},
        content_type => $env->{CONTENT_TYPE},
        content_length => $env->{CONTENT_LENGTH},
        remote => $env->{REMOTE_ADDR},
        body => $body,
    };
    return [
        201,
        ['Content-Type' => 'application/octet-stream', 'X-PSGI' => 'yes'],
        [join('|', $env->{REQUEST_METHOD}, $env->{PATH_INFO}, $body)],
    ];
};

my $test = PAGI::Test::HTTP3Client->new(
    psgi_app => $psgi_app,
    server_config => server_config(),
);

my $get = $test->get('/from-psgi?hello=world');
is($get->status, 201, 'PSGI status crosses the HTTP/3 adapter');
is($get->body, 'GET|/from-psgi|', 'PSGI array body crosses HTTP/3');
is($get->header('content-type'), 'application/octet-stream',
    'PSGI response headers are normalized for HTTP/3');
is($get->header('x-psgi'), 'yes', 'PSGI custom response header is preserved');

my $post_body = "potato\0over-h3";
my $post = $test->post(
    '/submit?source=psgi',
    headers => [
        ['content-type', 'application/octet-stream'],
        ['content-length', length($post_body)],
    ],
    body => $post_body,
);
is($post->body, "POST|/submit|$post_body",
    'PSGI psgi.input preserves POST bytes including NUL');
is_deeply(
    $seen[1],
    {
        method => 'POST',
        path => '/submit',
        query => 'source=psgi',
        protocol => 'HTTP/3',
        scheme => 'https',
        host => $test->base_uri =~ s{\Ahttps://}{}r,
        content_type => 'application/octet-stream',
        content_length => length($post_body),
        remote => '127.0.0.1',
        body => $post_body,
    },
    'PSGI environment is built from the HTTP/3 PAGI scope',
);

eval {
    PAGI::Server::HTTP3->new(
        app => sub { Future->done },
        psgi_app => $psgi_app,
        config => server_config(),
    );
};
like($@, qr/exactly one of app or psgi_app/,
    'listener rejects ambiguous PAGI and PSGI applications');

$test->stop;
done_testing;
