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

my $client_address = ['127.0.0.1', 45_003];
my $server_address = ['127.0.0.1', 8_445];
my %transport = (
    max_idle_timeout => 10_000,
    max_recv_udp_payload_size => 1_350,
    max_send_udp_payload_size => 1_350,
    initial_max_stream_data_bidi_remote => 1_000_000,
    initial_max_stream_data_uni => 1_000_000,
    initial_max_streams_bidi => 100,
    initial_max_streams_uni => 100,
    disable_active_migration => 1,
);

my $client = Net::Quiche::Connection->connect(
    config => Net::Quiche->config(
        %transport,
        verify_peer => 0,
        initial_max_data => 2_048,
        initial_max_stream_data_bidi_local => 512,
    ),
    server_name => 'localhost',
    source_connection_id => 'pressure-client-id',
    local => $client_address,
    peer => $server_address,
);
my $server = Net::Quiche::Connection->accept(
    config => Net::Quiche->config(
        %transport,
        certificate_chain => $cert,
        private_key => $key,
        initial_max_data => 1_000_000,
        initial_max_stream_data_bidi_local => 1_000_000,
    ),
    source_connection_id => 'pressure-server-id',
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
    'small-window QUIC pair establishes');

my $response_body = '0123456789abcdef' x 4_096;
my (@body_futures, @application_done, @connection_states, $send_callback);
my $application_number = 0;
my @errors;
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    my $number = $application_number++;
    $connection_states[$number] = $scope->{'pagi.connection'};
    $send_callback = $send;
    await $receive->();
    await $send->({
        type => 'http.response.start',
        status => 200,
        headers => [['content-type', 'application/octet-stream']],
    });
    $body_futures[$number] = $send->({
        type => 'http.response.body',
        body => $response_body,
        more => 0,
    });
    await $body_futures[$number];
    $application_done[$number] = 1;
};

my $writes = 0;
my $protocol = PAGI::Server::Protocol::HTTP3->new(
    app => $app,
    connection => $server,
    client => $client_address,
    server => $server_address,
    on_write => sub { $writes++ },
    on_error => sub { push @errors, $_[0] },
);
my $client_h3 = $client->http3;
my $stream_id = $client_h3->send_request(
    headers => [
        [':method', 'GET'],
        [':scheme', 'https'],
        [':authority', 'localhost:8445'],
        [':path', '/large-response'],
    ],
    final => 1,
);
pump($client, $server);
$protocol->drain_events;

my $body_future = $body_futures[0];
ok($body_future, 'PAGI application receives a response-body Future');
ok($body_future && !$body_future->is_ready,
    'response-body Future stays pending after the first partial write');
ok(!$application_done[0], 'application remains suspended during backpressure');
my $writes_before_blocked_retry = $writes;
is($protocol->drain_events, 0,
    'retry can run without a new HTTP/3 application event');
ok(!$body_future->is_ready,
    'quiche DONE leaves the response Future pending for a later retry');
is($writes, $writes_before_blocked_retry,
    'a fully blocked retry does not report transport write progress');
is_deeply(\@errors, [], 'quiche DONE is not exposed as an application error');
my $overlapping_send = $send_callback->({
    type => 'http.response.body', body => 'not queued', more => 1,
});
ok($overlapping_send->is_failed,
    'a second send is rejected while backpressure is pending');
my ($overlap_error) = $overlapping_send->failure;
like($overlap_error, qr/Only one pending send/,
    'overlapping send error explains the await requirement');

my (@headers, $received_body, $finished, $data_events);
$received_body = '';
for my $iteration (1 .. 10_000) {
    pump($server, $client);
    while (my $event = $client_h3->poll) {
        if ($event->{type} eq 'headers') {
            @headers = @{$event->{headers}};
        } elsif ($event->{type} eq 'data') {
            $received_body .= $event->{body};
            $data_events++;
        } elsif ($event->{type} eq 'finished') {
            $finished = 1;
        }
    }
    pump($client, $server);
    $protocol->drain_events;
    last if $finished && $body_future && $body_future->is_ready;
}

is_deeply(\@headers, [
    [':status', '200'],
    ['content-type', 'application/octet-stream'],
], 'response headers survive the blocked transfer');
is($received_body, $response_body,
    'client receives every response byte after flow-control updates');
ok($finished, 'client receives the terminal FIN');
ok($body_future && $body_future->is_done,
    'response-body Future resolves after every byte and FIN are accepted');
ok($application_done[0], 'application resumes after backpressure clears');
cmp_ok($data_events // 0, '>', 1, 'response arrives in multiple body reads');
cmp_ok($writes, '>', 2, 'transport owner is notified for retry progress');
is_deeply(\@errors, [], 'backpressure does not report an application error');
is($protocol->active_streams, 0,
    'completed backpressured stream releases its PAGI state');
is($stream_id, 0, 'test uses the first client request stream');

my @disconnect_callbacks;
$connection_states[1] = undef;
my $disconnect_stream = $client_h3->send_request(
    headers => [
        [':method', 'GET'],
        [':scheme', 'https'],
        [':authority', 'localhost:8445'],
        [':path', '/disconnect-during-backpressure'],
    ],
    final => 1,
);
pump($client, $server);
$protocol->drain_events;
my $disconnect_future = $body_futures[1];
ok($disconnect_future && !$disconnect_future->is_ready,
    'second response is pending behind its stream window');
$connection_states[1]->on_disconnect(sub {
    push @disconnect_callbacks, $_[0];
});
$protocol->disconnect('server_shutdown');
ok($disconnect_future->is_done,
    'in-flight send resolves successfully when its stream disconnects');
ok(!$disconnect_future->is_failed,
    'disconnect is not exposed as a send failure');
ok($application_done[1],
    'application resumes from an in-flight send after disconnect');
ok(!$connection_states[1]->is_connected,
    'connection state records the disconnected request');
is($connection_states[1]->disconnect_reason, 'server_shutdown',
    'connection state records the standard disconnect reason');
is_deeply(\@disconnect_callbacks, ['server_shutdown'],
    'disconnect callback fires before application teardown');
is_deeply(\@errors, [],
    'disconnecting an in-flight response is not an application error');
is($disconnect_stream, 4, 'disconnect test uses a separate request stream');

done_testing;
