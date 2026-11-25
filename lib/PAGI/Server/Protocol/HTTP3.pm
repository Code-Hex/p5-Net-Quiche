package PAGI::Server::Protocol::HTTP3;

use strict;
use warnings;
use Carp qw(croak);
use Encode qw(decode FB_CROAK);
use Future ();
use Scalar::Util qw(blessed weaken);
use URI::Escape qw(uri_unescape);
use PAGI::Server::HTTP3::ConnectionState ();

our $VERSION = '0.013';

# quiche's HTTP/3 C ABI encodes a transport error as the QUIC error minus
# 1000. QUICHE_ERR_STREAM_STOPPED is -15, so this is a peer-aborted response,
# not an application failure.
my $H3_TRANSPORT_STREAM_STOPPED = -1015;
my $H3_NO_ERROR = 0x100;
my $H3_INTERNAL_ERROR = 0x102;
my $BODY_CHUNK_SIZE = 16 * 1024;
my $DEFAULT_REQUEST_BODY_BUFFER = 1024 * 1024;

sub new {
    my ($class, @arguments) = @_;
    my %options = _options('new', @arguments);
    my %known = map { $_ => 1 }
        qw(app connection client server on_write on_idle on_error
           max_request_body_buffer);
    my @unknown = sort grep { !$known{$_} } keys %options;
    croak "new() received unknown option '$unknown[0]'" if @unknown;
    for my $name (qw(app connection client server)) {
        croak "new() requires app, connection, client, and server"
            unless exists $options{$name};
    }
    croak 'app must be a code reference' unless ref($options{app}) eq 'CODE';
    croak 'connection must be an established Net::Quiche::Connection'
        unless blessed($options{connection})
            && $options{connection}->isa('Net::Quiche::Connection')
            && $options{connection}->is_established;
    for my $name (qw(client server)) {
        croak "$name must be an [IP address, port] array reference"
            unless ref($options{$name}) eq 'ARRAY' && @{$options{$name}} == 2;
    }
    for my $name (qw(on_write on_idle on_error)) {
        croak "$name must be a code reference"
            if exists($options{$name}) && ref($options{$name}) ne 'CODE';
    }
    my $body_buffer = $options{max_request_body_buffer}
        // $DEFAULT_REQUEST_BODY_BUFFER;
    croak 'max_request_body_buffer must be a positive integer'
        if ref($body_buffer) || $body_buffer !~ /\A[1-9][0-9]*\z/;

    return bless {
        app        => $options{app},
        connection => $options{connection},
        h3         => $options{connection}->http3,
        client     => [@{$options{client}}],
        server     => [@{$options{server}}],
        on_write   => $options{on_write} || sub {},
        on_idle    => $options{on_idle} || sub {},
        on_error   => $options{on_error} || sub { warn "$_[0]\n" },
        streams    => {},
        next_request_stream_id => 0,
        max_request_body_buffer => 0 + $body_buffer,
        draining   => 0,
        drain_again => 0,
    }, $class;
}

sub drain_events {
    croak 'drain_events() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    # An application can call receive() from inside an event delivered here,
    # and receive() may need another poll. Run that poll after this one
    # instead of re-entering quiche's event loop.
    if ($self->{draining}) {
        $self->{drain_again} = 1;
        return 0;
    }
    local $self->{draining} = 1;
    my $count = 0;
    do {
        $self->{drain_again} = 0;
        while (my $event = $self->{h3}->poll(read_body => 0)) {
            $count++;
            my $type = $event->{type};
            if ($type eq 'headers') {
                $self->_on_headers($event);
            } elsif ($type eq 'data') {
                $self->_read_request_body($event->{stream_id});
            } elsif ($type eq 'finished') {
                $self->_on_finished($event->{stream_id});
            } elsif ($type eq 'reset') {
                $self->_disconnect_stream($event->{stream_id}, 'client_closed');
            }
        }
        $self->_drain_response_writes($_) for keys %{$self->{streams}};
    } while ($self->{drain_again});
    return $count;
}

sub disconnect {
    croak 'disconnect() expects one reason' unless @_ == 2;
    my ($self, $reason) = @_;
    $self->_disconnect_stream($_, $reason) for keys %{$self->{streams}};
    return;
}

sub active_streams {
    croak 'active_streams() takes no arguments' unless @_ == 1;
    return scalar keys %{$_[0]{streams}};
}

sub next_request_stream_id {
    croak 'next_request_stream_id() takes no arguments' unless @_ == 1;
    return $_[0]{next_request_stream_id};
}

