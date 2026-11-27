use strict;
use warnings;
use Test::More;
use Scalar::Util qw(isweak);
use Socket qw(AF_INET SOCK_DGRAM pack_sockaddr_in unpack_sockaddr_in inet_aton inet_ntoa);

BEGIN {
    eval {
        require Future;
        require IO::Async::Loop;
        require IO::Async::Socket;
        require IO::Async::Timer::Countdown;
        1;
    } or plan skip_all => 'Future and IO::Async are required';
}

use Net::Quiche;
use Net::Quiche::Connection;
use Net::Quiche::HTTP3::Client;
use Net::Quiche::Packet;

my $cert = 't/fixtures/cert.crt';
my $key  = 't/fixtures/cert.key';
BAIL_OUT('bundled TLS fixtures are missing from t/fixtures')
    unless -f $cert && -f $key;

my %transport = (
    max_idle_timeout                    => 10_000,
    max_recv_udp_payload_size           => 1_350,
    max_send_udp_payload_size           => 1_350,
    initial_max_data                    => 10_000_000,
    initial_max_stream_data_bidi_local  => 1_000_000,
    initial_max_stream_data_bidi_remote => 1_000_000,
    initial_max_stream_data_uni         => 1_000_000,
    initial_max_streams_bidi            => 100,
    initial_max_streams_uni             => 100,
    disable_active_migration            => 1,
);

# Minimal pure-Net::Quiche UDP loopback HTTP/3 echo server (zero PAGI dependency).
sub start_h3_echo_server {
    my ($loop) = @_;
    my $server_config = Net::Quiche->config(
        certificate_chain => $cert,
        private_key       => $key,
        %transport,
    );

    my $sock = IO::Async::Socket->new(
        on_recv => sub {},
        on_recv_error => sub {},
    );
    $loop->add($sock);
    $sock->bind(
        family   => 'inet',
        socktype => 'dgram',
        host     => '127.0.0.1',
        service  => 0,
    )->get;

    my ($port, $ip_bin) = unpack_sockaddr_in($sock->read_handle->sockname);
    my $local_addr = [inet_ntoa($ip_bin), $port];
    my %conns;
    my $next_scid = 1;

    my $flush;
    $flush = sub {
        my ($st) = @_;
        while (my $d = $st->{conn}->next_datagram) {
            my $dest = pack_sockaddr_in($d->{to}[1], inet_aton($d->{to}[0]));
            $sock->send($d->{data}, 0, $dest);
        }
        $st->{timer}->stop if $st->{timer}->is_running;
        if (defined(my $ms = $st->{conn}->timeout_ms)) {
            $st->{timer}->configure(delay => $ms / 1_000);
            $st->{timer}->start;
        }
    };

    my $drain_h3 = sub {
        my ($st) = @_;
        return unless $st->{conn}->is_established;
        $st->{h3} ||= $st->{conn}->http3;
        while (my $ev = $st->{h3}->poll) {
            my $sid = $ev->{stream_id};
            if ($ev->{type} eq 'headers') {
                my %pseudo = map { $_->[0] => $_->[1] } grep { $_->[0] =~ /\A:/ } @{$ev->{headers}};
                $st->{streams}{$sid} = {
                    method => $pseudo{':method'} // 'GET',
                    path   => $pseudo{':path'}   // '/',
                    body   => '',
                };
            } elsif ($ev->{type} eq 'data') {
                $st->{streams}{$sid}{body} .= $ev->{body} if $st->{streams}{$sid};
            } elsif ($ev->{type} eq 'finished') {
                my $req = delete $st->{streams}{$sid} or next;
                if ($req->{path} eq '/redirect') {
                    $st->{h3}->send_response(
                        $sid,
                        status  => 302,
                        headers => [['location', '/hello']],
                        final   => 1,
                    );
                    next;
                }
                if ($req->{path} eq '/goaway') {
                    $st->{h3}->send_goaway($sid + 4);
                    $st->{h3}->send_response(
                        $sid,
                        status  => 200,
                        headers => [['content-type', 'text/plain']],
                        final   => 0,
                    );
                    $st->{h3}->send_body($sid, 'GOING-AWAY', final => 1);
                    next;
                }
                if ($req->{path} eq '/slow') {
                    # Intentionally never reply so client can cancel
                    next;
                }
                my $resp_body = $req->{path} eq '/big'
                    ? ('B' x 8_192)
                    : $req->{method} eq 'POST'
                        ? "POST:$req->{body}"
                        : "GET:$req->{path}";
                $st->{h3}->send_response(
                    $sid,
                    status  => 200,
                    headers => [['content-type', 'text/plain']],
                    final   => 0,
                );
                $st->{h3}->send_body($sid, $resp_body, final => 1);
            }
        }
    };

    $sock->configure(
        on_recv => sub {
            my ($self, $dgram, $addr) = @_;
            my ($peer_port, $peer_ip_bin) = unpack_sockaddr_in($addr);
            my $peer = [inet_ntoa($peer_ip_bin), $peer_port];
            my $hdr = eval { Net::Quiche::Packet->header_info($dgram) } or return;
            my $dcid = $hdr->{destination_connection_id};
            my $st = $conns{$dcid};
            if (!$st) {
                my $scid = sprintf('srv-%012d', $next_scid++);
                my $conn = Net::Quiche::Connection->accept(
                    config               => $server_config,
                    source_connection_id => $scid,
                    local                => $local_addr,
                    peer                 => $peer,
                );
                my $timer;
                $st = { conn => $conn, h3 => undef, streams => {}, scid => $scid };
                $timer = IO::Async::Timer::Countdown->new(
                    delay => 1,
                    on_expire => sub {
                        $st->{conn}->on_timeout;
                        $drain_h3->($st);
                        $flush->($st);
                    },
                );
                $loop->add($timer);
                $st->{timer} = $timer;
                $conns{$scid} = $st;
                $conns{$dcid} = $st;
            }
            eval { $st->{conn}->receive_datagram($dgram, from => $peer, to => $local_addr); 1 } or return;
            $drain_h3->($st);
            $flush->($st);
        },
    );

    my $stop = sub {
        for my $st (values %conns) {
            $st->{timer}->stop if $st->{timer} && $st->{timer}->is_running;
            $loop->remove($st->{timer}) if $st->{timer} && $st->{timer}->parent;
        }
        %conns = ();
        $loop->remove($sock) if $sock->parent;
    };

    return ($port, $stop);
}

