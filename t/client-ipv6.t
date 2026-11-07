use strict;
use warnings;
use Test::More;

BEGIN {
    eval {
        require Future;
        require Future::AsyncAwait;
        Future::AsyncAwait->import;
        require IO::Async::Loop;
        require IO::Socket::IP;
        1;
    } or plan skip_all => 'Future::AsyncAwait, IO::Async, and IO::Socket::IP are required';
}

use Net::Quiche;
use Net::Quiche::HTTP3::Client;
use PAGI::Server::HTTP3;

my $probe = IO::Socket::IP->new(
    LocalHost => '::1', LocalPort => 0, Proto => 'udp',
);
plan skip_all => 'IPv6 loopback is not available' unless $probe;
$probe->close;

my $cert = 't/fixtures/cert.crt';
my $key  = 't/fixtures/cert.key';
BAIL_OUT('bundled TLS fixtures are missing from t/fixtures')
    unless -f $cert && -f $key;

my %transport = (
    max_idle_timeout => 10_000,
    initial_max_data => 1_000_000,
    initial_max_stream_data_bidi_local => 100_000,
    initial_max_stream_data_bidi_remote => 100_000,
    initial_max_stream_data_uni => 100_000,
    initial_max_streams_bidi => 10,
    initial_max_streams_uni => 10,
);
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    await $receive->();
    await $send->({
        type => 'http.response.start', status => 200, headers => [],
    });
    await $send->({
        type => 'http.response.body',
        body => join(':', $scope->{client}[0], $scope->{server}[0]),
        more => 0,
    });
};

my $loop = IO::Async::Loop->new;
my $server = PAGI::Server::HTTP3->new(
    app => $app,
    config => Net::Quiche->config(
        %transport, certificate_chain => $cert, private_key => $key,
    ),
    host => '::1', port => 0,
);
my $client = Net::Quiche::HTTP3::Client->new(
    config => Net::Quiche->config(%transport, verify_peer => 0),
);
$loop->add($server);
$loop->add($client);
$loop->await($server->listen)->get;

my $response = $loop->await(
    $client->get('https://[::1]:' . $server->bound_port . '/')
)->get;
is($response->status, 200, 'HTTP/3 client completes an IPv6 request');
is($response->body, '::1:::1',
    'IPv6 client and server addresses reach the PAGI scope');
is($client->connection_count, 1,
    'bracketed IPv6 URI creates one reusable origin');

$client->stop;
$server->stop;
done_testing;
