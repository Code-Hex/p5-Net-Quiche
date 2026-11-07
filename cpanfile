requires 'perl', '5.016';
requires 'Future', '0.50';
requires 'Future::AsyncAwait', '0.66';
requires 'IO::Async', '0.802';
requires 'IO::Socket::IP', '0.43';
requires 'URI', '1.76';
requires 'URI::Escape', '3.31';
requires 'XSLoader';
requires 'version';

recommends 'PAGI::App::WrapPSGI';

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
