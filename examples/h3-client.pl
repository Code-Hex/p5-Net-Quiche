#!/usr/bin/env perl

use strict;
use warnings;
use Getopt::Long qw(GetOptions);
use IO::Async::Loop;
use Net::Quiche;
use Net::Quiche::HTTP3::Client;

my $ca_file = $ENV{SSL_CERT_FILE};
$ca_file = '/etc/ssl/cert.pem' if !defined($ca_file) && -f '/etc/ssl/cert.pem';
my $insecure = 0;
my $max_redirects = 0;
my $proxy;
my $timeout;
GetOptions(
    'ca-file=s' => \$ca_file,
    'insecure' => \$insecure,
    'max-redirects=i' => \$max_redirects,
    'proxy=s' => \$proxy,
    'timeout=f' => \$timeout,
) or die "Usage: $0 [--ca-file PATH | --insecure] [--max-redirects N] [--proxy socks5[h]://HOST:PORT] [--timeout SECONDS] https://host/path\n";
my $uri = shift @ARGV
    or die "Usage: $0 [--ca-file PATH | --insecure] [--max-redirects N] [--proxy socks5[h]://HOST:PORT] [--timeout SECONDS] https://host/path\n";
die "Unexpected arguments: @ARGV\n" if @ARGV;
die "No CA file found; pass --ca-file PATH or --insecure\n"
    if !$insecure && (!defined($ca_file) || !-f $ca_file);

my %transport = (
    verify_peer => $insecure ? 0 : 1,
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
$transport{verify_locations_file} = $ca_file unless $insecure;

my $loop = IO::Async::Loop->new;
my $client = Net::Quiche::HTTP3::Client->new(
    config => Net::Quiche->config(%transport),
    (defined($proxy) ? (proxy => $proxy) : ()),
);
$loop->add($client);
my $response = $loop->await($client->get(
    $uri, max_redirects => $max_redirects,
    (defined($timeout) ? (timeout => $timeout) : ()),
))->get;
print STDERR "HTTP/3 ", $response->status, "\n";
print STDERR "Effective URI ", $response->effective_uri, "\n"
    if @{$response->redirect_history};
print $response->body;
$client->stop;
