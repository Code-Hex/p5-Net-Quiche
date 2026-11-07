use strict;
use warnings;
use Test::More;

BEGIN {
    eval {
        require Future;
        require Future::AsyncAwait;
        Future::AsyncAwait->import;
        require IO::Async::Loop;
        1;
    } or plan skip_all => 'Future::AsyncAwait and IO::Async are required';
}

use Net::Quiche;
use PAGI::Test::HTTP3Client;

my $cert = 't/fixtures/cert.crt';
my $key  = 't/fixtures/cert.key';
BAIL_OUT('bundled TLS fixtures are missing from t/fixtures')
    unless -f $cert && -f $key;

my ($seen_scope, $seen_body, $test);
my @errors;
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    $seen_scope = $scope;
    my $body = '';
    while (1) {
        my $event = await $receive->();
        last unless $event->{type} eq 'http.request';
        $body .= $event->{body} // '';
        last unless $event->{more};
    }
    $seen_body = $body;
    await $test->{loop}->delay_future(after => 0.08)
        if $scope->{path} eq '/slow';
    if ($scope->{path} eq '/redirect') {
        await $send->({
            type => 'http.response.start', status => 302,
            headers => [['location', '/redirected']],
        });
        await $send->({
            type => 'http.response.body', body => 'moving', more => 0,
        });
        return;
    }
    await $send->({
        type => 'http.response.start', status => 201,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => "$scope->{method} $scope->{path} $body", more => 0,
    });
};

$test = PAGI::Test::HTTP3Client->new(
    app => $app,
    server_config => Net::Quiche->config(
        certificate_chain => $cert,
        private_key => $key,
        max_idle_timeout => 10_000,
        max_recv_udp_payload_size => 1_350,
        max_send_udp_payload_size => 1_350,
        initial_max_data => 1_000_000,
        initial_max_stream_data_bidi_local => 1_000_000,
        initial_max_stream_data_bidi_remote => 1_000_000,
        initial_max_stream_data_uni => 1_000_000,
        initial_max_streams_bidi => 100,
        initial_max_streams_uni => 100,
        disable_active_migration => 1,
    ),
    request_timeout => 0.03,
    on_error => sub { push @errors, "$_[0]" },
);

my $response = $test->post(
    '/submit?source=test',
    headers => [['content-type', 'text/plain']],
    body => 'potato',
    timeout => 1,
);
isa_ok($response, 'Net::Quiche::HTTP3::Response');
is($response->status, 201, 'test client returns the application status');
is($response->body, 'POST /submit potato',
    'test client drives a PAGI request and response');
is($seen_scope->{http_version}, '3', 'test app runs through the HTTP/3 adapter');
is($seen_scope->{query_string}, 'source=test',
    'test client preserves the query string');
is($seen_body, 'potato', 'test app receives its POST body');
my $redirected = $test->get(
    '/redirect', max_redirects => 1, timeout => 1,
);
is($redirected->body, 'GET /redirected ',
    'test client forwards redirect policy to the HTTP/3 client');
like($test->base_uri, qr{\Ahttps://127\.0\.0\.1:[0-9]+\z},
    'test client exposes its bound origin');
eval { $test->get('/slow') };
like($@, qr/timed out after 0\.03 seconds/,
    'test client forwards its constructor request timeout');
is_deeply(\@errors, [], 'test-client timeout is an ordinary disconnect');

$test->stop;
done_testing;
