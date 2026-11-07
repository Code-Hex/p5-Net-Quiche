use strict;
use warnings;
use Test::More;

BEGIN {
    eval {
        require Future;
        require Future::AsyncAwait;
        Future::AsyncAwait->import;
        1;
    } or plan skip_all => 'Future and Future::AsyncAwait are required';
}

use Net::Quiche;
use PAGI::Server::Protocol::HTTP3;

my $cert = 't/fixtures/cert.crt';
my $key  = 't/fixtures/cert.key';
BAIL_OUT('bundled TLS fixtures are missing from t/fixtures')
    unless -f $cert && -f $key;

my $client_address = ['127.0.0.1', 45_005];
my $server_address = ['127.0.0.1', 8_447];
my %transport = (
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
);

my $client = Net::Quiche::Connection->connect(
    config => Net::Quiche->config(%transport, verify_peer => 0),
    server_name => 'localhost',
    source_connection_id => 'conformance-client',
    local => $client_address,
    peer => $server_address,
);
my $server = Net::Quiche::Connection->accept(
    config => Net::Quiche->config(
        %transport, certificate_chain => $cert, private_key => $key,
    ),
    source_connection_id => 'conformance-server',
    local => $server_address,
    peer => $client_address,
);

sub pump {
    my ($from, $to) = @_;
    my $count = 0;
    while (my $datagram = $from->next_datagram) {
        $to->receive_datagram($datagram);
        die 'QUIC pump did not quiesce' if ++$count > 10_000;
    }
    return $count;
}

sub pump_both {
    my ($left, $right) = @_;
    for (1 .. 1_000) {
        return unless pump($left, $right) + pump($right, $left);
    }
    die 'QUIC handshake did not quiesce';
}

pump_both($client, $server);
ok($client->is_established && $server->is_established,
    'conformance QUIC pair establishes');

my ($scope, $connection_state, $started_after_send, $complete_after_send);
my (@clean_callbacks, @disconnect_callbacks, @errors);
my ($disconnect_state, $disconnect_future, $cancelled_observer, $disconnect_event);
my ($post_disconnect_send_done, @disconnect_order);

my $app = async sub {
    my ($current_scope, $receive, $send) = @_;
    if ($current_scope->{path} eq '/scope') {
        $scope = $current_scope;
        $connection_state = $scope->{'pagi.connection'};
        if ($connection_state) {
            $connection_state->on_disconnect(sub {
                push @clean_callbacks, 'disconnect';
            });
            $connection_state->on_complete(sub {
                push @clean_callbacks, 'complete';
            });
        }
        await $receive->();
        await $send->({
            type => 'http.response.start', status => 200,
            headers => [
                ['content-type', 'text/plain'],
                ['content-length', '2'],
                ['transfer-encoding', 'chunked'],
            ],
        });
        $started_after_send = $connection_state
            ? $connection_state->response_started : undef;
        await $send->({
            type => 'http.response.body', body => 'OK', more => 0,
        });
        $complete_after_send = $connection_state
            ? $connection_state->response_complete : undef;
        return;
    }

    if ($current_scope->{path} eq '/head') {
        await $receive->();
        await $send->({
            type => 'http.response.start', status => 200,
            headers => [
                ['content-type', 'text/plain'],
                ['content-length', '11'],
            ],
        });
        await $send->({
            type => 'http.response.body', body => 'hello world', more => 0,
        });
        return;
    }

    if ($current_scope->{path} eq '/disconnect') {
        $disconnect_state = $current_scope->{'pagi.connection'};
        if ($disconnect_state) {
            $disconnect_state->on_disconnect(sub {
                push @disconnect_order, "callback:$_[0]";
                push @disconnect_callbacks, $_[0];
            });
            $disconnect_state->on_complete(sub {
                push @disconnect_callbacks, 'complete';
            });
            $cancelled_observer = $disconnect_state->disconnect_future;
            $disconnect_future = $disconnect_state->disconnect_future;
            $cancelled_observer->cancel;
        }
        await $receive->();
        $disconnect_event = await $receive->();
        push @disconnect_order, 'receive:'
            . ($disconnect_state && !$disconnect_state->is_connected
                ? 'disconnected' : 'connected');
        my $send_future = $send->({
            type => 'http.response.start', status => 200, headers => [],
        });
        await $send_future;
        $post_disconnect_send_done = $send_future->is_done;
        return;
    }

    die "unexpected conformance path '$current_scope->{path}'";
};

my $protocol = PAGI::Server::Protocol::HTTP3->new(
    app => $app,
    connection => $server,
    client => $client_address,
    server => $server_address,
    on_error => sub { push @errors, $_[0] },
);
my $client_h3 = $client->http3;

