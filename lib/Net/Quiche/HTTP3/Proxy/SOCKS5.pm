package Net::Quiche::HTTP3::Proxy::SOCKS5;

use strict;
use warnings;
use Carp qw(croak);
use Future ();
use Socket qw(
    AF_INET AF_INET6 inet_ntop inet_pton sockaddr_family
    unpack_sockaddr_in unpack_sockaddr_in6
);
use URI ();

our $VERSION = '0.013';

sub new {
    my ($class, $input) = @_;
    croak 'proxy must be a defined URI scalar'
        if !defined($input) || ref($input);
    my $uri = URI->new("$input");
    my $scheme = lc($uri->scheme // '');
    croak 'HTTP/3 proxy only supports socks5 and socks5h URIs'
        unless $scheme eq 'socks5' || $scheme eq 'socks5h';
    my $authority = $uri->authority // '';
    croak 'SOCKS5 proxy URI must include a host' unless length $authority;
    croak 'SOCKS5 proxy authentication is not supported'
        if $authority =~ /\@/;
    croak 'SOCKS5 proxy URI must not include a path, query, or fragment'
        if (defined($uri->path) && length($uri->path))
            || defined($uri->query) || defined($uri->fragment);
    my ($host, $port);
    if ($authority =~ /\A\[([^\]]+)\](?::([0-9]+))?\z/) {
        ($host, $port) = ($1, $2);
    } elsif ($authority =~ /\A([^:]+)(?::([0-9]+))?\z/) {
        ($host, $port) = ($1, $2);
    } else {
        croak 'SOCKS5 proxy URI has an invalid authority';
    }
    $port = 1080 unless defined $port;
    croak 'SOCKS5 proxy port must be from 1 to 65535'
        unless $port =~ /\A[1-9][0-9]*\z/ && $port <= 65_535;
    return bless {
        uri => "$uri", host => $host, port => 0 + $port,
        remote_dns => $scheme eq 'socks5h' ? 1 : 0,
    }, $class;
}

sub uri { return $_[0]{uri} }
sub host { return $_[0]{host} }
sub port { return $_[0]{port} }
sub remote_dns { return $_[0]{remote_dns} }

sub negotiate_udp_associate {
    my ($self, $stream) = @_;
    return $stream->write(pack('CCC', 5, 1, 0))->then(sub {
        return _read_exactly($stream, 2, 'SOCKS5 method selection');
    })->then(sub {
        my ($reply) = @_;
        my ($version, $method) = unpack('CC', $reply);
        return Future->fail('SOCKS5 proxy sent an invalid method selection')
            unless $version == 5;
        return Future->fail('SOCKS5 proxy requires unsupported authentication')
            unless $method == 0;
        my $associate = pack('CCCC', 5, 3, 0, 1)
            . pack('C4', 0, 0, 0, 0) . pack('n', 0);
        return $stream->write($associate);
    })->then(sub {
        return _read_exactly($stream, 4, 'SOCKS5 UDP ASSOCIATE reply');
    })->then(sub {
        my ($header) = @_;
        my ($version, $reply, $reserved, $type) = unpack('CCCC', $header);
        return Future->fail('SOCKS5 proxy sent an invalid UDP ASSOCIATE reply')
            unless $version == 5 && $reserved == 0;
        return Future->fail("SOCKS5 UDP ASSOCIATE failed with reply $reply")
            unless $reply == 0;
        return _read_reply_address($stream, $type);
    });
}

sub target {
    my ($self, $host, $port, $addresses) = @_;
    my $header = _numeric_header($host, $port);
    if (!$header && $self->{remote_dns}) {
        my $bytes = "$host";
        croak 'SOCKS5 destination hostname must be a byte string'
            unless utf8::downgrade($bytes, 1);
        croak 'SOCKS5 destination hostname is longer than 255 bytes'
            if length($bytes) > 255;
        $header = pack('CC', 3, length($bytes)) . $bytes . pack('n', $port);
        return { header => $header, logical_peer => undef };
    }
    if (!$header) {
        croak 'SOCKS5 local DNS resolution produced no address'
            unless ref($addresses) eq 'ARRAY' && @{$addresses};
        my $packed = $addresses->[0]{addr};
        $header = _packed_header($packed);
        substr($header, -2, 2, pack('n', $port));
        return { header => $header, logical_peer => _unpack_address($packed) };
    }
    return { header => $header, logical_peer => [$host, $port] };
}

