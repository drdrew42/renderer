package RenderApp::Model::Problem;

use strict;
use warnings;

use Mojo::Base -base;


sub new { bless {}, shift };

sub validate {
  my ($self, $path, $seed) = @_;
};

1;
