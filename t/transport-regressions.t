use strict;
use warnings;
use Test::More;
use File::Copy qw(copy);
use File::Spec;
use File::Temp qw(tempdir);
use Socket qw(pack_sockaddr_in inet_aton);
use Net::Quiche;

my $cert = 't/fixtures/cert.crt';
my $key  = 't/fixtures/cert.key';
BAIL_OUT('bundled TLS fixtures are missing from t/fixtures')
    unless -f $cert && -f $key;

my $client_address = ['127.0.0.1', 44_501];
my $server_address = ['127.0.0.1', 8_501];

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
    die 'QUIC exchange did not quiesce';
}

sub connected_pair {
    my ($tag) = @_;
    my $client = Net::Quiche::Connection->connect(
        config => Net::Quiche->config(transport_config(), verify_peer => 0),
        server_name => 'localhost', source_connection_id => "$tag-client",
        local => $client_address, peer => $server_address,
    );
    my $server = Net::Quiche::Connection->accept(
        config => Net::Quiche->config(
            transport_config(), certificate_chain => $cert, private_key => $key,
        ),
        source_connection_id => "$tag-server",
        local => $server_address, peer => $client_address,
    );
    is($client->timeout_ms, undef,
        "$tag: no timer is armed before the first flight");
    pump_both($client, $server);
    ok($server->is_established, "$tag: handshake completed");
    my $timeout = $client->timeout_ms;
    ok(defined($timeout) && $timeout < 3_600_000,
        "$tag: an established connection reports a real timer");
    return ($client, $server);
}

sub request_headers {
    return [
        [':method', 'POST'], [':scheme', 'https'],
        [':authority', 'localhost'], [':path', '/'],
    ];
}

subtest 'http3() rejects creating a second session and holds no back-reference' => sub {
    my ($client, $server) = connected_pair('reuse');
    my $client_h3 = $client->http3;
    my $server_h3 = $server->http3;
    ok(!exists($server->{_http3}) && !exists($server->{_http3_session}),
        'connection does not cache HTTP/3 objects');
    my $second_ok = eval { $server->http3; 1 };
    ok(!$second_ok, 'second http3() call on the same connection croaks');
    like($@, qr/already been created/, 'duplicate http3() call fails clearly');

    my $stream_id = $client_h3->send_request(
        headers => request_headers(), final => 1);
    pump_both($client, $server);
    my $event = $server_h3->poll;
    is($event->{type}, 'headers', 'the single session sees the request');
    $server_h3->send_response($stream_id, status => 204, final => 1);
    pump_both($client, $server);
    ok(!$client->is_closed, 'the peer did not close the connection');
    ok(!defined($client->peer_error), 'no HTTP/3 stream creation error');
    my $response = $client_h3->poll;
    is($response->{type}, 'headers', 'the client receives the response');
};