sub wrap_datagram {
    my ($self, $target, $data) = @_;
    return "\0\0\0" . $target->{header} . $data;
}

sub unwrap_datagram {
    my ($self, $packet) = @_;
    croak 'SOCKS5 UDP relay sent a short packet' if length($packet) < 7;
    my ($reserved, $fragment, $type) = unpack('nCC', substr($packet, 0, 4));
    croak 'SOCKS5 UDP relay sent invalid reserved bytes' if $reserved != 0;
    croak 'SOCKS5 UDP fragmentation is not supported' if $fragment != 0;
    my $offset;
    if ($type == 1) {
        croak 'SOCKS5 UDP relay sent a short IPv4 packet'
            if length($packet) < 10;
        $offset = 8;
    } elsif ($type == 4) {
        croak 'SOCKS5 UDP relay sent a short IPv6 packet'
            if length($packet) < 22;
        $offset = 20;
    } elsif ($type == 3) {
        my $length = unpack('C', substr($packet, 4, 1));
        croak 'SOCKS5 UDP relay sent a short domain packet'
            if length($packet) < 7 + $length;
        $offset = 5 + $length;
    } else {
        croak "SOCKS5 UDP relay sent unsupported address type $type";
    }
    return substr($packet, $offset + 2);
}

sub _read_reply_address {
    my ($stream, $type) = @_;
    if ($type == 1) {
        return _read_exactly($stream, 6, 'SOCKS5 IPv4 relay address')
            ->then(sub {
                my ($bytes) = @_;
                return Future->done([
                    inet_ntop(AF_INET, substr($bytes, 0, 4)),
                    unpack('n', substr($bytes, 4, 2)),
                ]);
            });
    }
    if ($type == 4) {
        return _read_exactly($stream, 18, 'SOCKS5 IPv6 relay address')
            ->then(sub {
                my ($bytes) = @_;
                return Future->done([
                    inet_ntop(AF_INET6, substr($bytes, 0, 16)),
                    unpack('n', substr($bytes, 16, 2)),
                ]);
            });
    }
    if ($type == 3) {
        return _read_exactly($stream, 1, 'SOCKS5 relay hostname length')
            ->then(sub {
                my ($length_byte) = @_;
                my $length = unpack('C', $length_byte);
                return _read_exactly(
                    $stream, $length + 2, 'SOCKS5 relay hostname');
            })->then(sub {
                my ($bytes) = @_;
                return Future->done([
                    substr($bytes, 0, length($bytes) - 2),
                    unpack('n', substr($bytes, -2)),
                ]);
            });
    }
    return Future->fail("SOCKS5 proxy sent unsupported address type $type");
}

sub _read_exactly {
    my ($stream, $length, $name) = @_;
    return $stream->read_exactly($length)->then(sub {
        my ($bytes, $eof) = @_;
        return Future->fail("$name ended after " . length($bytes) . " bytes")
            if length($bytes) != $length;
        return Future->done($bytes);
    });
}

sub _numeric_header {
    my ($host, $port) = @_;
    my $binary = inet_pton(AF_INET, $host);
    return pack('C', 1) . $binary . pack('n', $port) if defined $binary;
    $binary = inet_pton(AF_INET6, $host);
    return pack('C', 4) . $binary . pack('n', $port) if defined $binary;
    return;
}

sub _packed_header {
    my ($packed) = @_;
    my $family = sockaddr_family($packed);
    if ($family == AF_INET) {
        my ($port, $binary) = unpack_sockaddr_in($packed);
        return pack('C', 1) . $binary . pack('n', $port);
    }
    if ($family == AF_INET6) {
        my ($port, $binary) = unpack_sockaddr_in6($packed);
        return pack('C', 4) . $binary . pack('n', $port);
    }
    croak 'SOCKS5 target uses an unsupported address family';
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
    croak 'SOCKS5 target uses an unsupported address family';
}

1;

__END__

=head1 NAME

Net::Quiche::HTTP3::Proxy::SOCKS5 - SOCKS5 UDP association for HTTP/3

=head1 DESCRIPTION

This class implements the no-authentication UDP ASSOCIATE subset of SOCKS5.
The HTTP/3 client owns an instance for each proxied origin and keeps its TCP
control stream open for the lifetime of the QUIC connection.
