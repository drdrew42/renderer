package RenderApp::Controller::IO;
use Mojo::Base 'Mojolicious::Controller';
use File::Spec::Functions qw(splitdir);
use File::Find qw(find);
use MIME::Base64 qw(decode_base64);

sub raw {
  my $c = shift;
  my $file_path = $c->param('sourceFilePath'); # || $c->session('filePath');
  my $problem = $c->newProblem({log => $c->log, read_path => $file_path});
  return $c->render(json => $problem->errport(), status => $problem->{status}) unless $problem->success();
  $c->render(text => $problem->{problem_contents});
}

sub writer {
  my $c = shift;
  my $source = decode_base64($c->param('problemSource'));
  my $file_path = $c->param('writeFilePath');
  my $problem = $c->newProblem({log => $c->log, write_path=>$file_path, problem_contents=>$source});

  return $c->render(json => $problem->errport(), status => $problem->{status}) unless $problem->success();

  return ($problem->save) ? $c->render(text=>$problem->{write_path}) : $c->render(json => $problem->errport(), status => $problem->{status});
}

sub catalog {
  my $c = shift;
  return $c->render(json => {
    statusCode => 412,
    error => "Precondition Failed",
    message => "You must provide a valid base path."
  }, status => 412) unless ( defined($c->param('basePath')) && $c->param('basePath') =~ m/\S/ );

  my $root_path = $c->param('basePath');
  my $depth = $c->param('maxDepth') // 2;

  $root_path =~ s!\s+|\.\./!!g;
  $root_path =~ s!^Library/!webwork-open-problem-library/OpenProblemLibrary/!;
  $root_path =~ s!^Contrib/!webwork-open-problem-library/Contrib/!;

  # no peeking outside of these two directory trees
  return $c->render(json => {
    statusCode => 403,
    error => "Forbidden",
    message => "I'm sorry Dave, I'm afraid I can't do that."
  }, status => 403) unless (
    $root_path =~ m/^webwork-open-problem-library\/?/ ||
    $root_path =~ m/^private\/?/
  );

  if ( $depth == 0 || !-d $root_path ) {
    # warn($root_path) if !(-e $root_path);
    return (-e $root_path) ? $c->rendered(200) : $c->rendered(404);
  }

  local $File::Find::skip_pattern = qr/^\./; #skip any hidden folders
  my %all;
  my $wanted = sub {
    (my $rel = $File::Find::name) =~ s!^\Q$root_path\E/?!!; #measure depth relative to root_path
    my $path = $File::Find::name;
    $File::Find::prune = 1 if File::Spec::Functions::splitdir($rel) >= $depth;
    $path = $path.'/' if -d $File::Find::name;
    $all{$path}++ if ( $path =~ m!.+/$! || $path =~ m!.+\.pg$! ); #only report .pg files and directories
  };
  File::Find::find {wanted=>$wanted, no_chdir=>1}, $root_path;

  $c->render( json => \%all );
}

sub search {
  my $c = shift;
  return $c->render(json => {
    statusCode => 412,
    error => "Precondition Failed",
    message => "You must provide a valid path to search."
  }, status => 412) unless ( defined($c->param('basePath')) && $c->param('basePath') =~ m/\S/ );

  my $target = $c->param('basePath');
  # cannot search for a path that doesn't end in a pg file
  return $c->render(json => {
    statusCode => 403,
    error => "Forbidden",
    message => "I'm sorry Dave, I'm afraid I can't do that."
  }, status => 403) unless ( $target =~ m!.+\.pg$! );
  my @targetArray = split /\//, $target;

  local $File::Find::skip_pattern = qr/^\./; #skip any hidden folders
  my @sources = ('private/', 'webwork-open-problem-library/OpenProblemLibrary/', 'webwork-open-problem-library/Contrib/');
  my %found;
  my $wanted = sub {
    my $path = $File::Find::name;
    my %pathHash = map { $_ => 1 } split /\//, $path;
    my $matchCount = 0;
    # don't continue unless the actual pg file matches...
    unless ( defined($pathHash{ $targetArray[-1] }) ) {
      return;
    }
    # when we have a matching filename, measure how much of the requested target is a match
    for my $piece (@targetArray) {
      $matchCount++ if (defined($pathHash{$piece}) || ($piece eq 'Library' && defined($pathHash{'OpenProblemLibrary'})))
    }
    $found{$path} = $matchCount/($#targetArray+1); # only happens if the filename matches
  };
  for my $source (@sources) {
    File::Find::find {wanted=>$wanted, no_chdir=>1}, $source;
  }

  $c->render( json => \%found );
}

1;
