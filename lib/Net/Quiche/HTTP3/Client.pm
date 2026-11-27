package Net::Quiche::HTTP3::Client;

use strict;
use warnings;
use Carp qw(croak);
use Future ();
use IO::Async::Socket ();
use IO::Async::Stream ();
use IO::Async::Timer::Countdown ();
use Scalar::Util qw(blessed looks_like_number weaken);
use Time::HiRes qw(time);
use Socket qw(
    AF_INET AF_INET6
    SOCK_DGRAM SOCK_STREAM getaddrinfo inet_ntop
    sockaddr_family
    unpack_sockaddr_in unpack_sockaddr_in6
);
use URI ();
use parent 'IO::Async::Notifier';

use Net::Quiche::Connection ();
use Net::Quiche::HTTP3::Exchange ();
use Net::Quiche::HTTP3::Proxy::SOCKS5 ();
use Net::Quiche::HTTP3::Response ();

our $VERSION = '0.013';

use constant LOCAL_CONNECTION_ID_LENGTH => 16;
use constant H3_NO_ERROR => 0x100;
use constant H3_REQUEST_CANCELLED => 0x10c;

sub _init {
    my ($self, $params) = @_;
    $self->{config} = delete $params->{config};
    $self->{max_response_body} =
        delete($params->{max_response_body}) // 16 * 1024 * 1024;
    $self->{response_buffer_limit} =
        delete($params->{response_buffer_limit}) // 1024 * 1024;
    $self->{max_redirects} = delete($params->{max_redirects}) // 0;
    $self->{request_timeout} = delete $params->{request_timeout};
    my $proxy = delete $params->{proxy};
    $self->{proxy} = defined($proxy)
        ? Net::Quiche::HTTP3::Proxy::SOCKS5->new($proxy) : undef;

    croak 'config must be a Net::Quiche::Config object'
        unless blessed($self->{config})
            && $self->{config}->isa('Net::Quiche::Config');
    _positive_integer('max_response_body', $self->{max_response_body});
    _positive_integer('response_buffer_limit', $self->{response_buffer_limit});
    _nonnegative_integer('max_redirects', $self->{max_redirects});
    _positive_number('request_timeout', $self->{request_timeout})
        if defined $self->{request_timeout};
    $self->{origins} = {};
    $self->{retired_origins} = {};
    $self->{next_origin_id} = 0;
    $self->{stopped} = 0;
    $self->SUPER::_init($params);
}

sub get {
    my ($self, $uri, @arguments) = @_;
    croak 'get() requires a URI' unless defined $uri;
    my %options = _options('get', @arguments);
    _unknown('get', \%options,
        { headers => 1, max_redirects => 1, timeout => 1 });
    return $self->request(
        method => 'GET', uri => $uri,
        headers => $options{headers} // [], body => '',
        (exists($options{max_redirects})
            ? (max_redirects => $options{max_redirects}) : ()),
        (exists($options{timeout}) ? (timeout => $options{timeout}) : ()),
    );
}

sub post {
    my ($self, $uri, @arguments) = @_;
    croak 'post() requires a URI' unless defined $uri;
    my %options = _options('post', @arguments);
    _unknown('post', \%options,
        { headers => 1, body => 1, max_redirects => 1, timeout => 1 });
    return $self->request(
        method => 'POST', uri => $uri,
        headers => $options{headers} // [],
        body => exists($options{body}) ? $options{body} : '',
        (exists($options{max_redirects})
            ? (max_redirects => $options{max_redirects}) : ()),
        (exists($options{timeout}) ? (timeout => $options{timeout}) : ()),
    );
}

sub request {
    my ($self, @arguments) = @_;
    my %options = _options('request', @arguments);
    _unknown('request', \%options,
        { method => 1, uri => 1, headers => 1, body => 1,
          max_redirects => 1, timeout => 1 });
    croak 'request() requires method and uri'
        unless exists($options{method}) && exists($options{uri});
    croak 'uri must be a defined scalar'
        if !defined($options{uri}) || ref($options{uri});
    my $body = _bytes('request body',
        exists($options{body}) ? $options{body} : '');
    my $maximum = exists($options{max_redirects})
        ? _nonnegative_integer('max_redirects', $options{max_redirects})
        : $self->{max_redirects};
    my $timeout = exists($options{timeout})
        ? _positive_number('timeout', $options{timeout})
        : $self->{request_timeout};
    my $headers = $options{headers} // [];
    croak 'headers must be an array reference' unless ref($headers) eq 'ARRAY';
    $headers = [map {
        croak 'each header must be a [name, value] array reference'
            unless ref($_) eq 'ARRAY' && @{$_} == 2;
        [@{$_}]
    } @{$headers}];
    my $context = {};
    my $operation = $self->_request_redirects({
        method => $options{method}, uri => "$options{uri}",
        headers => $headers, body => $body,
        maximum => $maximum, count => 0, history => [],
        context => $context,
        (defined($timeout) ? (
            deadline => time() + $timeout,
            timeout_label => $timeout,
        ) : ()),
    });
    my $result = Future->new;
    $context->{operation} = $operation;
    $result->on_cancel(sub {
        my $exchange = $context->{active_exchange};
        $exchange->cancel if $exchange;
    });
    $operation->on_done(sub {
        $result->done(@_) unless $result->is_ready;
    });
    $operation->on_fail(sub {
        $result->fail(@_) unless $result->is_ready;
    });
    $operation->on_ready(sub {
        delete $context->{operation};
        delete $context->{active_exchange};
    });
    return $result;
}

