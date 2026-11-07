#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my $curl = $ENV{NET_QUICHE_CURL} // do {
    my @candidates = map { File::Spec->catfile($_, 'curl') } File::Spec->path;
    (grep { -f $_ && -x $_ } @candidates)[0] // '';
};
my $h3i = $ENV{NET_QUICHE_H3I}
    // File::Spec->catfile($root, '.deps', 'quiche', 'target', 'release', 'h3i');
my $source = File::Spec->catdir($root, '.deps', 'quiche');
my $expected_commit = '55886df3be579579207104c8e645825b6347a209';
my @errors;

my $native_version = eval {
    require Net::Quiche;
    Net::Quiche::version();
};
if (defined $native_version) {
    print "ok native-quiche $native_version\n";
} else {
    push @errors, 'Net::Quiche is not built; run perl Build.PL and ./Build';
}

my ($git_status, $commit) = capture('git', '-C', $source, 'rev-parse', 'HEAD');
if ($git_status == 0 && $commit eq $expected_commit) {
    print "ok quiche-source $commit\n";
} else {
    push @errors, "quiche source must be commit $expected_commit";
}

if (-x $curl) {
    my ($status, $version) = capture($curl, '--version');
    if ($status == 0 && $version =~ /^Features:.*\bHTTP3\b/m) {
        my ($first_line) = split /\n/, $version;
        print "ok curl $first_line\n";
    } else {
        push @errors, "$curl does not report the HTTP3 feature";
    }
} else {
    push @errors, "HTTP/3 curl is not executable at $curl";
}

if (-x $h3i) {
    my ($status, $version) = capture($h3i, '--version');
    if ($status == 0) {
        print "ok h3i $version ($h3i)\n";
    } else {
        push @errors, "h3i failed at $h3i";
    }
} else {
    push @errors, "h3i is not built at $h3i";
}

my @fixtures = map {
    File::Spec->catfile($root, 't', 'fixtures', $_)
} qw(cert.crt cert.key);
if (!grep { !-f $_ } @fixtures) {
    print "ok tls-fixtures bundled public quiche certificate and key\n";
} else {
    push @errors, 'bundled TLS fixtures are missing from t/fixtures';
}

if (@errors) {
    print STDERR "not ready: $_\n" for @errors;
    exit 1;
}

print "HTTP/3 verification environment ready\n";

sub capture {
    my (@command) = @_;
    open my $pipe, '-|', @command or return (255, '');
    my $output = do { local $/; <$pipe> };
    close $pipe;
    my $status = $? >> 8;
    $output = '' unless defined $output;
    $output =~ s/\s+\z//;
    return ($status, $output);
}
