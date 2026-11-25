package Net::Quiche::Connection;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(weaken);
use Socket qw(
    AF_INET AF_INET6
    inet_ntop inet_pton
    pack_sockaddr_in pack_sockaddr_in6
    sockaddr_family
    unpack_sockaddr_in unpack_sockaddr_in6
);
use Net::Quiche::Config ();
use Net::Quiche::XS ();

our $VERSION = '0.013';

my %COMMON = map { $_ => 1 } qw(config source_connection_id local peer);

sub connect {
    my ($class, @arguments) = @_;
    _class($class);
    my %options = _options('connect', @arguments);
    my %known = (%COMMON, server_name => 1);
    _unknown('connect', \%options, \%known);
    _required('connect', \%options, qw(config source_connection_id local peer));

    my $config = _config($options{config});
    my $source_id = _connection_id('source_connection_id', $options{source_connection_id}, 1);
    my ($local, $local_packed) = _address('local', $options{local});
    my ($peer,  $peer_packed)  = _address('peer',  $options{peer});
    my $server_name = _server_name($options{server_name});
    my $native = Net::Quiche::XS::_connection_connect(
        $config, $server_name, $source_id, $local_packed, $peer_packed,
    );

    return bless {
        _native => $native,
        local   => $local,
        peer    => $peer,
    }, $class;
}

sub accept {
    my ($class, @arguments) = @_;
    _class($class);
    my %options = _options('accept', @arguments);
    my %known = (%COMMON, original_destination_connection_id => 1);
    _unknown('accept', \%options, \%known);
    _required('accept', \%options, qw(config source_connection_id local peer));

    my $config = _config($options{config});
    my $source_id = _connection_id('source_connection_id', $options{source_connection_id}, 1);
    my $original_id = exists $options{original_destination_connection_id}
        ? _connection_id(
            'original_destination_connection_id',
            $options{original_destination_connection_id}, 0,
        )
        : undef;
    my ($local, $local_packed) = _address('local', $options{local});
    my ($peer,  $peer_packed)  = _address('peer',  $options{peer});
    my $native = Net::Quiche::XS::_connection_accept(
        $config, $source_id, $original_id, $local_packed, $peer_packed,
    );

    return bless {
        _native => $native,
        local   => $local,
        peer    => $peer,
    }, $class;
}

sub receive_datagram {
    my ($self, $packet, @arguments) = @_;
    croak 'receive_datagram() requires a datagram or byte string'
        unless defined $packet;

    my ($data, $from, $to);
    if (ref($packet) eq 'HASH') {
        croak 'receive_datagram() does not accept options after a datagram hash'
            if @arguments;
        $data = $packet->{data};
        $from = $packet->{from};
        $to   = $packet->{to};
        croak 'datagram requires data, from, and to values'
            unless exists($packet->{data}) && exists($packet->{from}) && exists($packet->{to});
    } else {
        my %options = _options('receive_datagram', @arguments);
        _unknown('receive_datagram', \%options, { from => 1, to => 1 });
        $data = $packet;
        $from = exists $options{from} ? $options{from} : $self->{peer};
        $to   = exists $options{to}   ? $options{to}   : $self->{local};
    }

    $data = _bytes('datagram data', $data);
    my (undef, $from_packed) = _address('from', $from);
    my (undef, $to_packed)   = _address('to', $to);
    return Net::Quiche::XS::_connection_receive(
        $self->{_native}, $data, $from_packed, $to_packed,
    );
}

sub next_datagram {
    croak 'next_datagram() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    my $packet = Net::Quiche::XS::_connection_next_datagram($self->{_native});
    return unless defined $packet;
    return {
        data => $packet->[0],
        from => _unpack_address($packet->[1]),
        to   => _unpack_address($packet->[2]),
    };
}

sub timeout_ms {
    croak 'timeout_ms() takes no arguments' unless @_ == 1;
    return Net::Quiche::XS::_connection_timeout_ms($_[0]{_native});
}

sub on_timeout {
    croak 'on_timeout() takes no arguments' unless @_ == 1;
    Net::Quiche::XS::_connection_on_timeout($_[0]{_native});
    return $_[0];
}

