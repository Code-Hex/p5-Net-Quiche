use strict;
use warnings;
use Test::More;

BEGIN {
    eval {
        require Future;
        require Future::AsyncAwait;
        Future::AsyncAwait->import;
        1;
    } or plan skip_all => 'Future and Future::AsyncAwait are required for PAGI tests';
}

use Net::Quiche;
use PAGI::Server::Protocol::HTTP3;

my $cert = 't/fixtures/cert.crt';
my $key  = 't/fixtures/cert.key';
BAIL_OUT('bundled TLS fixtures are missing from t/fixtures')
    unless -f $cert && -f $key;

my $client_address = ['127.0.0.1', 45_002];
my $server_address = ['127.0.0.1', 8_444];

sub transport_config {
    return (
        max_idle_timeout                     => 10_000,
        max_recv_udp_payload_size            => 1_350,
        max_send_udp_payload_size            => 1_350,
        initial_max_data                     => 10_000_000,
        initial_max_stream_data_bidi_local   => 1_000_000,
        initial_max_stream_data_bidi_remote  => 1_000_000,
        initial_max_stream_data_uni          => 1_000_000,
        initial_max_streams_bidi             => 100,
        initial_max_streams_uni              => 100,
        disable_active_migration             => 1,
    );
}

my $client = Net::Quiche::Connection->connect(
    config => Net::Quiche->config(transport_config(), verify_peer => 0),
    server_name => 'localhost', source_connection_id => 'pagi-client-source',
    local => $client_address, peer => $server_address,
);
my $server = Net::Quiche::Connection->accept(
    config => Net::Quiche->config(
        transport_config(), certificate_chain => $cert, private_key => $key,
    ),
    source_connection_id => 'pagi-server-source',
    local => $server_address, peer => $client_address,
);

sub pump {
    my ($from, $to) = @_;
    my $count = 0;
    while (my $datagram = $from->next_datagram) {
        $to->receive_datagram($datagram);
        die 'QUIC pump did not quiesce' if ++$count > 1_000;
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
ok($server->is_established, 'server transport is established');

my ($seen_scope, @request_events);
my ($app_calls, @protocol_errors);
my $release_app = Future->new;
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    $app_calls++;
    $seen_scope = $scope;
    push @request_events, await $receive->();
    await $send->({
        type => 'http.response.start', status => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body', body => "Hello from PAGI over HTTP/3\n",
        more => 0,
    });
    await $release_app;
};

my $writes = 0;
my $protocol = PAGI::Server::Protocol::HTTP3->new(
    app => $app, connection => $server,
    client => $client_address, server => $server_address,
    on_write => sub { $writes++ },
    on_error => sub { push @protocol_errors, $_[0] },
);
my $client_h3 = $client->http3;
my $stream_id = $client_h3->send_request(
    headers => [
        [':method', 'GET'], [':scheme', 'https'],
        [':authority', 'localhost:8444'],
        [':path', '/hello%20world?name=perl'],
        ['cookie', 'a=1'], ['cookie', 'b=2'],
        ['user-agent', 'Net-Quiche-test'],
    ],
    final => 1,
);
pump($client, $server);
$protocol->drain_events;

my %scope_fields = %{$seen_scope};
my $scope_connection = delete $scope_fields{'pagi.connection'};
is_deeply(\%scope_fields, {
    type => 'http',
    pagi => { version => '0.5', spec_version => '0.5' },
    http_version => '3', method => 'GET', scheme => 'https',
    path => '/hello world', raw_path => '/hello%20world',
    query_string => 'name=perl', root_path => '',
    headers => [
        ['host', 'localhost:8444'],
        ['user-agent', 'Net-Quiche-test'],
        ['cookie', 'a=1; b=2'],
    ],
    client => $client_address, server => $server_address,
    state => {}, extensions => {},
}, 'HTTP/3 pseudo-headers become one PAGI request scope');
isa_ok($scope_connection, 'PAGI::Server::HTTP3::ConnectionState',
    'scope has per-request connection state');
is_deeply(\@request_events, [
    { type => 'http.request', body => '', more => 0 },
], 'bodyless GET produces one terminal PAGI request event');
cmp_ok($writes, '>=', 2, 'PAGI sends notify the UDP owner to flush transport');
is($protocol->active_streams, 1,
    'stream stays owned while the PAGI application Future is pending');
is($protocol->next_request_stream_id, 4,
    'protocol records the cutoff after the first accepted request stream');

pump($server, $client);
my $response_headers = $client_h3->poll;
is($response_headers->{stream_id}, $stream_id, 'response stays on request stream');
is_deeply($response_headers->{headers}, [
    [':status', '200'], ['content-type', 'text/plain'],
], 'PAGI response start becomes HTTP/3 headers');
is($client_h3->poll->{body}, "Hello from PAGI over HTTP/3\n",
    'PAGI response body crosses HTTP/3');
is($client_h3->poll->{type}, 'finished', 'PAGI terminal body closes the stream');
$release_app->done;
is($protocol->active_streams, 0,
    'stream is released after request, response, and application complete');

my $bad_stream_id = $client_h3->send_request(
    headers => [
        [':scheme', 'https'],
        [':authority', 'localhost:8444'],
        [':path', '/missing-method'],
    ],
    final => 1,
);
pump($client, $server);
$protocol->drain_events;
pump($server, $client);

my $bad_headers = $client_h3->poll;
is_deeply($bad_headers->{headers}, [
    [':status', '400'],
    ['content-type', 'text/plain'],
    ['content-length', '12'],
], 'an invalid request receives the queued error response headers');
is($client_h3->poll->{body}, "Bad Request\n",
    'the queued error response body reaches the client');
is($client_h3->poll->{type}, 'finished',
    'the queued error response closes the stream');
is($app_calls, 1, 'invalid request does not invoke the PAGI application');
like($protocol_errors[-1], qr/Missing HTTP\/3 pseudo-header ':method'/,
    'invalid request reports the scope validation error');
is($protocol->active_streams, 0,
    'internal error response state is released after completion');
is($bad_stream_id, 4, 'error response uses the second request stream');
is($protocol->next_request_stream_id, 8,
    'invalid handled requests also advance the final GOAWAY cutoff');

done_testing;
