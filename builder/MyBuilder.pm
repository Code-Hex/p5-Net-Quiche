package builder::MyBuilder;

use strict;
use warnings;
use parent 'Module::Build';

my $minimum_quiche = '0.29.3';

sub new {
    my ($class, %args) = @_;
    my ($cflags, $libs) = native_flags();
    $cflags .= ' -Wno-compound-token-split-by-macro' if $^O eq 'darwin';

    return $class->SUPER::new(
        %args,
        extra_compiler_flags => $cflags,
        extra_linker_flags => $libs,
        dynamic_config => 1,
    );
}

sub native_flags {
    if (exists $ENV{QUICHE_CFLAGS} || exists $ENV{QUICHE_LIBS}) {
        die "Set both QUICHE_CFLAGS and QUICHE_LIBS. See doc/DEVELOPMENT.md.\n"
            unless defined $ENV{QUICHE_CFLAGS}
                && defined $ENV{QUICHE_LIBS} && length $ENV{QUICHE_LIBS};
        return @ENV{qw(QUICHE_CFLAGS QUICHE_LIBS)};
    }

    pkg_config("--atleast-version=$minimum_quiche", 'quiche');
    return (pkg_config('--cflags', 'quiche'), pkg_config('--libs', 'quiche'));
}

sub pkg_config {
    my @args = @_;
    my $program = $ENV{PKG_CONFIG} || 'pkg-config';
    my $help = "quiche >= $minimum_quiche with its C API is required.\n"
        . "Build quiche with --features ffi,pkg-config-meta and set PKG_CONFIG_PATH,\n"
        . "or set both QUICHE_CFLAGS and QUICHE_LIBS. See doc/DEVELOPMENT.md.\n";
    open my $pipe, '-|', $program, @args
        or die "Cannot execute $program: $!\n$help";
    my $output = do { local $/; <$pipe> };
    close $pipe or die "$program @args failed.\n$help";
    $output = '' unless defined $output;
    $output =~ s/\s+\z//;
    return $output;
}

1;
