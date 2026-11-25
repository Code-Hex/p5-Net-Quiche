# Net::Quiche

Early Perl binding to quiche's official C ABI. `Net::Quiche::Config`,
`Net::Quiche::Packet`, `Net::Quiche::Connection`, and `Net::Quiche::HTTP3`
form the transport API. `Net::Quiche::HTTP3::Client` adds an IO::Async client,
and `PAGI::Server::HTTP3` adds an IO::Async UDP listener.
`Net::Quiche::XS` keeps native pointer conversion, C calls, and destruction out
of the Perl layer.

```perl
use Net::Quiche;
print Net::Quiche::version(), "\n";  # 0.29.3 with the pinned build below

my $config = Net::Quiche::Config->new(
    certificate_chain                    => 'cert.pem',
    private_key                          => 'key.pem',
    max_idle_timeout                     => 30_000,
    initial_max_data                     => 10_000_000,
    initial_max_stream_data_bidi_remote  => 1_000_000,
    initial_max_streams_bidi             => 100,
);
```

`Net::Quiche::Config->new` accepts named arguments or a hash reference. It
defaults ALPN to `h3` and validates every option name and value shape before
allocating native state. Invalid values and native errors throw exceptions at
the user's call site. Setters return the same object, so calls can be chained.
Perl owns each native config and frees it when the object goes out of scope.

```perl
my $config = Net::Quiche->config({ verify_peer => 0 });

$config
    ->application_protocols('h3')
    ->max_idle_timeout(10_000)
    ->disable_active_migration(1);
```

Available constructor options and setters are documented in
`perldoc Net::Quiche::Config`. `max_idle_timeout` is measured in milliseconds.
Protocol names are byte strings and the module produces their ALPN wire encoding.

## Packet routing and version negotiation

`Net::Quiche::Packet` parses the small amount of header state a UDP server
needs before selecting a connection. It also creates a Version Negotiation
response without taking ownership of a socket:

```perl
my $header = Net::Quiche::Packet->header_info(
    $udp_payload,
    destination_connection_id_length => 16,
);

if (!Net::Quiche::Packet->version_is_supported($header->{version})) {
    my $reply = Net::Quiche::Packet->negotiate_version(
        source_connection_id      => $header->{source_connection_id},
        destination_connection_id => $header->{destination_connection_id},
    );
    # Send $reply to the peer that supplied $udp_payload.
}
```

Both methods return ordinary Perl values and accept byte-string connection
IDs. `PAGI::Server::HTTP3` performs this check automatically for an unknown
route. Unsupported nonzero versions receive a response and do not allocate a
QUIC connection; version-zero packets are ignored to avoid negotiation loops.

## QUIC without socket ownership

`Net::Quiche::Connection` accepts named arguments and consumes or produces one
UDP datagram at a time. It does not create a socket, register an I/O watcher,
or sleep for a timer. Those responsibilities stay with the Perl server and its
event loop.

```perl
my $connection = Net::Quiche::Connection->accept(
    config               => $server_config,
    source_connection_id => $server_connection_id,
    local => ['127.0.0.1', 8443],
    peer  => [$peer_ipv4, $peer_port],
);

$connection->receive_datagram({
    data => $udp_payload,
    from => [$peer_ipv4, $peer_port],
    to   => ['127.0.0.1', 8443],
});

while (my $datagram = $connection->next_datagram) {
    # Send $datagram->{data} from $datagram->{from} to $datagram->{to}.
}

my $milliseconds = $connection->timeout_ms;
# undef means quiche has no timer armed. Otherwise, when it expires:
$connection->on_timeout;
```

Addresses are `[IPv4 or IPv6 literal, port]` pairs. The module canonicalizes
the literal when it creates the connection. IPv6 zone identifiers such as
`fe80::1%en0` are not supported. The datagram hash is a value object suitable
for an IO::Async/Future adapter and deterministic tests. Connection IDs and
datagram contents are byte strings.

Pass `original_destination_connection_id` only after sending a QUIC Retry.
A server that accepts the client's first Initial directly must omit it. Sending
the Retry transport parameter without a Retry causes conforming clients to
close the handshake.

