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

use Scalar::Util qw(weaken);
use Net::Quiche;
use Net::Quiche::HTTP3::Client;
use Net::Quiche::HTTP3::Exchange;
use Net::Quiche::HTTP3::Response;
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
my $hold = Future->new;
my $streamed_until_disconnect = 0;
# Built outside the async sub: some Future::AsyncAwait releases lose a
# constant-folded value when a loop resumes after await.
my $CHUNK = 'z' x 16_384;

my $app = async sub {
    my ($scope, $receive, $send) = @_;
    my $path = $scope->{path};
    if ($path eq '/reject') {
        # Answer at once and never read the upload.
        await $send->({ type => 'http.response.start', status => 413,
            headers => [] });
        await $send->({ type => 'http.response.body', body => 'too big',
            more => 0 });
        return;
    }
    if ($path eq '/endless') {
        await $send->({ type => 'http.response.start', status => 200,
            headers => [] });
        my $connection = $scope->{'pagi.connection'};
        while ($connection->is_connected) {
            await $send->({ type => 'http.response.body',
                body => $CHUNK, more => 1 });
        }
        $streamed_until_disconnect = 1;
        return;
    }
    while (1) {
        my $event = await $receive->();
        last unless $event->{type} eq 'http.request' && $event->{more};
    }
    await $hold if $path eq '/hold';
    await $send->({ type => 'http.response.start', status => 200,
        headers => [] });
    await $send->({ type => 'http.response.body', body => "ok:$path",
        more => 0 });
};

sub new_server {
    my (%options) = @_;
    my $server = PAGI::Server::HTTP3->new(
        app => $app,
        config => Net::Quiche->config(
            %transport, certificate_chain => $cert, private_key => $key,
        ),
        host => '127.0.0.1', port => $options{port} // 0,
        on_error => sub {},
    );
    $loop->add($server);
    $loop->await($server->listen)->get;
    return $server;
}

sub new_client {
    my (%options) = @_;
    my $client = Net::Quiche::HTTP3::Client->new(
        config => Net::Quiche->config(%transport, verify_peer => 0),
        %options,
    );
    $loop->add($client);
    return $client;
}

