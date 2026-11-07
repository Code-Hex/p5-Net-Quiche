package Net::Quiche::Config;

use strict;
use warnings;
use Carp qw(croak);
use Config ();
use Net::Quiche::XS ();

our $VERSION = '0.013';

my @ORDER = qw(
    application_protocols
    certificate_chain
    private_key
    verify_locations_file
    verify_locations_directory
    verify_peer
    max_idle_timeout
    max_recv_udp_payload_size
    max_send_udp_payload_size
    initial_max_data
    initial_max_stream_data_bidi_local
    initial_max_stream_data_bidi_remote
    initial_max_stream_data_uni
    initial_max_streams_bidi
    initial_max_streams_uni
    disable_active_migration
);

my %KNOWN = map { $_ => 1 } @ORDER;
my %INTEGER = map { $_ => 1 } qw(
    max_idle_timeout
    max_recv_udp_payload_size
    max_send_udp_payload_size
    initial_max_data
    initial_max_stream_data_bidi_local
    initial_max_stream_data_bidi_remote
    initial_max_stream_data_uni
    initial_max_streams_bidi
    initial_max_streams_uni
);

my $MAX_UV = $Config::Config{uvsize} >= 8
    ? '18446744073709551615'
    : '4294967295';

sub new {
    my ($class, @arguments) = @_;
    croak "new() must be called on Net::Quiche::Config or a subclass"
        unless defined($class) && !ref($class)
            && eval { $class->isa(__PACKAGE__) };
    my %options = _named_options(@arguments);

    my @unknown = sort grep { !$KNOWN{$_} } keys %options;
    croak "Unknown config option '$unknown[0]'" if @unknown;

    $options{application_protocols} = ['h3']
        unless exists $options{application_protocols};

    # Validate everything before allocating or changing native state.
    my %validated;
    for my $name (keys %options) {
        if ($name eq 'application_protocols') {
            $validated{$name} = [_protocols($options{$name})];
        } elsif ($name eq 'verify_locations_directory') {
            $validated{$name} = _directory_path($options{$name});
        } elsif ($name eq 'certificate_chain' || $name eq 'private_key'
                || $name eq 'verify_locations_file') {
            $validated{$name} = _path($name, $options{$name});
        } elsif ($name eq 'verify_peer' || $name eq 'disable_active_migration') {
            $validated{$name} = _boolean($name, $options{$name});
        } elsif ($INTEGER{$name}) {
            $validated{$name} = _integer($name, $options{$name});
        }
    }

    my $self = Net::Quiche::XS::_config_new($class);

    for my $name (@ORDER) {
        next unless exists $validated{$name};
        if ($name eq 'application_protocols') {
            $self->application_protocols(@{$validated{$name}});
        } else {
            $self->$name($validated{$name});
        }
    }

    return $self;
}

sub load_verify_locations_from_file {
    croak "load_verify_locations_from_file() expects one path" unless @_ == 2;
    my ($self, $path) = @_;
    $path = _path('verify locations file', $path);
    _check_native(
        Net::Quiche::XS::_config_load_verify_locations_from_file($self, $path),
        "load verify locations file '$path'",
    );
    return $self;
}

sub verify_locations_file {
    croak "verify_locations_file() expects one path" unless @_ == 2;
    return $_[0]->load_verify_locations_from_file($_[1]);
}

sub load_verify_locations_from_directory {
    croak "load_verify_locations_from_directory() expects one path"
        unless @_ == 2;
    my ($self, $path) = @_;
    $path = _directory_path($path);
    _check_native(
        Net::Quiche::XS::_config_load_verify_locations_from_directory(
            $self, $path),
        "load verify locations directory '$path'",
    );
    return $self;
}

sub verify_locations_directory {
    croak "verify_locations_directory() expects one path" unless @_ == 2;
    return $_[0]->load_verify_locations_from_directory($_[1]);
}

sub load_cert_chain {
    croak "load_cert_chain() expects one path" unless @_ == 2;
    my ($self, $path) = @_;
    $path = _path('certificate chain', $path);
    _check_native(
        Net::Quiche::XS::_config_load_cert_chain($self, $path),
        "load certificate chain '$path'",
    );
    return $self;
}

sub certificate_chain {
    croak "certificate_chain() expects one path" unless @_ == 2;
    my ($self, $path) = @_;
    return $self->load_cert_chain($path);
}

sub load_private_key {
    croak "load_private_key() expects one path" unless @_ == 2;
    my ($self, $path) = @_;
    $path = _path('private key', $path);
    _check_native(
        Net::Quiche::XS::_config_load_private_key($self, $path),
        "load private key '$path'",
    );
    return $self;
}

sub private_key {
    croak "private_key() expects one path" unless @_ == 2;
    my ($self, $path) = @_;
    return $self->load_private_key($path);
}

sub application_protocols {
    my ($self, @protocols) = @_;
    @protocols = @{$protocols[0]}
        if @protocols == 1 && ref($protocols[0]) eq 'ARRAY';
    @protocols = _protocols(\@protocols);
    my $wire = join '', map { chr(length($_)) . $_ } @protocols;
    _check_native(
        Net::Quiche::XS::_config_set_application_protocols($self, $wire),
        'set application protocols',
    );
    return $self;
}

sub verify_peer {
    croak "verify_peer() expects one boolean" unless @_ == 2;
    my ($self, $value) = @_;
    $value = _boolean('verify_peer', $value);
    Net::Quiche::XS::_config_verify_peer($self, $value);
    return $self;
}

