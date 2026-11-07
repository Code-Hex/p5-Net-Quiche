use strict;
use warnings;
use Test::More;

BEGIN {
    eval {
        require Future;
        require Future::AsyncAwait;
        Future::AsyncAwait->import;
        require IO::Async::Loop;
        1;
    } or plan skip_all => 'Future::AsyncAwait and IO::Async are required';
}

use Net::Quiche;
use Net::Quiche::HTTP3::Client;
use PAGI::Server::HTTP3;

my $cert = 't/fixtures/cert.crt';
my $key  = 't/fixtures/cert.key';
BAIL_OUT('bundled TLS fixtures are missing from t/fixtures')
    unless -f $cert && -f $key;

my %transport = (
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
);

my $loop = IO::Async::Loop->new;
my $slow_started = Future->new;
my $release_slow = Future->new;
my @errors;
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    while (1) {
        my $event = await $receive->();
        last unless $event->{type} eq 'http.request' && $event->{more};
    }
    if ($scope->{path} eq '/slow') {
        $slow_started->done unless $slow_started->is_ready;
        await $release_slow;
    }
    await $send->({
        type => 'http.response.start', status => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body', body => $scope->{path}, more => 0,
    });
};

my $server = PAGI::Server::HTTP3->new(
    app => $app,
    config => Net::Quiche->config(
        %transport, certificate_chain => $cert, private_key => $key,
    ),
    host => '127.0.0.1', port => 0,
    on_error => sub { push @errors, "$_[0]" },
);
my $client = Net::Quiche::HTTP3::Client->new(
    config => Net::Quiche->config(%transport, verify_peer => 0),
);
$loop->add($server);
$loop->add($client);
$loop->await($server->listen)->get;
my $base = 'https://127.0.0.1:' . $server->bound_port;

my $slow = $client->get("$base/slow");
$loop->await($slow_started)->get;
is($client->connection_count, 1,
    'slow request owns the first QUIC connection');

my $sent = $loop->await($server->goaway)->get;
is($sent, $server, 'server GOAWAY Future resolves to the listener');
$loop->await($loop->delay_future(after => 0.02))->get;

my $fresh = $loop->await($client->get("$base/fresh"))->get;
is($fresh->body, '/fresh',
    'request after GOAWAY uses a replacement connection');
is($client->connection_count, 2,
    'retiring and replacement connections coexist while work is active');

$release_slow->done;
my $slow_response = $loop->await($slow)->get;
is($slow_response->body, '/slow',
    'request accepted before GOAWAY finishes on the retiring connection');
is($client->connection_count, 1,
    'retiring connection is released after its accepted stream completes');
is($client->active_requests, 0, 'GOAWAY leaves no request state behind');
is_deeply(\@errors, [], 'graceful GOAWAY is not a PAGI server error');

$client->stop;
$server->stop;
done_testing;