sub wait_until {
    my ($condition, $seconds) = @_;
    my $deadline = time + ($seconds // 5);
    until ($condition->()) {
        return 0 if time > $deadline;
        $loop->loop_once(0.05);
    }
    return 1;
}

my $server = new_server();
my $base = 'https://127.0.0.1:' . $server->bound_port;

subtest 'buffered responses are freed after use' => sub {
    my $client = new_client();
    my $response = $loop->await($client->get("$base/plain"))->get;
    is($response->body, 'ok:/plain', 'the request succeeds');
    my $weak = $response;
    weaken($weak);
    undef $response;
    ok(!defined $weak, 'the Response and its body are released');
    $client->stop;
    $loop->remove($client);
};

subtest 'slurp() does not keep the response alive' => sub {
    my $response = Net::Quiche::HTTP3::Response->_new(
        status => 200, headers => []);
    $response->_push_body('a');
    $response->_finish;
    is($response->slurp->get, 'a', 'slurp returns the body');
    my $weak = $response;
    weaken($weak);
    undef $response;
    ok(!defined $weak, 'no reference cycle remains');
};

subtest 'a cancelled read() does not block later reads' => sub {
    my $response = Net::Quiche::HTTP3::Response->_new(
        status => 200, headers => []);
    my $first = $response->read;
    $first->cancel;
    $response->_push_body('chunk');
    my $second = $response->read;
    ok($second->is_done, 'the next read() resolves');
    is($second->get, 'chunk', 'with the chunk that arrived after the cancel');
};

subtest 'max_response_body stops the download' => sub {
    my $client = new_client(max_response_body => 64 * 1024);
    my $future = $client->get("$base/endless");
    $loop->await($future);
    like(scalar($future->failure), qr/exceeds 65536 bytes/,
        'the request fails at the limit');
    ok(wait_until(sub { $client->active_requests == 0 }, 2),
        'the exchange is no longer active');
    ok(wait_until(sub { $streamed_until_disconnect }, 5),
        'the server sees the stream cancelled');
    $client->stop;
    $loop->remove($client);
};

subtest 'an early response with STOP_SENDING ends the upload cleanly' => sub {
    my $client = new_client();
    my $future = $client->post("$base/reject", body => 'x' x (4 * 1024 * 1024));
    $loop->await($future);
    ok($future->is_done, 'the request resolves')
        or diag scalar $future->failure;
    if ($future->is_done) {
        my $response = $future->get;
        is($response->status, 413, 'with the early response');
        is($response->body, 'too big', 'and its body');
    }
    is($loop->await($client->get("$base/after"))->get->body, 'ok:/after',
        'the connection is still usable');
    $client->stop;
    $loop->remove($client);
};

subtest 'stop() closes the QUIC connection' => sub {
    my $client = new_client();
    $loop->await($client->get("$base/close"))->get;
    ok(wait_until(sub { $server->connection_count >= 1 }, 2),
        'the server has the connection');
    my $before = $server->connection_count;
    $client->stop;
    ok(wait_until(sub { $server->connection_count < $before }, 3),
        'the server releases it well before the idle timeout');
    $loop->remove($client);
};

subtest 'a retry from a failure callback opens a new connection' => sub {
    my $client = new_client(request_timeout => 5);
    my $retry;
    my $first = $client->get("$base/hold");
    $first->on_fail(sub {
        $retry = $client->get("$base/again");
    });
    ok(wait_until(sub { $client->connection_count == 1
        && (values %{$client->{origins}})[0]{status} eq 'ready' }, 2),
        'the first request is on an established connection');
    my ($state) = values %{$client->{origins}};
    # Fail the connection the way a transport error would.
    $client->_fail_origin($state, 'simulated transport failure');
    ok($first->is_failed, 'the first request fails with its connection');
    ok($retry, 'the failure callback started a retry');
    my ($next) = values %{$client->{origins}};
    ok($next && $next != $state, 'the retry uses a new connection');
    $loop->await($retry) if $retry;
    ok($retry && $retry->is_done, 'the retry completes')
        or diag $retry && scalar $retry->failure;
    is($retry->get->body, 'ok:/again', 'with the response')
        if $retry && $retry->is_done;
    $client->stop;
    $loop->remove($client);
};

{
    package Local::StubConnection;
    sub new { bless { shutdowns => [] }, shift }
    sub shutdown_stream { push @{$_[0]{shutdowns}}, [@_[1 .. $#_]]; 1 }
    package Local::StubH3;
    sub new { bless {}, shift }
    sub _forget_stream { 1 }
}

subtest 'interim responses, trailers and malformed headers' => sub {
    my $client = new_client();
    my $state = {
        status => 'ready', flushing => 1, retired => 0, pending => [],
        exchanges => {}, cancelled_streams => {},
        connection => Local::StubConnection->new, h3 => Local::StubH3->new,
    };
    my $make = sub {
        my ($stream_id) = @_;
        my $exchange = Net::Quiche::HTTP3::Exchange->_new(
            client => $client, state => $state, headers => []);
        $exchange->{stream_id} = $stream_id;
        $state->{exchanges}{$stream_id} = $exchange;
        return $exchange;
    };

    my $exchange = $make->(0);
    $client->_response_headers($state, { stream_id => 0,
        headers => [[':status', '103'], ['link', '</a.css>']] });
    ok(!$exchange->response->is_ready, '103 Early Hints is not the response');
    $client->_response_headers($state, { stream_id => 0,
        headers => [[':status', '200']] });
    is($exchange->response->get->status, 200, 'the final response follows');
    $client->_response_headers($state, { stream_id => 0,
        headers => [['grpc-status', '0']] });
    ok(!defined($exchange->{failure}), 'trailers do not fail the request');

    my $bad = $make->(4);
    my $ok = eval {
        $client->_response_headers($state, { stream_id => 4,
            headers => [[':status', 'abc']] });
        1;
    };
    ok($ok, 'a malformed status does not take down the connection')
        or diag $@;
    like($bad->{failure} // '', qr/invalid :status/, 'only that request fails');
    ok($state->{cancelled_streams}{4}, 'and its stream is cancelled');
    is_deeply([map { $_->[0] } @{$state->{connection}{shutdowns}}], [4, 4],
        'both directions of the stream are shut down');
    $loop->remove($client);
};

$hold->done;
$server->stop;
$loop->remove($server);

done_testing;
