use strict;
use warnings;
use Test::More;
use Net::Quiche;

my $cert = 't/fixtures/cert.crt';
my $key  = 't/fixtures/cert.key';

BAIL_OUT('bundled TLS fixtures are missing from t/fixtures')
    unless -f $cert && -f $key;

my $client_address = ['127.0.0.1', 44_445];
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
    server_name => 'localhost',
    source_connection_id => 'client-h3-source',
    local => $client_address,
    peer  => $server_address,
);

my $server = Net::Quiche::Connection->accept(
    config => Net::Quiche->config(
        transport_config(), certificate_chain => $cert, private_key => $key,
    ),
    source_connection_id              => 'server-h3-source',
    local => $server_address,
    peer  => $client_address,
);

sub pump_one_way {
    my ($from, $to) = @_;
    my $count = 0;
    while (my $datagram = $from->next_datagram) {
        $to->receive_datagram($datagram);
        $count++;
        die 'in-memory QUIC pump did not quiesce' if $count > 1_000;
    }
    return $count;
}

sub pump_both_ways {
    my ($left, $right) = @_;
    for (1 .. 1_000) {
        my $moved = pump_one_way($left, $right) + pump_one_way($right, $left);
        return if !$moved;
    }
    die 'in-memory QUIC handshake did not quiesce';
}

pump_both_ways($client, $server);
ok($client->is_established, 'client handshake completed');
ok($server->is_established, 'server handshake completed');
is($client->application_protocol, 'h3', 'client negotiated h3');
is($server->application_protocol, 'h3', 'server negotiated h3');

my $client_h3 = $client->http3;
my $server_h3 = $server->http3;
isa_ok($client_h3, 'Net::Quiche::HTTP3');
isa_ok($server_h3, 'Net::Quiche::HTTP3');
is($client->http3, $client_h3, 'connection returns its existing HTTP/3 session');

my $stream_id = $client_h3->send_request(
    headers => [
        [':method',    'GET'],
        [':scheme',    'https'],
        [':authority', 'localhost:8444'],
        [':path',      '/hello?name=perl'],
        ['cookie',     'a=1'],
        ['cookie',     'b=2'],
    ],
    final => 1,
);
is($stream_id, 0, 'first client request uses stream zero');
pump_both_ways($client, $server);

my $headers = $server_h3->poll;
is($headers->{type}, 'headers', 'server receives a headers event');
is($headers->{stream_id}, $stream_id, 'headers retain stream identity');
is_deeply($headers->{headers}[0], [':method', 'GET'], 'pseudo header bytes are preserved');
ok(!$headers->{more}, 'header event reports no following request frames');

my $finished = $server_h3->poll;
is($finished->{type}, 'finished', 'request completion is a separate event');
is($finished->{stream_id}, $stream_id, 'completion retains stream identity');
is($server_h3->poll, undef, 'poll returns undef when no H3 event is ready');

my $bad_response = eval {
    $server_h3->send_response($stream_id,
        status => 200, headers => [[':method', 'GET']],
    );
    1;
};
ok(!$bad_response, 'response pseudo-headers are rejected before entering XS');
like($@, qr/must not be a pseudo-header/, 'response header error names the rule');

is($server_h3->send_response($stream_id,
    status => 200,
    headers => [
        ['content-type', 'text/plain'],
        ['set-cookie', 'first=1'],
        ['set-cookie', 'second=2'],
    ],
), 1, 'response headers are accepted');
is($server_h3->send_body($stream_id, "Hello over H3\n", final => 1), 14,
    'response body reports accepted bytes');
pump_both_ways($server, $client);

my $response_headers = $client_h3->poll;
is($response_headers->{type}, 'headers', 'client receives response headers');
is_deeply($response_headers->{headers}, [
    [':status', '200'],
    ['content-type', 'text/plain'],
    ['set-cookie', 'first=1'],
    ['set-cookie', 'second=2'],
], 'response status and duplicate headers are preserved');

my $body = $client_h3->poll;
is($body->{type}, 'data', 'client receives response data');
is($body->{body}, "Hello over H3\n", 'response body remains bytes');
is($client_h3->poll->{type}, 'finished', 'client receives response completion');

eval { $server_h3->send_goaway(5) };
like($@, qr/quiche_h3_send_goaway\(\) failed/,
    'server rejects a GOAWAY ID that is not a request-stream boundary');
is($server_h3->send_goaway(4), 1,
    'server queues a GOAWAY cutoff on its control stream');
pump_both_ways($server, $client);
my $goaway = $client_h3->poll;
is_deeply($goaway, { type => 'goaway', id => 4 },
    'GOAWAY exposes its connection-wide cutoff instead of a request stream');
eval {
    $client_h3->send_request(
        headers => [
            [':method', 'GET'], [':scheme', 'https'],
            [':authority', 'localhost:8444'], [':path', '/too-late'],
        ],
        final => 1,
    );
};
like($@, qr/quiche_h3_send_request\(\) failed/,
    'quiche refuses a new request on a connection after GOAWAY');
eval { $server_h3->send_goaway(8) };
like($@, qr/quiche_h3_send_goaway\(\) failed/,
    'a later GOAWAY cannot increase its cutoff');

is($server->close(
    application => 1, error_code => 0x100, reason => 'graceful shutdown',
), $server, 'established server starts an HTTP/3 application close');
pump_both_ways($server, $client);
is_deeply($client->peer_error, {
    application => 1, code => 0x100, reason => 'graceful shutdown',
}, 'client observes H3_NO_ERROR and the copied close reason');
ok($client->is_draining || $client->is_closed,
    'peer enters draining or closed state after CONNECTION_CLOSE');

done_testing;
