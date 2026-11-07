package PAGI::Server::HTTP3::ConnectionState;

use strict;
use warnings;
use Carp qw(croak);
use Future ();

our $VERSION = '0.013';

sub new {
    my ($class, @arguments) = @_;
    croak 'new() received an odd number of arguments'
        if @arguments != 1 && @arguments % 2;
    my %options = @arguments == 1 && ref($arguments[0]) eq 'HASH'
        ? %{$arguments[0]} : @arguments;
    my @unknown = grep { $_ ne 'on_error' } keys %options;
    croak "new() received unknown option '$unknown[0]'" if @unknown;
    croak 'on_error must be a code reference'
        if exists($options{on_error}) && ref($options{on_error}) ne 'CODE';
    return bless {
        connected          => 1,
        completed          => 0,
        reason             => undef,
        response_started   => 0,
        response_complete  => 0,
        disconnect_future  => undef,
        disconnect_callbacks => [],
        complete_callbacks => [],
        on_error           => $options{on_error} || sub { warn "$_[0]\n" },
    }, $class;
}

sub is_connected {
    croak 'is_connected() takes no arguments' unless @_ == 1;
    return $_[0]{connected} ? 1 : 0;
}

sub disconnect_reason {
    croak 'disconnect_reason() takes no arguments' unless @_ == 1;
    return $_[0]{reason};
}

sub response_started {
    croak 'response_started() takes no arguments' unless @_ == 1;
    return $_[0]{response_started} ? 1 : 0;
}

sub response_complete {
    croak 'response_complete() takes no arguments' unless @_ == 1;
    return $_[0]{response_complete} ? 1 : 0;
}

sub on_disconnect {
    croak 'on_disconnect() expects one callback' unless @_ == 2;
    my ($self, $callback) = @_;
    croak 'on_disconnect callback must be a code reference'
        unless ref($callback) eq 'CODE';
    if ($self->{connected}) {
        push @{$self->{disconnect_callbacks}}, $callback;
    } elsif (!$self->{completed}) {
        $self->_invoke($callback, $self->{reason});
    }
    return $self;
}

sub on_complete {
    croak 'on_complete() expects one callback' unless @_ == 2;
    my ($self, $callback) = @_;
    croak 'on_complete callback must be a code reference'
        unless ref($callback) eq 'CODE';
    if ($self->{connected}) {
        push @{$self->{complete_callbacks}}, $callback;
    } elsif ($self->{completed}) {
        $self->_invoke($callback);
    }
    return $self;
}

sub disconnect_future {
    croak 'disconnect_future() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    if (!$self->{disconnect_future}) {
        my $future = $self->{disconnect_future} = Future->new;
        $future->done($self->{reason})
            if !$self->{connected} && !$self->{completed};
    }
    return $self->{disconnect_future}->without_cancel;
}

sub _mark_response_started {
    $_[0]{response_started} = 1;
    return;
}

sub _mark_complete {
    my ($self) = @_;
    return unless $self->{connected};
    $self->{connected} = 0;
    $self->{completed} = 1;
    $self->{response_complete} = 1;
    $self->_invoke($_) for @{$self->{complete_callbacks}};
    $self->{complete_callbacks} = [];
    $self->{disconnect_callbacks} = [];
    return;
}

sub _mark_disconnected {
    my ($self, $reason) = @_;
    return unless $self->{connected};
    $self->{connected} = 0;
    $self->{reason} = $reason;
    if ($self->{disconnect_future} && !$self->{disconnect_future}->is_ready) {
        $self->{disconnect_future}->done($reason);
    }
    $self->_invoke($_, $reason) for @{$self->{disconnect_callbacks}};
    $self->{disconnect_callbacks} = [];
    $self->{complete_callbacks} = [];
    return;
}

sub _invoke {
    my ($self, $callback, @arguments) = @_;
    my $ok = eval { $callback->(@arguments); 1 };
    if (!$ok) {
        my $error = $@;
        eval { $self->{on_error}->("PAGI connection callback failed: $error"); 1 }
            or warn "PAGI connection error callback failed: $@";
    }
    return;
}

1;

__END__

=head1 NAME

PAGI::Server::HTTP3::ConnectionState - Per-request PAGI HTTP/3 state

=head1 DESCRIPTION

Instances are exposed as C<< $scope->{'pagi.connection'} >>. They report
response progress and distinguish clean completion from abnormal disconnects
without consuming request-body events. C<disconnect_future> returns a
cancellation-isolated Future for each caller.
