package PAGI::Server::HTTP3;

use strict;
use warnings;
use Carp qw(croak);
use Future ();
use IO::Async::Loop ();
use IO::Async::Socket ();
use IO::Async::Timer::Countdown ();
use IO::Socket::IP ();
use Scalar::Util qw(blessed weaken);
use Socket qw(
    AF_INET AF_INET6
    inet_ntop inet_pton
    pack_sockaddr_in pack_sockaddr_in6
    sockaddr_family
    unpack_sockaddr_in unpack_sockaddr_in6
);
use parent 'IO::Async::Notifier';

use Net::Quiche ();
use PAGI::Server::Protocol::HTTP3 ();

our $VERSION = '0.013';

use constant LOCAL_CONNECTION_ID_LENGTH => 16;
use constant MAX_REQUEST_STREAM_ID => 4_611_686_018_427_387_900;
use constant H3_NO_ERROR => 0x100;
use constant DEFAULT_SHUTDOWN_GRACE => 5;

sub _init {
    my ($self, $params) = @_;
    my $has_app = exists $params->{app};
    my $has_psgi_app = exists $params->{psgi_app};
    croak 'new() requires exactly one of app or psgi_app'
        if $has_app == $has_psgi_app;
    my $app = delete $params->{app};
    my $psgi_app = delete $params->{psgi_app};
    if ($has_psgi_app) {
        croak 'psgi_app must be a PSGI code reference'
            unless ref($psgi_app) eq 'CODE';
        eval { require PAGI::App::WrapPSGI; 1 }
            or croak "psgi_app requires PAGI::App::WrapPSGI: $@";
        $app = PAGI::App::WrapPSGI->new(psgi_app => $psgi_app)->to_app;
    }
    $self->{app} = $app;
    $self->{config} = delete $params->{config};
    $self->{host} = delete($params->{host}) // '127.0.0.1';
    $self->{port} = delete($params->{port}) // 8443;
    $self->{max_connections} = delete($params->{max_connections}) // 1_000;
    $self->{on_error} = delete($params->{on_error}) || sub { warn "$_[0]\n" };

    croak 'app must be a PAGI code reference' unless ref($self->{app}) eq 'CODE';
    croak 'config must be a Net::Quiche::Config object'
        unless blessed($self->{config})
            && $self->{config}->isa('Net::Quiche::Config');
    my ($host, $family) = _host($self->{host});
    $self->{host} = $host;
    $self->{family} = $family;
    croak 'port must be an integer from 0 to 65535'
        unless defined($self->{port}) && !ref($self->{port})
            && $self->{port} =~ /\A(?:0|[1-9][0-9]*)\z/
            && $self->{port} <= 65_535;
    croak 'max_connections must be a positive integer'
        unless defined($self->{max_connections}) && !ref($self->{max_connections})
            && $self->{max_connections} =~ /\A[1-9][0-9]*\z/;
    croak 'on_error must be a code reference' unless ref($self->{on_error}) eq 'CODE';

    $self->{socket} = undef;
    $self->{listen_future} = undef;
    $self->{bound_port} = undef;
    $self->{routes} = {};
    $self->{connections} = {};
    $self->{stopped} = 0;
    $self->{shutting_down} = 0;
    $self->{shutdown_stage} = undef;
    $self->{shutdown_future} = undef;
    $self->{shutdown_timer} = undef;
    $self->{shutdown_check_scheduled} = 0;
    $self->SUPER::_init($params);
}

