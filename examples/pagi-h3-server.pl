#!/usr/bin/env perl

use strict;
use warnings;
use Future::AsyncAwait;
use Getopt::Long qw(GetOptions);
use IO::Async::Loop;
use Net::Quiche;
use PAGI::Server::HTTP3;

my $host = '127.0.0.1';
my $port = 8443;
my $certificate = 't/fixtures/cert.crt';
my $private_key = 't/fixtures/cert.key';
GetOptions(
    'host=s' => \$host,
    'port=i' => \$port,
    'certificate=s' => \$certificate,
    'private-key=s' => \$private_key,
) or die "Invalid command-line options\n";

my $app = async sub {
    my ($scope, $receive, $send) = @_;
    die "Unsupported PAGI scope '$scope->{type}'\n" if $scope->{type} ne 'http';

    my $body = '';
    my $request = await $receive->();
    $body .= $request->{body} // '';
    while ($request->{more}) {
        $request = await $receive->();
        $body .= $request->{body} // '';
    }

    my $response = "Hello from Perl over HTTP/3\n";
    $response .= 'Received ' . length($body) . " request bytes\n"
        if length $body;

    await $send->({
        type => 'http.response.start',
        status => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => $response,
        more => 0,
    });
};

my $config = Net::Quiche->config(
    certificate_chain => $certificate,
    private_key => $private_key,
    max_idle_timeout => 30_000,
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
my $server = PAGI::Server::HTTP3->new(
    app => $app,
    config => $config,
    host => $host,
    port => $port,
);
$loop->add($server);
$server->listen->get;

my $shutdown;
my $begin_shutdown = sub {
    return if $shutdown;
    $shutdown = $server->shutdown(grace => 5);
    $shutdown->on_ready(sub { $loop->stop });
};
$loop->watch_signal(INT => $begin_shutdown);
$loop->watch_signal(TERM => $begin_shutdown);

my $url_host = index($host, ':') >= 0 ? "[$host]" : $host;
print STDERR "PAGI HTTP/3 listening on https://$url_host:",
    $server->bound_port, "/\n";
$loop->run;
$loop->unwatch_signal('INT');
$loop->unwatch_signal('TERM');
