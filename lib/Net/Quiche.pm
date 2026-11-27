package Net::Quiche;

use strict;
use warnings;
use Carp qw(croak);
use Net::Quiche::XS ();
use Net::Quiche::Config ();
use Net::Quiche::Connection ();
use Net::Quiche::HTTP3 ();
use Net::Quiche::Packet ();

our $VERSION = '0.013';

sub version {
    return Net::Quiche::XS::version(@_);
}

sub config {
    my ($class, @arguments) = @_;
    croak "config() must be called as Net::Quiche->config(...)"
        unless defined($class) && !ref($class) && $class eq __PACKAGE__;
    local $Carp::CarpLevel = 1;
    return Net::Quiche::Config->new(@arguments);
}

1;

__END__

=for stopwords backpressure proxying BoringSSL

=head1 NAME

Net::Quiche - Perl interface to quiche

=head1 SYNOPSIS

    use Net::Quiche;
    print Net::Quiche::version(), "\n";

    my $config = Net::Quiche->config(
        certificate_chain => 'cert.pem',
        private_key       => 'key.pem',
    );

=head1 DESCRIPTION

Net::Quiche binds quiche's official C API for QUIC and HTTP/3. The XS layer
converts values, calls C functions and frees native handles. Perl owns UDP
sockets, timers and application state.

L<Net::Quiche::Config>, L<Net::Quiche::Packet>, L<Net::Quiche::Connection> and
L<Net::Quiche::HTTP3> provide the transport API. L<Net::Quiche::HTTP3::Client>
provides an IO::Async client.

This is an experimental implementation. The current tests cover QUIC handshakes,
HTTP/3 request/response framing, packet version negotiation, and transport
regressions. Retry tokens, connection migration, trailers and production
resource limits are not implemented.

=head1 INSTALLATION

Perl 5.16 or later, a C compiler and released quiche 0.29.3 or later are
required. Build quiche with C<ffi,pkg-config-meta>, then point
C<PKG_CONFIG_PATH> at its C<quiche.pc>. quiche is a separate native dependency
and is not bundled or downloaded during Perl module installation.

From a checkout or source distribution:

    cpanm --installdeps .
    perl Build.PL
    ./Build
    ./Build test
    ./Build install

See L<doc/DEVELOPMENT.md|https://github.com/Code-Hex/p5-Net-Quiche/blob/main/doc/DEVELOPMENT.md>
for the pinned quiche build, Minilla commands and HTTP/3 test environment.
The shared quiche library must remain available at runtime.

=head1 EXAMPLES

After building, run the HTTP/3 client example:

    perl -Mblib examples/h3-client.pl https://cloudflare-quic.com/

See L<doc/API.md|https://github.com/Code-Hex/p5-Net-Quiche/blob/main/doc/API.md>
for the client and transport APIs.

=head1 FUNCTIONS

=head2 version()

Returns the linked quiche library version, for example C<0.29.3>.
Takes no arguments and does not export symbols. C<$Net::Quiche::VERSION>
identifies this Perl distribution separately.

=head2 config(%options)

    my $config = Net::Quiche->config(
        certificate_chain => 'cert.pem',
        private_key       => 'key.pem',
    );

Convenience class method for L<Net::Quiche::Config/new>.

=head1 DEVELOPMENT

The distribution uses Minilla. Edit C<cpanfile>, C<minil.toml>, the build
helper in C<builder/MyBuilder.pm> and this POD; C<Build.PL>, C<META.json> and
C<README.md> are generated. C<minil test> tests a clean distribution, and
C<minil dist> creates the source archive. Minilla is needed by maintainers,
not by users installing a release.

=head1 AUTHOR

Kei Kamikawa E<lt>6500104+Code-Hex@users.noreply.github.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright 2026 Kei Kamikawa.

This library is free software; you can redistribute it and/or modify it
under the same terms as Perl itself.

The public TLS test fixtures come from quiche and retain their BSD license
in C<t/fixtures/COPYING.quiche>. quiche and BoringSSL are separate dependencies
with their own licenses.

=cut
