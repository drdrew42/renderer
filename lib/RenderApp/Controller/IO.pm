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

  return ($problem->save) ? $c->render(text=>$file_path) : $c->render(json => $problem->errport(), status => $problem->{status});
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

  # no peeking outside of these two directory trees
  return $c->render(json => {
    statusCode => 403,
    error => "Forbidden",
    message => "I'm sorry Dave, I'm afraid I can't do that."
  }, status => 403) unless ( $root_path =~ m/^webwork-open-problem-library\/?/ || $root_path =~ m/^private\/?/);

  if ( $depth == 0 || !-d $root_path ) {
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

1;