sub _request_redirects {
    my ($self, $request) = @_;
    my $remaining;
    if (defined $request->{deadline}) {
        $remaining = $request->{deadline} - time();
        return Future->fail(_timeout_error($request->{timeout_label}))
            if $remaining <= 0;
    }
    my $exchange = $self->_start_request({
        method => $request->{method},
        uri => $request->{uri},
        headers => $request->{headers},
        (defined($remaining) ? (timeout => $remaining) : ()),
    }, defined($remaining) ? _timeout_error($request->{timeout_label}) : undef);
    $request->{context}{active_exchange} = $exchange;
    my $sent = length($request->{body})
        ? $exchange->write($request->{body})->then(sub {
            return $exchange->finish_request;
        })
        : $exchange->finish_request;
    my $received = $exchange->response->then(sub {
        my ($response) = @_;
        return $response->slurp(
            max_bytes => $self->{max_response_body},
        )->then_done($response);
    });
    # When either side fails (for example the body exceeds
    # max_response_body), stop the stream instead of downloading the rest.
    return Future->needs_all($sent, $received)->on_fail(sub {
        $exchange->cancel;
    })->then(sub {
        my @results = @_;
        my $response = $results[-1];
        $response->_set_effective_uri($request->{uri});
        $response->_set_redirect_history($request->{history});
        my $location = $response->header('location');
        return Future->done($response)
            unless defined($location) && _redirect_status($response->status)
                && $request->{maximum} > 0;
        return Future->fail(
            "HTTP/3 redirect exceeded $request->{maximum} redirects")
            if $request->{count} >= $request->{maximum};

        my $next_uri = eval {
            my $absolute = URI->new_abs($location, $request->{uri});
            $absolute->fragment(undef);
            "$absolute";
        };
        return Future->fail($@ || "Invalid HTTP redirect Location '$location'")
            unless defined($next_uri) && length($next_uri);

        my ($method, $body) = @{$request}{qw(method body)};
        my $rewrite = ($response->status == 303 && $method ne 'HEAD')
            || (($response->status == 301 || $response->status == 302)
                && $method eq 'POST');
        if ($rewrite) {
            $method = 'GET';
            $body = '';
        }
        my $cross_origin = !_same_origin($request->{uri}, $next_uri);
        my %remove = (host => 1);
        @remove{qw(content-encoding content-language content-length
            content-location content-type digest)} = (1) x 7 if $rewrite;
        @remove{qw(authorization cookie proxy-authorization)} = (1) x 3
            if $cross_origin;
        my @headers = map { [@{$_}] }
            grep { !$remove{lc $_->[0]} } @{$request->{headers}};
        my @history = (
            @{$request->{history}},
            {
                status => $response->status,
                uri => $request->{uri},
                location => $location,
            },
        );
        return $self->_request_redirects({
            method => $method, uri => $next_uri, headers => \@headers,
            body => $body, maximum => $request->{maximum},
            count => $request->{count} + 1, history => \@history,
            context => $request->{context},
            (defined($request->{deadline}) ? (
                deadline => $request->{deadline},
                timeout_label => $request->{timeout_label},
            ) : ()),
        });
    });
}

sub start_request {
    my ($self, @arguments) = @_;
    croak 'HTTP/3 client has been stopped' if $self->{stopped};
    croak 'HTTP/3 client must be added to an IO::Async loop before use'
        unless $self->loop;
    my %options = _options('start_request', @arguments);
    _unknown('start_request', \%options,
        { method => 1, uri => 1, headers => 1, timeout => 1 });
    return $self->_start_request(\%options);
}

