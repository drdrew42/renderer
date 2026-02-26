# Perl dependencies installed via cpanm (beyond Ubuntu apt packages).
# Pin versions for reproducible builds.
#
# To update: build without pins, check versions with:
#   docker run --rm renderer perl -MModule::Name -e 'print $Module::Name::VERSION'
# Then update the version numbers here.

requires 'Mojolicious', '== 9.42';
requires 'Statistics::R::IO::Rserve', '== 1.0002';
requires 'Date::Format', '== 2.24';
requires 'Future::AsyncAwait', '== 0.71';
requires 'Crypt::JWT', '== 0.037';
requires 'IO::Socket::SSL', '== 2.098';
requires 'CGI::Cookie', '== 4.59';