my $scope_stream = $client_h3->send_request(
    headers => [
        [':method', 'GET'],
        [':scheme', 'https'],
        [':authority', 'localhost:8447'],
        [':path', '/scope?encoded=%2F'],
        ['cookie', 'a=1'],
        ['cookie', 'b=2'],
        ['x-opaque', "a\xffb"],
    ],
    final => 1,
);
pump($client, $server);
$protocol->drain_events;
pump($server, $client);

is($scope->{pagi}{version}, '0.5', 'scope advertises PAGI core 0.5');
is($scope->{pagi}{spec_version}, '0.5',
    'scope advertises the current HTTP sub-spec contract');
is($scope->{http_version}, '3', 'scope identifies HTTP/3');
is($scope->{query_string}, 'encoded=%2F', 'query string stays encoded bytes');
is_deeply($scope->{state}, {}, 'scope contains an isolated state hash');
is_deeply($scope->{extensions}, {},
    'scope does not advertise unimplemented TLS introspection');
is_deeply([grep { $_->[0] eq 'cookie' } @{$scope->{headers}}], [
    ['cookie', 'a=1; b=2'],
], 'scope combines Cookie fields into one lower-case byte header');
ok(!utf8::is_utf8((grep { $_->[0] eq 'x-opaque' } @{$scope->{headers}})[0][1]),
    'opaque request header value remains a byte string');

ok($connection_state, 'HTTP scope provides pagi.connection');
if ($connection_state) {
    can_ok($connection_state, qw(
        is_connected disconnect_reason on_disconnect response_started
        on_complete response_complete disconnect_future
    ));
    ok($started_after_send, 'response_started changes during response.start send');
    ok($complete_after_send, 'response_complete changes during terminal body send');
    ok(!$connection_state->is_connected,
        'cleanly completed request reaches a terminal state');
    is($connection_state->disconnect_reason, undef,
        'clean completion has no disconnect reason');
}
is_deeply(\@clean_callbacks, ['complete'],
    'clean request fires only its completion callback');

my $scope_headers = $client_h3->poll;
is_deeply($scope_headers->{headers}, [
    [':status', '200'],
    ['content-type', 'text/plain'],
    ['content-length', '2'],
], 'server ignores application Transfer-Encoding');
is($client_h3->poll->{body}, 'OK', 'ordinary GET response body is delivered');
is($client_h3->poll->{type}, 'finished', 'ordinary GET response is complete');
is($scope_stream, 0, 'scope conformance uses the first request stream');

my $head_stream = $client_h3->send_request(
    headers => [
        [':method', 'HEAD'],
        [':scheme', 'https'],
        [':authority', 'localhost:8447'],
        [':path', '/head'],
    ],
    final => 1,
);
pump($client, $server);
$protocol->drain_events;
pump($server, $client);
my @head_events;
push @head_events, $_ while $_ = $client_h3->poll;
is($head_events[0]{type}, 'headers', 'HEAD response carries headers');
is_deeply($head_events[0]{headers}, [
    [':status', '200'],
    ['content-type', 'text/plain'],
    ['content-length', '11'],
], 'HEAD preserves the GET-equivalent Content-Length');
is_deeply([map { $_->{type} } @head_events], ['headers', 'finished'],
    'HEAD suppresses response body bytes and closes the stream');
is($head_stream, 4, 'HEAD uses an independent HTTP/3 request stream');

my $disconnect_stream = $client_h3->send_request(
    headers => [
        [':method', 'POST'],
        [':scheme', 'https'],
        [':authority', 'localhost:8447'],
        [':path', '/disconnect'],
    ],
    final => 0,
);
pump($client, $server);
$protocol->drain_events;
$protocol->disconnect('server_shutdown');

ok($disconnect_state, 'disconnecting HTTP scope provides pagi.connection');
if ($disconnect_state) {
    ok(!$disconnect_state->is_connected,
        'disconnect updates synchronous state before resuming receive');
    is($disconnect_state->disconnect_reason, 'server_shutdown',
        'disconnect exposes a standard reason');
    ok($disconnect_future && $disconnect_future->is_done,
        'disconnect Future resolves on abnormal end');
    ok($cancelled_observer->is_cancelled,
        'one caller can cancel its disconnect observer');
    is(($disconnect_future->get)[0], 'server_shutdown',
        'cancelling one observer does not disarm another');
}
is_deeply(\@disconnect_callbacks, ['server_shutdown'],
    'abnormal request fires only its disconnect callback');
is_deeply(\@disconnect_order, [
    'callback:server_shutdown', 'receive:disconnected',
], 'state and callbacks update before pending receive resumes');
is_deeply($disconnect_event, {
    type => 'http.disconnect', reason => 'server_shutdown',
}, 'pending receive resolves with http.disconnect');
ok($post_disconnect_send_done,
    'send after disconnect resolves successfully as a no-op');
is($disconnect_stream, 8, 'disconnect state belongs to its request stream');

is_deeply(\@errors, [], 'conformance subset reports no protocol errors');

done_testing;