sub send_goaway {
    croak 'send_goaway() expects one identifier' unless @_ == 2;
    my ($self, $id) = @_;
    my $sent = $self->{h3}->send_goaway($id);
    $self->{on_write}->() if defined $sent;
    return $sent;
}

sub _on_headers {
    my ($self, $event) = @_;
    my $stream_id = $event->{stream_id};
    my $next_stream_id = $stream_id + 4;
    $next_stream_id = 4_611_686_018_427_387_900
        if $next_stream_id > 4_611_686_018_427_387_900;
    $self->{next_request_stream_id} = $next_stream_id
        if $next_stream_id > $self->{next_request_stream_id};
    if ($self->{streams}{$stream_id}) {
        $self->_report_error("Trailers are not supported on HTTP/3 stream $stream_id");
        return;
    }

    my $scope = eval { $self->_scope_from_headers($event->{headers}) };
    if (!$scope) {
        my $error = $@ || 'Invalid HTTP/3 request headers';
        $self->_send_error_response(
            $stream_id, 400, "Bad Request\n", $event->{more} ? 0 : 1);
        $self->_report_error($error);
        return;
    }

    my $connection_state = PAGI::Server::HTTP3::ConnectionState->new(
        on_error => $self->{on_error},
    );
    $scope->{state} = {};
    $scope->{'pagi.connection'} = $connection_state;
    my $stream = $self->{streams}{$stream_id} = {
        queue            => [],
        receive_waiter   => undef,
        request_done     => !$event->{more},
        response_started => 0,
        response_done    => 0,
        response_queue   => [],
        write_draining   => 0,
        disconnected     => 0,
        app_future       => undef,
        app_done         => 0,
        connection_state => $connection_state,
        head_request     => $scope->{method} eq 'HEAD' ? 1 : 0,
        queued_bytes     => 0,
        body_paused      => 0,
    };
    push @{$stream->{queue}}, {
        type => 'http.request', body => '', more => $event->{more} ? 1 : 0,
    };
    $self->_start_app($stream_id, $scope);
}

# Read request body from quiche until the stream's unread events reach
# max_request_body_buffer. The rest stays in quiche, where QUIC flow control
# stops the client until the application catches up with receive().
sub _read_request_body {
    my ($self, $stream_id) = @_;
    my $stream = $self->{streams}{$stream_id};
    if (!$stream || $stream->{request_done} || $stream->{disconnected}
            || $stream->{app_done}) {
        # Nobody will read this body. Drop it so quiche's buffer is freed.
        1 while defined eval { $self->{h3}->recv_body($stream_id, $BODY_CHUNK_SIZE) };
        return;
    }
    while ($stream->{queued_bytes} < $self->{max_request_body_buffer}) {
        my $body = eval { $self->{h3}->recv_body($stream_id, $BODY_CHUNK_SIZE) };
        if (my $error = $@) {
            $stream->{body_paused} = 0;
            $self->_report_error("HTTP/3 request body read failed: $error")
                unless $error =~ /failed: -101[56]\b/;
            $self->_disconnect_stream($stream_id, 'client_closed');
            return;
        }
        if (!defined $body) {
            $stream->{body_paused} = 0;
            return;
        }
        $self->_deliver($stream, {
            type => 'http.request', body => $body, more => 1,
        });
        # Delivering ran application code, which may have finished the
        # stream or stopped reading it.
        return if !$self->{streams}{$stream_id} || $stream->{disconnected}
            || $stream->{request_done};
    }
    $stream->{body_paused} = 1;
    return;
}

sub _resume_request_body {
    my ($self, $stream_id) = @_;
    my $stream = $self->{streams}{$stream_id} or return;
    return unless $stream->{body_paused};
    # This runs inside the application's receive(). Report failures here
    # rather than turning them into an exception in application code.
    eval {
        $self->_read_request_body($stream_id);
        # A finished event, if any, only follows once the body has been read.
        $self->drain_events;
        # Reading returned flow-control credit, which must reach the client.
        $self->{on_write}->();
        1;
    } or $self->_report_error($@ || 'HTTP/3 request body read failed');
    return;
}

sub _on_finished {
    my ($self, $stream_id) = @_;
    my $stream = $self->{streams}{$stream_id} or return;
    return if $stream->{request_done} || $stream->{disconnected};
    $stream->{request_done} = 1;
    $self->_deliver($stream, {
        type => 'http.request', body => '', more => 0,
    });
    $self->_maybe_finish($stream_id);
}

