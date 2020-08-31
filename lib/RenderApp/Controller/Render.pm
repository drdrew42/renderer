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
  $inputs_ref{formURL} ||= $c->app->config('form');
  $inputs_ref{baseURL} ||= $c->app->config('url');

  # consider passing the problem object alongside the inputs_ref - this will become unnecessary
  $inputs_ref{sourceFilePath} = $problem->{read_path}; # in case the path was updated...

  my @errs = checkInputs(\%inputs_ref);
  my $ww_return_json = $problem->render(\%inputs_ref);
  my $ww_return_hash = decode_json($ww_return_json);

  $ww_return_hash->{debug}->{render_warn} = \@errs;

  $c->respond_to(
    html => { text => $ww_return_hash->{renderedHTML}},
    json => { json => $ww_return_hash }
  );
}

sub checkInputs {
  my $inputs_ref = shift;
  my @errs;
  while (my ($k, $v) = each %$inputs_ref) {
    next unless $v;
    if ($v =~ /[^\x01-\x7F]/) {
      my $err = "$k response contains nonstandard character(s): ";
      while ($v =~ /([^\x00-\x7F])/g) {
        $err = $err.'"'.$1.'" as '.sprintf("\\u%04x", ord($1));
      }
      if ( $v =~ /\x00/ ) {
        print $inputs_ref->{sourceFilePath}." has generated a NUL byte response.\n";
        my @v_array = split(/\x00/, $v);
        $inputs_ref->{$k} = \@v_array;
      } else {
        print $err."\n";
        push @errs, $err;
      }
    }
  }
  return @errs;
}

1;
