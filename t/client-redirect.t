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
    initial_max_data => 2_000_000,
    initial_max_stream_data_bidi_local => 1_000_000,
    initial_max_stream_data_bidi_remote => 1_000_000,
    initial_max_stream_data_uni => 1_000_000,
    initial_max_streams_bidi => 100,
    initial_max_streams_uni => 100,
    disable_active_migration => 1,
);

my (@requests, $other_base);
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    my $body = '';
    while (1) {
        my $event = await $receive->();
        $body .= $event->{body} // '';
        last unless $event->{more};
    }
    my %headers = map { lc($_->[0]) => $_->[1] } @{$scope->{headers}};
    push @requests, {
        method => $scope->{method}, path => $scope->{path}, body => $body,
        authorization => $headers{authorization}, cookie => $headers{cookie},
    };

    my ($status, $location, $response_body) = (200, undef,
        "$scope->{method}:$scope->{path}:$body");
    ($status, $location) = (302, '/final') if $scope->{path} eq '/relative';
    ($status, $location) = (302, '/post-final') if $scope->{path} eq '/post-302';
    ($status, $location) = (303, '/post-final') if $scope->{path} eq '/post-303';
    ($status, $location) = (307, '/post-final') if $scope->{path} eq '/post-307';
    ($status, $location) = (308, '/post-final') if $scope->{path} eq '/post-308';
    ($status, $location) = (302, '/loop') if $scope->{path} eq '/loop';
    ($status, $location) = (302, "$other_base/credentials")
        if $scope->{path} eq '/cross-origin';

    my @response_headers = (['content-type', 'text/plain']);
    push @response_headers, ['location', $location] if defined $location;
    await $send->({
        type => 'http.response.start', status => $status,
        headers => \@response_headers,
    });
    await $send->({
        type => 'http.response.body', body => $response_body, more => 0,
    });
};

my $loop = IO::Async::Loop->new;
my @servers = map {
    PAGI::Server::HTTP3->new(
        app => $app,
        config => Net::Quiche->config(
            %transport, certificate_chain => $cert, private_key => $key,
        ),
        host => '127.0.0.1', port => 0,
    )
} 1 .. 2;
$loop->add($_) for @servers;
$loop->await(Future->needs_all(map { $_->listen } @servers))->get;
my $base = 'https://127.0.0.1:' . $servers[0]->bound_port;
$other_base = 'https://127.0.0.1:' . $servers[1]->bound_port;

my $client = Net::Quiche::HTTP3::Client->new(
    config => Net::Quiche->config(%transport, verify_peer => 0),
);
$loop->add($client);

my $not_followed = $loop->await($client->get("$base/relative"))->get;
is($not_followed->status, 302, 'redirect following stays opt-in');

my $relative = $loop->await($client->get(
    "$base/relative", max_redirects => 3,
))->get;
is($relative->status, 200, 'relative redirect reaches its final response');
is($relative->body, 'GET:/final:', 'relative Location resolves against request URI');
is($relative->effective_uri, "$base/final", 'response records the final URI');
is_deeply($relative->redirect_history, [
    { status => 302, uri => "$base/relative", location => '/final' },
], 'response records redirect history without retaining response objects');

for my $case (
    [302, 'GET', ''], [303, 'GET', ''],
    [307, 'POST', 'potato'], [308, 'POST', 'potato'],
) {
    my ($status, $method, $body) = @{$case};
    my $response = $loop->await($client->post(
        "$base/post-$status", body => 'potato', max_redirects => 2,
    ))->get;
    is($response->body, "$method:/post-final:$body",
        "$status applies the expected method and body rule");
}

my $cross = $loop->await($client->get(
    "$base/cross-origin",
    headers => [
        ['authorization', 'Bearer secret'],
        ['cookie', 'session=secret'],
    ],
    max_redirects => 2,
))->get;
is($cross->status, 200, 'cross-origin redirect completes');
my $credential_request = $requests[-1];
is($credential_request->{path}, '/credentials', 'request reached the other origin');
ok(!defined $credential_request->{authorization},
    'cross-origin redirect strips authorization');
ok(!defined $credential_request->{cookie},
    'cross-origin redirect strips cookie');

my $looped = $client->get("$base/loop", max_redirects => 2);
$loop->await($looped);
ok($looped->is_failed, 'redirect loop fails after the configured bound');
like(($looped->failure)[0], qr/exceeded 2 redirects/,
    'redirect loop failure names the configured bound');

$client->stop;
$_->stop for @servers;
done_testing;