sub listen {
    croak 'listen() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    croak 'HTTP/3 server is shutting down' if $self->{shutting_down};
    return Future->done($self) if $self->{socket} && defined $self->{bound_port};
    return $self->{listen_future} if $self->{listen_future};
    croak 'PAGI::Server::HTTP3 must be added to an IO::Async loop before listen()'
        unless $self->loop;

    my $weak_self = $self;
    weaken($weak_self);
    my $socket = IO::Async::Socket->new(
        recv_len => 65_535,
        recv_all => 1,
        autoflush => 1,
        on_recv => sub {
            my (undef, $data, $peer_address) = @_;
            return unless $weak_self;
            $weak_self->_receive_datagram($data, $peer_address);
        },
        on_recv_error => sub {
            return unless $weak_self;
            $weak_self->_report_error("UDP receive failed: $_[1]");
        },
        on_send_error => sub {
            return unless $weak_self;
            $weak_self->_report_error("UDP send failed: $_[1]");
        },
    );
    $self->{socket} = $socket;
    $self->add_child($socket);

    my $future = $socket->bind(
        host => $self->{host},
        service => $self->{port},
        family => $self->{family},
        socktype => 'dgram',
    )->then(sub {
        return Future->fail('HTTP/3 listener was destroyed during bind')
            unless $weak_self;
        my $handle = $socket->read_handle;
        $weak_self->{bound_port} = $handle->sockport;
        $weak_self->{stopped} = 0;
        $weak_self->{shutdown_future} = undef;
        $weak_self->{shutdown_stage} = undef;
        return Future->done($weak_self);
    });
    $self->{listen_future} = $future;
    $future->on_fail(sub {
        return unless $weak_self && $weak_self->{socket}
            && $weak_self->{socket} == $socket;
        $weak_self->remove_child($socket) if $socket->parent;
        $socket->close;
        $weak_self->{socket} = undef;
    });
    $future->on_ready(sub {
        $weak_self->{listen_future} = undef if $weak_self;
    });
    return $future;
}

sub run {
    croak 'run() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    my $loop = IO::Async::Loop->new;
    $loop->add($self);
    $self->listen->get;
    $loop->run;
    return;
}

sub stop {
    croak 'stop() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    return if $self->{stopped};
    $self->{stopped} = 1;
    for my $id (keys %{$self->{connections}}) {
        my $state = $self->{connections}{$id};
        $state->{protocol}->disconnect('server_shutdown') if $state->{protocol};
        $self->_drop_connection($state);
    }
    if (my $socket = delete $self->{socket}) {
        $self->remove_child($socket) if $socket->parent;
        $socket->close;
    }
    $self->{bound_port} = undef;
    $self->{shutting_down} = 0;
    $self->{shutdown_stage} = undef;
    $self->_remove_shutdown_timer;
    if (my $future = $self->{shutdown_future}) {
        $future->done($self) unless $future->is_ready;
    }
    return;
}

sub goaway {
    croak 'goaway() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    croak 'HTTP/3 server has been stopped' if $self->{stopped};
    my @futures;
    for my $state (values %{$self->{connections}}) {
        push @futures, $self->_queue_goaway($state, MAX_REQUEST_STREAM_ID);
    }
    return Future->done($self) unless @futures;
    return Future->needs_all(map { $_->without_cancel } @futures)
        ->then_done($self);
}

sub shutdown {
    my ($self, @arguments) = @_;
    my %options = _options('shutdown', @arguments);
    my @unknown = sort grep { $_ ne 'grace' } keys %options;
    croak "shutdown() received unknown option '$unknown[0]'" if @unknown;
    my $grace = exists($options{grace})
        ? _nonnegative_number('grace', $options{grace})
        : DEFAULT_SHUTDOWN_GRACE;

    return Future->done($self) if $self->{stopped};
    if ($self->{shutting_down}) {
        return $self->{shutdown_future}->without_cancel;
    }

    $self->{shutting_down} = 1;
    $self->{shutdown_stage} = 'initial';
    $self->{shutdown_future} = Future->new;
    if ($grace > 0 && $self->{socket}) {
        my $weak_self = $self;
        weaken($weak_self);
        my $timer = IO::Async::Timer::Countdown->new(
            delay => $grace,
            on_expire => sub {
                $weak_self->_finish_shutdown(1) if $weak_self;
            },
        );
        $self->{shutdown_timer} = $timer;
        $self->add_child($timer);
        $timer->start;
    }

    $self->_check_shutdown;
    $self->_finish_shutdown(1) if $grace == 0 && $self->{shutting_down};
    return $self->{shutdown_future}->without_cancel;
}

sub bound_port {
    croak 'bound_port() takes no arguments' unless @_ == 1;
    return $_[0]{bound_port};
}

sub connection_count {
    croak 'connection_count() takes no arguments' unless @_ == 1;
    return scalar keys %{$_[0]{connections}};
}

