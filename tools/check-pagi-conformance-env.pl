#!/usr/bin/env perl

use strict;
use warnings;
use FindBin qw($Bin);
use File::Spec;

my $root = File::Spec->rel2abs(File::Spec->catdir($Bin, '..'));
my @sources = (
    {
        name => 'PAGI-spec-0.002008',
        path => File::Spec->catdir($root, '.build-deps', 'pagi-spec-0.002008'),
        commit => 'd6f77363dd1f9b3e08b7d65c237ef24e383c07fb',
        contract => File::Spec->catfile('lib', 'PAGI', 'Spec', 'Www.pod'),
    },
    {
        name => 'PAGI-Server-0.002012',
        path => File::Spec->catdir($root, '.build-deps', 'pagi-server-0.002012'),
        commit => '62ab71b79b1b0d67b5b9189bbfbaa5ebfe810771',
        contract => File::Spec->catfile('lib', 'PAGI', 'Server', 'Compliance.pod'),
    },
);
my @errors;

for my $source (@sources) {
    my ($status, $commit) = capture(
        'git', '-C', $source->{path}, 'rev-parse', 'HEAD',
    );
    my $contract = File::Spec->catfile(
        $source->{path}, split m{/}, $source->{contract},
    );
    if ($status == 0 && $commit eq $source->{commit} && -f $contract) {
        print "ok $source->{name} $commit\n";
    } else {
        push @errors, "$source->{name} must be commit $source->{commit}";
    }
}

my $test = File::Spec->catfile($root, 't', 'pagi-conformance.t');
if (-f $test) {
    print "ok conformance-test $test\n";
} else {
    push @errors, 't/pagi-conformance.t is missing';
}

if (@errors) {
    print STDERR "not ready: $_\n" for @errors;
    exit 1;
}

print "PAGI HTTP/3 conformance environment ready\n";

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
