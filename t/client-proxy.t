use strict;
use warnings;
use Test::More;

BEGIN {
    eval {
        require Future;
        require Future::AsyncAwait;
        Future::AsyncAwait->import;
        require IO::Async::Listener;
        require IO::Async::Loop;
        require IO::Async::Socket;
        1;
    } or plan skip_all => 'Future::AsyncAwait and IO::Async are required';
}

use Socket qw(AF_INET SOCK_DGRAM getaddrinfo inet_ntop pack_sockaddr_in);
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

my $loop = IO::Async::Loop->new;
my @server_errors;
my $app = async sub {
    my ($scope, $receive, $send) = @_;
    my $body = '';
    while (1) {
        my $event = await $receive->();
        $body .= $event->{body} // '';
        last unless $event->{more};
    }
    await $loop->delay_future(after => 0.08)
        if $scope->{path} eq '/slow';
    await $send->({
        type => 'http.response.start', status => 200,
        headers => [['content-type', 'text/plain']],
    });
    await $send->({
        type => 'http.response.body',
        body => "$scope->{method}:$scope->{path}:$body", more => 0,
    });
};

my $server = PAGI::Server::HTTP3->new(
    app => $app,
    config => Net::Quiche->config(
        %transport, certificate_chain => $cert, private_key => $key,
    ),
    host => '127.0.0.1', port => 0,
    on_error => sub { push @server_errors, "$_[0]" },
);
$loop->add($server);
$loop->await($server->listen)->get;

my (@control_streams, @destinations, @relays);
my $listener = IO::Async::Listener->new(
    on_stream => sub {
        my (undef, $stream) = @_;
        push @control_streams, $stream;
        my ($relay, $client_address);
        my $stage = 'greeting';
        $stream->configure(on_read => sub {
            my ($stream, $buffer, $eof) = @_;
            if ($stage eq 'greeting') {
                return 0 if length($$buffer) < 2;
                my ($version, $count) = unpack('CC', substr($$buffer, 0, 2));
                return 0 if length($$buffer) < 2 + $count;
                substr($$buffer, 0, 2 + $count, '');
                die 'bad SOCKS5 greeting' unless $version == 5;
                $stream->write(pack('CC', 5, 0));
                $stage = 'associate';
            }
            if ($stage eq 'associate') {
                return 0 if length($$buffer) < 10;
                my ($version, $command, $reserved, $type) =
                    unpack('CCCC', substr($$buffer, 0, 4));
                die 'bad UDP ASSOCIATE request'
                    unless $version == 5 && $command == 3
                        && $reserved == 0 && $type == 1;
                substr($$buffer, 0, 10, '');
                $stage = 'binding';
                $relay = IO::Async::Socket->new(
                    recv_len => 65_535, recv_all => 1, autoflush => 1,
                    on_recv => sub {
                        my (undef, $packet, $peer) = @_;
                        if (defined($client_address) && $peer ne $client_address) {
                            my $header = _address_header($peer);
                            $relay->send("\0\0\0" . $header . $packet,
                                0, $client_address);
                            return;
                        }
                        $client_address = $peer;
                        my ($destination, $payload, $label) =
                            _unwrap_request($packet);
                        push @destinations, $label;
                        $relay->send($payload, 0, $destination);
                    },
                    on_recv_error => sub { die "relay receive failed: $_[1]" },
                    on_send_error => sub { die "relay send failed: $_[1]" },
                );
                push @relays, $relay;
                $loop->add($relay);
                $relay->bind(
                    host => '127.0.0.1', service => 0,
                    family => AF_INET, socktype => 'dgram',
                )->on_done(sub {
                    my $port = $relay->read_handle->sockport;
                    $stream->write(pack('CCCC', 5, 0, 0, 1)
                        . pack('C4', 127, 0, 0, 1) . pack('n', $port));
                    $stage = 'ready';
                });
            }
            return 0;
        });
        $loop->add($stream);
    },
);
$loop->add($listener);
$loop->await($listener->listen(
    host => '127.0.0.1', service => 0, socktype => 'stream',
))->get;
my $proxy_port = $listener->read_handle->sockport;

eval {
    Net::Quiche::HTTP3::Client->new(
        config => Net::Quiche->config(%transport, verify_peer => 0),
        proxy => 'http://127.0.0.1:8080',
    );
};
like($@, qr/only supports socks5 and socks5h/i,
    'ordinary TCP HTTP proxies are rejected for QUIC');
eval {
    Net::Quiche::HTTP3::Client->new(
        config => Net::Quiche->config(%transport, verify_peer => 0),
        proxy => "socks5://user:secret\@127.0.0.1:$proxy_port",
    );
};
like($@, qr/authentication is not supported/,
    'proxy credentials are rejected instead of being ignored or leaked');

