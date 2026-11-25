package Net::Quiche::XS;

use strict;
use warnings;
use XSLoader ();
use version ();

our $VERSION = '0.013';

XSLoader::load(__PACKAGE__, $VERSION);

my $library_version = Net::Quiche::XS::version();
die "Net::Quiche::XS requires released quiche >= 0.29.3; loaded $library_version\n"
    unless $library_version =~ /\A[0-9]+\.[0-9]+\.[0-9]+\z/
        && version->parse($library_version) >= version->parse('0.29.3');

# Native handles hold raw pointers. A cloned interpreter must not free them
# a second time.
sub Net::Quiche::XS::Connection::CLONE_SKIP { 1 }
sub Net::Quiche::XS::HTTP3::CLONE_SKIP { 1 }

1;

__END__

=head1 NAME

Net::Quiche::XS - Thin binding to the quiche C API

=head1 SYNOPSIS

    use Net::Quiche::XS ();
    print Net::Quiche::XS::version(), "\n";

=head1 FUNCTIONS

=head2 version()

Calls C<quiche_version()> and returns a Perl-owned copy of the library's
version string. Takes no arguments. No functions are exported.

Loading this module rejects quiche releases older than 0.29.3 and prerelease
version strings. C<$VERSION> is the Perl distribution version, not the native
library version.

=cut
