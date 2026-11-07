package PAGI::Test::HTTP3Client;

use strict;
use warnings;
use Carp qw(croak);
use Scalar::Util qw(blessed);
use IO::Async::Loop ();

use Net::Quiche ();
use Net::Quiche::HTTP3::Client ();
use PAGI::Server::HTTP3 ();

our $VERSION = '0.013';

sub new {
    my ($class, @arguments) = @_;
    croak 'new() must be called on PAGI::Test::HTTP3Client or a subclass'
        unless defined($class) && !ref($class) && eval { $class->isa(__PACKAGE__) };
    my %options = _options('new', @arguments);
    _unknown('new', \%options, {
        app => 1, psgi_app => 1, server_config => 1, client_config => 1,
        host => 1, max_response_body => 1, max_redirects => 1,
        request_timeout => 1, proxy => 1, on_error => 1,
    });
    croak 'new() requires server_config'
        unless exists $options{server_config};
    croak 'new() requires exactly one of app or psgi_app'
        if exists($options{app}) == exists($options{psgi_app});
    croak 'app must be a PAGI code reference'
        if exists($options{app}) && ref($options{app}) ne 'CODE';
    croak 'psgi_app must be a PSGI code reference'
        if exists($options{psgi_app}) && ref($options{psgi_app}) ne 'CODE';
    croak 'server_config must be a Net::Quiche::Config object'
        unless blessed($options{server_config})
            && $options{server_config}->isa('Net::Quiche::Config');
    croak 'client_config must be a Net::Quiche::Config object'
        if exists($options{client_config})
            && (!blessed($options{client_config})
                || !$options{client_config}->isa('Net::Quiche::Config'));
    croak 'on_error must be a code reference'
        if exists($options{on_error}) && ref($options{on_error}) ne 'CODE';

    my $client_config = $options{client_config} || Net::Quiche->config(
        verify_peer => 0,
        max_idle_timeout => 10_000,
        max_recv_udp_payload_size => 1_350,
        max_send_udp_payload_size => 1_350,
        initial_max_data => 10_000_000,
        initial_max_stream_data_bidi_local => 1_000_000,
        initial_max_stream_data_bidi_remote => 1_000_000,
        initial_max_stream_data_uni => 1_000_000,
        initial_max_streams_bidi => 100,
        initial_max_streams_uni => 100,
        disable_active_migration => 1,
    );
    my $loop = IO::Async::Loop->new;
    my $host = $options{host} // '127.0.0.1';
    my $server = PAGI::Server::HTTP3->new(
        (exists($options{app})
            ? (app => $options{app}) : (psgi_app => $options{psgi_app})),
        config => $options{server_config},
        host => $host,
        port => 0,
        on_error => $options{on_error} || sub { warn "$_[0]\n" },
    );
    my $client = Net::Quiche::HTTP3::Client->new(
        config => $client_config,
        max_response_body => $options{max_response_body} // 16 * 1024 * 1024,
        (exists($options{max_redirects})
            ? (max_redirects => $options{max_redirects}) : ()),
        (exists($options{request_timeout})
            ? (request_timeout => $options{request_timeout}) : ()),
        (exists($options{proxy}) ? (proxy => $options{proxy}) : ()),
    );
    $loop->add($server);
    $loop->add($client);
    return bless {
        loop => $loop,
        server => $server,
        client => $client,
        started => 0,
        stopped => 0,
        base_uri => undef,
        host => $host,
    }, $class;
}

sub get {
    my ($self, $path, @arguments) = @_;
    croak 'get() requires a path or URI' unless defined $path;
    my %options = _options('get', @arguments);
    _unknown('get', \%options,
        { headers => 1, max_redirects => 1, timeout => 1 });
    return $self->request(
        method => 'GET', path => $path,
        headers => $options{headers} // [], body => '',
        (exists($options{max_redirects})
            ? (max_redirects => $options{max_redirects}) : ()),
        (exists($options{timeout}) ? (timeout => $options{timeout}) : ()),
    );
}

sub post {
    my ($self, $path, @arguments) = @_;
    croak 'post() requires a path or URI' unless defined $path;
    my %options = _options('post', @arguments);
    _unknown('post', \%options,
        { headers => 1, body => 1, max_redirects => 1, timeout => 1 });
    return $self->request(
        method => 'POST', path => $path,
        headers => $options{headers} // [],
        body => exists($options{body}) ? $options{body} : '',
        (exists($options{max_redirects})
            ? (max_redirects => $options{max_redirects}) : ()),
        (exists($options{timeout}) ? (timeout => $options{timeout}) : ()),
    );
}

sub request {
    my ($self, @arguments) = @_;
    croak 'test client has been stopped' if $self->{stopped};
    my %options = _options('request', @arguments);
    _unknown('request', \%options,
        { method => 1, path => 1, headers => 1, body => 1,
          max_redirects => 1, timeout => 1 });
    croak 'request() requires method and path'
        unless exists($options{method}) && exists($options{path});
    $self->_start;
    my $uri = "$options{path}";
    if ($uri !~ m{\Ahttps://}) {
        croak 'test request path must begin with /' unless $uri =~ m{\A/};
        $uri = $self->{base_uri} . $uri;
    }
    my $future = $self->{client}->request(
        method => $options{method}, uri => $uri,
        headers => $options{headers} // [],
        body => exists($options{body}) ? $options{body} : '',
        (exists($options{max_redirects})
            ? (max_redirects => $options{max_redirects}) : ()),
        (exists($options{timeout}) ? (timeout => $options{timeout}) : ()),
    );
    return $self->{loop}->await($future)->get;
}

sub base_uri {
    croak 'base_uri() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    $self->_start;
    return $self->{base_uri};
}

sub stop {
    croak 'stop() takes no arguments' unless @_ == 1;
    my ($self) = @_;
    return if $self->{stopped};
    $self->{stopped} = 1;
    $self->{client}->stop;
    $self->{server}->stop;
    $self->{loop}->remove($self->{client}) if $self->{client}->parent;
    $self->{loop}->remove($self->{server}) if $self->{server}->parent;
    return;
}

sub _start {
    my ($self) = @_;
    return if $self->{started};
    $self->{loop}->await($self->{server}->listen)->get;
    my $host = $self->{host};
    $host = "[$host]" if index($host, ':') >= 0;
    $self->{base_uri} = 'https://' . $host . ':' . $self->{server}->bound_port;
    $self->{started} = 1;
    return;
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
    $self->stop if $self->{loop} && !$self->{stopped};
}

1;

__END__

=head1 NAME

PAGI::Test::HTTP3Client - Blocking HTTP/3 client for PAGI application tests

=head1 SYNOPSIS

    my $test = PAGI::Test::HTTP3Client->new(
        app => $app,
        server_config => $server_config,
    );
    my $response = $test->post('/echo', body => 'hello');

=head1 DESCRIPTION

This test helper runs a real L<PAGI::Server::HTTP3> and
L<Net::Quiche::HTTP3::Client> on one private IO::Async loop. Its C<get>,
C<post>, and C<request> methods block until the buffered response completes,
which keeps ordinary Test::More code synchronous. The server configuration
must provide a test certificate and private key. The default client
configuration disables peer verification and must not be reused in production.
Pass C<psgi_app> instead of C<app> to run a PSGI code reference through
C<PAGI::App::WrapPSGI> and the real HTTP/3 listener.
The constructor forwards C<max_redirects>, C<request_timeout>, and C<proxy> to
the HTTP/3 client. Each buffered request can override C<max_redirects> and
C<timeout>.
