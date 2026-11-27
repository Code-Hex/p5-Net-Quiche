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
provides an IO::Async client.

This is an experimental implementation. The current tests cover QUIC handshakes,
HTTP/3 request/response framing, packet version negotiation, and transport
regressions. Retry tokens, connection migration, trailers and production
resource limits are not implemented.

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

After building, run the HTTP/3 client example:

    perl -Mblib examples/h3-client.pl https://cloudflare-quic.com/

See [doc/API.md](https://github.com/Code-Hex/p5-Net-Quiche/blob/main/doc/API.md)
for the client and transport APIs.

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
