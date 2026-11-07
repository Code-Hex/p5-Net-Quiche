use strict;
use warnings;
use Test::More;

BEGIN {
    eval {
        require Future;
        require IO::Async::Loop;
        require IO::Async::Socket;
        require IO::Async::Timer::Countdown;
        require IO::Socket::IP;
        require PAGI::Server::HTTP3;
        1;
    } or plan skip_all => 'Future, IO::Async, and IO::Socket::IP are required';
}

use Net::Quiche;
use Socket qw(AF_INET6 inet_pton pack_sockaddr_in6);

my $probe = IO::Socket::IP->new(
    LocalHost => '::1', LocalPort => 0, Proto => 'udp',
);
plan skip_all => 'IPv6 loopback is not available' unless $probe;
$probe->close;

my $client_config = Net::Quiche->config(
    verify_peer => 0,
    initial_max_data => 1_000_000,
    initial_max_stream_data_bidi_local => 100_000,
    initial_max_stream_data_bidi_remote => 100_000,
    initial_max_stream_data_uni => 100_000,
    initial_max_streams_bidi => 10,
    initial_max_streams_uni => 10,
);
my $client = eval {
    Net::Quiche::Connection->connect(
        config => $client_config,
        server_name => 'localhost',
        source_connection_id => 'ipv6-client-id',
        local => ['0:0:0:0:0:0:0:1', 45_006],
        peer => ['0:0:0:0:0:0:0:1', 8_443],
    );
};
ok($client, 'connection accepts IPv6 address pairs')
    or diag($@ || 'connect() returned undef');

my $initial;
SKIP: {
    skip 'IPv6 connection was not created', 3 unless $client;
    my $datagram = $client->next_datagram;
    ok($datagram, 'IPv6 connection produces an Initial datagram');
    is_deeply($datagram->{from}, ['::1', 45_006],
        'outgoing IPv6 source address round-trips');
    is_deeply($datagram->{to}, ['::1', 8_443],
        'outgoing IPv6 peer address round-trips');
    $initial = $datagram->{data};
}

my $server = eval {
    PAGI::Server::HTTP3->new(
        app => sub { Future->done },
        config => Net::Quiche->config,
        host => '::1',
        port => 0,
    );
};
ok($server, 'PAGI listener accepts an IPv6 bind address')
    or diag($@ || 'listener constructor returned undef');

SKIP: {
    skip 'IPv6 listener was not created', 8 unless $server;
    my $loop = IO::Async::Loop->new;
    $loop->add($server);
    is($server->listen->get, $server,
        'IPv6 listen Future resolves to the server');
    cmp_ok($server->bound_port, '>', 0,
        'IPv6 UDP port zero selects a real local port');

    SKIP: {
        skip 'IPv6 Initial datagram was not produced', 5 unless defined $initial;
        substr($initial, 1, 4, pack('N', 0xface_b00c));
        my $request_header = Net::Quiche::Packet->header_info($initial);
        my $response;
        my $client_socket = IO::Async::Socket->new(
            recv_len => 65_535,
            recv_all => 1,
            on_recv => sub {
                (undef, $response) = @_;
                $loop->stop;
            },
            on_recv_error => sub {
                diag("IPv6 UDP receive failed: $_[1]");
                $loop->stop;
            },
        );
        $loop->add($client_socket);
        $client_socket->bind(
            host => '::1', service => 0, family => 'inet6', socktype => 'dgram',
        )->get;
        my $timeout = IO::Async::Timer::Countdown->new(
            delay => 2,
            on_expire => sub { $loop->stop },
        );
        $loop->add($timeout);
        $timeout->start;
        $client_socket->send(
            $initial, 0,
            pack_sockaddr_in6(
                $server->bound_port, inet_pton(AF_INET6, '::1')),
        );
        $loop->run;
        $timeout->stop if $timeout->is_running;
        $loop->remove($timeout);
        $loop->remove($client_socket);
        $client_socket->close;

        ok(defined $response,
            'IPv6 listener returns a Version Negotiation datagram');
        SKIP: {
            skip 'no IPv6 Version Negotiation response', 3
                unless defined $response;
            my $response_header = Net::Quiche::Packet->header_info($response);
            is($response_header->{version}, 0,
                'IPv6 listener response uses version zero');
            is($response_header->{destination_connection_id},
                $request_header->{source_connection_id},
                'IPv6 response targets the client source connection ID');
            is($response_header->{source_connection_id},
                $request_header->{destination_connection_id},
                'IPv6 response preserves the original destination ID');
        }
        is($server->connection_count, 0,
            'unsupported IPv6 packet does not allocate a connection');
    }

    $server->stop;
    is($server->bound_port, undef, 'IPv6 listener stops cleanly');
    $loop->remove($server);
}

done_testing;
