use strict;
use warnings;
use Test::More;
use version ();
use Net::Quiche ();
use Net::Quiche::XS ();

my $library_version = Net::Quiche::version();
like($library_version, qr/\A[0-9]+\.[0-9]+\.[0-9]+\z/,
    'returns a released quiche version');
ok(version->parse($library_version) >= version->parse('0.29.3'),
    'linked quiche meets the minimum version');
is($library_version, Net::Quiche::XS::version(),
    'public wrapper returns the native library version');
isnt($library_version, $Net::Quiche::VERSION,
    'native library version is separate from the distribution version');

my $changed = Net::Quiche::XS::version();
substr($changed, 0, 1) = 'x';
is(Net::Quiche::XS::version(), $library_version,
    'returned scalar does not modify quiche-owned storage');
is_deeply([map { Net::Quiche::version() } 1 .. 100],
    [($library_version) x 100], 'repeated calls are stable');

for my $call (\&Net::Quiche::version, \&Net::Quiche::XS::version) {
    my $ok = eval { $call->('unexpected'); 1 };
    ok(!$ok, 'arguments are rejected');
    like($@, qr/Usage:.*version\(\)/, 'argument error names the function');
}

done_testing;