my $client = Net::Quiche::HTTP3::Client->new(
    config => Net::Quiche->config(%transport, verify_peer => 0),
    proxy => "socks5h://127.0.0.1:$proxy_port",
);
$loop->add($client);
my $base = 'https://localhost:' . $server->bound_port;
eval {
    $client->get(
        "$base/leak",
        headers => [['proxy-authorization', 'Basic secret']],
    );
};
like($@, qr/proxy-authorization is not a supported origin request header/,
    'proxy credentials cannot be sent as an origin header');
my $get = $loop->await($client->get("$base/proxied"))->get;
is($get->body, 'GET:/proxied:', 'GET crosses a SOCKS5 UDP relay');
my $post = $loop->await($client->post(
    "$base/upload", body => "potato\0proxy",
))->get;
is($post->body, "POST:/upload:potato\0proxy",
    'POST body crosses the same proxied QUIC connection');
ok(grep($_ eq 'localhost:' . $server->bound_port, @destinations),
    'socks5h sends the destination hostname to the proxy');
is(scalar(@control_streams), 1,
    'one TCP UDP-association control connection owns the origin lifetime');
is($client->connection_count, 1,
    'proxied requests reuse one QUIC connection');
my $proxy_timeout = $loop->await(
    $client->get("$base/slow", timeout => 0.02));
ok($proxy_timeout->is_failed,
    'request timeout also cancels a stream through SOCKS5 UDP relay');
like(($proxy_timeout->failure)[0], qr/timed out after 0\.02 seconds/,
    'proxied timeout preserves the public timeout error');
my $after_timeout = $loop->await(
    $client->get("$base/after-timeout"))->get;
is($after_timeout->body, 'GET:/after-timeout:',
    'proxied connection remains reusable after timeout');
is_deeply(\@server_errors, [],
    'proxied cancellation is not reported as a PAGI server error');

$client->stop;
my $local_dns_client = Net::Quiche::HTTP3::Client->new(
    config => Net::Quiche->config(%transport, verify_peer => 0),
    proxy => "socks5://127.0.0.1:$proxy_port",
);
$loop->add($local_dns_client);
my $local_dns = $loop->await($local_dns_client->get(
    'https://127.0.0.1:' . $server->bound_port . '/local-dns',
))->get;
is($local_dns->body, 'GET:/local-dns:',
    'socks5 uses a locally resolved numeric destination');
ok(grep($_ eq '127.0.0.1:' . $server->bound_port, @destinations),
    'socks5 sends the numeric destination to the proxy');
$local_dns_client->stop;

my $ipv6_codec = Net::Quiche::HTTP3::Proxy::SOCKS5->new(
    'socks5://[::1]:1080');
my $ipv6_target = $ipv6_codec->target('::1', 443, []);
is(unpack('C', $ipv6_target->{header}), 4,
    'SOCKS5 codec uses the IPv6 address type');
is($ipv6_codec->unwrap_datagram(
    "\0\0\0" . $ipv6_target->{header} . 'ipv6-payload'),
    'ipv6-payload', 'SOCKS5 codec unwraps an IPv6 relay header');

$server->stop;
$listener->close;
$_->close for @relays;
done_testing;

sub _unwrap_request {
    my ($packet) = @_;
    die 'short SOCKS5 UDP packet' if length($packet) < 7;
    my ($reserved, $fragment, $type) = unpack('nCC', substr($packet, 0, 4));
    die 'bad SOCKS5 UDP packet' if $reserved != 0 || $fragment != 0;
    my ($host, $offset);
    if ($type == 1) {
        die 'short IPv4 SOCKS5 UDP packet' if length($packet) < 10;
        $host = join '.', unpack('C4', substr($packet, 4, 4));
        $offset = 8;
    } elsif ($type == 3) {
        my $length = unpack('C', substr($packet, 4, 1));
        die 'short domain SOCKS5 UDP packet' if length($packet) < 7 + $length;
        $host = substr($packet, 5, $length);
        $offset = 5 + $length;
    } else {
        die "unsupported SOCKS5 address type $type in test relay";
    }
    my $port = unpack('n', substr($packet, $offset, 2));
    my ($error, @addresses) = getaddrinfo(
        $host, $port, { family => AF_INET, socktype => SOCK_DGRAM },
    );
    die "test relay cannot resolve $host: $error" if $error || !@addresses;
    return ($addresses[0]{addr}, substr($packet, $offset + 2), "$host:$port");
}

sub _address_header {
    my ($packed) = @_;
    my ($port, $address) = Socket::unpack_sockaddr_in($packed);
    return pack('C', 1) . $address . pack('n', $port);
}