sub _start_request {
    my ($self, $options, $timeout_error) = @_;
    croak 'HTTP/3 client has been stopped' if $self->{stopped};
    croak 'HTTP/3 client must be added to an IO::Async loop before use'
        unless $self->loop;
    croak 'start_request() requires method and uri'
        unless exists($options->{method}) && exists($options->{uri});
    my $timeout = exists($options->{timeout})
        ? _positive_number('timeout', $options->{timeout})
        : $self->{request_timeout};
    my $request = _request(
        $options->{method}, $options->{uri}, $options->{headers} // []);

    my $state = $self->{origins}{$request->{origin_key}};
    if (!$state || $state->{status} eq 'failed') {
        $state = $self->{origins}{$request->{origin_key}}
            = $self->_new_origin($request);
    }
    croak 'origin is not accepting new HTTP/3 requests' if $state->{goaway};
    my $exchange = Net::Quiche::HTTP3::Exchange->_new(
        client => $self,
        state => $state,
        origin_key => $request->{origin_key},
        headers => $request->{headers},
    );
    push @{$state->{pending}}, $exchange;
    $self->_arm_exchange_timeout(
        $exchange, $timeout, $timeout_error || _timeout_error($timeout))
        if defined $timeout;
    $self->_start_origin($state) if $state->{status} eq 'new';
    $self->_flush_state($state) if $state->{h3};
    return $exchange;
}

sub stop {
    croak 'stop() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    return if $self->{stopped};
    $self->{stopped} = 1;
    my @states = (
        values(%{$self->{origins}}),
        values(%{$self->{retired_origins}}),
    );
    $self->_fail_origin($_, 'HTTP/3 client stopped') for @states;
    $self->{origins} = {};
    $self->{retired_origins} = {};
    return;
}

sub connection_count {
    croak 'connection_count() takes no arguments' unless @_ == 1;
    return scalar(keys %{$_[0]{origins}})
        + scalar(keys %{$_[0]{retired_origins}});
}

sub active_requests {
    croak 'active_requests() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    my $count = 0;
    for my $state (
        values(%{$self->{origins}}),
        values(%{$self->{retired_origins}}),
    ) {
        $count += @{$state->{pending}};
        $count += scalar keys %{$state->{exchanges}};
    }
    return $count;
}

sub _new_origin {
    my ($self, $request) = @_;
    my $state = {
        id => ++$self->{next_origin_id},
        key => $request->{origin_key},
        host => $request->{host},
        port => $request->{port},
        socket => undef,
        connection => undef,
        h3 => undef,
        timer => undef,
        pending => [],
        exchanges => {},
        cancelled_streams => {},
        buffered_bytes => 0,
        status => 'new',
        goaway => 0,
        goaway_id => undef,
        retired => 0,
        flushing => 0,
        proxy => $self->{proxy},
        proxy_target => undef,
        proxy_control => undef,
    };
    return $state;
}

sub _start_origin {
    my ($self, $state) = @_;
    return $self->_start_origin_via_socks5($state) if $state->{proxy};
    $state->{status} = 'resolving';
    my ($resolve_error, @addresses) = getaddrinfo(
        $state->{host}, $state->{port}, { socktype => SOCK_DGRAM },
    );
    if ($resolve_error || !@addresses) {
        $self->_fail_origin(
            $state,
            'DNS resolution failed for ' . $state->{host} . ': '
                . ($resolve_error || 'no addresses'),
        );
        return;
    }

    my $weak_self = $self;
    weaken($weak_self);
    my $socket = $self->_new_udp_socket($state);
    $state->{socket} = $socket;
    $self->add_child($socket);
    $state->{status} = 'connecting';
    my $connect = $socket->connect(addrs => \@addresses);
    $state->{connect_future} = $connect;
    $connect->on_done(sub {
        return unless $weak_self && $state->{status} eq 'connecting';
        my $handle = $socket->read_handle;
        my $peer = eval { _unpack_address(getpeername($handle)) };
        if (!$peer) {
            $weak_self->_fail_origin(
                $state, $@ || 'Could not inspect connected UDP socket');
            return;
        }
        $weak_self->_activate_quic($state, $socket, $peer);
    });
    $connect->on_fail(sub {
        $weak_self->_fail_origin($state, "UDP connect failed: $_[0]")
            if $weak_self;
    });
    return;
}

sub _start_origin_via_socks5 {
    my ($self, $state) = @_;
    my $proxy = $state->{proxy};
    $state->{status} = 'resolving';

    my @origin_addresses;
    if (!$proxy->remote_dns) {
        my ($origin_error, @resolved) = getaddrinfo(
            $state->{host}, $state->{port}, { socktype => SOCK_DGRAM },
        );
        if ($origin_error || !@resolved) {
            $self->_fail_origin(
                $state,
                'DNS resolution failed for ' . $state->{host} . ': '
                    . ($origin_error || 'no addresses'),
            );
            return;
        }
        @origin_addresses = @resolved;
    }
    my $target = eval {
        $proxy->target($state->{host}, $state->{port}, \@origin_addresses);
    };
    if (!$target) {
        $self->_fail_origin($state, $@ || 'Could not encode SOCKS5 target');
        return;
    }
    $state->{proxy_target} = $target;

    my ($proxy_error, @proxy_addresses) = getaddrinfo(
        $proxy->host, $proxy->port, { socktype => SOCK_STREAM },
    );
    if ($proxy_error || !@proxy_addresses) {
        $self->_fail_origin(
            $state,
            'DNS resolution failed for SOCKS5 proxy ' . $proxy->host . ': '
                . ($proxy_error || 'no addresses'),
        );
        return;
    }

    my $weak_self = $self;
    weaken($weak_self);
    my $control = IO::Async::Stream->new(
        autoflush => 1,
        on_read => sub { return 0 },
        on_read_eof => sub {
            $weak_self->_fail_origin(
                $state, 'SOCKS5 UDP association control connection closed')
                if $weak_self && $state->{status} ne 'failed';
        },
        on_read_error => sub {
            $weak_self->_fail_origin($state, "SOCKS5 control read failed: $_[1]")
                if $weak_self;
        },
        on_write_error => sub {
            $weak_self->_fail_origin($state, "SOCKS5 control write failed: $_[1]")
                if $weak_self;
        },
    );
    $state->{proxy_control} = $control;
    $self->add_child($control);
    $state->{status} = 'proxy_connecting';
    my $connect = $control->connect(addrs => \@proxy_addresses);
    $state->{proxy_connect_future} = $connect;
    $connect->on_done(sub {
        return unless $weak_self && $state->{status} eq 'proxy_connecting';
        my $peer = eval {
            _unpack_address(getpeername($control->read_handle));
        };
        if (!$peer) {
            $weak_self->_fail_origin(
                $state, $@ || 'Could not inspect SOCKS5 control connection');
            return;
        }
        $state->{proxy_control_peer} = $peer;
        $state->{status} = 'proxy_negotiating';
        my $negotiation = $proxy->negotiate_udp_associate($control);
        $state->{proxy_negotiation_future} = $negotiation;
        $negotiation->on_done(sub {
            my ($relay) = @_;
            return unless $weak_self
                && $state->{status} eq 'proxy_negotiating';
            $control->configure(on_read => sub {
                my (undef, $buffer) = @_;
                return 0 unless length($$buffer);
                $$buffer = '';
                $weak_self->_fail_origin(
                    $state, 'SOCKS5 control connection sent unexpected data')
                    if $weak_self;
                return 0;
            });
            $relay->[0] = $peer->[0]
                if $relay->[0] eq '0.0.0.0' || $relay->[0] eq '::';
            $weak_self->_connect_socks5_relay($state, $relay);
        });
        $negotiation->on_fail(sub {
            $weak_self->_fail_origin($state, "SOCKS5 negotiation failed: $_[0]")
                if $weak_self;
        });
    });
    $connect->on_fail(sub {
        $weak_self->_fail_origin($state, "SOCKS5 TCP connect failed: $_[0]")
            if $weak_self;
    });
    return;
}

sub _connect_socks5_relay {
    my ($self, $state, $relay) = @_;
    $state->{status} = 'proxy_relay_resolving';
    my ($relay_error, @relay_addresses) = getaddrinfo(
        $relay->[0], $relay->[1], { socktype => SOCK_DGRAM },
    );
    if ($relay_error || !@relay_addresses) {
        $self->_fail_origin(
            $state,
            'DNS resolution failed for SOCKS5 UDP relay ' . $relay->[0] . ': '
                . ($relay_error || 'no addresses'),
        );
        return;
    }
    my $weak_self = $self;
    weaken($weak_self);
    my $socket = $self->_new_udp_socket($state);
    $state->{socket} = $socket;
    $self->add_child($socket);
    $state->{status} = 'connecting';
    my $connect = $socket->connect(addrs => \@relay_addresses);
    $state->{connect_future} = $connect;
    $connect->on_done(sub {
        return unless $weak_self && $state->{status} eq 'connecting';
        my $peer = $state->{proxy_target}{logical_peer}
            || [$state->{proxy_control_peer}[0], $state->{port}];
        $weak_self->_activate_quic($state, $socket, $peer);
    });
    $connect->on_fail(sub {
        $weak_self->_fail_origin($state, "SOCKS5 UDP relay connect failed: $_[0]")
            if $weak_self;
    });
    return;
}

sub _new_udp_socket {
    my ($self, $state) = @_;
    my $weak_self = $self;
    weaken($weak_self);
    return IO::Async::Socket->new(
        recv_len => 65_535,
        recv_all => 1,
        autoflush => 1,
        on_recv => sub {
            my (undef, $data, $peer_address) = @_;
            $weak_self->_receive_datagram($state, $data, $peer_address)
                if $weak_self;
        },
        on_recv_error => sub {
            $weak_self->_fail_origin($state, "UDP receive failed: $_[1]")
                if $weak_self;
        },
        on_send_error => sub {
            $weak_self->_fail_origin($state, "UDP send failed: $_[1]")
                if $weak_self;
        },
    );
}

sub _activate_quic {
    my ($self, $state, $socket, $peer) = @_;
    my $local = eval { _unpack_address(getsockname($socket->read_handle)) };
    if (!$local) {
        $self->_fail_origin(
            $state, $@ || 'Could not inspect connected UDP socket');
        return;
    }
    my $connection = eval {
        Net::Quiche::Connection->connect(
            config => $self->{config},
            server_name => $state->{host},
            source_connection_id => _random_connection_id(),
            local => $local,
            peer => $peer,
        );
    };
    if (!$connection) {
        $self->_fail_origin(
            $state, $@ || 'Could not create QUIC client connection');
        return;
    }
    $state->{connection} = $connection;
    $state->{local} = $local;
    $state->{peer} = $peer;
    $state->{status} = 'handshaking';
    my $weak_self = $self;
    weaken($weak_self);
    my $timer = IO::Async::Timer::Countdown->new(
        delay => 0,
        on_expire => sub {
            return unless $weak_self && $state->{connection};
            $state->{connection}->on_timeout;
            $weak_self->_flush_state($state);
        },
    );
    $state->{timer} = $timer;
    $self->add_child($timer);
    $self->_flush_state($state);
    return;
}

sub _receive_datagram {
    my ($self, $state, $data, $peer_address) = @_;
    return unless $state->{connection} && $state->{status} ne 'failed';
    my $ok = eval {
        if ($state->{proxy}) {
            $data = $state->{proxy}->unwrap_datagram($data);
        }
        my $peer = $state->{proxy} ? $state->{peer} : defined($peer_address)
            ? _unpack_address($peer_address) : $state->{peer};
        $state->{connection}->receive_datagram(
            $data, from => $peer, to => $state->{local},
        );
        1;
    };
    if (!$ok) {
        $self->_fail_origin($state, $@ || 'Failed to receive QUIC datagram');
        return;
    }
    $self->_flush_state($state);
}

sub _flush_state {
    my ($self, $state) = @_;
    return if $state->{status} eq 'failed' || $state->{flushing};
    return unless $state->{connection};
    $state->{flushing} = 1;
    my $ok = eval {
        if ($state->{connection}->is_established && !$state->{h3}) {
            $state->{h3} = $state->{connection}->http3;
            $state->{status} = 'ready';
        }
        if ($state->{h3}) {
            $self->_drain_request_writes($state);
            $self->_drain_response_events($state);
            $self->_drain_request_writes($state);
        }
        while (my $datagram = $state->{connection}->next_datagram) {
            my $data = $state->{proxy}
                ? $state->{proxy}->wrap_datagram(
                    $state->{proxy_target}, $datagram->{data})
                : $datagram->{data};
            $state->{socket}->send($data);
        }
        1;
    };
    $state->{flushing} = 0;
    if (!$ok) {
        $self->_fail_origin($state, $@ || 'HTTP/3 client processing failed');
        return;
    }
    if ($state->{connection}->is_closed) {
        $self->_fail_origin($state, _closed_error($state->{connection}));
        return;
    }
    $self->_arm_timer($state);
    return;
}

sub _drain_request_writes {
    my ($self, $state) = @_;
    my $h3 = $state->{h3};
    while (@{$state->{pending}}) {
        my $exchange = $state->{pending}[0];
        my $stream_id = $h3->send_request(
            headers => $exchange->{headers},
            final => $exchange->_header_final,
        );
        last unless defined $stream_id;
        shift @{$state->{pending}};
        $state->{exchanges}{$stream_id} = $exchange;
        $exchange->_header_sent($stream_id);
        $self->_cleanup_exchange($state, $exchange);
    }

    for my $stream_id (sort { $a <=> $b } keys %{$state->{exchanges}}) {
        my $exchange = $state->{exchanges}{$stream_id};
        while (my $operation = $exchange->_next_write) {
            my $remaining = substr($operation->{body}, $operation->{offset});
            my $written = eval {
                $h3->send_body(
                    $stream_id, $remaining, final => $operation->{final},
                );
            };
            if (my $error = $@) {
                die $error unless Net::Quiche::HTTP3::_is_stream_error($error);
                # The server sent STOP_SENDING, usually after an early
                # response (RFC 9114 section 4.1). The upload is over, but
                # the response is still valid and the connection is fine.
                $exchange->_request_stopped;
                $self->_cleanup_exchange($state, $exchange);
                last;
            }
            last unless defined $written;
            croak 'quiche accepted more request bytes than supplied'
                if $written > length($remaining);
            $operation->{offset} += $written;
            last if $operation->{offset} < length($operation->{body});
            $exchange->_write_complete;
            $self->_cleanup_exchange($state, $exchange);
        }
    }
    return;
}

sub _drain_response_events {
    my ($self, $state) = @_;
    while ($state->{buffered_bytes} < $self->{response_buffer_limit}) {
        my $event = $state->{h3}->poll or last;
        my $type = $event->{type};
        my $stream_id = $event->{stream_id};
        if (defined($stream_id) && $state->{cancelled_streams}{$stream_id}) {
            delete $state->{cancelled_streams}{$stream_id}
                if $type eq 'finished' || $type eq 'reset';
            next;
        }
        if ($type eq 'headers') {
            $self->_response_headers($state, $event);
        } elsif ($type eq 'data') {
            $self->_response_data($state, $event);
        } elsif ($type eq 'finished') {
            $self->_response_finished($state, $event->{stream_id});
        } elsif ($type eq 'reset') {
            $self->_reset_exchange($state, $event->{stream_id});
        } elsif ($type eq 'goaway') {
            $self->_receive_goaway($state, $event->{id});
            last if $state->{status} eq 'failed';
        }
    }
    return;
}

sub _response_headers {
    my ($self, $state, $event) = @_;
    my $stream_id = $event->{stream_id};
    my $exchange = $state->{exchanges}{$stream_id}
        or croak "response headers arrived for unknown stream $stream_id";
    # A second HEADERS frame after the final response carries trailers.
    # They are not exposed yet, so skip them rather than failing the
    # request, which already has its status and body.
    return if $exchange->{response};
    my ($status, @headers, $error);
    for my $header (@{$event->{headers}}) {
        my ($name, $value) = @{$header};
        if ($name eq ':status') {
            $error = "duplicate :status on HTTP/3 stream $stream_id"
                if defined $status;
            $error = "invalid :status on HTTP/3 stream $stream_id"
                unless $value =~ /\A[1-5][0-9]{2}\z/;
            $status = 0 + $value if $value =~ /\A[0-9]+\z/;
        } elsif (substr($name, 0, 1) eq ':') {
            $error = "unexpected response pseudo-header '$name'";
        } else {
            push @headers, [$name, $value];
        }
        last if defined $error;
    }
    $error = "missing :status on HTTP/3 stream $stream_id"
        unless defined($error) || defined($status);
    if (defined $error) {
        # A malformed response is a problem with this stream only.
        $self->_cancel_exchange($exchange, $error);
        return;
    }
    # 1xx responses such as 100 Continue and 103 Early Hints are interim.
    # The final response follows on the same stream.
    return if $status < 200;
    my $weak_self = $self;
    weaken($weak_self);
    my $weak_state = $state;
    weaken($weak_state);
    my $response = Net::Quiche::HTTP3::Response->_new(
        status => $status,
        headers => \@headers,
        on_consume => sub {
            $weak_self->_response_consumed($weak_state, $_[0])
                if $weak_self && $weak_state;
        },
    );
    $exchange->_set_response($response);
    return;
}

sub _response_data {
    my ($self, $state, $event) = @_;
    my $stream_id = $event->{stream_id};
    my $exchange = $state->{exchanges}{$stream_id}
        or croak "response body arrived for unknown stream $stream_id";
    if (!$exchange->{response}) {
        $self->_cancel_exchange($exchange,
            "response body arrived before headers on stream $stream_id");
        return;
    }
    $state->{buffered_bytes} += length $event->{body};
    $exchange->{response}->_push_body($event->{body});
    return;
}

sub _response_finished {
    my ($self, $state, $stream_id) = @_;
    my $exchange = $state->{exchanges}{$stream_id}
        or croak "response FINISHED arrived for unknown stream $stream_id";
    if (!$exchange->{response}) {
        $self->_cancel_exchange($exchange,
            "response FINISHED arrived before headers on stream $stream_id");
        return;
    }
    $exchange->{response}->_finish;
    $exchange->_response_finished;
    $self->_cleanup_exchange($state, $exchange);
    return;
}

sub _response_consumed {
    my ($self, $state, $length) = @_;
    return if !$state || $state->{status} eq 'failed';
    $state->{buffered_bytes} -= $length;
    $state->{buffered_bytes} = 0 if $state->{buffered_bytes} < 0;
    $self->_flush_state($state);
    return;
}

sub _exchange_updated {
    my ($self, $exchange) = @_;
    my $state = $exchange->{state} or return;
    $self->_flush_state($state);
    return;
}

sub _cleanup_exchange {
    my ($self, $state, $exchange) = @_;
    return unless $exchange->_is_done;
    $self->_disarm_exchange_timeout($exchange);
    delete $state->{exchanges}{$exchange->{stream_id}};
    delete $exchange->{client};
    $self->_finish_retired_origin($state);
    return;
}

sub _reset_exchange {
    my ($self, $state, $stream_id) = @_;
    my $exchange = $state->{exchanges}{$stream_id} or return;
    $self->_fail_exchange($state, $exchange, 'HTTP/3 request stream was reset');
    return;
}

sub _fail_exchange {
    my ($self, $state, $exchange, $error) = @_;
    @{$state->{pending}} = grep { $_ != $exchange } @{$state->{pending}};
    delete $state->{exchanges}{$exchange->{stream_id}}
        if defined $exchange->{stream_id};
    $self->_disarm_exchange_timeout($exchange);
    $exchange->_fail($error);
    delete $exchange->{client};
    $self->_finish_retired_origin($state);
    return;
}

sub _fail_pending {
    my ($self, $state, $error) = @_;
    for my $exchange (splice @{$state->{pending}}) {
        next unless $exchange;
        $self->_disarm_exchange_timeout($exchange);
        $exchange->_fail($error);
        delete $exchange->{client};
    }
    return;
}

sub _fail_origin {
    my ($self, $state, $error) = @_;
    return if $state->{status} eq 'failed';
    $state->{status} = 'failed';
    # Unregister before failing any Future, so a retry started from a
    # failure callback opens a new connection instead of joining this one.
    delete $self->{origins}{$state->{key}}
        if $self->{origins}{$state->{key}}
            && $self->{origins}{$state->{key}} == $state;
    delete $self->{retired_origins}{$state->{id}}
        if $self->{retired_origins}{$state->{id}}
            && $self->{retired_origins}{$state->{id}} == $state;
    $self->_close_connection($state);
    $self->_fail_pending($state, $error);
    for my $exchange (values %{$state->{exchanges}}) {
        next unless $exchange;
        $self->_disarm_exchange_timeout($exchange);
        $exchange->_fail($error);
        delete $exchange->{client};
    }
    $state->{exchanges} = {};
    if (my $timer = delete $state->{timer}) {
        $timer->stop if $timer->is_running && $timer->loop;
        $self->remove_child($timer) if $timer->parent;
    }
    if (my $socket = delete $state->{socket}) {
        $self->remove_child($socket) if $socket->parent;
        $socket->close;
    }
    if (my $control = delete $state->{proxy_control}) {
        $self->remove_child($control) if $control->parent;
        $control->close_now;
    }
    delete $state->{h3};
    delete $state->{connection};
    return;
}

# Tell the server the connection is going away, so it can free its state
# now instead of waiting for the idle timeout.
sub _close_connection {
    my ($self, $state) = @_;
    my $connection = $state->{connection} or return;
    my $socket = $state->{socket} or return;
    eval {
        return 1 if $connection->is_closed;
        $connection->close(
            application => 1, error_code => H3_NO_ERROR, reason => '',
        );
        while (my $datagram = $connection->next_datagram) {
            my $data = $state->{proxy}
                ? $state->{proxy}->wrap_datagram(
                    $state->{proxy_target}, $datagram->{data})
                : $datagram->{data};
            $socket->send($data);
        }
        1;
    };
    return;
}

sub _receive_goaway {
    my ($self, $state, $id) = @_;
    $state->{goaway} = 1;
    $state->{goaway_id} = $id;
    $self->_retire_origin($state);

    $self->_fail_pending(
        $state, 'HTTP/3 peer sent GOAWAY before opening the request stream');
    for my $stream_id (sort { $a <=> $b } keys %{$state->{exchanges}}) {
        next if $stream_id < $id;
        my $exchange = $state->{exchanges}{$stream_id} or next;
        $self->_cancel_exchange(
            $exchange,
            "HTTP/3 peer GOAWAY did not accept request stream $stream_id",
        );
    }
    $self->_finish_retired_origin($state);
    return;
}

sub _retire_origin {
    my ($self, $state) = @_;
    return if $state->{retired};
    delete $self->{origins}{$state->{key}}
        if $self->{origins}{$state->{key}}
            && $self->{origins}{$state->{key}} == $state;
    $state->{retired} = 1;
    $self->{retired_origins}{$state->{id}} = $state;
    return;
}

sub _finish_retired_origin {
    my ($self, $state) = @_;
    return unless $state->{retired} && $state->{status} ne 'failed';
    return if @{$state->{pending}} || keys %{$state->{exchanges}};
    $self->_fail_origin($state, 'HTTP/3 GOAWAY connection retired');
    return;
}

sub _arm_exchange_timeout {
    my ($self, $exchange, $timeout, $error) = @_;
    my $weak_self = $self;
    my $weak_exchange = $exchange;
    weaken($weak_self);
    weaken($weak_exchange);
    my $timer = IO::Async::Timer::Countdown->new(
        delay => $timeout,
        on_expire => sub {
            $weak_self->_cancel_exchange($weak_exchange, $error)
                if $weak_self && $weak_exchange;
        },
    );
    $exchange->{timeout_timer} = $timer;
    $self->add_child($timer);
    $timer->start;
    return;
}

sub _disarm_exchange_timeout {
    my ($self, $exchange) = @_;
    my $timer = delete $exchange->{timeout_timer} or return;
    $timer->stop if $timer->is_running && $timer->loop;
    $self->remove_child($timer) if $timer->parent;
    return;
}

sub _cancel_exchange {
    my ($self, $exchange, $error) = @_;
    my $state = $exchange->{state} or return 0;
    my $stream_id = $exchange->{stream_id};
    my $active = defined($stream_id)
        ? $state->{exchanges}{$stream_id}
            && $state->{exchanges}{$stream_id} == $exchange
        : scalar grep { defined($_) && $_ == $exchange } @{$state->{pending}};
    return 0 unless $active;

    my $shutdown_error;
    if (defined($stream_id) && $state->{connection}) {
        $state->{cancelled_streams}{$stream_id} = 1;
        $state->{h3}->_forget_stream($stream_id) if $state->{h3};
        eval {
            $state->{connection}->shutdown_stream(
                $stream_id, direction => 'read',
                error_code => H3_REQUEST_CANCELLED,
            );
            $state->{connection}->shutdown_stream(
                $stream_id, direction => 'write',
                error_code => H3_REQUEST_CANCELLED,
            );
            1;
        } or $shutdown_error = $@ || 'QUIC stream shutdown failed';
    }
    $self->_fail_exchange($state, $exchange, $error);
    if ($shutdown_error) {
        $self->_fail_origin(
            $state, "Could not cancel HTTP/3 request stream: $shutdown_error");
    } elsif (defined $stream_id) {
        $self->_flush_state($state);
    } elsif ($state->{status} ne 'ready'
            && !@{$state->{pending}} && !keys %{$state->{exchanges}}) {
        $self->_fail_origin($state, $error);
    }
    return 1;
}

sub _arm_timer {
    my ($self, $state) = @_;
    my $timer = $state->{timer} or return;
    $timer->stop if $timer->is_running && $timer->loop;
    my $milliseconds = $state->{connection}->timeout_ms;
    return unless defined $milliseconds;
    $timer->configure(delay => $milliseconds / 1_000);
    $timer->start;
    return;
}

sub _request {
    my ($method, $uri_input, $headers_input) = @_;
    croak 'method must be an uppercase HTTP token'
        if !defined($method) || ref($method)
            || $method !~ /\A[A-Z][A-Z0-9!#\$%&'*+.^_`|~-]*\z/;
    croak 'uri must be a defined scalar'
        if !defined($uri_input) || ref($uri_input);
    my $uri = URI->new("$uri_input");
    croak 'HTTP/3 client only supports https URIs'
        unless defined($uri->scheme) && lc($uri->scheme) eq 'https';
    croak 'HTTP/3 URI must include a host' unless defined $uri->host;
    croak 'HTTP/3 URI must not include userinfo'
        if defined($uri->userinfo) && length($uri->userinfo);
    croak 'HTTP/3 URI must not include a fragment'
        if defined($uri->fragment) && length($uri->fragment);

    my $host = $uri->host;
    my $port = $uri->port;
    my $authority = $uri->authority;
    my $path = $uri->path;
    $path = '/' unless defined($path) && length($path);
    $path .= '?' . $uri->query if defined $uri->query;
    $path = _bytes('request path', $path);
    $authority = _bytes('request authority', $authority);

    my $headers = _request_headers($headers_input, \$authority);
    return {
        host => $host,
        port => $port,
        origin_key => join("\0", lc($host), $port),
        headers => [
            [':method', "$method"],
            [':scheme', 'https'],
            [':authority', $authority],
            [':path', $path],
            @{$headers},
        ],
    };
}

sub _request_headers {
    my ($input, $authority) = @_;
    croak 'headers must be an array reference' unless ref($input) eq 'ARRAY';
    my @headers;
    my %forbidden = map { $_ => 1 } qw(
        connection keep-alive proxy-connection transfer-encoding upgrade
    );
    for my $header (@{$input}) {
        croak 'each header must be a [name, value] array reference'
            unless ref($header) eq 'ARRAY' && @{$header} == 2;
        my $name = _bytes('header name', $header->[0]);
        my $value = _bytes('header value', $header->[1]);
        croak 'header names must not be empty' unless length $name;
        croak "request header '$name' must not be a pseudo-header"
            if substr($name, 0, 1) eq ':';
        croak "header name '$name' must be lowercase" if $name =~ /[A-Z]/;
        croak 'header names and values must not contain CR, LF, or NUL'
            if $name =~ /[\r\n\0]/ || $value =~ /[\r\n\0]/;
        croak "HTTP/3 request header '$name' is connection-specific"
            if $forbidden{$name};
        croak 'proxy-authorization is not a supported origin request header'
            if $name eq 'proxy-authorization';
        croak "HTTP/3 te request header may only contain 'trailers'"
            if $name eq 'te' && $value ne 'trailers';
        if ($name eq 'host') {
            $$authority = $value;
            next;
        }
        push @headers, [$name, $value];
    }
    return \@headers;
}

sub _random_connection_id {
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
    return $id;
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
    croak 'UDP socket uses an unsupported address family';
}

sub _closed_error {
    my ($connection) = @_;
    for my $side (qw(local peer)) {
        my $method = "${side}_error";
        my $error = $connection->$method() or next;
        return sprintf(
            'QUIC %s error code=%s application=%s reason=%s',
            $side, $error->{code}, $error->{application} ? 1 : 0,
            length($error->{reason}) ? $error->{reason} : '(empty)',
        );
    }
    return 'QUIC connection closed';
}

sub _bytes {
    my ($name, $value) = @_;
    croak "$name must be a defined byte string" if !defined($value) || ref($value);
    my $bytes = $value;
    croak "$name must be a byte string" unless utf8::downgrade($bytes, 1);
    return $bytes;
}

sub _positive_integer {
    my ($name, $value) = @_;
    croak "$name must be a positive integer"
        if !defined($value) || ref($value) || $value !~ /\A[1-9][0-9]*\z/;
    return 0 + $value;
}

sub _nonnegative_integer {
    my ($name, $value) = @_;
    croak "$name must be a non-negative integer"
        if !defined($value) || ref($value)
            || $value !~ /\A(?:0|[1-9][0-9]*)\z/;
    return 0 + $value;
}

sub _positive_number {
    my ($name, $value) = @_;
    croak "$name must be a positive number"
        if !defined($value) || ref($value)
            || !looks_like_number($value) || "$value" =~ /(?:inf|nan)/i
            || $value <= 0;
    return 0 + $value;
}

sub _timeout_error {
    return "HTTP/3 request timed out after $_[0] seconds";
}

sub _redirect_status {
    return $_[0] == 301 || $_[0] == 302 || $_[0] == 303
        || $_[0] == 307 || $_[0] == 308;
}

sub _same_origin {
    my ($left_input, $right_input) = @_;
    my $left = URI->new($left_input);
    my $right = URI->new($right_input);
    return lc($left->scheme // '') eq lc($right->scheme // '')
        && lc($left->host // '') eq lc($right->host // '')
        && $left->port == $right->port;
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
    my @unknown = sort grep { !$known->{$_} } keys %{$options};
    croak "$method() received unknown option '$unknown[0]'" if @unknown;
}

sub DESTROY {
    my ($self) = @_;
    $self->stop if $self->{origins} && !$self->{stopped};
}

1;

__END__

=head1 NAME

Net::Quiche::HTTP3::Client - IO::Async HTTP/3 client

=head1 SYNOPSIS

    my $client = Net::Quiche::HTTP3::Client->new(
        config => $quiche_config,
    );
    $loop->add($client);

    my $response = await $client->post(
        'https://example.test/upload',
        headers => [['content-type', 'application/octet-stream']],
        body => $bytes,
    );

=head1 DESCRIPTION

C<get>, C<post>, and C<request> buffer the response body with a configured
limit. C<start_request> returns a L<Net::Quiche::HTTP3::Exchange> for
streaming upload and download. The client owns UDP sockets, QUIC timers, and
one reusable connection per origin. It keeps request streams separate while
quiche multiplexes them over a connection.

C<max_redirects> defaults to zero. It can be set on the constructor or on a
buffered C<get>, C<post>, or C<request>. The client follows 301, 302, 303,
307, and 308, drains intermediate responses, and removes credentials when a
redirect changes origin. A L<Net::Quiche::HTTP3::Response> exposes the final
URI and copied redirect history. Streaming C<start_request> calls do not
follow redirects.

C<request_timeout> sets an optional default deadline in seconds. A buffered
C<get>, C<post>, or C<request>, and a streaming C<start_request>, can override
it with C<timeout>. Fractional seconds are accepted. A buffered request's
deadline covers its complete redirect chain. Cancelling the Future returned
by a buffered request cancels its current exchange; streaming callers use
C<cancel> on the returned exchange.

The optional C<proxy> constructor argument accepts C<socks5://> and
C<socks5h://> URIs. They use SOCKS5 UDP ASSOCIATE without authentication.
The client keeps the association's TCP control connection open until its
origin state closes. HTTP proxy CONNECT and MASQUE CONNECT-UDP are not
implemented.

When a server sends GOAWAY, the client retires that QUIC connection. Request
streams below the advertised cutoff can finish there. The next request for
the same origin opens a replacement connection, which can coexist with the
retiring connection until its accepted streams finish. A stream at or above
the cutoff fails with an explicit GOAWAY error instead of being replayed
silently.

Only C<https> URIs are accepted. TLS peer verification is controlled by the
supplied L<Net::Quiche::Config> and should remain enabled outside tests.
