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

sub make_server {
    my ($loop, $app, $errors) = @_;
    my $server = PAGI::Server::HTTP3->new(
        app => $app,
        config => Net::Quiche->config(
            %transport, certificate_chain => $cert, private_key => $key,
        ),
        host => '127.0.0.1', port => 0,
        on_error => sub { push @$errors, "$_[0]" },
    );
    my $client = Net::Quiche::HTTP3::Client->new(
        config => Net::Quiche->config(%transport, verify_peer => 0),
    );
    $loop->add($server);
    $loop->add($client);
    $loop->await($server->listen)->get;
    return ($server, $client,
        'https://127.0.0.1:' . $server->bound_port);
}

my $loop = IO::Async::Loop->new;
my $started = Future->new;
my $release = Future->new;
my @errors;
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    while (1) {
        my $event = await $receive->();
        last unless $event->{type} eq 'http.request' && $event->{more};
    }
    $started->done unless $started->is_ready;
    await $release;
    await $send->({
        type => 'http.response.start', status => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body', body => $scope->{path}, more => 0,
    });
};

my ($server, $client, $base) = make_server($loop, $app, \@errors);
my $response = $client->get("$base/slow", timeout => 2);
$loop->await($started)->get;

eval { $server->shutdown(grace => -1) };
like($@, qr/grace must be a non-negative number/,
    'shutdown validates grace before changing listener state');

my $cancelled_view = $server->shutdown(grace => 1);
ok(!$cancelled_view->is_ready, 'shutdown waits for an accepted PAGI stream');
$cancelled_view->cancel;
my $shutdown = $server->shutdown;
ok(!$shutdown->is_ready,
    'cancelling one shutdown Future does not cancel server shutdown');

$loop->await($loop->delay_future(after => 0.02))->get;
my $replacement = $client->get("$base/rejected", timeout => 0.05);
my $replacement_error;
eval { $loop->await($replacement)->get; 1 }
    or $replacement_error = $@;
like($replacement_error, qr/timed out/i,
    'shutdown rejects a replacement QUIC connection');
is($server->connection_count, 1,
    'rejected connection does not enter the server routing table');

$release->done;
$loop->await(Future->needs_all($response, $shutdown))->get;
is($response->get->body, '/slow',
    'accepted response reaches the client before graceful close');
is($shutdown->get, $server, 'shutdown Future resolves to the listener');
is($server->bound_port, undef, 'shutdown closes the UDP listener');
is($server->connection_count, 0, 'shutdown releases every QUIC connection');
is_deeply(\@errors, [], 'graceful shutdown does not report an application error');
$client->stop;
$loop->remove($client) if $client->parent;
$loop->remove($server) if $server->parent;

my $never = Future->new;
my $forced_started = Future->new;
my @forced_errors;
my $blocking_app = async sub {
    my ($scope, $receive, $send) = @_;
    my $event = await $receive->();
    $forced_started->done unless $forced_started->is_ready;
    await $never;
};
my ($forced_server, $forced_client, $forced_base) =
    make_server($loop, $blocking_app, \@forced_errors);
my $blocked = $forced_client->get("$forced_base/blocked", timeout => 0.3);
$loop->await($forced_started)->get;
my $forced = $forced_server->shutdown(grace => 0.02);
is($loop->await($forced)->get, $forced_server,
    'shutdown grace expiry forces completion');
my $blocked_error;
eval { $loop->await($blocked)->get; 1 } or $blocked_error = $@;
like($blocked_error, qr/(?:closed|timed out|shutdown|GOAWAY)/i,
    'forced shutdown fails the unfinished client request');
is($forced_server->connection_count, 0,
    'forced shutdown releases the blocked connection');
is($forced_server->bound_port, undef,
    'forced shutdown closes the UDP listener');
is_deeply(\@forced_errors, [],
    'the configured shutdown deadline is not reported as an application error');
$forced_client->stop;
$loop->remove($forced_client) if $forced_client->parent;
$loop->remove($forced_server) if $forced_server->parent;

done_testing;