subtest 'poll() survives a stream reset in the middle of a body' => sub {
    my ($client, $server) = connected_pair('reset');
    my $client_h3 = $client->http3;
    my $server_h3 = $server->http3;
    my $stream_id = $client_h3->send_request(
        headers => request_headers(), final => 0);
    $client_h3->send_body($stream_id, 'x' x 20_000, final => 0);
    pump_both($client, $server);

    my $headers = $server_h3->poll;
    is($headers->{type}, 'headers', 'headers arrive first');
    my $data = $server_h3->poll;
    is($data->{type}, 'data', 'a body chunk arrives');
    ok(length($data->{body}) < 20_000, 'the body is read in bounded chunks');

    $client->shutdown_stream($stream_id,
        direction => 'write', error_code => 0x10c);
    pump_both($client, $server);

    my $event = eval { $server_h3->poll };
    is($@, '', 'poll does not die after the peer resets the stream');
    is_deeply($event, { type => 'reset', stream_id => $stream_id },
        'the reset is reported for that stream');

    my $other = $client_h3->send_request(
        headers => request_headers(), final => 1);
    pump_both($client, $server);
    my @types;
    while (my $next = $server_h3->poll) {
        push @types, "$next->{type}:" . ($next->{stream_id} // '');
    }
    ok((grep { $_ eq "headers:$other" } @types),
        'later polls reach other streams') or diag explain \@types;
};

subtest 'poll(read_body => 0) leaves the body in quiche' => sub {
    my ($client, $server) = connected_pair('manual');
    my $client_h3 = $client->http3;
    my $server_h3 = $server->http3;
    my $stream_id = $client_h3->send_request(
        headers => request_headers(), final => 0);
    $client_h3->send_body($stream_id, 'abc', final => 1);
    pump_both($client, $server);

    is($server_h3->poll(read_body => 0)->{type}, 'headers', 'headers');
    is_deeply($server_h3->poll(read_body => 0),
        { type => 'data', stream_id => $stream_id },
        'a data event carries no body');
    is($server_h3->poll(read_body => 0), undef,
        'finished is held back while the body is unread');
    is($server_h3->recv_body($stream_id, 2), 'ab', 'recv_body honours max_bytes');
    is($server_h3->recv_body($stream_id), 'c', 'recv_body returns the rest');
    is($server_h3->recv_body($stream_id), undef, 'then reports no more data');
    is_deeply($server_h3->poll(read_body => 0),
        { type => 'finished', stream_id => $stream_id },
        'finished follows once the body has been read');
    eval { $server_h3->recv_body($stream_id, 0) };
    like($@, qr/max_bytes must be a positive integer/, 'max_bytes is validated');
};

subtest 'error codes are limited to QUIC varints' => sub {
    my ($client) = connected_pair('varint');
    eval { $client->close(application => 1, error_code => 2**62) };
    like($@, qr/error_code must be an integer from 0 to 2\^62-1/,
        'close rejects an error code that would abort inside quiche');
    eval { $client->close(application => 1, error_code => '99999999999999999999') };
    like($@, qr/error_code must be an integer from 0 to 2\^62-1/,
        'close rejects a huge decimal string');
    ok($client->close(application => 1,
        error_code => 4_611_686_018_427_387_903), 'the largest varint is accepted');
};

subtest 'native socket addresses are validated' => sub {
    my $client = Net::Quiche::Connection->connect(
        config => Net::Quiche->config(transport_config(), verify_peer => 0),
        server_name => 'localhost', source_connection_id => 'addr-client',
        local => $client_address, peer => $server_address,
    );
    my $good = pack_sockaddr_in(443, inet_aton('127.0.0.1'));
    my $unix_family = pack('S', 1) . ("\0" x (length($good) - 2));
    for my $case (
        ['short', substr($good, 0, 4)],
        ['unknown family', $unix_family],
        ['IPv4 with trailing bytes', $good . "\0" x 8],
    ) {
        my ($label, $packed) = @$case;
        eval {
            Net::Quiche::XS::_connection_receive(
                $client->_native, 'x' x 1200, $packed, $good);
        };
        like($@, qr/Invalid packed from socket address/,
            "$label address croaks instead of reaching quiche");
    }
};

subtest 'certificate paths are passed as bytes' => sub {
    my $directory = tempdir(CLEANUP => 1);
    # A UTF-8 encoded byte string, as readdir() or @ARGV would return it.
    my $path = File::Spec->catfile($directory, "cert-\xC3\xA9.crt");
    copy($cert, $path) or plan skip_all => "cannot create a UTF-8 file name: $!";
    my $config = Net::Quiche::Config->new;
    ok(eval { $config->load_cert_chain($path); 1 },
        'UTF-8 encoded bytes reach quiche unchanged') or diag $@;

    eval { $config->load_cert_chain(
        File::Spec->catfile($directory, "cert-\xE9.crt")) };
    like($@, qr/path must be UTF-8 encoded bytes/,
        'a non-UTF-8 byte path croaks instead of aborting inside quiche');
    eval { $config->load_cert_chain(
        File::Spec->catfile($directory, "cert-\x{263A}.crt")) };
    like($@, qr/path must be a byte string/, 'a wide-character path is refused');
    eval { Net::Quiche::XS::_config_load_cert_chain($config, "bad-\xE9.crt") };
    like($@, qr/quiche requires a UTF-8 encoded path/,
        'the XS layer refuses non-UTF-8 paths on its own');
};

ok(Net::Quiche::XS::Connection->can('CLONE_SKIP')
    && Net::Quiche::XS::Connection->CLONE_SKIP,
    'native connections are not cloned into new threads');
ok(Net::Quiche::XS::HTTP3->can('CLONE_SKIP')
    && Net::Quiche::XS::HTTP3->CLONE_SKIP,
    'native HTTP/3 sessions are not cloned into new threads');

subtest 'Connection and HTTP3 survive either destruction order' => sub {
    # Order A: drop outer $conn reference while $h3 is still alive
    {
        my ($client, $server) = connected_pair('d1');
        my $client_h3 = $client->http3;
        my $server_h3 = $server->http3;
        undef $client;
        my $sid = $client_h3->send_request(
            headers => request_headers(), final => 1);
        ok(defined $sid, 'HTTP3 still works after caller drops outer Connection ref');
        undef $client_h3;
        undef $server_h3;
        undef $server;
    }
    # Order B: drop $h3 while $conn remains alive
    {
        my ($client, $server) = connected_pair('d2');
        {
            my $h3 = $client->http3;
            ok($h3, 'created HTTP3 session');
        }
        ok($client->is_established, 'Connection stays valid after HTTP3 is destroyed');
        ok(!$client->is_closed, 'Connection is not closed when HTTP3 is dropped');
        my $dup = eval { $client->http3; 1 };
        ok(!$dup, 'cannot re-attach a second HTTP3 session after dropping the first');
    }
};

done_testing;
