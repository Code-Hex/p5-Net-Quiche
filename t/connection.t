use strict;
use warnings;
use Test::More;
use Net::Quiche;

my $client_address = ['127.0.0.1', 44_444];
my $server_address = ['127.0.0.1', 8_443];

my $client_config = Net::Quiche->config(
    verify_peer                         => 0,
    initial_max_data                    => 1_000_000,
    initial_max_stream_data_bidi_local  => 100_000,
    initial_max_stream_data_bidi_remote => 100_000,
    initial_max_stream_data_uni         => 100_000,
    initial_max_streams_bidi            => 10,
    initial_max_streams_uni             => 10,
);

my $client = Net::Quiche::Connection->connect(
    config               => $client_config,
    server_name          => 'localhost',
    source_connection_id => 'client-source-id',
    local                => $client_address,
    peer                 => $server_address,
);

isa_ok($client, 'Net::Quiche::Connection');
ok(!$client->is_established, 'client starts handshaking');
ok(!$client->is_closed, 'new client is open');
is($client->source_connection_id, 'client-source-id', 'source ID is copied back');
ok(length($client->destination_connection_id) > 0, 'client has a destination ID');
cmp_ok($client->timeout_ms, '>=', 0, 'handshake exposes an event-loop timeout');
ok(!$client->shutdown_stream(
    0, direction => 'read', error_code => 0x10c,
), 'shutdown_stream reports an unopened stream as already done');
eval { $client->shutdown_stream(0, direction => 'sideways', error_code => 0) };
like($@, qr/direction must be 'read' or 'write'/,
    'shutdown_stream validates its direction before entering XS');
eval { $client->shutdown_stream(0, direction => 'read', error_code => -1) };
like($@, qr/error_code must be a non-negative integer/,
    'shutdown_stream validates its wire error code');

my $closing = Net::Quiche::Connection->connect(
    config               => $client_config,
    server_name          => 'localhost',
    source_connection_id => 'closing-client-id',
    local                => $client_address,
    peer                 => $server_address,
);
is($closing->close(
    application => 0, error_code => 0x100, reason => 'server shutdown',
), $closing, 'close is chainable');
is_deeply($closing->local_error, {
    application => !!0, code => 0x100, reason => 'server shutdown',
}, 'close copies the transport error into quiche');
eval { $closing->close(application => 2) };
like($@, qr/application must be 0 or 1/,
    'close validates the application flag before entering XS');
eval { $closing->close(reason => "wide \N{SNOWMAN}") };
like($@, qr/reason must be a byte string/,
    'close rejects a wide-character wire reason');

my $early_h3 = eval { $client->http3; 1 };
ok(!$early_h3, 'HTTP/3 cannot be created before the handshake');
like($@, qr/before the QUIC handshake is established/, 'early HTTP/3 error explains ordering');

my $initial = $client->next_datagram;
ok($initial, 'client produces an initial UDP datagram');
ok(length($initial->{data}) >= 1_200, 'QUIC Initial is padded');
is_deeply($initial->{from}, $client_address, 'outgoing datagram identifies local address');
is_deeply($initial->{to}, $server_address, 'outgoing datagram identifies peer address');

my @invalid = (
    [sub { Net::Quiche::Connection->connect(config => $client_config) }, qr/requires.*source_connection_id.*local.*peer/],
    [sub { Net::Quiche::Connection->connect(
        config => $client_config, source_connection_id => '',
        local => $client_address, peer => $server_address,
    ) }, qr/source_connection_id must contain 1 to 20 bytes/],
    [sub { Net::Quiche::Connection->connect(
        config => $client_config, source_connection_id => 'x' x 21,
        local => $client_address, peer => $server_address,
    ) }, qr/source_connection_id must contain 1 to 20 bytes/],
    [sub { Net::Quiche::Connection->connect(
        config => $client_config, source_connection_id => 'valid',
        local => ['not-an-ip', 1], peer => $server_address,
    ) }, qr/local host must be an IPv4 or IPv6 address/],
    [sub { Net::Quiche::Connection->connect(
        config => $client_config, source_connection_id => 'valid',
        local => ['fe80::1%lo0', 1], peer => $server_address,
    ) }, qr/local host must be an IPv4 or IPv6 address/],
    [sub { Net::Quiche::Connection->connect(
        config => $client_config, source_connection_id => 'valid',
        local => ['127.0.0.1', 70_000], peer => $server_address,
    ) }, qr/local port must be an integer from 0 to 65535/],
);

for my $case (@invalid) {
    my ($code, $message) = @$case;
    my $ok = eval { $code->(); 1 };
    ok(!$ok, 'invalid connection arguments are rejected');
    like($@, $message, 'connection error names the invalid argument');
}

done_testing;
