use strict;
use warnings;
use Test::More;

BEGIN {
    eval {
        require Future;
        require IO::Async::Loop;
        require IO::Async::Socket;
        require IO::Async::Timer::Countdown;
        require PAGI::Server::HTTP3;
        1;
    } or plan skip_all => 'Future and IO::Async are required for listener tests';
}

use Net::Quiche;
use Socket qw(inet_aton pack_sockaddr_in);

my $cert = 't/fixtures/cert.crt';
my $key  = 't/fixtures/cert.key';
BAIL_OUT('bundled TLS fixtures are missing from t/fixtures')
    unless -f $cert && -f $key;

my $server = PAGI::Server::HTTP3->new(
    app => sub { Future->done },
    config => Net::Quiche->config(
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
    ),
    host => '127.0.0.1',
    port => 0,
);
my $loop = IO::Async::Loop->new;
$loop->add($server);
is($server->listen->get, $server, 'listen Future resolves to the server');
cmp_ok($server->bound_port, '>', 0, 'UDP port zero selects a real local port');
is($server->connection_count, 0, 'listener starts with no QUIC connections');
is($server->goaway->get, $server,
    'GOAWAY with no current connections resolves without stopping listener');

my $client_config = Net::Quiche->config(
    verify_peer => 0,
    initial_max_data => 1_000_000,
    initial_max_stream_data_bidi_local => 100_000,
    initial_max_stream_data_bidi_remote => 100_000,
    initial_max_stream_data_uni => 100_000,
    initial_max_streams_bidi => 10,
    initial_max_streams_uni => 10,
);
my $client = Net::Quiche::Connection->connect(
    config => $client_config,
    server_name => 'localhost',
    source_connection_id => 'version-client-id',
    local => ['127.0.0.1', 45_002],
    peer => ['127.0.0.1', $server->bound_port],
);
my $initial = $client->next_datagram->{data};
substr($initial, 1, 4, pack('N', 0xface_b00c));
my $request_header = Net::Quiche::Packet->header_info($initial);

my ($response, $timed_out);
my $client_socket = IO::Async::Socket->new(
    recv_len => 65_535,
    recv_all => 1,
    on_recv => sub {
        (undef, $response) = @_;
        $loop->stop;
    },
    on_recv_error => sub {
        diag("UDP client receive failed: $_[1]");
        $loop->stop;
    },
);
$loop->add($client_socket);
$client_socket->bind(
    host => '127.0.0.1', service => 0, family => 'inet', socktype => 'dgram',
)->get;
my $timeout = IO::Async::Timer::Countdown->new(
    delay => 2,
    on_expire => sub {
        $timed_out = 1;
        $loop->stop;
    },
);
$loop->add($timeout);
$timeout->start;
$client_socket->send(
    $initial, 0,
    pack_sockaddr_in($server->bound_port, inet_aton('127.0.0.1')),
);
$loop->run;
$timeout->stop if $timeout->is_running;
$loop->remove($timeout);
$loop->remove($client_socket);
$client_socket->close;

ok(defined $response, 'listener returns a version negotiation UDP datagram')
    or diag($timed_out ? 'timed out waiting for version negotiation' : 'no response');
if (defined $response) {
    my $response_header = Net::Quiche::Packet->header_info($response);
    is($response_header->{version}, 0,
        'listener response is a version negotiation packet');
    is($response_header->{destination_connection_id},
        $request_header->{source_connection_id},
        'listener response targets the client source connection ID');
    is($response_header->{source_connection_id},
        $request_header->{destination_connection_id},
        'listener response identifies the original destination connection ID');
}
is($server->connection_count, 0,
    'unsupported version does not allocate a QUIC connection');

$server->stop;
is($server->bound_port, undef, 'stop closes the UDP listener');
$loop->remove($server);

done_testing;
