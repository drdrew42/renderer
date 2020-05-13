package RenderApp::Model::Users;

use strict;
use warnings;

use Mojo::Util 'secure_compare';

my $USERS = {
  joel      => 'las3rs',
  marcus    => 'lulz',
  sebastian => 'secr3t'
};

sub new { bless {}, shift };

sub check {
  my ($self, $user, $pass) = @_;

  # Success
  return 1 if $USERS->{$user} && secure_compare $USERS->{$user}, $pass;

  # Fail
  return undef;
}

1;
