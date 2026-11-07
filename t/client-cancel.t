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

my $loop = IO::Async::Loop->new;
my @server_errors;
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    while (1) {
        my $event = await $receive->();
        last unless $event->{type} eq 'http.request' && $event->{more};
    }
    await $loop->delay_future(after => 0.08)
        if $scope->{path} eq '/redirect-slow';
    await $loop->delay_future(after => 0.10)
        if $scope->{path} eq '/slow';
    if ($scope->{path} eq '/redirect-slow') {
        await $send->({
            type => 'http.response.start', status => 302,
            headers => [['location', '/slow']],
        });
        await $send->({
            type => 'http.response.body', body => 'moving', more => 0,
        });
        return;
    }
    await $send->({
        type => 'http.response.start', status => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body', body => $scope->{path}, more => 0,
    });
};

my $server = PAGI::Server::HTTP3->new(
    app => $app,
    config => Net::Quiche->config(
        %transport, certificate_chain => $cert, private_key => $key,
    ),
    host => '127.0.0.1', port => 0,
    on_error => sub { push @server_errors, "$_[0]" },
);
$loop->add($server);
$loop->await($server->listen)->get;
my $base = 'https://127.0.0.1:' . $server->bound_port;

my $pending_client = Net::Quiche::HTTP3::Client->new(
    config => Net::Quiche->config(%transport, verify_peer => 0),
);
$loop->add($pending_client);
my $pending = $pending_client->get("$base/pending");
$pending->cancel;
ok($pending->is_cancelled,
    'cancelling the buffered Future preserves Future cancellation state');
is($pending_client->active_requests, 0,
    'cancelling before a stream exists releases the pending exchange');
is($pending_client->connection_count, 0,
    'cancelling the only pre-handshake request tears down its origin');
$pending_client->stop;
$loop->remove($pending_client);

my $client = Net::Quiche::HTTP3::Client->new(
    config => Net::Quiche->config(%transport, verify_peer => 0),
    max_redirects => 2,
);
$loop->add($client);
my $prime = $loop->await($client->get("$base/ready"))->get;
is($prime->body, '/ready', 'the real HTTP/3 connection is established');

my $cancelled = $client->get("$base/slow");
$loop->await($loop->delay_future(after => 0.02))->get;
$cancelled->cancel;
ok($cancelled->is_cancelled, 'buffered request Future is cancellable');
is($client->active_requests, 0,
    'buffered cancellation releases request state immediately');
my $after_cancel = $loop->await($client->get("$base/after-cancel"))->get;
is($after_cancel->body, '/after-cancel',
    'another request succeeds after cancelling an active stream');
is($client->connection_count, 1,
    'active-stream cancellation preserves the reusable QUIC connection');

my $timed = $loop->await($client->get("$base/slow", timeout => 0.03));
ok($timed->is_failed, 'per-request timeout fails a slow request');
like(($timed->failure)[0], qr/timed out after 0\.03 seconds/,
    'per-request timeout reports its configured deadline');
is($client->active_requests, 0,
    'timed-out request releases its exchange state');

my $redirected = $loop->await($client->get(
    "$base/redirect-slow", timeout => 0.15,
));
ok($redirected->is_failed,
    'timeout deadline covers the complete redirect chain');
like(($redirected->failure)[0], qr/timed out after 0\.15 seconds/,
    'redirect timeout reports the logical request deadline');

my $exchange = $client->start_request(
    method => 'GET', uri => "$base/slow", headers => [],
);
my $response = $exchange->response;
$loop->await($exchange->finish_request)->get;
is($exchange->cancel, 1, 'streaming exchange can be cancelled explicitly');
is($exchange->cancel, 0, 'streaming cancellation is idempotent');
ok($response->is_failed, 'streaming cancellation fails the response Future');
like(($response->failure)[0], qr/request cancelled/,
    'streaming response reports cancellation');

my $stream_timeout = $client->start_request(
    method => 'GET', uri => "$base/slow", headers => [], timeout => 0.02,
);
my $stream_timeout_response = $stream_timeout->response;
$loop->await($stream_timeout->finish_request)->get;
$loop->await($stream_timeout_response);
ok($stream_timeout_response->is_failed,
    'streaming exchange accepts its own timeout');
like(($stream_timeout_response->failure)[0],
    qr/timed out after 0\.02 seconds/,
    'streaming timeout fails its response Future');

my $default_client = Net::Quiche::HTTP3::Client->new(
    config => Net::Quiche->config(%transport, verify_peer => 0),
    request_timeout => 0.02,
);
$loop->add($default_client);
my $default_timeout = $loop->await($default_client->get("$base/slow"));
ok($default_timeout->is_failed,
    'constructor request_timeout supplies the default deadline');
like(($default_timeout->failure)[0], qr/timed out after 0\.02 seconds/,
    'default timeout reports its configured value');
$default_client->stop;
$loop->remove($default_client);

for my $invalid (0, -1, 'soon', 'Inf', 'NaN', []) {
    eval {
        Net::Quiche::HTTP3::Client->new(
            config => Net::Quiche->config(%transport, verify_peer => 0),
            request_timeout => $invalid,
        );
    };
    like($@, qr/request_timeout must be a positive number/,
        'constructor rejects an invalid request timeout');
}
eval { $client->get("$base/invalid", timeout => 0) };
like($@, qr/timeout must be a positive number/,
    'request rejects a non-positive timeout at the call site');

my $final = $loop->await($client->get("$base/final"))->get;
is($final->body, '/final', 'connection remains usable after timeout and cancel');
is($client->active_requests, 0, 'no request state remains after recovery');

$client->stop;
$server->stop;
is_deeply(\@server_errors, [], 'request cancellation is not a server error');
done_testing;
