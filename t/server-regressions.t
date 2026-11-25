use strict;
use warnings;
use Test::More;

BEGIN {
    eval {
        require Future;
        require Future::AsyncAwait;
        Future::AsyncAwait->import;
        require IO::Async::Loop;
        require PAGI::Server::HTTP3;
        1;
    } or plan skip_all => 'Future, Future::AsyncAwait and IO::Async are required';
}

use Net::Quiche;
use PAGI::Server::Protocol::HTTP3;
use Socket qw(inet_aton pack_sockaddr_in);

my $cert = 't/fixtures/cert.crt';
my $key  = 't/fixtures/cert.key';
BAIL_OUT('bundled TLS fixtures are missing from t/fixtures')
    unless -f $cert && -f $key;

my $client_address = ['127.0.0.1', 45_102];
my $server_address = ['127.0.0.1', 8_502];

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

sub server_config {
    return Net::Quiche->config(
        transport_config(), certificate_chain => $cert, private_key => $key,
    );
}

sub pump {
    my ($from, $to) = @_;
    my $count = 0;
    while (my $datagram = $from->next_datagram) {
        $to->receive_datagram($datagram);
        die 'QUIC pump did not quiesce' if ++$count > 10_000;
    }
    return $count;
}

# Move datagrams both ways and let the server protocol handle every event.
sub settle {
    my ($client, $server, $protocol) = @_;
    for (1 .. 1_000) {
        my $moved = pump($client, $server);
        $protocol->drain_events if $protocol;
        $moved += pump($server, $client);
        return unless $moved;
    }
    die 'QUIC exchange did not quiesce';
}

my $pair = 0;
sub harness {
    my (%options) = @_;
    $pair++;
    my $client = Net::Quiche::Connection->connect(
        config => Net::Quiche->config(transport_config(), verify_peer => 0),
        server_name => 'localhost', source_connection_id => "fix-client-$pair",
        local => $client_address, peer => $server_address,
    );
    my $server = Net::Quiche::Connection->accept(
        config => server_config(),
        source_connection_id => "fix-server-$pair",
        local => $server_address, peer => $client_address,
    );
    settle($client, $server);
    my @errors;
    my $protocol = PAGI::Server::Protocol::HTTP3->new(
        app => $options{app}, connection => $server,
        client => $client_address, server => $server_address,
        on_error => sub { push @errors, $_[0] },
        (exists $options{max_request_body_buffer}
            ? (max_request_body_buffer => $options{max_request_body_buffer})
            : ()),
    );
    return {
        client => $client, server => $server, protocol => $protocol,
        client_h3 => $client->http3, errors => \@errors,
    };
}

sub request {
    my ($h, %options) = @_;
    my $headers = $options{headers} || [
        [':method', $options{method} || 'GET'], [':scheme', 'https'],
        [':authority', 'localhost'], [':path', '/'],
    ];
    return $h->{client_h3}->send_request(
        headers => $headers, final => $options{final} // 1);
}

sub client_events {
    my ($h) = @_;
    my @events;
    while (my $event = $h->{client_h3}->poll) {
        push @events, $event;
    }
    return @events;
}

subtest 'an application that dies after http.response.start' => sub {
    my $h = harness(app => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200,
            headers => [['content-type', 'text/plain']] });
        await $send->({ type => 'http.response.body', body => 'partial',
            more => 1 });
        die "boom\n";
    });
    my $stream_id = request($h);
    settle(@{$h}{qw(client server protocol)});
    is($h->{protocol}->active_streams, 0, 'the stream leaves the table');
    my @types = map { $_->{type} } client_events($h);
    ok((grep { $_ eq 'reset' } @types),
        'the client sees the response stream reset') or diag explain \@types;
    like($h->{errors}[-1], qr/boom/, 'the failure is reported');
};

subtest 'an application that returns before finishing its response' => sub {
    my $h = harness(app => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 200,
            headers => [] });
        return;
    });
    request($h);
    settle(@{$h}{qw(client server protocol)});
    is($h->{protocol}->active_streams, 0, 'the stream leaves the table');
    my @types = map { $_->{type} } client_events($h);
    ok((grep { $_ eq 'reset' } @types), 'the client sees a reset')
        or diag explain \@types;
};

subtest 'a cancelled receive() does not break the stream' => sub {
    my ($first, $second);
    my $h = harness(app => async sub {
        my ($scope, $receive, $send) = @_;
        my $request = await $receive->();
        my $pending = $receive->();
        $pending->cancel;
        $second = await $receive->();
        await $send->({ type => 'http.response.start', status => 204,
            headers => [] });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    });
    my $stream_id = request($h, method => 'POST', final => 0);
    settle(@{$h}{qw(client server protocol)});
    $h->{client_h3}->send_body($stream_id, 'payload', final => 1);
    settle(@{$h}{qw(client server protocol)});
    ok($second, 'a later receive() resolves');
    is($second->{body}, 'payload',
        'the event that arrived after the cancel is not lost');
    is_deeply($h->{errors}, [], 'no errors were reported');
};

subtest 'Host is kept when :authority is absent' => sub {
    my $scope;
    my $h = harness(app => async sub {
        ($scope, my ($receive, $send)) = @_;
        await $send->({ type => 'http.response.start', status => 204,
            headers => [] });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    });
    request($h, headers => [
        [':method', 'GET'], [':scheme', 'https'], [':path', '/'],
        ['host', 'example.test'],
    ]);
    settle(@{$h}{qw(client server protocol)});
    is_deeply([grep { $_->[0] eq 'host' } @{$scope->{headers}}],
        [['host', 'example.test']], 'the scope carries the Host header');
};