sub _receive_datagram {
    my ($self, $data, $peer_packed) = @_;
    return if $self->{stopped};
    my $header = eval {
        Net::Quiche::Packet->header_info(
            $data,
            destination_connection_id_length => LOCAL_CONNECTION_ID_LENGTH,
        );
    };
    if (!$header) {
        $self->_report_error($@ || 'Failed to parse QUIC packet');
        return;
    }

    my $destination_id = $header->{destination_connection_id};
    $self->_debug(sprintf(
        'recv bytes=%d version=%u type=%u dcid=%s',
        length($data), $header->{version}, $header->{type}, unpack('H*', $destination_id),
    ));
    my $state = $self->{routes}{$destination_id};
    if (!$state) {
        return if $self->{shutting_down};
        if (!Net::Quiche::Packet->version_is_supported($header->{version})) {
            return if $header->{version} == 0;
            my $negotiation = eval {
                Net::Quiche::Packet->negotiate_version(
                    source_connection_id => $header->{source_connection_id},
                    destination_connection_id => $destination_id,
                );
            };
            if (!defined $negotiation) {
                $self->_report_error(
                    $@ || 'Failed to generate QUIC version negotiation packet');
                return;
            }
            $self->{socket}->send($negotiation, 0, $peer_packed);
            $self->_debug(sprintf(
                'sent version negotiation bytes=%d dcid=%s',
                length($negotiation),
                unpack('H*', $header->{source_connection_id}),
            ));
            return;
        }
        if ($self->connection_count >= $self->{max_connections}) {
            $self->_report_error('HTTP/3 connection limit reached');
            return;
        }
        $state = eval { $self->_create_connection($header, $peer_packed) };
        if (!$state) {
            $self->_report_error($@ || 'Failed to create QUIC connection');
            return;
        }
        $self->_debug('created connection scid=' . unpack('H*', $state->{id}));
    }

    my $peer = _unpack_address($peer_packed);
    my $received = eval {
        $state->{connection}->receive_datagram(
            $data,
            from => $peer,
            to => [$self->{host}, $self->{bound_port}],
        );
        1;
    };
    if (!$received) {
        $self->_report_error($@ || 'Failed to receive QUIC datagram');
        return;
    }

    if ($state->{connection}->is_established && !$state->{protocol}) {
        $self->_debug('QUIC handshake established scid=' . unpack('H*', $state->{id}));
        my $id = $state->{id};
        my $weak_self = $self;
        weaken($weak_self);
        $state->{protocol} = PAGI::Server::Protocol::HTTP3->new(
            app => $self->{app},
            connection => $state->{connection},
            client => $state->{peer},
            server => [$self->{host}, $self->{bound_port}],
            on_write => sub {
                $weak_self->_flush_by_id($id) if $weak_self;
            },
            on_idle => sub {
                $weak_self->_schedule_shutdown_check if $weak_self;
            },
            on_error => sub {
                $weak_self->_report_error($_[0]) if $weak_self;
            },
        );
        if ($self->{shutting_down}) {
            $self->_queue_goaway($state, MAX_REQUEST_STREAM_ID);
        } else {
            $self->_try_goaway($state);
        }
    }
    if ($state->{protocol}) {
        eval { $state->{protocol}->drain_events; 1 }
            or $self->_report_error($@);
    }
    $self->_flush_state($state);
    $self->_schedule_shutdown_check if $self->{shutting_down};
}

sub _create_connection {
    my ($self, $header, $peer_packed) = @_;
    my $original_id = $header->{destination_connection_id};
    croak 'QUIC Initial destination connection ID is empty'
        unless length $original_id;
    my $source_id = $self->_new_connection_id;
    my $peer = _unpack_address($peer_packed);
    my $connection = Net::Quiche::Connection->accept(
        config => $self->{config},
        source_connection_id => $source_id,
        local => [$self->{host}, $self->{bound_port}],
        peer => $peer,
    );

    my $state = {
        id => $source_id,
        aliases => [$original_id, $source_id],
        connection => $connection,
        peer => $peer,
        protocol => undef,
        timer => undef,
        goaway_id => undef,
        goaway_future => undef,
        goaway_sent => 0,
        goaway_sent_id => undef,
        goaway_sending => 0,
        goaway_failed => 0,
        goaway_error => undef,
    };
    my $weak_self = $self;
    weaken($weak_self);
    my $timer = IO::Async::Timer::Countdown->new(
        delay => 0,
        on_expire => sub {
            $weak_self->_on_timeout($source_id) if $weak_self;
        },
    );
    $state->{timer} = $timer;
    $self->add_child($timer);
    $self->{connections}{$source_id} = $state;
    $self->{routes}{$_} = $state for @{$state->{aliases}};
    return $state;
}

