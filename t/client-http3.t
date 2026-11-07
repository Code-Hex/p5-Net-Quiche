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
use Net::Quiche::HTTP3::Client;
use PAGI::Server::HTTP3;

my $cert = 't/fixtures/cert.crt';
my $key  = 't/fixtures/cert.key';
BAIL_OUT('bundled TLS fixtures are missing from t/fixtures')
    unless -f $cert && -f $key;

my %transport = (
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

my $app = async sub {
    my ($scope, $receive, $send) = @_;
    my $body = '';
    while (1) {
        my $event = await $receive->();
        last unless $event->{type} eq 'http.request';
        $body .= $event->{body} // '';
        last unless $event->{more};
    }

    my $response = $scope->{path} eq '/post' ? $body
        : $scope->{path} eq '/sink' ? length($body)
        : $scope->{path} eq '/stream' ? ('response-' x 4_000)
        : "$scope->{method}:$scope->{path}?$scope->{query_string}";
    await $send->({
        type => 'http.response.start', status => 200,
        headers => [
            ['content-type', 'application/octet-stream'],
            ['x-duplicate', 'one'],
            ['x-duplicate', 'two'],
        ],
    });
    if ($scope->{path} eq '/stream') {
        await $send->({
            type => 'http.response.body',
            body => substr($response, 0, 20_000), more => 1,
        });
        await $send->({
            type => 'http.response.body',
            body => substr($response, 20_000), more => 0,
        });
    } else {
        await $send->({
            type => 'http.response.body', body => $response, more => 0,
        });
    }
};

my $loop = IO::Async::Loop->new;
my $server = PAGI::Server::HTTP3->new(
    app => $app,
    config => Net::Quiche->config(
        %transport, certificate_chain => $cert, private_key => $key,
    ),
    host => '127.0.0.1', port => 0,
);
my $client = Net::Quiche::HTTP3::Client->new(
    config => Net::Quiche->config(%transport, verify_peer => 0),
    max_response_body => 1_000_000,
    response_buffer_limit => 16 * 1024,
);
$loop->add($server);
$loop->add($client);
$loop->await($server->listen)->get;
my $base = 'https://127.0.0.1:' . $server->bound_port;

my $get = $loop->await($client->get("$base/get?x=1"))->get;
isa_ok($get, 'Net::Quiche::HTTP3::Response');
is($get->status, 200, 'GET returns its status');
is($get->http_version, '3', 'response identifies HTTP/3');
is($get->body, 'GET:/get?x=1', 'GET returns a buffered body');
is($loop->await($get->slurp)->get, $get->body,
    'slurp is repeatable after a buffered request');
is_deeply($get->header_values('x-duplicate'), ['one', 'two'],
    'response preserves duplicate headers');
is($get->header('content-type'), 'application/octet-stream',
    'response offers a first-header convenience method');
ok($get->is_success, '2xx response is successful');

my $post_body = "alpha\0omega" x 2_000;
my $post = $loop->await($client->post(
    "$base/post",
    headers => [['content-type', 'application/octet-stream']],
    body => $post_body,
))->get;
is($post->body, $post_body, 'POST round-trips exact binary bytes');

my $sink = $client->start_request(
    method => 'POST', uri => "$base/sink", headers => [],
);
my $large_body = 'x' x 2_000_000;
my $large_write = $sink->write($large_body);
my $overlapping_write = $sink->write('must-not-be-queued');
ok($overlapping_write->is_failed,
    'streaming upload rejects an overlapping write');
like(($overlapping_write->failure)[0], qr/Only one pending write/,
    'overlapping write failure explains the sequential contract');
$loop->await($large_write)->get;
$loop->await($sink->finish_request)->get;
my $sink_response = $loop->await($sink->response)->get;
$loop->await($sink_response->slurp)->get;
is($sink_response->body, length($large_body),
    'large streaming upload retains all bytes through backpressure');

my $exchange = $client->start_request(
    method => 'POST', uri => "$base/stream",
    headers => [['content-type', 'application/octet-stream']],
);
isa_ok($exchange, 'Net::Quiche::HTTP3::Exchange');
$loop->await(
    $exchange->write('first-')->then(sub {
        return $exchange->write("second\0");
    })->then(sub {
        return $exchange->finish_request;
    })
)->get;
my $streaming_response = $loop->await($exchange->response)->get;
my $streamed = '';
while (1) {
    my $chunk = $loop->await($streaming_response->read)->get;
    last unless defined $chunk;
    $streamed .= $chunk;
}
is($streamed, 'response-' x 4_000,
    'streaming response read returns every byte');
ok($streaming_response->is_complete,
    'streaming response records terminal FINISHED');

my $limited_exchange = $client->start_request(
    method => 'GET', uri => "$base/stream", headers => [],
);
$loop->await($limited_exchange->finish_request)->get;
my $limited_response = $loop->await($limited_exchange->response)->get;
eval { $limited_response->body };
like($@, qr/available after slurp/,
    'streaming body is not exposed as a partially buffered scalar');
my $limited = $loop->await($limited_response->slurp(max_bytes => 1_000));
ok($limited->is_failed, 'slurp enforces its byte limit');
like(($limited->failure)[0], qr/exceeds 1000 bytes/,
    'body limit failure reports the configured bound');

my $one = $client->get("$base/one");
my $two = $client->get("$base/two");
my ($one_response, $two_response) =
    $loop->await(Future->needs_all($one, $two))->get;
is($one_response->body, 'GET:/one?',
    'first multiplexed response stays on its stream');
is($two_response->body, 'GET:/two?',
    'second multiplexed response stays on its stream');
is($client->connection_count, 1,
    'requests for one origin reuse one QUIC connection');
is($client->active_requests, 0,
    'completed requests release client exchange state');

eval { $client->get('http://127.0.0.1/plaintext') };
like($@, qr/only supports https URIs/,
    'invalid request arguments fail at the call site');
eval {
    $client->request(
        method => 'GET', uri => bless({}, 'StringifiesAsURI'),
    );
};
like($@, qr/uri must be a defined scalar/,
    'buffered request preserves the scalar-only URI contract');
my $dns_failure = $client->get('https://net-quiche-test.invalid/');
ok($dns_failure->is_failed,
    'DNS failure is returned through the request Future');
like(($dns_failure->failure)[0], qr/DNS resolution failed/,
    'DNS failure identifies the unresolved origin');

my $pending_at_stop = $client->get("$base/stopped");
$client->stop;
ok($pending_at_stop->is_failed,
    'stop fails a request that has not completed');
like(($pending_at_stop->failure)[0], qr/client stopped/,
    'stopped request reports its lifecycle failure');
eval { $client->get("$base/after-stop") };
like($@, qr/client has been stopped/,
    'stopped client rejects new requests at the call site');
$server->stop;
done_testing;
