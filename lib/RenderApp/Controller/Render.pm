package RenderApp::Controller::Render;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(decode_json);

sub problem {
  my $c = shift;
  my $file_path = $c->param('sourceFilePath'); # || $c->session('filePath');
  my $random_seed = $c->param('problemSeed');
  my $problem = $c->newProblem({read_path => $file_path, random_seed => $random_seed});
  return $c->render(json => $problem->errport(), status => $problem->{status}) unless $problem->success();

  my %inputs_ref = WeBWorK::Form->new_from_paramable($c->req)->Vars;
  $inputs_ref{formURL} = $c->app->config('form') unless $inputs_ref{formURL};
  $inputs_ref{baseURL} = $c->app->config('url') unless $inputs_ref{baseURL};

  # consider passing the problem object alongside the inputs_ref - this will become unnecessary
  $inputs_ref{sourceFilePath} = $problem->{read_path}; # in case the path was updated...

  my $ww_return_json = $problem->render(\%inputs_ref);
  my $ww_return_hash = decode_json($ww_return_json);
  
  $c->respond_to(
    html => { text => $ww_return_hash->{renderedHTML}},
    json => { json => $ww_return_hash }
  );
}

1;
