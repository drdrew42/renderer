package RenderApp::Controller::IO;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(decode_json);
use Mojo::File;
use MIME::Base64 qw(decode_base64);
use RenderApp::Model::Problem;

sub raw {
  my $c = shift;
  my $file_path = $c->param('sourceFilePath'); # || $c->session('filePath');
  my $problem = $c->newProblem({read_path => $file_path});
  return $c->render(json => $problem->errport(), status => $problem->{status}) unless $problem->success();
  $c->render(text => $problem->{problem_contents});
}

sub writer {
  my $c = shift;
  my $source = decode_base64($c->param('problemSource'));
  my $file_path = $c->param('writeFilePath');
  my $problem = $c->newProblem({write_path=>$file_path, problem_contents=>$source});

  return $c->render(json => {
    statusCode => 403,
    error => "Forbidden",
    message => "You may not save to that path."
  }, status => 403) unless ($problem->{write_allowed});

  eval {
    my $success = $problem->save;
    $success;
  } or do {
    return $c->render( json => {
      statusCode => 400,
      error => "Bad Request",
      message => $@
    }, status => 400);
  };
  return $c->render(text=>$file_path);
}

sub catalog {
  my $c = shift;
  my $depth = $c->param('maxDepth') // 2;
  if ( defined($c->param('basePath')) && $c->param('basePath') =~ m/\S/ ) {
    my $root_path = $c->param('basePath');
    # only allow cataloguing of the two main directories
    if ( $root_path =~ m/^webwork-open-problem-library\/?/
      || $root_path =~ m/^private\/?/) {
        my $root_path = Mojo::File->new($root_path);
        my $paths = $root_path->list_tree({max_depth=>$depth, dir=>0});
        return $c->render( text => $paths->join("\n") );
      } else {
        return $c->render(json => {
          statusCode => 403,
          error => "Forbidden",
          message => "I'm sorry Dave, I'm afraid I can't do that."
        }, status => 403);
      }
  } else {
    return $c->render(json => {
      statusCode => 412,
      error => "Precondition Failed",
      message => "You must provide a valid base path."
    }, status => 412);
  }
}

1;