my $loop = IO::Async::Loop->new;
my ($port, $stop_server) = start_h3_echo_server($loop);

# 1. GET, POST, and connection reuse with explicit verify_peer => 0
{
    my $client = Net::Quiche::HTTP3::Client->new(
        config => Net::Quiche->config(%transport, verify_peer => 0),
        request_timeout => 5,
    );
    $loop->add($client);

    my $get = $loop->await($client->get("https://127.0.0.1:$port/hello"))->get;
    is($get->status, 200, 'GET returns 200');
    is($get->body, 'GET:/hello', 'GET body matches');

    my $post = $loop->await($client->post("https://127.0.0.1:$port/echo", body => 'ping-h3'))->get;
    is($post->status, 200, 'POST returns 200');
    is($post->body, 'POST:ping-h3', 'POST body echoed');

    # Concurrent multiplexed requests on the same connection
    my ($r1, $r2) = $loop->await(Future->needs_all(
        $client->get("https://127.0.0.1:$port/one"),
        $client->get("https://127.0.0.1:$port/two"),
    ))->get;
    is($r1->body, 'GET:/one', 'multiplexed request 1 ok');
    is($r2->body, 'GET:/two', 'multiplexed request 2 ok');
    is($client->connection_count, 1, 'reuses a single QUIC connection');

    # 2. Exchange holds genuine weak references (no cycle)
    my $exchange = $client->start_request(
        method => 'GET', uri => "https://127.0.0.1:$port/big",
    );
    $loop->await($exchange->finish_request)->get;
    ok(isweak($exchange->{client}), 'Exchange->{client} is a weak reference');
    ok(isweak($exchange->{state}),  'Exchange->{state} is a weak reference');
    {
        # Drop the Response without reading its 8 KiB body
        my $unread_resp = $loop->await($exchange->response)->get;
        is($unread_resp->status, 200, 'streaming response received');
    }
    # Subsequent request on the same origin must NOT stall
    my $after = $loop->await($client->get("https://127.0.0.1:$port/after-drop"))->get;
    is($after->body, 'GET:/after-drop', 'dropping unread response does not stall origin');

    # 3. Streaming request upload + streaming response read
    my $stream_ex = $client->start_request(
        method => 'POST', uri => "https://127.0.0.1:$port/stream-up",
    );
    $loop->await($stream_ex->write('chunk1-'))->get;
    $loop->await($stream_ex->write('chunk2'))->get;
    $loop->await($stream_ex->finish_request)->get;
    my $stream_resp = $loop->await($stream_ex->response)->get;
    my $collected = '';
    while (defined(my $chunk = $loop->await($stream_resp->read)->get)) {
        $collected .= $chunk;
    }
    is($collected, 'POST:chunk1-chunk2', 'streaming write + read round-trip ok');

    # 4. Redirect handling (302 -> /hello)
    my $redir = $loop->await($client->get("https://127.0.0.1:$port/redirect", max_redirects => 2))->get;
    is($redir->status, 200, '302 redirect followed to 200');
    is($redir->body, 'GET:/hello', 'redirect target body matches');

    # 5. Request cancellation does not break subsequent requests
    my $slow_f = $client->get("https://127.0.0.1:$port/slow");
    $slow_f->cancel;
    ok($slow_f->is_cancelled, 'cancelled request Future is marked cancelled');
    my $post_cancel = $loop->await($client->get("https://127.0.0.1:$port/after-cancel"))->get;
    is($post_cancel->body, 'GET:/after-cancel', 'connection stays healthy after cancel');

    # 6. GOAWAY causes subsequent request to open a new connection cleanly
    my $ga = $loop->await($client->get("https://127.0.0.1:$port/goaway"))->get;
    is($ga->body, 'GOING-AWAY', 'in-flight request completes on GOAWAY');
    my $after_ga = $loop->await($client->get("https://127.0.0.1:$port/fresh"))->get;
    is($after_ga->body, 'GET:/fresh', 'next request succeeds after GOAWAY');

    $client->stop;
    $loop->remove($client);
}

# 3. Default client config enables verify_peer => 1 and rejects self-signed cert
{
    my $strict_client = Net::Quiche::HTTP3::Client->new(
        config => Net::Quiche->config(%transport),
        request_timeout => 2,
    );
    $loop->add($strict_client);
    my $ok = eval { $loop->await($strict_client->get("https://127.0.0.1:$port/strict"))->get; 1 };
    ok(!$ok, 'default client config verifies peer and rejects self-signed cert');
    $strict_client->stop;
    $loop->remove($strict_client);
}

$stop_server->();
done_testing;
