package Net::Quiche::HTTP3::Response;

use strict;
use warnings;
use Carp qw(croak);
use Future ();

our $VERSION = '0.013';

sub _new {
    my ($class, %options) = @_;
    return bless {
        status        => $options{status},
        headers       => [map { [@$_] } @{$options{headers}}],
        queue         => [],
        waiter        => undef,
        complete      => 0,
        discard       => 0,
        failure       => undef,
        buffered_body => undef,
        effective_uri => undef,
        redirect_history => [],
        on_consume    => $options{on_consume} || sub {},
    }, $class;
}

sub status {
    croak 'status() takes no arguments' unless @_ == 1;
    return $_[0]{status};
}

sub http_version {
    croak 'http_version() takes no arguments' unless @_ == 1;
    return '3';
}

sub headers {
    croak 'headers() takes no arguments' unless @_ == 1;
    return [map { [@$_] } @{$_[0]{headers}}];
}

sub header_values {
    croak 'header_values() expects one name' unless @_ == 2;
    my ($self, $name) = @_;
    $name = _header_name($name);
    return [map { $_->[1] }
        grep { $_->[0] eq $name } @{$self->{headers}}];
}

sub header {
    croak 'header() expects one name' unless @_ == 2;
    my ($self, $name) = @_;
    my $values = $self->header_values($name);
    return $values->[0];
}

sub is_success {
    croak 'is_success() takes no arguments' unless @_ == 1;
    return $_[0]{status} >= 200 && $_[0]{status} < 300 ? 1 : 0;
}

sub is_complete {
    croak 'is_complete() takes no arguments' unless @_ == 1;
    return $_[0]{complete} ? 1 : 0;
}

sub effective_uri {
    croak 'effective_uri() takes no arguments' unless @_ == 1;
    return $_[0]{effective_uri};
}

sub redirect_history {
    croak 'redirect_history() takes no arguments' unless @_ == 1;
    return [map { { %{$_} } } @{$_[0]{redirect_history}}];
}

sub read {
    croak 'read() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    if (@{$self->{queue}}) {
        my $chunk = shift @{$self->{queue}};
        $self->{on_consume}->(length $chunk);
        return Future->done($chunk);
    }
    return Future->fail($self->{failure}) if defined $self->{failure};
    return Future->done(undef) if $self->{complete};
    if (my $pending = $self->{waiter}) {
        return Future->fail(
            'Only one pending read() is allowed per HTTP/3 response')
            unless $pending->is_ready;
        # The caller cancelled its earlier read().
        delete $self->{waiter};
    }
    # Cancelling this Future only abandons the read; the next chunk stays
    # queued for a later read().
    return $self->{waiter} = Future->new;
}

sub slurp {
    my ($self, @arguments) = @_;
    my %options = _options('slurp', @arguments);
    my @unknown = grep { $_ ne 'max_bytes' } keys %options;
    croak "slurp() received unknown option '$unknown[0]'" if @unknown;
    my $maximum = $options{max_bytes};
    croak 'max_bytes must be a positive integer'
        if defined($maximum) && (ref($maximum) || $maximum !~ /\A[1-9][0-9]*\z/);
    if (defined $self->{buffered_body}) {
        return Future->fail("HTTP/3 response body exceeds $maximum bytes")
            if defined($maximum)
                && length($self->{buffered_body}) > $maximum;
        return Future->done($self->{buffered_body});
    }
    return Future->fail('HTTP/3 response body was discarded')
        if $self->{discard};

    my $body = '';
    my $read;
    # $read refers to itself to loop. Break that cycle once the loop ends,
    # or every slurped response and its body would be kept alive.
    $read = sub {
        return $self->read->then(sub {
            my ($chunk) = @_;
            if (defined $chunk) {
                $body .= $chunk;
                if (defined($maximum) && length($body) > $maximum) {
                    $self->_discard;
                    return Future->fail(
                        "HTTP/3 response body exceeds $maximum bytes");
                }
                return $read->();
            }
            $self->{buffered_body} = $body;
            return Future->done($body);
        });
    };
    return $read->()->on_ready(sub { undef $read });
}

sub body {
    croak 'body() takes no arguments' unless @_ == 1;
    croak 'body() is available after slurp() or a buffered client request'
        unless defined $_[0]{buffered_body};
    return $_[0]{buffered_body};
}

sub _push_body {
    my ($self, $body) = @_;
    return if $self->{complete} || defined $self->{failure};
    if ($self->{discard}) {
        $self->{on_consume}->(length $body);
        return;
    }
    my $waiter = delete $self->{waiter};
    if ($waiter && !$waiter->is_ready) {
        $self->{on_consume}->(length $body);
        $waiter->done($body);
    } else {
        push @{$self->{queue}}, $body;
    }
    return;
}

sub _finish {
    my ($self) = @_;
    return if $self->{complete} || defined $self->{failure};
    $self->{complete} = 1;
    if (my $waiter = delete $self->{waiter}) {
        $waiter->done(undef) unless $waiter->is_ready;
    }
    return;
}

sub _fail {
    my ($self, $error) = @_;
    return if $self->{complete} || defined $self->{failure};
    $self->{failure} = "$error";
    $self->{on_consume}->(length $_) for @{$self->{queue}};
    $self->{queue} = [];
    if (my $waiter = delete $self->{waiter}) {
        $waiter->fail($self->{failure}) unless $waiter->is_ready;
    }
    return;
}

sub _discard {
    my ($self) = @_;
    $self->{discard} = 1;
    $self->{on_consume}->(length $_) for @{$self->{queue}};
    $self->{queue} = [];
    return 1;
}

sub DESTROY {
    my ($self) = @_;
    return unless ref($self) && ref($self->{queue}) eq 'ARRAY'
        && ref($self->{on_consume}) eq 'CODE';
    my $queue = delete $self->{queue};
    my $on_consume = delete $self->{on_consume};
    $on_consume->(length $_) for @{$queue};
}

sub _set_effective_uri {
    $_[0]{effective_uri} = "$_[1]";
    return;
}

sub _set_redirect_history {
    my ($self, $history) = @_;
    $self->{redirect_history} = [map { { %{$_} } } @{$history}];
    return;
}

sub _header_name {
    my ($name) = @_;
    croak 'header name must be a defined scalar' if !defined($name) || ref($name);
    my $bytes = lc "$name";
    croak 'header name must be a byte string' unless utf8::downgrade($bytes, 1);
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

=head1 NAME

Net::Quiche::HTTP3::Response - HTTP/3 response headers and body reader

=head1 DESCRIPTION

C<read> returns a Future for the next response-body byte string and yields
C<undef> after FINISHED. C<slurp> drains the reader with an optional byte
limit; C<body> is available after that drain. Header order and duplicates are
preserved. C<effective_uri> returns the final request URI for a buffered
client request. C<redirect_history> returns a new array and copied hash for
each redirect hop, so callers cannot mutate response state.