sub _new_connection_id {
    my ($self) = @_;
    for (1 .. 10) {
        open my $random, '<:raw', '/dev/urandom'
            or croak "Cannot open /dev/urandom: $!";
        my $id = '';
        while (length($id) < LOCAL_CONNECTION_ID_LENGTH) {
            my $count = read $random, my $chunk,
                LOCAL_CONNECTION_ID_LENGTH - length($id);
            croak "Cannot read /dev/urandom: $!" unless defined $count;
            croak 'Unexpected EOF from /dev/urandom' if $count == 0;
            $id .= $chunk;
        }
        close $random;
        return $id unless exists $self->{routes}{$id};
    }
    croak 'Could not generate a unique QUIC connection ID';
}

sub _flush_by_id {
    my ($self, $id) = @_;
    my $state = $self->{connections}{$id} or return;
    $self->_flush_state($state);
}

sub _flush_state {
    my ($self, $state) = @_;
    my $socket = $self->{socket} or return;
    $self->_try_goaway($state);
    my $sent = 0;
    while (my $datagram = $state->{connection}->next_datagram) {
        my $target = _pack_address($datagram->{to});
        $socket->send($datagram->{data}, 0, $target);
        $sent++;
    }
    $self->_debug("flushed datagrams=$sent") if $sent;
    if ($state->{connection}->is_closed) {
        for my $side (qw(local peer)) {
            my $method = "${side}_error";
            my $error = $state->{connection}->$method() or next;
            my $message = sprintf(
                'QUIC %s error code=%s application=%s reason=%s',
                $side, $error->{code}, $error->{application} ? 1 : 0,
                length($error->{reason}) ? $error->{reason} : '(empty)',
            );
            if ($error->{code} == 0) {
                $self->_debug($message);
            } else {
                $self->_report_error($message);
            }
        }
        $state->{protocol}->disconnect('client_closed') if $state->{protocol};
        $self->_drop_connection($state);
        return;
    }
    $self->_arm_timer($state);
}

sub _try_goaway {
    my ($self, $state) = @_;
    return if $state->{goaway_sent}
        || $state->{goaway_sending}
        || $state->{goaway_failed};
    return unless $state->{goaway_future} && $state->{protocol};
    $state->{goaway_sending} = 1;
    my $sent = eval { $state->{protocol}->send_goaway($state->{goaway_id}) };
    my $error = $@;
    $state->{goaway_sending} = 0;
    if ($error) {
        $state->{goaway_failed} = 1;
        $state->{goaway_error} = $error;
        $state->{goaway_future}->fail($error)
            unless $state->{goaway_future}->is_ready;
        $self->_schedule_shutdown_check if $self->{shutting_down};
        return;
    }
    return unless defined $sent;
    $state->{goaway_sent} = 1;
    $state->{goaway_sent_id} = $state->{goaway_id};
    $state->{goaway_future}->done
        unless $state->{goaway_future}->is_ready;
    $self->_schedule_shutdown_check if $self->{shutting_down};
    return;
}

sub _queue_goaway {
    my ($self, $state, $id) = @_;
    if (defined($state->{goaway_sent_id})
            && $state->{goaway_sent_id} <= $id) {
        return Future->done;
    }
    if ($state->{goaway_failed}) {
        return Future->fail($state->{goaway_error});
    }
    if ($state->{goaway_future} && !$state->{goaway_future}->is_ready) {
        $state->{goaway_id} = $id if $id < $state->{goaway_id};
        $self->_try_goaway($state);
        return $state->{goaway_future};
    }

    $state->{goaway_id} = $id;
    $state->{goaway_future} = Future->new;
    $state->{goaway_sent} = 0;
    $self->_try_goaway($state);
    return $state->{goaway_future};
}

