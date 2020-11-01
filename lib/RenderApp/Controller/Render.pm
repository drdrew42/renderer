package RenderApp::Controller::Render;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(decode_json);

sub problem {
  my $c = shift;
  my $file_path = $c->param('sourceFilePath'); # || $c->session('filePath');
  my $random_seed = $c->param('problemSeed');
  my $problem_contents = $c->param('problemSource');
  my $problem = $c->newProblem({log => $c->log, read_path => $file_path, random_seed => $random_seed, problem_contents => $problem_contents});
  return $c->render(json => $problem->errport(), status => $problem->{status}) unless $problem->success();

  my %inputs_ref = WeBWorK::Form->new_from_paramable($c->req)->Vars;
  $inputs_ref{formURL} ||= $c->app->config('form');
  $inputs_ref{baseURL} ||= $c->app->config('url');

  $inputs_ref{sourceFilePath} = $problem->{read_path}; # in case the path was updated...

  my @input_errs = checkInputs(\%inputs_ref);
  if (@input_errs) {
    my $err_log = "Form data submitted for ".$inputs_ref{sourceFilePath}." contained errors: {";
    $err_log .= join "}, {", @input_errs;
    $c->log->error($err_log."}");
  }

  # consider passing the problem object alongside the inputs_ref - this will become unnecessary
  my $ww_return_json = $problem->render(\%inputs_ref);
  my $ww_return_hash = decode_json($ww_return_json);
  my @output_errs = checkOutputs($ww_return_hash);
  if (@output_errs) {
    my $err_log = "Output from rendering ".$inputs_ref{sourceFilePath}." contained errors: {";
    $err_log .= join "}, {", @output_errs;
    $c->log->error($err_log."}");
  }

  $ww_return_hash->{debug}->{render_warn} = [@input_errs, @output_errs];

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
      my $err = "UNICODE: $k contains nonstandard character(s):";
      while ($v =~ /([^\x00-\x7F])/g) {
        $err .= ' "'.$1.'" as '.sprintf("\\u%04x", ord($1));
      }
      if ( $v =~ /\x00/ ) {
        $err .= " NUL byte -- creating array.";
        my @v_array = split(/\x00/, $v);
        $inputs_ref->{$k} = \@v_array;
      }
      push @errs, $err;
    }
  }
  return @errs;
}

sub checkOutputs {
  my $outputs_ref = shift;
  my @errs;
  my @expected_keys = (
    'answers',
    'debug',
    'flags',
    'form_data',
    'problem_result',
    'problem_state',
    'renderedHTML'
  );
  if (ref $outputs_ref ne ref {}) {
    push @errs, "renderer result is not a hash: $outputs_ref";
  } else {
    for my $key (@expected_keys) {
      if (! defined $outputs_ref->{$key}) {
        if (! exists $outputs_ref->{$key}) {
          push @errs, "expected key: $key is missing";
        } else {
          push @errs, "expected key: $key is empty";
        }
      }
    }
  }
  return @errs;
}

1;