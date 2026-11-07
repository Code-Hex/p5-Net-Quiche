use strict;
use warnings;
use Test::More;

# Test the load-time policy in fresh processes with a version-only XS double.
# Real native loading and returned scalar ownership are tested in version.t.
my $probe = <<'PERL';
use strict;
use warnings;
use XSLoader ();
my $load = \&XSLoader::load;
{
    no warnings qw(redefine once);
    *XSLoader::load = sub {
        if ($_[0] eq 'Net::Quiche::XS') {
            *Net::Quiche::XS::version = sub { $ARGV[0] };
            return;
        }
        goto &$load;
    };
}
my $ok = eval { require Net::Quiche; 1 };
print $ok ? Net::Quiche::version() : $@;
exit($ok ? 0 : 1);
PERL

for my $case (
    ['0.29.3', 1], ['0.29.4', 1], ['0.30.0', 1], ['1.0.0', 1],
    ['0.29.2', 0], ['0.9.99', 0], ['0.29.3-rc.1', 0], ['invalid', 0],
) {
    my ($native_version, $accepted) = @$case;
    open my $child, '-|', $^X, '-Ilib', '-e', $probe, $native_version
        or die "Cannot start version guard probe: $!";
    my $output = do { local $/; <$child> };
    close $child;
    is($?, $accepted ? 0 : 256, "load policy for $native_version");
    if ($accepted) {
        is($output, $native_version, 'accepted version is exposed unchanged');
    } else {
        like($output, qr/requires released quiche >= 0\.29\.3; loaded \Q$native_version\E/,
            'rejection reports the actual version and minimum');
    }
}

done_testing;
