use strict;
use warnings;
use Test::More;
use Scalar::Util qw(blessed);
use Net::Quiche;

my $config = Net::Quiche::Config->new;
isa_ok($config, 'Net::Quiche::Config');
is(blessed($config), 'Net::Quiche::Config', 'constructor returns the public class');
ok(Net::Quiche::Config->CLONE_SKIP, 'native config is not cloned into interpreter threads');

my $ok = eval { $$config = 0; 1 };
ok(!$ok, 'opaque native handle cannot be changed from Perl');
like($@, qr/read-only/, 'handle mutation reports a read-only value');
is($config->max_idle_timeout(1), $config, 'config remains usable after mutation attempt');

my $configured = Net::Quiche::Config->new(
    application_protocols               => ['h3'],
    verify_peer                          => 0,
    max_idle_timeout                     => 30_000,
    max_recv_udp_payload_size            => 1350,
    max_send_udp_payload_size            => 1350,
    initial_max_data                     => 10_000_000,
    initial_max_stream_data_bidi_local   => 1_000_000,
    initial_max_stream_data_bidi_remote  => 1_000_000,
    initial_max_stream_data_uni          => 100_000,
    initial_max_streams_bidi             => 100,
    initial_max_streams_uni              => 3,
    disable_active_migration             => 1,
);
isa_ok($configured, 'Net::Quiche::Config', 'named constructor');

is($configured->application_protocols('h3'), $configured,
    'application_protocols is chainable');
is($configured->application_protocols(['h3']), $configured,
    'application_protocols also accepts an array reference');
is($configured->verify_peer(1), $configured, 'boolean setter is chainable');
is($configured->max_idle_timeout(10_000), $configured,
    'integer setter is chainable');
is($configured->initial_max_data(1_000_000), $configured,
    'flow control setter is chainable');

my $from_hashref = Net::Quiche::Config->new({
    application_protocols => ['h3', 'hq-interop'],
});
isa_ok($from_hashref, 'Net::Quiche::Config', 'hashref constructor');

my $entrypoint = Net::Quiche->config(max_idle_timeout => 1_000);
isa_ok($entrypoint, 'Net::Quiche::Config', 'Net::Quiche entry point');
my $entrypoint_error_line = __LINE__ + 1;
$ok = eval { Net::Quiche->config(max_idle_timeout => '30s'); 1 };
ok(!$ok, 'entry point propagates option errors');
like($@, qr/at \Q$0\E line $entrypoint_error_line\b/,
    'entry point reports the user call site');

{
    package Local::Quiche::Config;
    our @ISA = ('Net::Quiche::Config');
}
my $subclass = Local::Quiche::Config->new;
isa_ok($subclass, 'Local::Quiche::Config', 'subclass constructor');

my @invalid = (
    [sub { Net::Quiche::Config->new(unknown => 1) }, qr/Unknown config option 'unknown'/],
    [sub { Net::Quiche::Config->new('max_idle_timeout') }, qr/odd number/],
    [sub { Net::Quiche::Config->new(max_idle_timeout => -1) }, qr/non-negative integer/],
    [sub { Net::Quiche::Config->new(max_idle_timeout => '1.5') }, qr/non-negative integer/],
    [sub { Net::Quiche::Config->new(verify_peer => 'false') }, qr/must be 0 or 1/],
    [sub { Net::Quiche::Config->new(application_protocols => []) }, qr/at least one protocol/],
    [sub { Net::Quiche::Config->new(application_protocols => ['']) }, qr/1 to 255 bytes/],
    [sub { Net::Quiche::Config->new(application_protocols => ["h\x{100}"]) }, qr/byte strings/],
    [sub { Net::Quiche::Config->new(certificate_chain => "bad\0path") }, qr/must not contain NUL/],
    [sub { Net::Quiche::Config->new(initial_max_data => '4611686018427387904') }, qr/no greater than/],
    [sub { $configured->max_idle_timeout(1, 2) }, qr/expects one integer/],
    [sub { $configured->application_protocols() }, qr/at least one protocol/],
);

for my $case (@invalid) {
    my ($code, $expected) = @$case;
    my $ok = eval { $code->(); 1 };
    ok(!$ok, 'invalid configuration is rejected');
    like($@, $expected, 'configuration error explains the invalid value');
}

my $missing = 'this-certificate-does-not-exist.pem';
$ok = eval { Net::Quiche::Config->new(certificate_chain => $missing); 1 };
ok(!$ok, 'native certificate loading failure is reported');
like($@, qr/Failed to load certificate chain '\Q$missing\E': quiche error -[0-9]+/,
    'native error includes operation, path, and quiche code');

$ok = eval { Net::Quiche::Config->new(verify_locations_file => $missing); 1 };
ok(!$ok, 'native CA file loading failure is reported');
like($@, qr/Failed to load verify locations file '\Q$missing\E': quiche error -[0-9]+/,
    'CA file error includes operation, path, and quiche code');

$ok = eval {
    Net::Quiche::Config->new(verify_locations_directory => $missing); 1
};
ok(!$ok, 'missing CA directory is rejected before native configuration');
like($@, qr/verify locations directory '\Q$missing\E' does not exist/,
    'CA directory error identifies the invalid path');

SKIP: {
my $cert = 't/fixtures/cert.crt';
my $key  = 't/fixtures/cert.key';
    skip 'pinned quiche PEM fixtures are not present', 4
        unless -f $cert && -f $key;
    my $tls_config = eval {
        Net::Quiche::Config->new(
            certificate_chain => $cert,
            private_key       => $key,
        );
    };
    ok($tls_config, 'loads a real certificate and private key');
    is($@, '', 'real PEM loading has no native error');
    is($tls_config->verify_locations_file($cert), $tls_config,
        'loads a real CA file and remains chainable');
    is($tls_config->verify_locations_directory('t/fixtures'),
        $tls_config, 'loads a real CA directory and remains chainable');
}

my $destroyed = Net::Quiche::Config->new;
$destroyed->DESTROY;
$ok = eval { $destroyed->max_idle_timeout(1); 1 };
ok(!$ok, 'use after explicit destruction is rejected');
like($@, qr/Net::Quiche::Config object has already been destroyed/,
    'use-after-destroy error identifies the object state');
$destroyed->DESTROY;
pass('destroying the same handle twice is harmless');

for (1 .. 1_000) {
    my $short_lived = Net::Quiche::Config->new(max_idle_timeout => $_);
}
pass('short-lived native configs are destroyed without a crash');

done_testing;