sub close {
    my ($self, @arguments) = @_;
    my %options = _options('close', @arguments);
    _unknown('close', \%options,
        { application => 1, error_code => 1, reason => 1 });
    my $application = exists($options{application})
        ? _boolean('application', $options{application}) : 0;
    my $error_code = exists($options{error_code})
        ? _error_code($options{error_code}) : 0;
    my $reason = _bytes('reason', $options{reason} // '');
    Net::Quiche::XS::_connection_close(
        $self->{_native}, $application, $error_code, $reason,
    );
    return $self;
}

sub shutdown_stream {
    my ($self, $stream_id, @arguments) = @_;
    $stream_id = _nonnegative_integer('stream_id', $stream_id);
    my %options = _options('shutdown_stream', @arguments);
    _unknown('shutdown_stream', \%options,
        { direction => 1, error_code => 1 });
    croak 'shutdown_stream() requires direction and error_code'
        unless exists($options{direction}) && exists($options{error_code});
    my $direction = $options{direction};
    croak "direction must be 'read' or 'write'"
        if !defined($direction) || ref($direction)
            || ($direction ne 'read' && $direction ne 'write');
    my $error_code = _error_code($options{error_code});
    return !!Net::Quiche::XS::_connection_stream_shutdown(
        $self->{_native}, $stream_id, $direction eq 'read' ? 0 : 1,
        $error_code,
    );
}

sub is_established {
    croak 'is_established() takes no arguments' unless @_ == 1;
    return !!Net::Quiche::XS::_connection_is_established($_[0]{_native});
}

sub is_closed {
    croak 'is_closed() takes no arguments' unless @_ == 1;
    return !!Net::Quiche::XS::_connection_is_closed($_[0]{_native});
}

sub is_draining {
    croak 'is_draining() takes no arguments' unless @_ == 1;
    return !!Net::Quiche::XS::_connection_is_draining($_[0]{_native});
}

sub local_error {
    croak 'local_error() takes no arguments' unless @_ == 1;
    return _connection_error($_[0], 1);
}

sub peer_error {
    croak 'peer_error() takes no arguments' unless @_ == 1;
    return _connection_error($_[0], 0);
}

sub source_connection_id {
    croak 'source_connection_id() takes no arguments' unless @_ == 1;
    return Net::Quiche::XS::_connection_source_id($_[0]{_native});
}

sub destination_connection_id {
    croak 'destination_connection_id() takes no arguments' unless @_ == 1;
    return Net::Quiche::XS::_connection_destination_id($_[0]{_native});
}

sub application_protocol {
    croak 'application_protocol() takes no arguments' unless @_ == 1;
    return Net::Quiche::XS::_connection_application_protocol($_[0]{_native});
}

sub http3 {
    croak 'http3() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    croak 'Cannot create HTTP/3 before the QUIC handshake is established'
        unless $self->is_established;
    return $self->{_http3} if $self->{_http3};
    require Net::Quiche::HTTP3;
    # The native HTTP/3 session and its read state belong to the transport.
    # Only the Perl wrapper is cached weakly, so dropping the wrapper and
    # calling http3() again reuses the same session instead of opening a
    # second set of control and QPACK streams on the connection.
    my $session = $self->{_http3_session} ||= {};
    my $http3 = Net::Quiche::HTTP3->_new(
        connection => $self, session => $session,
    );
    $self->{_http3} = $http3;
    weaken($self->{_http3});
    return $http3;
}

sub CLONE_SKIP { 1 }

sub _native { $_[0]{_native} }

sub _connection_error {
    my ($self, $local) = @_;
    my $error = Net::Quiche::XS::_connection_error($self->{_native}, $local);
    return unless $error;
    return {
        application => !!$error->[0],
        code        => $error->[1],
        reason      => $error->[2],
    };
}

sub _class {
    my ($class) = @_;
    croak 'Connection constructor must be called on Net::Quiche::Connection or a subclass'
        unless defined($class) && !ref($class) && eval { $class->isa(__PACKAGE__) };
}

sub _options {
    my ($method, @arguments) = @_;
    return () unless @arguments;
    return %{$arguments[0]} if @arguments == 1 && ref($arguments[0]) eq 'HASH';
    croak "$method() received an odd number of arguments" if @arguments % 2;
    return @arguments;
}

sub _unknown {
    my ($method, $options, $known) = @_;
    my @unknown = sort grep { !$known->{$_} } keys %$options;
    croak "$method() received unknown option '$unknown[0]'" if @unknown;
}

sub _required {
    my ($method, $options, @names) = @_;
    my @missing = grep { !exists $options->{$_} } @names;
    croak "$method() requires config, source_connection_id, local, and peer"
        if @missing;
}

sub _config {
    my ($config) = @_;
    croak 'config must be a Net::Quiche::Config object'
        unless eval { $config->isa('Net::Quiche::Config') };
    return $config;
}

sub _server_name {
    my ($name) = @_;
    return undef unless defined $name;
    croak 'server_name must be a scalar' if ref $name;
    croak 'server_name must not contain NUL' if index($name, "\0") >= 0;
    return "$name";
}

sub _connection_id {
    my ($name, $value, $required) = @_;
    return undef if !$required && !defined $value;
    my $bytes = _bytes($name, $value);
    croak "$name must contain 1 to 20 bytes"
        if length($bytes) < 1 || length($bytes) > 20;
    return $bytes;
}

sub _nonnegative_integer {
    my ($name, $value) = @_;
    croak "$name must be a non-negative integer"
        if !defined($value) || ref($value)
            || $value !~ /\A(?:0|[1-9][0-9]*)\z/;
    return 0 + $value;
}

sub _error_code {
    my ($value) = @_;
    # QUIC encodes error codes as varints. quiche panics, and so aborts the
    # process, when asked to encode anything larger.
    croak 'error_code must be an integer from 0 to 2^62-1'
        if !defined($value) || ref($value)
            || $value !~ /\A(?:0|[1-9][0-9]*)\z/
            || length($value) > 19
            || $value > 4_611_686_018_427_387_903;
    return 0 + $value;
}

sub _boolean {
    my ($name, $value) = @_;
    croak "$name must be 0 or 1"
        if !defined($value) || ref($value) || $value !~ /\A[01]\z/;
    return 0 + $value;
}

sub _bytes {
    my ($name, $value) = @_;
    croak "$name must be a defined byte string" if !defined($value) || ref($value);
    my $bytes = $value;
    croak "$name must be a byte string" unless utf8::downgrade($bytes, 1);
    return $bytes;
}

sub _address {
    my ($name, $address) = @_;
    croak "$name must be an [IP address, port] array reference"
        unless ref($address) eq 'ARRAY' && @$address == 2;
    my ($host, $port) = @$address;
    croak "$name host must be an IPv4 or IPv6 address"
        if !defined($host) || ref($host) || index($host, '%') >= 0;
    croak "$name port must be an integer from 0 to 65535"
        if !defined($port) || ref($port) || $port !~ /\A(?:0|[1-9][0-9]*)\z/
            || $port > 65_535;

    my $binary = inet_pton(AF_INET, $host);
    if (defined $binary) {
        my $canonical = inet_ntop(AF_INET, $binary);
        return ([$canonical, 0 + $port], pack_sockaddr_in($port, $binary));
    }
    $binary = inet_pton(AF_INET6, $host);
    croak "$name host must be an IPv4 or IPv6 address" unless defined $binary;
    my $canonical = inet_ntop(AF_INET6, $binary);
    return ([$canonical, 0 + $port], pack_sockaddr_in6($port, $binary));
}

sub _unpack_address {
    my ($packed) = @_;
    my $family = sockaddr_family($packed);
    if ($family == AF_INET) {
        my ($port, $binary) = unpack_sockaddr_in($packed);
        return [inet_ntop(AF_INET, $binary), $port];
    }
    if ($family == AF_INET6) {
        my ($port, $binary) = unpack_sockaddr_in6($packed);
        return [inet_ntop(AF_INET6, $binary), $port];
    }
    croak 'Native datagram contains an unsupported socket address family';
}

1;

__END__

=for stopwords datagram

=head1 NAME

Net::Quiche::Connection - Event-loop-neutral QUIC connection

=head1 DESCRIPTION

This class consumes and produces UDP datagram values. It never opens a socket,
which lets PAGI servers keep socket, timer, and connection-table ownership in
Perl. One connection can contain many independent HTTP/3 request streams.
Addresses are C<[IPv4 or IPv6 literal, port]> array references. IPv6 literals
with a zone identifier are not supported.

C<original_destination_connection_id> is only valid after the server sent a
QUIC Retry. Omit it when accepting the client's first Initial directly.
C<local_error> and C<peer_error> return copied error details when quiche has a
close reason.

C<shutdown_stream> accepts a stream ID plus C<direction> (C<read> or C<write>)
and an application C<error_code> from 0 to 2^62-1. It returns false when quiche no
longer has work for that direction, and true when shutdown was applied.

C<close> starts QUIC connection close and returns the connection. It accepts
C<application>, C<error_code>, and a byte-string C<reason>; omitted values
produce a transport-level NO_ERROR close. C<error_code> must not exceed
2^62-1, the largest value a QUIC varint can carry.

C<timeout_ms> returns the number of milliseconds until C<on_timeout> must be
called, or C<undef> when quiche has no timer armed.

C<http3> returns the connection's HTTP/3 session. The native session lives as
long as the connection, so calling C<http3> again after dropping the returned
object reuses it. C<is_draining> reports quiche's
draining state after either endpoint closes the connection.
