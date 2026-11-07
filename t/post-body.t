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

my $client_address = ['127.0.0.1', 45_004];
my $server_address = ['127.0.0.1', 8_446];
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
    source_connection_id => 'post-client-source',
    local => $client_address,
    peer => $server_address,
);
my $server = Net::Quiche::Connection->accept(
    config => Net::Quiche->config(
        %transport, certificate_chain => $cert, private_key => $key,
    ),
    source_connection_id => 'post-server-source',
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
    'POST test QUIC pair establishes');

my (@request_events, $scope, $received_body);
my @errors;
my $app = async sub {
    ($scope, my $receive, my $send) = @_;
    my $body = '';
    while (1) {
        my $event = await $receive->();
        push @request_events, { %{$event} };
        last unless $event->{type} eq 'http.request';
        $body .= $event->{body} // '';
        last unless $event->{more};
    }
    $received_body = $body;
    await $send->({
        type => 'http.response.start', status => 200,
        headers => [['content-type', 'application/octet-stream']],
    });
    await $send->({
        type => 'http.response.body', body => $body, more => 0,
    });
};

my $protocol = PAGI::Server::Protocol::HTTP3->new(
    app => $app,
    connection => $server,
    client => $client_address,
    server => $server_address,
    on_error => sub { push @errors, $_[0] },
);
my $client_h3 = $client->http3;
my @chunks = ('alpha-' x 1_000, "omega\0tail");
my $body = join '', @chunks;
my $stream_id = $client_h3->send_request(
    headers => [
        [':method', 'POST'],
        [':scheme', 'https'],
        [':authority', 'localhost:8446'],
        [':path', '/echo?mode=stream'],
        ['content-type', 'application/octet-stream'],
        ['content-length', length($body)],
    ],
    final => 0,
);
pump($client, $server);
$protocol->drain_events;

is_deeply(\@request_events, [
    { type => 'http.request', body => '', more => 1 },
], 'POST headers expose an initial non-terminal request event');

is($client_h3->send_body($stream_id, $chunks[0], final => 0),
    length($chunks[0]), 'first POST body chunk is accepted');
pump($client, $server);
$protocol->drain_events;

is($client_h3->send_body($stream_id, $chunks[1], final => 1),
    length($chunks[1]), 'terminal POST body chunk is accepted');
pump($client, $server);
$protocol->drain_events;

is($scope->{method}, 'POST', 'POST method reaches the PAGI scope');
is($scope->{path}, '/echo', 'POST path is decoded independently of its body');
is($scope->{query_string}, 'mode=stream', 'POST query string is preserved');
is($received_body, $body, 'PAGI application receives the exact POST bytes');
is_deeply(\@request_events, [
    { type => 'http.request', body => '', more => 1 },
    { type => 'http.request', body => $chunks[0], more => 1 },
    { type => 'http.request', body => $chunks[1], more => 1 },
    { type => 'http.request', body => '', more => 0 },
], 'DATA and FINISHED become an ordered PAGI request-body stream');

pump($server, $client);
my $response_headers = $client_h3->poll;
is($response_headers->{type}, 'headers', 'POST response starts with headers');
my $response = '';
my $finished;
while (my $event = $client_h3->poll) {
    $response .= $event->{body} if $event->{type} eq 'data';
    $finished = 1 if $event->{type} eq 'finished';
}
is($response, $body, 'HTTP/3 client receives the echoed binary POST body');
ok($finished, 'POST response receives FIN');
is_deeply(\@errors, [], 'POST streaming reports no PAGI protocol error');
is($protocol->active_streams, 0, 'completed POST releases its stream state');

done_testing;
