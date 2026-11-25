package Net::Quiche::HTTP3;

use strict;
use warnings;
use Carp qw(croak);
use Net::Quiche::XS ();

our $VERSION = '0.013';

my @EVENT_TYPE = qw(headers data finished goaway reset priority_update);
my $BODY_CHUNK_SIZE = 16 * 1024;

sub _new {
    my ($class, %options) = @_;
    my $connection = $options{connection};
    croak '_new() requires a Net::Quiche::Connection'
        unless eval { $connection->isa('Net::Quiche::Connection') };
    my $session = $options{session} || {};
    $session->{native} ||= Net::Quiche::XS::_h3_new($connection->_native);
    $session->{data_stream} = undef unless exists $session->{data_stream};
    return bless {
        connection => $connection,
        native     => $session->{native},
        session    => $session,
    }, $class;
}

sub poll {
    my ($self, @arguments) = @_;
    my %options = _options('poll', @arguments);
    _unknown('poll', \%options, { read_body => 1 });
    my $read_body = exists($options{read_body})
        ? _boolean('read_body', $options{read_body}) : 1;
    my $session = $self->{session};

    if (defined(my $stream_id = $session->{data_stream})) {
        # Clear the cursor first. If the read fails, later polls must still
        # reach the other streams instead of retrying this one forever.
        $session->{data_stream} = undef;
        my $body;
        my $ok = eval {
            $body = $self->recv_body($stream_id, $BODY_CHUNK_SIZE);
            1;
        };
        if (!$ok) {
            my $error = $@;
            return { type => 'reset', stream_id => $stream_id }
                if _is_stream_error($error);
            die $error;
        }
        if (defined $body) {
            $session->{data_stream} = $stream_id;
            return {
                type      => 'data',
                stream_id => $stream_id,
                body      => $body,
            };
        }
    }

    my $event = Net::Quiche::XS::_h3_poll(
        $self->{native}, $self->{connection}->_native,
    );
    return unless defined $event;

    my ($type_number, $stream_id, $headers, $more) = @$event;
    my $type = $EVENT_TYPE[$type_number]
        // croak "Unknown HTTP/3 event type $type_number";
    if ($type eq 'headers') {
        return {
            type      => $type,
            stream_id => $stream_id,
            headers   => $headers,
            more      => !!$more,
        };
    }
    if ($type eq 'data') {
        return { type => $type, stream_id => $stream_id } unless $read_body;
        $session->{data_stream} = $stream_id;
        return $self->poll;
    }
    return { type => $type, id => $stream_id } if $type eq 'goaway';
    return { type => $type, stream_id => $stream_id };
}

sub recv_body {
    my ($self, $stream_id, $max_bytes) = @_;
    $stream_id = _stream_id($stream_id);
    $max_bytes = $BODY_CHUNK_SIZE unless defined $max_bytes;
    croak 'max_bytes must be a positive integer'
        if ref($max_bytes) || $max_bytes !~ /\A[1-9][0-9]*\z/
            || length($max_bytes) > 10;
    return Net::Quiche::XS::_h3_receive_body(
        $self->{native}, $self->{connection}->_native,
        $stream_id, 0 + $max_bytes,
    );
}

sub send_request {
    my ($self, @arguments) = @_;
    my %options = _options('send_request', @arguments);
    _unknown('send_request', \%options, { headers => 1, final => 1 });
    croak 'send_request() requires headers' unless exists $options{headers};
    my $headers = _headers($options{headers}, 1);
    my $final = _boolean('final', exists($options{final}) ? $options{final} : 0);
    return Net::Quiche::XS::_h3_send_request(
        $self->{native}, $self->{connection}->_native, $headers, $final,
    );
}