## HTTP/3 request-stream API

After the handshake, one HTTP/3 object belongs to one QUIC connection:

```perl
my $h3 = $connection->http3;

while (my $event = $h3->poll) {
    my $stream_id = $event->{stream_id};

    if ($event->{type} eq 'headers') {
        my $headers = $event->{headers}; # ordered [name, value] pairs
    } elsif ($event->{type} eq 'data') {
        my $bytes = $event->{body};
    } elsif ($event->{type} eq 'finished') {
        # The request body for this stream is complete.
    }
}

$h3->send_response($stream_id,
    status  => 200,
    headers => [['content-type', 'text/plain']],
);
$h3->send_body($stream_id, "Hello from Perl over HTTP/3\n", final => 1);

# A server cutoff is a client-initiated bidirectional stream ID.
$h3->send_goaway(4);
```

Every event carries a `stream_id`. Headers remain an ordered array of pairs,
so duplicates such as `set-cookie` are not collapsed. Body reads are bounded
chunks rather than an unbounded allocation. Writes return the accepted byte
count; a temporarily blocked write returns `undef` and can be retried after
transport progress. If the peer resets a stream while its body is being read,
`poll` returns `{ type => "reset", stream_id => $id }` for that stream and
keeps working for the others.

By default `poll` reads each `data` event's body for you. Pass
`read_body => 0` to get `{ type => "data", stream_id => $id }` without a
body, then call `$h3->recv_body($stream_id, $max_bytes)` until it returns
`undef`. Data that has not been read stays in quiche and holds back the
peer's flow-control window, which lets a server apply backpressure to a
request body. quiche does not report `data` again for a stream until its
buffered body has been read to the end, and a `finished` event only follows
once the body has been read.

Calling `$connection->http3` again after dropping the returned object gives a
new wrapper around the same HTTP/3 session. Error codes passed to `close` and
`shutdown_stream` must fit in a QUIC varint (at most 2^62-1).

GOAWAY events use `{ type => "goaway", id => $cutoff }` because the cutoff
belongs to the connection rather than one request stream. `send_goaway`
returns `undef` if the control stream is blocked. The caller must retain the
cutoff and retry after transport progress. GOAWAY does not close QUIC.

## HTTP/3 client

`Net::Quiche::HTTP3::Client` owns UDP sockets and QUIC timers. It reuses one
connection per HTTPS origin and keeps concurrent request streams separate.
Add it to an IO::Async loop before sending requests:

```perl
use Future::AsyncAwait;
use IO::Async::Loop;
use Net::Quiche;
use Net::Quiche::HTTP3::Client;

my $loop = IO::Async::Loop->new;
my $client = Net::Quiche::HTTP3::Client->new(
    config => Net::Quiche->config(
        verify_peer => 1,
        verify_locations_file => '/etc/ssl/cert.pem',
        initial_max_data => 10_000_000,
        initial_max_stream_data_bidi_local => 1_000_000,
        initial_max_stream_data_bidi_remote => 1_000_000,
        initial_max_stream_data_uni => 1_000_000,
        initial_max_streams_bidi => 100,
        initial_max_streams_uni => 100,
    ),
    request_timeout => 30,
);
$loop->add($client);

my $response = await $client->post(
    'https://example.test/echo',
    headers => [['content-type', 'application/octet-stream']],
    body => $bytes,
);
say $response->status;
say $response->body;
```

`request_timeout` is an optional client default in seconds. A buffered request
can override it, and cancelling its Future cancels the active request stream:

```perl
my $future = $client->get(
    'https://example.test/report',
    timeout => 5.5,
);
$future->cancel if $request_is_no_longer_needed;
```

The timeout covers the complete logical request, including followed redirects.
A timeout fails the Future; an explicit `cancel` leaves it in Future's cancelled
state. In both cases the client sends HTTP/3 `H3_REQUEST_CANCELLED` once a QUIC
stream exists and keeps a healthy origin connection available for later
requests.