sub _schedule_shutdown_check {
    my ($self) = @_;
    return unless $self->{shutting_down} && !$self->{shutdown_check_scheduled};
    my $loop = $self->loop or return $self->_check_shutdown;
    $self->{shutdown_check_scheduled} = 1;
    my $weak_self = $self;
    weaken($weak_self);
    $loop->later(sub {
        return unless $weak_self;
        $weak_self->{shutdown_check_scheduled} = 0;
        $weak_self->_check_shutdown;
    });
    return;
}

sub _check_shutdown {
    my ($self) = @_;
    return unless $self->{shutting_down};
    my @states = values %{$self->{connections}};
    return $self->_finish_shutdown(0) unless @states;

    if ($self->{shutdown_stage} eq 'initial') {
        for my $state (@states) {
            next unless $state->{protocol};
            my $future = $self->_queue_goaway(
                $state, MAX_REQUEST_STREAM_ID);
            if ($future->is_failed) {
                return $self->_finish_shutdown(0, ($future->failure)[0]);
            }
            return unless $future->is_ready;
        }
        for my $state (@states) {
            return if $state->{protocol}
                && $state->{protocol}->active_streams;
        }
        $self->{shutdown_stage} = 'final';
    }

    if ($self->{shutdown_stage} eq 'final') {
        for my $state (@states) {
            next unless $state->{protocol};
            my $future = $self->_queue_goaway(
                $state, $state->{protocol}->next_request_stream_id);
            if ($future->is_failed) {
                return $self->_finish_shutdown(0, ($future->failure)[0]);
            }
            return unless $future->is_ready;
        }
        return $self->_finish_shutdown(0);
    }
    return;
}

sub _finish_shutdown {
    my ($self, $forced, $error) = @_;
    return unless $self->{shutting_down};
    $self->{shutting_down} = 0;
    $self->{shutdown_stage} = 'closed';
    $self->_remove_shutdown_timer;

    my $socket = $self->{socket};
    for my $state (values %{$self->{connections}}) {
        $state->{protocol}->disconnect('server_shutdown')
            if $state->{protocol} && $state->{protocol}->active_streams;
        my $closed = eval {
            $state->{connection}->close(
                application => 1,
                error_code => H3_NO_ERROR,
                reason => $forced ? 'shutdown deadline' : 'server shutdown',
            );
            if ($socket) {
                while (my $datagram = $state->{connection}->next_datagram) {
                    $socket->send(
                        $datagram->{data}, 0, _pack_address($datagram->{to}));
                }
            }
            1;
        };
        $error ||= $@ unless $closed;
        $self->_drop_connection($state);
    }
    if (my $listener = delete $self->{socket}) {
        $self->remove_child($listener) if $listener->parent;
        $listener->close;
    }
    $self->{bound_port} = undef;
    $self->{stopped} = 1;

    my $future = $self->{shutdown_future};
    if ($error) {
        $future->fail($error) unless $future->is_ready;
    } else {
        $future->done($self) unless $future->is_ready;
    }
    return;
}

sub _remove_shutdown_timer {
    my ($self) = @_;
    my $timer = delete $self->{shutdown_timer} or return;
    $timer->stop if $timer->is_running && $timer->loop;
    $self->remove_child($timer) if $timer->parent;
    return;
}

sub _arm_timer {
    my ($self, $state) = @_;
    my $timer = $state->{timer};
    $timer->stop if $timer->is_running;
    my $milliseconds = $state->{connection}->timeout_ms;
    $timer->configure(delay => $milliseconds / 1_000);
    $timer->start;
}

sub _on_timeout {
    my ($self, $id) = @_;
    my $state = $self->{connections}{$id} or return;
    $state->{connection}->on_timeout;
    $self->_flush_state($state);
}