sub disable_active_migration {
    croak "disable_active_migration() expects one boolean" unless @_ == 2;
    my ($self, $value) = @_;
    $value = _boolean('disable_active_migration', $value);
    Net::Quiche::XS::_config_set_disable_active_migration($self, $value);
    return $self;
}

my %INTEGER_XS = (
    max_idle_timeout                    => '_config_set_max_idle_timeout',
    max_recv_udp_payload_size           => '_config_set_max_recv_udp_payload_size',
    max_send_udp_payload_size           => '_config_set_max_send_udp_payload_size',
    initial_max_data                    => '_config_set_initial_max_data',
    initial_max_stream_data_bidi_local  => '_config_set_initial_max_stream_data_bidi_local',
    initial_max_stream_data_bidi_remote => '_config_set_initial_max_stream_data_bidi_remote',
    initial_max_stream_data_uni         => '_config_set_initial_max_stream_data_uni',
    initial_max_streams_bidi            => '_config_set_initial_max_streams_bidi',
    initial_max_streams_uni             => '_config_set_initial_max_streams_uni',
);

for my $name (keys %INTEGER_XS) {
    my $xs = $INTEGER_XS{$name};
    no strict 'refs';
    *{$name} = sub {
        croak "$name() expects one integer" unless @_ == 2;
        my ($self, $value) = @_;
        $value = _integer($name, $value);
        &{"Net::Quiche::XS::$xs"}($self, $value);
        return $self;
    };
}

sub CLONE_SKIP { 1 }

sub _named_options {
    my (@arguments) = @_;
    return () unless @arguments;
    if (@arguments == 1 && ref($arguments[0]) eq 'HASH') {
        return %{$arguments[0]};
    }
    croak "Net::Quiche::Config->new received an odd number of arguments"
        if @arguments % 2;
    return @arguments;
}

sub _protocols {
    my ($protocols) = @_;
    croak "application_protocols must be an array reference"
        unless ref($protocols) eq 'ARRAY';
    croak "application_protocols must contain at least one protocol"
        unless @$protocols;

    my @bytes;
    for my $protocol (@$protocols) {
        croak "application protocols must be defined byte strings"
            if !defined($protocol) || ref($protocol);
        my $bytes = $protocol;
        croak "application protocols must be byte strings"
            unless utf8::downgrade($bytes, 1);
        my $length = length $bytes;
        croak "application protocol length must be 1 to 255 bytes"
            if $length < 1 || $length > 255;
        push @bytes, $bytes;
    }
    return @bytes;
}

sub _path {
    my ($name, $path) = @_;
    croak "$name path must be a defined scalar"
        if !defined($path) || ref($path);
    croak "$name path must not contain NUL" if index($path, "\0") >= 0;
    return "$path";
}

sub _directory_path {
    my ($path) = @_;
    $path = _path('verify locations directory', $path);
    croak "verify locations directory '$path' does not exist or is not a directory"
        unless -d $path;
    return $path;
}

sub _boolean {
    my ($name, $value) = @_;
    croak "$name must be 0 or 1"
        if !defined($value) || ref($value) || $value !~ /\A[01]\z/;
    return 0 + $value;
}

sub _integer {
    my ($name, $value) = @_;
    croak "$name must be a non-negative integer no greater than $MAX_UV"
        if !defined($value) || ref($value) || $value !~ /\A(?:0|[1-9][0-9]*)\z/
            || length($value) > length($MAX_UV)
            || (length($value) == length($MAX_UV) && $value gt $MAX_UV);
    return 0 + $value;
}

sub _check_native {
    my ($status, $operation) = @_;
    croak "Failed to $operation: quiche error $status" if $status < 0;
    return;
}

1;

__END__

=head1 NAME

Net::Quiche::Config - Owned quiche configuration

=head1 SYNOPSIS

    use Net::Quiche;

    my $config = Net::Quiche::Config->new(
        certificate_chain     => 'cert.pem',
        private_key           => 'key.pem',
        application_protocols => ['h3'],
        max_idle_timeout      => 30_000,
    );

    $config
        ->initial_max_data(10_000_000)
        ->initial_max_streams_bidi(100);

=head1 DESCRIPTION

This class owns one native C<quiche_config>. Perl frees it when the object goes
out of scope. Config objects cannot cross interpreter threads.

C<new> accepts named arguments or one hash reference. It defaults
C<application_protocols> to C<['h3']>. Unknown options and invalid values throw
exceptions before native state is allocated. Native setter failures also throw
exceptions. Setter methods return the config object for chaining.

=head1 CONSTRUCTOR OPTIONS AND METHODS

=over 4

=item * C<certificate_chain>, C<load_cert_chain>

=item * C<private_key>, C<load_private_key>

=item * C<verify_locations_file>, C<load_verify_locations_from_file>

=item * C<verify_locations_directory>, C<load_verify_locations_from_directory>

=item * C<application_protocols>

=item * C<verify_peer>, C<disable_active_migration>

=item * C<max_idle_timeout>

=item * C<max_recv_udp_payload_size>, C<max_send_udp_payload_size>

=item * C<initial_max_data>

=item * C<initial_max_stream_data_bidi_local>

=item * C<initial_max_stream_data_bidi_remote>

=item * C<initial_max_stream_data_uni>

=item * C<initial_max_streams_bidi>, C<initial_max_streams_uni>

=back

Integer values must fit Perl's unsigned integer type. C<max_idle_timeout> uses
milliseconds. Application protocol names must be byte strings from 1 to 255
bytes. The module converts them to ALPN wire format.

=cut