sub _start_app {
    my ($self, $stream_id, $scope) = @_;
    my $stream = $self->{streams}{$stream_id} or return;
    my $weak_self = $self;
    weaken($weak_self);

    my $receive = sub {
        return Future->done({ type => 'http.disconnect' }) unless $weak_self;
        my $current = $weak_self->{streams}{$stream_id}
            or return Future->done({ type => 'http.disconnect' });
        if (@{$current->{queue}}) {
            my $event = shift @{$current->{queue}};
            $current->{queued_bytes} -= length($event->{body} // '');
            $weak_self->_resume_request_body($stream_id)
                if $current->{body_paused}
                    && $current->{queued_bytes}
                        < $weak_self->{max_request_body_buffer};
            return Future->done($event);
        }
        if ($current->{disconnected}) {
            return Future->done({ type => 'http.disconnect' });
        }
        if (my $waiter = $current->{receive_waiter}) {
            return Future->fail(
                'Only one pending receive() is allowed per PAGI stream')
                unless $waiter->is_ready;
            # The application cancelled its earlier receive().
            delete $current->{receive_waiter};
        }
        return $current->{receive_waiter} = Future->new;
    };

    my $send = sub {
        return Future->done unless $weak_self;
        return $weak_self->_send_event($stream_id, $_[0]);
    };

    my $future = eval { $self->{app}->($scope, $receive, $send) };
    if (my $error = $@) {
        $stream = $self->{streams}{$stream_id} or return;
        $stream->{app_done} = 1;
        $self->_application_failed($stream_id, $error);
        $self->_maybe_finish($stream_id);
        return;
    }
    if (!blessed($future) || !$future->isa('Future')) {
        $stream->{app_done} = 1;
        $self->_application_failed($stream_id, 'PAGI application must return a Future');
        $self->_maybe_finish($stream_id);
        return;
    }
    $stream->{app_future} = $future;
    $future->on_fail(sub {
        return unless $weak_self;
        my $current = $weak_self->{streams}{$stream_id} or return;
        $current->{app_done} = 1;
        $weak_self->_application_failed($stream_id, $_[0]);
        $weak_self->_maybe_finish($stream_id);
    });
    $future->on_done(sub {
        return unless $weak_self;
        my $current = $weak_self->{streams}{$stream_id} or return;
        $current->{app_done} = 1;
        if (!$current->{response_started}) {
            $weak_self->_send_error_response($stream_id, 500, "Internal Server Error\n");
        } elsif (!$current->{response_done} && !$current->{disconnected}) {
            $weak_self->_report_error(
                "PAGI application ended before completing response on stream $stream_id");
            $weak_self->_abort_response($stream_id);
        }
        $weak_self->_maybe_finish($stream_id);
    });
}

sub _send_event {
    my ($self, $stream_id, $event) = @_;
    my $stream = $self->{streams}{$stream_id}
        or return Future->fail('HTTP/3 request stream no longer exists');
    return Future->done if $stream->{disconnected};
    return Future->fail('send() expects an event hash reference')
        unless ref($event) eq 'HASH';
    return Future->fail('Only one pending send() is allowed per PAGI stream')
        if @{$stream->{response_queue}};

    my $operation;
    my $ok = eval {
        my $type = $event->{type} // '';
        if ($type eq 'http.response.start') {
            croak 'http.response.start may only be sent once'
                if $stream->{response_started};
            croak 'HTTP/3 trailers are not supported by this MVP'
                if $event->{trailers};
            my $status = $event->{status};
            croak 'status must be an integer from 100 to 599'
                if !defined($status) || ref($status)
                    || $status !~ /\A[1-5][0-9]{2}\z/;
            $operation = {
                type => 'start',
                status => 0 + $status,
                headers => _response_headers($event->{headers} // []),
                future => Future->new,
            };
        } elsif ($type eq 'http.response.body') {
            croak 'http.response.start must precede http.response.body'
                unless $stream->{response_started};
            croak 'response body is already complete' if $stream->{response_done};
            my $body = _bytes('response body',
                exists($event->{body}) ? $event->{body} : '');
            my $more = exists $event->{more} ? _boolean('more', $event->{more}) : 0;
            $operation = {
                type => 'body',
                body => $body,
                offset => 0,
                final => $more ? 0 : 1,
                future => Future->new,
            };
        } else {
            croak "Unsupported PAGI send event '$type'";
        }
        1;
    };
    return Future->fail($@) unless $ok;
    push @{$stream->{response_queue}}, $operation;
    $self->_drain_response_writes($stream_id);
    return $operation->{future};
}

sub _drain_response_writes {
    my ($self, $stream_id) = @_;
    my $stream = $self->{streams}{$stream_id} or return;
    return if $stream->{disconnected} || $stream->{write_draining};
    $stream->{write_draining} = 1;

    my $ok = eval {
        while (my $operation = $stream->{response_queue}[0]) {
            my ($complete, $progress);
            if ($operation->{type} eq 'start') {
                my $result = $self->{h3}->send_response(
                    $stream_id,
                    status => $operation->{status},
                    headers => $operation->{headers},
                );
                last unless defined $result;
                $stream->{response_started} = 1;
                $stream->{connection_state}->_mark_response_started;
                $complete = 1;
                $progress = 1;
            } else {
                my $length = length $operation->{body};
                if ($stream->{head_request} && !$operation->{final}) {
                    $complete = 1;
                } elsif ($stream->{head_request}) {
                    my $written = $self->{h3}->send_body(
                        $stream_id, '', final => 1,
                    );
                    last unless defined $written;
                    $stream->{response_done} = 1;
                    $stream->{connection_state}->_mark_complete;
                    $complete = 1;
                    $progress = 1;
                } elsif ($length == 0 && !$operation->{final}) {
                    $complete = 1;
                } else {
                    my $remaining = substr(
                        $operation->{body}, $operation->{offset});
                    my $written = $self->{h3}->send_body(
                        $stream_id,
                        $remaining,
                        final => $operation->{final},
                    );
                    last unless defined $written;
                    croak 'quiche accepted more response bytes than supplied'
                        if $written > length $remaining;
                    $operation->{offset} += $written;
                    $progress = $written > 0 || $operation->{final};
                    if ($operation->{offset} == $length) {
                        if ($operation->{final}) {
                            $stream->{response_done} = 1;
                            $stream->{connection_state}->_mark_complete;
                        }
                        $complete = 1;
                    }
                }
            }

            $self->{on_write}->() if $progress;
            last unless $complete;
            shift @{$stream->{response_queue}};
            $operation->{future}->done unless $operation->{future}->is_ready;
            $self->_maybe_finish($stream_id);
        }
        1;
    };
    $stream->{write_draining} = 0;
    if (!$ok) {
        my $error = $@ || 'Failed to write HTTP/3 response';
        if ($error =~ /\Aquiche_h3_send_(?:response|body)\(\) failed: \Q$H3_TRANSPORT_STREAM_STOPPED\E\b/) {
            $self->_disconnect_stream($stream_id, 'client_closed');
        } else {
            $self->_fail_response_writes($stream, $error);
        }
    }
    return;
}

sub _fail_response_writes {
    my ($self, $stream, $error) = @_;
    my @operations = splice @{$stream->{response_queue}};
    for my $operation (@operations) {
        $operation->{future}->fail($error) unless $operation->{future}->is_ready;
    }
}

sub _settle_response_writes {
    my ($self, $stream) = @_;
    my @operations = splice @{$stream->{response_queue}};
    for my $operation (@operations) {
        $operation->{future}->done unless $operation->{future}->is_ready;
    }
}

sub _deliver {
    my ($self, $stream, $event) = @_;
    my $waiter = delete $stream->{receive_waiter};
    if ($waiter && !$waiter->is_ready) {
        $waiter->done($event);
    } else {
        # No live receive(): keep the event, even if an earlier receive()
        # was cancelled, so the application still sees it next time.
        push @{$stream->{queue}}, $event;
        $stream->{queued_bytes} += length($event->{body} // '');
    }
}

sub _disconnect_stream {
    my ($self, $stream_id, $reason) = @_;
    my $stream = $self->{streams}{$stream_id} or return;
    return if $stream->{disconnected};
    $stream->{disconnected} = 1;
    $stream->{connection_state}->_mark_disconnected($reason);
    $self->_settle_response_writes($stream);
    $self->_deliver($stream, { type => 'http.disconnect', reason => $reason });
    $self->_maybe_finish($stream_id);
}

sub _application_failed {
    my ($self, $stream_id, $error) = @_;
    my $stream = $self->{streams}{$stream_id} or return;
    if (!$stream->{disconnected} && !$stream->{response_started}) {
        $self->_send_error_response($stream_id, 500, "Internal Server Error\n");
    } elsif (!$stream->{disconnected}) {
        $self->_abort_response($stream_id);
    }
    $self->_report_error("PAGI application failed on stream $stream_id: $error");
}

# The response has started, so a 500 is no longer possible. Reset the
# response stream so the client sees the failure now instead of waiting for
# its idle timeout, and so the stream can leave the table.
sub _abort_response {
    my ($self, $stream_id) = @_;
    my $stream = $self->{streams}{$stream_id} or return;
    return if $stream->{response_done} || $stream->{disconnected};
    $stream->{response_done} = 1;
    $self->_fail_response_writes($stream, 'HTTP/3 response was aborted');
    eval {
        $self->{connection}->shutdown_stream(
            $stream_id, direction => 'write', error_code => $H3_INTERNAL_ERROR,
        );
        1;
    } or $self->_report_error("Could not reset HTTP/3 stream $stream_id: $@");
    $self->_stop_reading($stream_id, $H3_INTERNAL_ERROR);
    $self->{on_write}->();
    return;
}

# Tell the client to stop sending a request body that no one will read.
sub _stop_reading {
    my ($self, $stream_id, $error_code) = @_;
    my $stream = $self->{streams}{$stream_id} or return;
    return if $stream->{request_done};
    $stream->{request_done} = 1;
    $stream->{body_paused} = 0;
    $stream->{queue} = [];
    $stream->{queued_bytes} = 0;
    eval {
        $self->{connection}->shutdown_stream(
            $stream_id, direction => 'read',
            error_code => $error_code // $H3_NO_ERROR,
        );
        1;
    } or $self->_report_error("Could not stop HTTP/3 stream $stream_id: $@");
    $self->{on_write}->();
    return;
}

sub _send_error_response {
    my ($self, $stream_id, $status, $body, $request_done) = @_;
    $self->{streams}{$stream_id} ||= {
        queue            => [],
        receive_waiter   => undef,
        request_done     => $request_done ? 1 : 0,
        response_started => 0,
        response_done    => 0,
        response_queue   => [],
        write_draining   => 0,
        disconnected     => 0,
        app_future       => undef,
        app_done         => 1,
        connection_state => PAGI::Server::HTTP3::ConnectionState->new(
            on_error => $self->{on_error},
        ),
        head_request     => 0,
        queued_bytes     => 0,
        body_paused      => 0,
    };
    my $weak_self = $self;
    weaken($weak_self);
    my $start = $self->_send_event($stream_id, {
        type => 'http.response.start',
        status => $status,
        headers => [
            ['content-type', 'text/plain'],
            ['content-length', length($body)],
        ],
    });
    $start->on_done(sub {
        return unless $weak_self;
        my $current = $weak_self->{streams}{$stream_id} or return;
        my $finish = $weak_self->_send_event($stream_id, {
            type => 'http.response.body', body => $body, more => 0,
        });
        $finish->on_fail(sub {
            $weak_self->_report_error($_[0]) if $weak_self;
        });
    });
    $start->on_fail(sub {
        $weak_self->_report_error($_[0]) if $weak_self;
    });
    return;
}

sub _scope_from_headers {
    my ($self, $headers) = @_;
    my (%pseudo, @regular, @cookies, $host);
    for my $header (@$headers) {
        my ($name, $value) = @$header;
        if (substr($name, 0, 1) eq ':') {
            croak "Duplicate HTTP/3 pseudo-header '$name'" if exists $pseudo{$name};
            $pseudo{$name} = $value;
        } elsif ($name eq 'cookie') {
            push @cookies, $value;
        } elsif ($name eq 'host') {
            $host //= $value;
        } else {
            push @regular, [$name, $value];
        }
    }
    for my $required (qw(:method :scheme :path)) {
        croak "Missing HTTP/3 pseudo-header '$required'" unless exists $pseudo{$required};
    }
    croak 'HTTP/3 request method must be uppercase'
        unless $pseudo{':method'} =~ /\A[A-Z]+\z/;
    croak 'HTTP/3 scheme must be http or https'
        unless $pseudo{':scheme'} eq 'http' || $pseudo{':scheme'} eq 'https';

    # RFC 9114 section 4.3.1: use :authority, or Host when it is absent.
    $host = $pseudo{':authority'} if exists $pseudo{':authority'};
    unshift @regular, ['host', $host] if defined $host;
    push @regular, ['cookie', join('; ', @cookies)] if @cookies;

    my ($raw_path, $query_string) = split /\?/, $pseudo{':path'}, 2;
    $query_string //= '';
    my $path_bytes = uri_unescape($raw_path);
    my $path = decode('UTF-8', $path_bytes, FB_CROAK);

    return {
        type          => 'http',
        pagi          => { version => '0.5', spec_version => '0.5' },
        http_version  => '3',
        method        => $pseudo{':method'},
        scheme        => $pseudo{':scheme'},
        path          => $path,
        raw_path      => $raw_path,
        query_string  => $query_string,
        root_path     => '',
        headers       => \@regular,
        client        => [@{$self->{client}}],
        server        => [@{$self->{server}}],
        extensions    => {},
    };
}

sub _maybe_finish {
    my ($self, $stream_id) = @_;
    my $stream = $self->{streams}{$stream_id} or return;
    # The response is complete and the application is gone, but the client
    # is still sending a body. Stop it (RFC 9114 section 4.1).
    $self->_stop_reading($stream_id)
        if $stream->{response_done} && $stream->{app_done}
            && !$stream->{request_done} && !$stream->{disconnected};
    $stream = $self->{streams}{$stream_id} or return;
    if ($stream->{disconnected} && $stream->{app_done}) {
        delete $self->{streams}{$stream_id};
        $self->{on_idle}->() unless keys %{$self->{streams}};
        return;
    }
    return unless $stream->{request_done} && $stream->{response_done}
        && $stream->{app_done};
    delete $self->{streams}{$stream_id};
    $self->{on_idle}->() unless keys %{$self->{streams}};
}

sub _report_error {
    my ($self, $error) = @_;
    $error =~ s/\s+\z//;
    $self->{on_error}->($error);
}

sub _boolean {
    my ($name, $value) = @_;
    croak "$name must be 0 or 1"
        if !defined($value) || ref($value) || $value !~ /\A[01]\z/;
    return 0 + $value;
}

sub _bytes {
    my ($name, $value) = @_;
    croak "$name must be a defined byte string"
        if !defined($value) || ref($value);
    my $bytes = $value;
    croak "$name must be a byte string" unless utf8::downgrade($bytes, 1);
    return $bytes;
}

sub _response_headers {
    my ($headers) = @_;
    croak 'headers must be an array reference' unless ref($headers) eq 'ARRAY';
    my @copy;
    for my $header (@{$headers}) {
        croak 'each header must be a [name, value] array reference'
            unless ref($header) eq 'ARRAY' && @{$header} == 2;
        my $name = _bytes('header name', $header->[0]);
        my $value = _bytes('header value', $header->[1]);
        croak 'header names must not be empty' unless length $name;
        croak "response header '$name' must not be a pseudo-header"
            if substr($name, 0, 1) eq ':';
        croak "header name '$name' must be lowercase" if $name =~ /[A-Z]/;
        croak 'header names and values must not contain CR, LF, or NUL'
            if $name =~ /[\r\n\0]/ || $value =~ /[\r\n\0]/;
        next if $name eq 'transfer-encoding';
        push @copy, [$name, $value];
    }
    return \@copy;
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

PAGI::Server::Protocol::HTTP3 - Bridge HTTP/3 request streams to PAGI

=head1 DESCRIPTION

One instance owns the PAGI stream table for one
L<Net::Quiche::Connection>. It translates HTTP/3 events into PAGI HTTP scopes
and Future-returning C<receive> and C<send> callbacks. UDP I/O remains the
listener's responsibility. A C<send> Future resolves only after quiche accepts
the complete event. If QUIC flow control blocks a response body, the stream
retains the unsent bytes and retries after later transport input. Applications
must await each C<send> Future; only one pending send is allowed per stream.
Request DATA is copied into byte-string C<http.request> events. The body is
read from quiche only while the stream has fewer than
C<max_request_body_buffer> bytes (default 1 MiB) of events the application has
not received, so a slow application applies QUIC flow control to the client.
When the application finishes its response without reading the rest of the
body, the protocol sends STOP_SENDING. When it fails or returns after
C<http.response.start> without completing the body, the response stream is
reset with H3_INTERNAL_ERROR. A final empty
event with C<< more =E<gt> 0 >> terminates a body after quiche reports
C<FINISHED>. Each HTTP scope includes a per-request
L<PAGI::Server::HTTP3::ConnectionState> object.
C<next_request_stream_id> returns the first request stream identifier after
the greatest identifier accepted by this connection. The listener uses it for
the final decreasing GOAWAY during bounded shutdown.