Redirect following is opt-in, which preserves access to the original 3xx
response. Set the limit on a client or one buffered request:

```perl
my $client = Net::Quiche::HTTP3::Client->new(
    config => $config,
    max_redirects => 5,
);

my $response = await $client->get(
    'https://example.test/old',
    max_redirects => 2,
);
say $response->effective_uri;
for my $hop (@{$response->redirect_history}) {
    say "$hop->{status} $hop->{uri} -> $hop->{location}";
}
```

The buffered API follows 301, 302, 303, 307, and 308. A POST becomes GET for
301 and 302; 303 becomes GET except for HEAD. 307 and 308 replay the method
and body. Cross-origin hops remove `authorization`, `proxy-authorization`,
and `cookie`. The client drains each intermediate response before opening the
next request. `start_request` never follows redirects because a streaming
body cannot be replayed safely.

HTTP/3 needs a UDP-capable proxy. This client implements the no-authentication
SOCKS5 UDP ASSOCIATE subset:

```perl
my $client = Net::Quiche::HTTP3::Client->new(
    config => $config,
    proxy => 'socks5h://127.0.0.1:1080',
);
```

With `socks5://`, Perl resolves the destination and sends its numeric address
to the proxy. With `socks5h://`, the proxy resolves the destination name. The
client keeps one TCP UDP-association control connection and one UDP relay
socket per origin. Plain `http://` and `https://` proxy URIs are rejected
because their ordinary CONNECT tunnel carries TCP, not QUIC datagrams.

`get`, `post`, and `request` buffer a response up to `max_response_body`,
which defaults to 16 MiB. `start_request` exposes request and response
backpressure directly:

```perl
my $exchange = $client->start_request(
    method => 'POST',
    uri => 'https://example.test/upload',
    headers => [['content-type', 'application/octet-stream']],
);

await $exchange->write($first_chunk);
await $exchange->write($second_chunk);
await $exchange->finish_request;

my $response = await $exchange->response;
while (defined(my $chunk = await $response->read)) {
    consume($chunk);
}
```

At any point, the owner can call
`$exchange->cancel if $upload_is_no_longer_needed`. It is idempotent and
returns true only when it cancels an active exchange.

Only one `write` and one response `read` may be pending per exchange. Request
body scalars remain owned by the exchange until quiche accepts them. Response
DATA is copied into Perl byte strings and retained until `read` consumes it.
`response_buffer_limit` bounds unread DATA across one origin and defaults to
1 MiB. HTTPS is mandatory and peer verification is controlled by the supplied
quiche config. SOCKS5 authentication, UDP fragmentation, MASQUE CONNECT-UDP,
0-RTT, response trailers, and connection migration are not implemented.
DNS currently uses a synchronous `getaddrinfo` call when an origin is first
opened; UDP and QUIC processing remain asynchronous after resolution. A request
deadline is armed before lookup, but cannot interrupt `getaddrinfo` while that
blocking system call is running.

For synchronous Test::More code, `PAGI::Test::HTTP3Client` runs the real PAGI
listener and client on a private loop:

```perl
my $test = PAGI::Test::HTTP3Client->new(
    app => $app,
    server_config => $config_with_test_certificate,
);

my $response = $test->post('/echo', body => 'hello');
is $response->status, 200;
is $response->body, 'hello';
```

The test helper disables certificate verification in its default client
configuration. It is not a production user agent.

After building, the included GET client can check another HTTP/3 server:

```sh
perl -Mblib examples/h3-client.pl https://example.com/
```

It uses `SSL_CERT_FILE` or `/etc/ssl/cert.pem`. Pass `--ca-file PATH` on
systems with a different CA bundle. `--insecure` is available for local test
certificates. `--max-redirects N` enables redirects and
`--proxy socks5h://HOST:PORT` sends QUIC through a SOCKS5 UDP relay.

## PAGI UDP listener

`PAGI::Server::HTTP3` binds an IPv4 or IPv6 UDP socket through IO::Async. Its
`host` option takes a numeric IP literal. It owns the DCID routing table and
quiche timers. `PAGI::Server::Protocol::HTTP3` owns one PAGI stream table per
QUIC connection and performs this translation:

