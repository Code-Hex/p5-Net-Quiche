package Net::Quiche::HTTP3::Exchange;

use strict;
use warnings;
use Carp qw(croak);
use Future ();
use Scalar::Util qw(weaken);

our $VERSION = '0.013';

sub _new {
    my ($class, %options) = @_;
    my $client = $options{client};
    my $state = $options{state};
    weaken($client);
    weaken($state);
    return bless {
        client             => $client,
        state              => $state,
        origin_key         => $options{origin_key},
        headers            => $options{headers},
        stream_id          => undef,
        writes             => [],
        write_pending      => 0,
        body_started       => 0,
        finish_requested   => 0,
        request_finished   => 0,
        response_finished  => 0,
        finish_future      => undef,
        response_future    => Future->new,
        response           => undef,
        failure            => undef,
    }, $class;
}

sub write {
    croak 'write() expects one byte string' unless @_ == 2;
    my ($self, $body) = @_;
    $body = _bytes('request body', $body);
    return Future->fail($self->{failure}) if defined $self->{failure};
    return Future->fail('HTTP/3 exchange is no longer active')
        unless $self->{client};
    return Future->fail('request body is already complete')
        if $self->{finish_requested};
    return Future->fail('Only one pending write() is allowed per HTTP/3 exchange')
        if $self->{write_pending};
    return Future->done if length($body) == 0;

    my $future = Future->new;
    $self->{write_pending} = 1;
    $self->{body_started} = 1;
    push @{$self->{writes}}, {
        body => $body, offset => 0, final => 0, future => $future,
    };
    $future->on_ready(sub { $self->{write_pending} = 0 });
    $self->{client}->_exchange_updated($self);
    return $future->without_cancel;
}

sub finish_request {
    croak 'finish_request() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    return Future->fail($self->{failure}) if defined $self->{failure};
    return Future->fail('HTTP/3 exchange is no longer active')
        unless $self->{client};
    return Future->fail('request body is already complete')
        if $self->{finish_requested};
    return Future->fail('write() must complete before finish_request()')
        if $self->{write_pending};

    $self->{finish_requested} = 1;
    my $future = $self->{finish_future} = Future->new;
    if ($self->{body_started} || defined $self->{stream_id}) {
        push @{$self->{writes}}, {
            body => '', offset => 0, final => 1, future => $future,
        };
    }
    $self->{client}->_exchange_updated($self);
    return $future->without_cancel;
}

sub response {
    croak 'response() takes no arguments' unless @_ == 1;
    return $_[0]{response_future}->without_cancel;
}

sub stream_id {
    croak 'stream_id() takes no arguments' unless @_ == 1;
    return $_[0]{stream_id};
}

sub cancel {
    croak 'cancel() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    my $client = $self->{client} or return 0;
    return $client->_cancel_exchange($self, 'HTTP/3 request cancelled') ? 1 : 0;
}

sub _header_final {
    my ($self) = @_;
    return $self->{finish_requested} && !$self->{body_started} ? 1 : 0;
}

sub _header_sent {
    my ($self, $stream_id) = @_;
    $self->{stream_id} = $stream_id;
    if ($self->_header_final) {
        $self->{request_finished} = 1;
        $self->{finish_future}->done
            if $self->{finish_future} && !$self->{finish_future}->is_ready;
    }
    return;
}

sub _next_write {
    return $_[0]{writes}[0];
}

sub _write_complete {
    my ($self) = @_;
    my $operation = shift @{$self->{writes}} or return;
    if ($operation->{final}) {
        $self->{request_finished} = 1;
    }
    $operation->{future}->done unless $operation->{future}->is_ready;
    return;
}

sub _set_response {
    my ($self, $response) = @_;
    $self->{response} = $response;
    $self->{response_future}->done($response)
        unless $self->{response_future}->is_ready;
    return;
}

sub _response_finished {
    $_[0]{response_finished} = 1;
    return;
}

sub _is_done {
    return $_[0]{request_finished} && $_[0]{response_finished};
}

sub _fail {
    my ($self, $error) = @_;
    return if defined $self->{failure};
    $self->{failure} = "$error";
    for my $operation (splice @{$self->{writes}}) {
        $operation->{future}->fail($self->{failure})
            unless $operation->{future}->is_ready;
    }
    $self->{finish_future}->fail($self->{failure})
        if $self->{finish_future} && !$self->{finish_future}->is_ready;
    $self->{response_future}->fail($self->{failure})
        unless $self->{response_future}->is_ready;
    $self->{response}->_fail($self->{failure}) if $self->{response};
    return;
}

sub _bytes {
    my ($name, $value) = @_;
    croak "$name must be a defined byte string" if !defined($value) || ref($value);
    my $bytes = $value;
    croak "$name must be a byte string" unless utf8::downgrade($bytes, 1);
    return $bytes;
}

1;

__END__

=head1 NAME

Net::Quiche::HTTP3::Exchange - One streaming HTTP/3 request and response

=head1 DESCRIPTION

C<write> retains each request-body byte string until quiche accepts it.
C<finish_request> sends the request FIN. Only one write may be pending. The
C<response> Future resolves when response headers arrive, after which C<read>
on the response provides body chunks. C<cancel> is idempotent. It fails the
exchange's outstanding Futures and, once a request stream exists, sends the
HTTP/3 request-cancel error in both stream directions.