sub send_response {
    my ($self, $stream_id, @arguments) = @_;
    $stream_id = _stream_id($stream_id);
    my %options = _options('send_response', @arguments);
    _unknown('send_response', \%options, { status => 1, headers => 1, final => 1 });
    croak 'send_response() requires status' unless exists $options{status};
    my $status = $options{status};
    croak 'status must be an integer from 100 to 599'
        if !defined($status) || ref($status) || $status !~ /\A[1-5][0-9]{2}\z/;
    my $headers = _headers($options{headers} // [], 0);
    unshift @$headers, [':status', "$status"];
    my $final = _boolean('final', exists($options{final}) ? $options{final} : 0);
    return Net::Quiche::XS::_h3_send_response(
        $self->{native}, $self->{connection}->_native,
        $stream_id, $headers, $final,
    );
}

sub send_body {
    my ($self, $stream_id, $body, @arguments) = @_;
    $stream_id = _stream_id($stream_id);
    $body = _bytes('body', $body);
    my %options = _options('send_body', @arguments);
    _unknown('send_body', \%options, { final => 1 });
    my $final = _boolean('final', exists($options{final}) ? $options{final} : 0);
    return Net::Quiche::XS::_h3_send_body(
        $self->{native}, $self->{connection}->_native,
        $stream_id, $body, $final,
    );
}

sub send_goaway {
    croak 'send_goaway() expects one identifier' unless @_ == 2;
    my ($self, $id) = @_;
    $id = _goaway_id($id);
    return Net::Quiche::XS::_h3_send_goaway(
        $self->{native}, $self->{connection}->_native, $id,
    );
}

sub _forget_stream {
    my ($self, $stream_id) = @_;
    my $session = $self->{session};
    $session->{data_stream} = undef
        if defined($session->{data_stream})
            && $session->{data_stream} == $stream_id;
    return;
}

# quiche's HTTP/3 C API reports a transport error as the QUIC error minus
# 1000: STREAM_STOPPED (-15) and STREAM_RESET (-16) affect one stream only.
sub _is_stream_error {
    my ($error) = @_;
    return $error =~ /\Aquiche_h3_\w+\(\) failed: -101[56]\b/ ? 1 : 0;
}

sub CLONE_SKIP { 1 }

sub DESTROY {
    my ($self) = @_;
    # The native session is shared with the connection; only drop references.
    delete $self->{native};
    delete $self->{session};
    delete $self->{connection};
}

sub _headers {
    my ($input, $allow_pseudo) = @_;
    croak 'headers must be an array reference' unless ref($input) eq 'ARRAY';
    my @headers;
    for my $header (@$input) {
        croak 'each header must be a [name, value] array reference'
            unless ref($header) eq 'ARRAY' && @$header == 2;
        my $name  = _bytes('header name',  $header->[0]);
        my $value = _bytes('header value', $header->[1]);
        croak 'header names must not be empty' unless length $name;
        croak "response header '$name' must not be a pseudo-header"
            if !$allow_pseudo && substr($name, 0, 1) eq ':';
        croak "header name '$name' must be lowercase"
            if $name =~ /[A-Z]/;
        croak 'header names and values must not contain CR, LF, or NUL'
            if $name =~ /[\r\n\0]/ || $value =~ /[\r\n\0]/;
        push @headers, [$name, $value];
    }
    return \@headers;
}

sub _stream_id {
    my ($value) = @_;
    croak 'stream_id must be a non-negative integer'
        if !defined($value) || ref($value) || $value !~ /\A(?:0|[1-9][0-9]*)\z/;
    return 0 + $value;
}

sub _goaway_id {
    my ($value) = @_;
    croak 'GOAWAY id must be an integer from 0 to 2^62-1'
        if !defined($value) || ref($value)
            || $value !~ /\A(?:0|[1-9][0-9]*)\z/
            || $value > 4_611_686_018_427_387_903;
    return 0 + $value;
}

sub _bytes {
    my ($name, $value) = @_;
    croak "$name must be a defined byte string" if !defined($value) || ref($value);
    my $bytes = $value;
    croak "$name must be a byte string" unless utf8::downgrade($bytes, 1);
    return $bytes;
}

sub _boolean {
    my ($name, $value) = @_;
    croak "$name must be 0 or 1"
        if !defined($value) || ref($value) || $value !~ /\A[01]\z/;
    return 0 + $value;
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

1;

__END__

=head1 NAME

Net::Quiche::HTTP3 - Stream-oriented HTTP/3 events and writes

=head1 DESCRIPTION

C<poll> returns one hash per HTTP/3 event. Request-stream events include
C<stream_id>, so a PAGI adapter can create one HTTP scope per request while
retaining one shared QUIC connection. A GOAWAY event contains C<id> because it
applies to the connection, not one request stream. Header order and duplicates
are preserved.

By default C<poll> reads the body of each C<data> event and returns it in
C<body>. With C<< read_body =E<gt> 0 >> a C<data> event has no C<body>; call
C<recv_body($stream_id, $max_bytes)> until it returns undef. Unread data
stays in quiche and holds back the peer's flow-control window. quiche reports
C<data> again only after the buffered body has been read to the end, and
C<finished> only follows once the whole body has been read. If the peer
resets a stream while its body is being read, C<poll> returns a C<reset>
event for that stream instead of dying.

C<send_body> returns the number of body bytes accepted by quiche. This can be
shorter than the supplied body. C<send_request>, C<send_response>, and
C<send_body> return undef when the operation is temporarily blocked. Retain
the unsent data and retry after transport progress; a blocked result is not a
connection error.

C<send_goaway> queues a connection-wide graceful-shutdown cutoff and returns
undef when the control stream is blocked. GOAWAY does not close the QUIC
connection.
