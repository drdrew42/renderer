package RenderApp::Controller::Render;
use Mojo::Base -async_await;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::UserAgent;
use Mojo::JSON qw(decode_json encode_json);
use Crypt::JWT qw(decode_jwt encode_jwt);
use Data::Dumper;

async sub problem {
  my $c = shift;
  my $problemJWT;
  my $sessionJWT;



  # set up inputs_ref
  my %inputs_ref = WeBWorK::Form->new_from_paramable($c->req)->Vars;
  delete $inputs_ref{JWTanswerURL};
  if (defined($c->req->param('webworkJWT'))) { # Use encrypted data from webworkJWT or problemJWT if present instead of params
    my $webworkJWT = $c->req->param('webworkJWT');
    print("Can't touch this\n");
    my $claims = decode_jwt(token => $webworkJWT, key => $ENV{webworkJWTsecret}, verify_iss=>$ENV{JWTanswerHost});
    %inputs_ref = (%inputs_ref, %$claims)
  }
  elsif (defined($c->req->param('problemJWT'))) {
    $problemJWT = $c->req->param('problemJWT');
    # my $claims = Mojo::JWT->new(secret => $ENV{JWTsecret})->decode($problemJWT);
    my $claims = decode_jwt(token => $problemJWT, key => $ENV{problemJWTsecret}, verify_aud=>$ENV{JWTanswerHost}); # TODO Add error handling

    # flatten down webwork key if present
    if (defined($claims->{webwork})) {
      $claims = decode_jwt(token => $claims->{webwork}, key => $ENV{problemJWTsecret}, verify_aud=>$ENV{JWTanswerHost}); # TODO Add error handling
    }
    $claims->{problemJWT} = $problemJWT;
    # $JWTanswerURL = $claims->{JWTanswerURL} || $JWTanswerURL;

    %inputs_ref = %$claims;
  }

  $inputs_ref{JWTanswerURL} ||= $ENV{JWTanswerURL};
  $inputs_ref{formURL} ||= $c->app->config('form');
  $inputs_ref{baseURL} ||= $c->app->config('url');
  print Dumper(%inputs_ref);


  my $problem = $c->newProblem({log => $c->log, read_path => $inputs_ref{sourceFilePath}, random_seed => $inputs_ref{problemSeed}, problem_contents => $inputs_ref{problemSource}});
  return $c->render(json => $problem->errport(), status => $problem->{status}) unless $problem->success();

  $inputs_ref{sourceFilePath} = $problem->{read_path}; # in case the path was updated...

  my @input_errs = checkInputs(\%inputs_ref);
  if (@input_errs) {
    my $err_log = "Form data submitted for ".$inputs_ref{sourceFilePath}." contained errors: {";
    $err_log .= join "}, {", @input_errs;
    $c->log->error($err_log."}");
  }

  $c->render_later;
  my $ww_return_json = await $problem->render(\%inputs_ref);

  unless ($problem->success()) {
    $c->log->warn($problem->{_message});
    return $c->render(
      json   => $problem->errport(),
      status => $problem->{status}
    );
  }

  my $ww_return_hash = decode_json($ww_return_json);
  my @output_errs = checkOutputs($ww_return_hash);
  if (@output_errs) {
    my $err_log = "Output from rendering ".$inputs_ref{sourceFilePath}." contained errors: {";
    $err_log .= join "}, {", @output_errs;
    $c->log->error($err_log."}");
  }

  $ww_return_hash->{debug}->{render_warn} = [@input_errs, @output_errs];


  if (defined($inputs_ref{submitAnswers})) {
    my $scoreHash = {};
    my $answerNum =0;
    # $sessionJWT = Mojo::JWT->new(claims=>\%inputs_ref, secret=>$ENV{JWTsecret})->encode;
    # $sessionJWT = encode_jwt(payload=>\%inputs_ref, alg=>'HS256', key=>$ENV{JWTsecret}); TODO: FIX sessionJWT

    foreach my $ans_id (keys %{$ww_return_hash->{answers}}) {
      $answerNum++;  # start with 1, this is also the row number
      $scoreHash->{$answerNum} = {
          ans_id => $ans_id,
          answer => $ww_return_hash->{answers}{$ans_id} // {},
          score => $ww_return_hash->{answers}{$ans_id}{score} // 0,
      };
    }
    my $scoreJSON = encode_json($scoreHash);

    my $responseHash = {
      score      => $scoreHash,
      problemJWT => $problemJWT,
      sessionJWT => 'World',
    };
    # my $answerJWT = Mojo::JWT->new(claims=>$responseHash, secret=>$ENV{JWTsecret})->encode;
    my $answerJWT = encode_jwt(payload=>$responseHash, alg=>'HS256', key=>$ENV{JWTsecret}, auto_iat=>1,);

    my $ua  = Mojo::UserAgent->new;
    # print Dumper({
    #     'Accept' => 'application/json',
    #     'Authorization' => "Bearer $answerJWT",
    #     'Host' => $ENV{JWTanswerHost},
    # });

    say $ua->post($inputs_ref{JWTanswerURL}, { # TODO: Handle if endpoint is offline
        'Accept' => 'application/json',
        'answerJWT' => "$answerJWT",
        'Host' => $ENV{JWTanswerHost},
    })->result->body;
    # warn "$JWTanswerURL\n";
  }

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