sub _drop_connection {
    my ($self, $state) = @_;
    return unless delete $self->{connections}{$state->{id}};
    for my $alias (@{$state->{aliases}}) {
        delete $self->{routes}{$alias}
            if $self->{routes}{$alias} && $self->{routes}{$alias} == $state;
    }
    if (my $timer = delete $state->{timer}) {
        $timer->stop if $timer->is_running && $timer->loop;
        $self->remove_child($timer) if $timer->parent;
    }
    if (my $future = delete $state->{goaway_future}) {
        $future->fail('QUIC connection closed before GOAWAY was sent')
            unless $future->is_ready;
    }
    delete $state->{protocol};
    delete $state->{connection};
    $self->_schedule_shutdown_check if $self->{shutting_down};
}

sub _report_error {
    my ($self, $error) = @_;
    $error = "$error";
    $error =~ s/\s+\z//;
    $self->{on_error}->($error);
}

sub _debug {
    return unless $ENV{NET_QUICHE_DEBUG};
    print STDERR "[net-quiche] $_[1]\n";
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
    croak 'UDP peer uses an unsupported socket address family';
}

sub _pack_address {
    my ($address) = @_;
    my $binary = inet_pton(AF_INET, $address->[0]);
    return pack_sockaddr_in($address->[1], $binary) if defined $binary;
    $binary = inet_pton(AF_INET6, $address->[0]);
    croak 'QUIC datagram uses an invalid IP address' unless defined $binary;
    return pack_sockaddr_in6($address->[1], $binary);
}

sub _host {
    my ($host) = @_;
    croak 'host must be an IPv4 or IPv6 address'
        if !defined($host) || ref($host) || index($host, '%') >= 0;
    my $binary = inet_pton(AF_INET, $host);
    return (inet_ntop(AF_INET, $binary), 'inet') if defined $binary;
    $binary = inet_pton(AF_INET6, $host);
    croak 'host must be an IPv4 or IPv6 address' unless defined $binary;
    return (inet_ntop(AF_INET6, $binary), 'inet6');
}

sub _options {
    my ($method, @arguments) = @_;
    return () unless @arguments;
    return %{$arguments[0]}
        if @arguments == 1 && ref($arguments[0]) eq 'HASH';
    croak "$method() received an odd number of arguments" if @arguments % 2;
    return @arguments;
}

sub _nonnegative_number {
    my ($name, $value) = @_;
    croak "$name must be a non-negative number"
        if !defined($value) || ref($value)
            || $value !~ /\A(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?\z/
            || $value < 0;
    return 0 + $value;
}

sub DESTROY {
    my ($self) = @_;
    $self->stop if $self->{socket} && !$self->{stopped};
}

1;

__END__

=head1 NAME

PAGI::Server::HTTP3 - IO::Async UDP listener for PAGI over HTTP/3

=head1 SYNOPSIS

    my $server = PAGI::Server::HTTP3->new(
        app => $app,
        config => $quiche_config,
        host => '::1',
        port => 8443,
    );

    my $loop = IO::Async::Loop->new;
    $loop->add($server);
    $server->listen->get;
    # Or pass psgi_app => $psgi_coderef instead of app.
    my $shutdown = $server->shutdown(grace => 5);
    $loop->await($shutdown)->get;

=head1 DESCRIPTION

The listener owns the UDP socket, QUIC connection routing table, and quiche
timers. It creates one PAGI HTTP scope for each HTTP/3 request stream. An
unsupported nonzero QUIC version receives a Version Negotiation response
without allocating a connection. The C<host> parameter accepts an IPv4 or
IPv6 literal. C<goaway> sends the maximum server GOAWAY ID to every current
connection and returns a Future that resolves after quiche accepts all frames.
It neither closes those connections nor stops the UDP listener, so accepted
request streams can finish and clients can open replacement connections.
C<shutdown> refuses new connections, sends initial and final GOAWAY frames,
waits up to C<grace> seconds for active PAGI streams, closes with H3_NO_ERROR,
and then closes the UDP listener. It returns a cancellation-isolated Future.
C<stop> remains immediate. Pass C<psgi_app> instead of C<app> to lazily wrap a
PSGI application with C<PAGI::App::WrapPSGI>; the two options are mutually
exclusive. Retry, migration, and trailers remain outside the current MVP. The
HTTP/3-specific conformance subset in
C<t/pagi-conformance.t> covers request scopes, POST bodies, response sequencing,
HEAD suppression, per-request connection state, and disconnect behavior. It is
not a claim of full PAGI conformance.
