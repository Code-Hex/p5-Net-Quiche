package Net::Quiche::Packet;

use strict;
use warnings;
use Carp qw(croak);
use Net::Quiche::XS ();

our $VERSION = '0.013';

sub header_info {
    my ($class, $packet, @arguments) = @_;
    _class($class);
    $packet = _bytes('packet', $packet);
    my %options = _options('header_info', @arguments);
    my @unknown = sort grep { $_ ne 'destination_connection_id_length' } keys %options;
    croak "header_info() received unknown option '$unknown[0]'" if @unknown;
    my $length = exists $options{destination_connection_id_length}
        ? $options{destination_connection_id_length} : 16;
    croak 'destination_connection_id_length must be an integer from 0 to 20'
        if !defined($length) || ref($length) || $length !~ /\A(?:0|[1-9][0-9]*)\z/
            || $length > 20;

    my $info = Net::Quiche::XS::_packet_header_info($packet, $length);
    return {
        version                   => $info->[0],
        type                      => $info->[1],
        source_connection_id      => $info->[2],
        destination_connection_id => $info->[3],
        token                     => $info->[4],
    };
}

sub version_is_supported {
    my ($class, $version) = @_;
    _class($class);
    croak 'version_is_supported() expects one unsigned 32-bit integer'
        unless @_ == 2 && defined($version) && !ref($version)
            && $version =~ /\A(?:0|[1-9][0-9]*)\z/
            && $version <= 4_294_967_295;
    return !!Net::Quiche::XS::_version_is_supported($version);
}

sub negotiate_version {
    my ($class, @arguments) = @_;
    _class($class);
    my %options = _options('negotiate_version', @arguments);
    my @unknown = sort grep {
        $_ ne 'source_connection_id' && $_ ne 'destination_connection_id'
    } keys %options;
    croak "negotiate_version() received unknown option '$unknown[0]'" if @unknown;

    for my $name (qw(source_connection_id destination_connection_id)) {
        croak "negotiate_version() requires $name" unless exists $options{$name};
        $options{$name} = _bytes($name, $options{$name});
        my $length = length $options{$name};
        croak "$name must contain at most 20 bytes" if $length > 20;
    }

    return Net::Quiche::XS::_packet_negotiate_version(
        $options{source_connection_id},
        $options{destination_connection_id},
    );
}

sub _class {
    my ($class) = @_;
    croak 'Packet method must be called on Net::Quiche::Packet'
        unless defined($class) && !ref($class) && $class eq __PACKAGE__;
}

sub _bytes {
    my ($name, $value) = @_;
    croak "$name must be a defined byte string" if !defined($value) || ref($value);
    my $bytes = $value;
    croak "$name must be a byte string" unless utf8::downgrade($bytes, 1);
    return $bytes;
}

sub _options {
    my ($method, @arguments) = @_;
    return () unless @arguments;
    return %{$arguments[0]} if @arguments == 1 && ref($arguments[0]) eq 'HASH';
    croak "$method() received an odd number of arguments" if @arguments % 2;
    return @arguments;
}

1;

__END__

=for stopwords datagram

=head1 NAME

Net::Quiche::Packet - Parse QUIC packet headers for server routing

=head1 DESCRIPTION

C<header_info> copies connection IDs and the Retry token into Perl byte
strings. The UDP listener uses the destination connection ID to find or create
a L<Net::Quiche::Connection> before passing the full datagram to quiche.
C<negotiate_version> accepts named source and destination connection IDs from
that header hash and returns a complete Version Negotiation UDP payload.

=head1 CLASS METHODS

=head2 header_info($packet, %options)

Returns a hash containing C<version>, C<type>, C<source_connection_id>,
C<destination_connection_id>, and C<token>. The optional
C<destination_connection_id_length> is used when parsing a short header and
defaults to 16.

=head2 version_is_supported($version)

Returns true when the linked quiche library supports the unsigned 32-bit QUIC
version.

=head2 negotiate_version(%options)

    my $reply = Net::Quiche::Packet->negotiate_version(
        source_connection_id      => $header->{source_connection_id},
        destination_connection_id => $header->{destination_connection_id},
    );

Returns a complete Version Negotiation packet as a byte string. Pass the
source and destination connection IDs exactly as parsed from the unsupported
incoming packet; the generated response places them in their required wire
positions. Each connection ID may contain from 0 to 20 bytes.
