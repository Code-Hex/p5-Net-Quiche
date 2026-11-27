requires 'perl', '5.016';
requires 'Future', '0.50';
requires 'IO::Async', '0.802';
requires 'URI', '1.76';
requires 'XSLoader';
requires 'version';

on configure => sub {
    requires 'Module::Build', '0.4005';
};

on test => sub {
    requires 'Test::More', '0.88';
};

on develop => sub {
    requires 'Minilla', 'v3.3.2';
    requires 'Software::License::Perl_5';
    requires 'Test::CPAN::Meta';
    requires 'Test::MinimumVersion::Fast';
    requires 'Test::Pod', '1.41';
};
