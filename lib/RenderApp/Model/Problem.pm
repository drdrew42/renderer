package RenderApp::Model::Problem;

use strict;
use warnings;

use Mojo::File;

##### Problem params: #####
# = random_seed      (set randomization for rendering)
# = read_path        (path to existing problem for edit/render)
# = write_path       (path for updating existing problem/saving new problem)
# = problem_contents (source code for problem)

##### Problem methods: #####
# - source (read/update problem_contents)
# - seed   (read/update random_seed)
# - path   (read/update read_path)
# - target (read/update write_path)
# - save   (write problem_contents to file at write_path)
# - load   (overwrite problem_contents with contents of file at read_path)

sub new {
  my $class = shift;
  my $problem_ref = {};
  bless $problem_ref, $class;
  $problem_ref->_init(@_);
  return $problem_ref;
};

sub _init {
  my ($self, $args) = @_;
  my $availability = 'private';

  my $read_path = $args->{read_path} || '';
  my $problem_contents = $args->{problem_contents} || '';
  die "Cannot create problem without either path or contents!\n" unless ($read_path =~ m/\S/ || $problem_contents =~ m/\S/);

  if ($read_path =~ m/\S/) {
    $self->path($read_path);
    $self->load;
  }
  if ($problem_contents =~ m/\S/) {
    $self->source($problem_contents);
  }

  $self->seed($args->{random_seed});
};

sub source {
  my $self = shift;
  if (scalar(@_) == 1) {
    my $contents = shift;
    # UNIX style line-endings are required
    $contents =~ s/\r\n/\n/g;
    $contents =~ s/\r/\n/g;
    $self->{problem_contents} = $contents;
  }
  return $self->{problem_contents};
}

sub seed {
  my $self = shift;
  if (scalar(@_) == 1) {
    my $random_seed = shift;
    die "You must provide a positive integer for the random seed!\n" unless $random_seed =~ m!^\d+$!;
    $self->{random_seed} = $random_seed;
  }
  return $self->{random_seed};
}

sub path {
  my $self = shift;
  if (scalar(@_) == 1) {
    my $read_path = shift;
    my $opl_root = $WeBWorK::Constants::OPL_ROOT;
    if ($read_path =~ m!^Library/!) {
      $read_path =~ s!^Library/!$opl_root/OpenProblemLibrary/!;
    } elsif ($read_path =~ m!^Contrib!) {
      $read_path =~ s!^Contrib/!$opl_root/Contrib/!;
    } else {
      # TODO: consider steps in pipeline towards OPL
      # these problems are not in OPL or Contrib yet
      # are we placing them in a folder relative to their user?
    }
    $read_path = Mojo::File->new($read_path);
    $self->{read_path} = $read_path;
  }
  return $self->{read_path};
}

sub target {
  my $self = shift;
  if (scalar(@_) == 1) {
    # TODO: include permission check to write to this path...
    $self->{write_allowed} = 1;
    $self->{write_path} = Mojo::Path->new(shift);
  }
  return $self->{write_path};
}

sub save {
  my $self = shift;
  my $success = 0;
  die "Nothing to write!" unless ($self->{problem_contents} =~ m/\S/);
  die "No file paths specified" unless ($self->{write_path} || $self->{read_path});
  my $write_path = $self->{write_path} ? $self->{write_path} : $self->{read_path};
  if (-w $self->{write_path}->to_string && $self->{write_allowed} ) {
    $write_path->spurt($self->{problem_contents});
    $success = 1;
  }
  return $success;
}

sub load {
  my $self = shift;
  my $success = 0;
  if (-r $self->{read_path}) {
    $self->{problem_contents} = $self->{read_path}->slurp;
    $success = 1;
  } else {
    warn "Problem set with un-read-able read_path!\n";
  }
  return $success;
}

1;
