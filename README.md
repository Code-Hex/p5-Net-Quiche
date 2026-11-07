# NAME

Net::Quiche - Perl interface to quiche

# SYNOPSIS

    use Net::Quiche;
    print Net::Quiche::version(), "\n";

    my $config = Net::Quiche->config(
        certificate_chain => 'cert.pem',
        private_key       => 'key.pem',
    );

# DESCRIPTION

Net::Quiche binds quiche's official C API for QUIC and HTTP/3. The XS layer
converts values, calls C functions and frees native handles. Perl owns UDP
sockets, timers and application state.

[Net::Quiche::Config](https://metacpan.org/pod/Net%3A%3AQuiche%3A%3AConfig), [Net::Quiche::Packet](https://metacpan.org/pod/Net%3A%3AQuiche%3A%3APacket), [Net::Quiche::Connection](https://metacpan.org/pod/Net%3A%3AQuiche%3A%3AConnection) and
[Net::Quiche::HTTP3](https://metacpan.org/pod/Net%3A%3AQuiche%3A%3AHTTP3) provide the transport API. [Net::Quiche::HTTP3::Client](https://metacpan.org/pod/Net%3A%3AQuiche%3A%3AHTTP3%3A%3AClient)
provides an IO::Async client. [PAGI::Server::HTTP3](https://metacpan.org/pod/PAGI%3A%3AServer%3A%3AHTTP3) runs PAGI applications
over HTTP/3, with an optional adapter for PSGI applications.

This is an experimental implementation. The current tests cover GET and POST,
IPv4 and IPv6, request streaming, response backpressure, redirects, SOCKS5 UDP
proxying, cancellation, GOAWAY and bounded shutdown. Retry tokens, connection
migration, trailers and production resource limits are not implemented.

# INSTALLATION

Perl 5.16 or later, a C compiler and released quiche 0.29.3 or later are
required. Build quiche with `ffi,pkg-config-meta`, then point
`PKG_CONFIG_PATH` at its `quiche.pc`. quiche is a separate native dependency
and is not bundled or downloaded during Perl module installation.

From a checkout or source distribution:

    cpanm --installdeps .
    perl Build.PL
    ./Build
    ./Build test
    ./Build install

See [doc/DEVELOPMENT.md](https://github.com/Code-Hex/p5-Net-Quiche/blob/main/doc/DEVELOPMENT.md)
for the pinned quiche build, Minilla commands and HTTP/3 test environment.
The shared quiche library must remain available at runtime.

# EXAMPLES

After building, run the PAGI server and an HTTP/3-enabled curl:

    perl -Mblib examples/pagi-h3-server.pl
    curl -k --http3-only https://127.0.0.1:8443/

The response is `Hello from Perl over HTTP/3`. The example uses a public test
certificate and key included in `t/fixtures`. Use your own certificate for
any other purpose. `--certificate` and `--private-key` override those paths.

Other examples are `examples/psgi-h3-server.pl` and `examples/h3-client.pl`.
See [doc/API.md](https://github.com/Code-Hex/p5-Net-Quiche/blob/main/doc/API.md)
for the client, transport and server APIs.

# FUNCTIONS

## version()

Returns the linked quiche library version, for example `0.29.3`.
Takes no arguments and does not export symbols. `$Net::Quiche::VERSION`
identifies this Perl distribution separately.

## config(%options)

    my $config = Net::Quiche->config(
        certificate_chain => 'cert.pem',
        private_key       => 'key.pem',
    );

Convenience class method for ["new" in Net::Quiche::Config](https://metacpan.org/pod/Net%3A%3AQuiche%3A%3AConfig#new).

# DEVELOPMENT

The distribution uses Minilla. Edit `cpanfile`, `minil.toml`, the build
helper in `builder/MyBuilder.pm` and this POD; `Build.PL`, `META.json` and
`README.md` are generated. `minil test` tests a clean distribution, and
`minil dist` creates the source archive. Minilla is needed by maintainers,
not by users installing a release.

# AUTHOR

Kei Kamikawa <6500104+Code-Hex@users.noreply.github.com>

# COPYRIGHT AND LICENSE

Copyright 2026 Kei Kamikawa.

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

The public TLS test fixtures come from quiche and retain their BSD license
in `t/fixtures/COPYING.quiche`. quiche and BoringSSL are separate dependencies
with their own licenses.