subtest 'request bodies are read at the application\'s pace' => sub {
    my $limit = 32 * 1024;
    my $release = Future->new;
    my ($body, $done, $peak) = ('', 0, 0);
    my $h;
    $h = harness(
        max_request_body_buffer => $limit,
        app => async sub {
            my ($scope, $receive, $send) = @_;
            await $release;
            while (1) {
                my $event = await $receive->();
                $body .= $event->{body};
                last unless $event->{more};
            }
            $done = 1;
            await $send->({ type => 'http.response.start', status => 204,
                headers => [] });
            await $send->({ type => 'http.response.body', body => '',
                more => 0 });
        },
    );
    my $stream_id = request($h, method => 'POST', final => 0);
    # Larger than the 1 MB stream window, so flow control has to engage.
    my $payload = join '', map { chr(65 + $_ % 26) x 1000 } 0 .. 2_999;
    my $offset = 0;
    for (1 .. 200) {
        my $written = $h->{client_h3}->send_body(
            $stream_id, substr($payload, $offset), final => 1);
        $offset += $written // 0;
        settle(@{$h}{qw(client server protocol)});
        my ($stream) = values %{$h->{protocol}{streams}};
        $peak = $stream->{queued_bytes} if $stream
            && $stream->{queued_bytes} > $peak;
        last if $offset >= length $payload;
    }
    ok($offset < length($payload),
        'flow control stops the client while the application is not reading');
    cmp_ok($peak, '<=', $limit + 16 * 1024,
        'the server buffers no more than the configured limit');

    $release->done;
    for (1 .. 200) {
        last if $offset >= length($payload) && $done;
        if ($offset < length $payload) {
            my $written = $h->{client_h3}->send_body(
                $stream_id, substr($payload, $offset), final => 1);
            $offset += $written // 0;
        }
        settle(@{$h}{qw(client server protocol)});
    }
    ok($done, 'the application receives the end of the body');
    is(length($body), length($payload), 'every byte arrives');
    ok($body eq $payload, 'the bytes arrive in order');
};

subtest 'a response that ignores the request body stops the upload' => sub {
    my $h = harness(app => async sub {
        my ($scope, $receive, $send) = @_;
        await $send->({ type => 'http.response.start', status => 413,
            headers => [] });
        await $send->({ type => 'http.response.body', body => '', more => 0 });
    });
    my $stream_id = request($h, method => 'POST', final => 0);
    $h->{client_h3}->send_body($stream_id, 'x' x 4096, final => 0);
    settle(@{$h}{qw(client server protocol)});
    is($h->{protocol}->active_streams, 0,
        'the stream is released without waiting for the client FIN');
    my $written = eval {
        $h->{client_h3}->send_body($stream_id, 'more', final => 1);
    };
    like($@ // '', qr/failed: -1015/,
        'the client is told to stop sending (STOP_SENDING)');
};

subtest 'a rejected request with a body is released' => sub {
    my $h = harness(app => sub { die 'not reached' });
    my $stream_id = request($h, final => 0, headers => [
        [':method', 'POST'], [':scheme', 'ftp'], [':path', '/'],
        [':authority', 'localhost'],
    ]);
    $h->{client_h3}->send_body($stream_id, 'x' x 1000, final => 0);
    settle(@{$h}{qw(client server protocol)});
    is($h->{protocol}->active_streams, 0, 'the 400 stream leaves the table');
    my ($headers) = grep { $_->{type} eq 'headers' } client_events($h);
    is_deeply([grep { $_->[0] eq ':status' } @{$headers->{headers}}],
        [[':status', '400']], 'the client receives 400');
};

subtest 'listener only creates connections for full-size Initials' => sub {
    my @errors;
    my $listener = PAGI::Server::HTTP3->new(
        app => sub { Future->done }, config => server_config(),
        host => '127.0.0.1', port => 0,
        on_error => sub { push @errors, $_[0] },
    );
    my $loop = IO::Async::Loop->new;
    $loop->add($listener);
    $listener->listen->get;
    my $peer = pack_sockaddr_in(45_103, inet_aton('127.0.0.1'));

    my $make_client = sub {
        my ($tag, @alpn) = @_;
        return Net::Quiche::Connection->connect(
            config => Net::Quiche->config(transport_config(), verify_peer => 0,
                @alpn ? (application_protocols => \@alpn) : ()),
            server_name => 'localhost', source_connection_id => "listen-$tag",
            local => ['127.0.0.1', 45_103],
            peer => ['127.0.0.1', $listener->bound_port],
        );
    };

    my $initial = $make_client->('short')->next_datagram->{data};
    cmp_ok(length($initial), '>=', 1_200, 'a client Initial is padded');
    $listener->_receive_datagram(substr($initial, 0, 600), $peer);
    is($listener->connection_count, 0, 'a short datagram is ignored');

    my $handshake = $make_client->('handshake')->next_datagram->{data};
    my $first = ord substr($handshake, 0, 1);
    substr($handshake, 0, 1, chr(($first & ~0x30) | 0x20));
    $listener->_receive_datagram($handshake, $peer);
    is($listener->connection_count, 0,
        'a non-Initial long header packet does not create a connection');

    @errors = ();
    my $bad_alpn = $make_client->('alpn', 'not-h3')->next_datagram->{data};
    $listener->_receive_datagram($bad_alpn, $peer);
    is($listener->connection_count, 0,
        'an Initial that quiche rejects does not keep a connection slot');
    ok(scalar(@errors), 'the rejection is reported');

    $listener->_receive_datagram(
        $make_client->('good')->next_datagram->{data}, $peer);
    is($listener->connection_count, 1, 'a valid Initial creates a connection');

    $listener->stop;
    $loop->remove($listener);
};

done_testing;