```text
headers(stream_id)  -> create one PAGI http scope with http_version => "3"
data(stream_id)     -> { type => "http.request", body => $bytes, more => 1 }
finished(stream_id) -> { type => "http.request", body => "", more => 0 }
response.start      -> send_response(stream_id, ...)
response.body       -> send_body(stream_id, ..., final => !$more)
```

The key boundary remains `QUIC connection != PAGI HTTP scope`. One connection
can multiplex many request stream IDs.

To retire the listener's current connections without dropping accepted
requests, send GOAWAY and await its Future:

```perl
await $server->goaway;
```

The listener sends the RFC 9114 maximum server cutoff to each current
connection. Existing request streams can finish. New connections are still
accepted, which lets clients reconnect to the same origin. Call `stop`
separately when the process is ready to close the UDP socket.

For process shutdown, use the bounded drain API:

```perl
await $server->shutdown(grace => 5);
```

`shutdown` immediately refuses new QUIC connections while continuing to route
packets for existing ones. It sends the initial maximum GOAWAY, waits for the
accepted PAGI streams, sends a final lower cutoff, and closes each QUIC
connection with H3_NO_ERROR. The `grace` value is a maximum wait in seconds and
defaults to 5. At the deadline, remaining PAGI streams receive
`server_shutdown` before the listener closes. Cancelling a caller's Future does
not cancel shutdown. `stop` remains the synchronous immediate-stop operation.

Request bodies arrive as byte-string `http.request` events. Keep receiving
until `more` is false:

```perl
my $body = '';
while (1) {
    my $event = await $receive->();
    last if $event->{type} ne 'http.request';
    $body .= $event->{body} // '';
    last unless $event->{more};
}
```

PAGI applications must await every `$send->(...)` Future. The Future resolves
only after quiche accepts the complete event. When QUIC flow control accepts
only part of a response body, the protocol keeps the unsent suffix and retries
it after later transport input. One pending send per request stream is allowed;
an overlapping send returns a failed Future instead of growing an unbounded
application-side queue.

Run the included PAGI app after building the XS module:

```sh
perl -Mblib examples/pagi-h3-server.pl

curl -k --http3-only \
  https://127.0.0.1:8443/
```

For IPv6 loopback, start the example with `--host ::1` and use a bracketed URL:

```sh
perl -Mblib examples/pagi-h3-server.pl --host ::1

curl -k --http3-only --noproxy '*' \
  'https://[::1]:8443/'
```

The response is:

```text
Hello from Perl over HTTP/3
```

The same listener accepts POST bodies:

```sh
curl -k --http3-only \
  --data-binary 'hello over HTTP/3' \
  https://127.0.0.1:8443/
```

The example reports `Received 17 request bytes` after the greeting.

Set `NET_QUICHE_DEBUG=1` to print packet routing and handshake progress.

Pass a PSGI code reference as `psgi_app`:

```perl
my $server = PAGI::Server::HTTP3->new(
    psgi_app => sub {
        my ($env) = @_;
        return [200, ['Content-Type' => 'text/plain'], ['Hello from PSGI']];
    },
    config => $config,
);
```

The listener lazily loads
[`PAGI::App::WrapPSGI`](https://github.com/jjn1056/PAGI-Tools/blob/master/lib/PAGI/App/WrapPSGI.pm).
Install PAGI-Tools to use this optional path. `app` and `psgi_app` are mutually
exclusive. The existing adapter buffers the full request body before calling
the PSGI application. The XS layer still knows nothing about PAGI scopes or
PSGI environments. Run `examples/psgi-h3-server.pl` for a complete example.

This is a PAGI HTTP MVP, not a PAGI conformance claim. It implements HTTP
scope creation, `http.request`, `http.response.start`, and
`http.response.body`. The unsupported protocol and production features are
listed below.

Build and test instructions are in [DEVELOPMENT.md](DEVELOPMENT.md).
