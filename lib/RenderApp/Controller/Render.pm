package RenderApp::Controller::Render;
use Mojo::Base -async_await;
use Mojo::Base 'Mojolicious::Controller';
use Mojo::JSON qw(encode_json decode_json);
use Crypt::JWT qw(encode_jwt decode_jwt);
use MIME::Base64 qw(encode_base64);
use WeBWorK::Form;

sub parseRequest {
  my $c = shift;
  my %params = WeBWorK::Form->new_from_paramable($c->req)->Vars;
  delete $params{JWTanswerURL}; # we are going to replace this?
  # webworkJWT are the result of problems that have already been rendered
  # keep the submitted params, but overwrite with JWT settings
  if (defined $params{webworkJWT}) {
    $c->log->info("Received JWT: using webworkJWT");
    my $webworkJWT = $params{webworkJWT};
    my $claims = decode_jwt(
      token      => $webworkJWT,
      key        => $ENV{webworkJWTsecret},
      verify_iss => $ENV{JWTanswerHost},
    );
    # override key-values in params with those provided in the JWT
    @params{keys %$claims} = values %$claims;
  }
  # if this is the initial render, there will be no webworkJWT
  # in such case, there's no params we would want to keep
  elsif (defined $params{problemJWT}) {
    $c->log->info("Received JWT: using problemJWT");
    my $problemJWT = $params{problemJWT};
    my $claims = decode_jwt(
      token => $problemJWT,
      key => $ENV{problemJWTsecret},
      verify_aud => $ENV{JWTanswerHost},
    );
    $claims = $claims->{webwork} if defined $claims->{webwork};
    $claims->{problemJWT} = $problemJWT; # does this only need to happen when the previous line is executed?
    %params = %$claims;
  }
  return \%params;
}

sub fetchRemoteSource_p {
  my $c = shift;
  my $url = shift;
  # tell the library who originated the request for pg source
  my $req_origin   = $c->req->headers->origin   || 'no origin';
  my $req_referrer = $c->req->headers->referrer || 'no referrer';
  my $header       = {
      Accept    => 'text/html;charset=utf-8',
      Requestor => $req_origin,
      Referrer  => $req_referrer,
  };

  # don't worry about overriding problemSource - it *shouldn't exist* if libraryURL is present
  return $c->ua->get_p( $url => $header )->
    then(
      sub {
          my $tx = shift;
          return encode_base64($tx->result->body);
      })->
    catch(
      sub {
          my $err = shift;
          $c->log->error("Problem source: Request to $url failed with error - $err");
          return $c->render( json => {
              status => 500,
              message => "Failed to retrieve problem source. Error: $err.",
            }, status => 500
          );
      }
  );
}

async sub problem {
  my $c = shift;
  my $inputs_ref = $c->parseRequest;
  $inputs_ref->{problemSource} = fetchRemoteSource_p($c, $inputs_ref->{libraryURL}) if $inputs_ref->{libraryURL};

  my $file_path = $inputs_ref->{sourceFilePath}; # || $c->session('filePath');
  my $random_seed = $inputs_ref->{problemSeed};
  my $problem_contents = $inputs_ref->{problemSource};
  if ( $inputs_ref->{problemSource} =~ /Mojo::Promise/ ) {
    $problem_contents = await $inputs_ref->{problemSource};
    # $c->log->info("Finished encoding problem source: \n$problem_contents");
  }
  
  $c->log->warn(("problem_contents is still a Mojo::Promise")) if $problem_contents =~ /Mojo::Promise/;
  my $problem = $c->newProblem({log => $c->log, read_path => $file_path, random_seed => $random_seed, problem_contents => $problem_contents});
  return $c->render(json => $problem->errport(), status => $problem->{status}) unless $problem->success();

  # my %inputs_ref = WeBWorK::Form->new_from_paramable($c->req)->Vars;
  $inputs_ref->{formURL} ||= $c->app->config('form');
  $inputs_ref->{baseURL} ||= $c->app->config('url');

  $inputs_ref->{sourceFilePath} = $problem->{read_path}; # in case the path was updated...

  my @input_errs = checkInputs($inputs_ref);
  if (@input_errs) {
    my $err_log = "Form data submitted for ".$inputs_ref->{sourceFilePath}." contained errors: {";
    $err_log .= join "}, {", @input_errs;
    $c->log->error($err_log."}");
  }

  $c->render_later;
  my $ww_return_json = await $problem->render($inputs_ref);

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
    my $err_log = "Output from rendering ".$inputs_ref->{sourceFilePath}." contained errors: {";
    $err_log .= join "}, {", @output_errs;
    $c->log->error($err_log."}");
  }

  $ww_return_hash->{debug}->{render_warn} = [@input_errs, @output_errs];

  if ( defined($inputs_ref->{problemJWT}) && $inputs_ref->{submitAnswers} ) {
    my $scoreHash = {};
    my $answerNum = 0;
    foreach my $id (keys %{$ww_return_hash->{answers}}) {
      $answerNum++;
      $scoreHash->{$answerNum} = {
        ans_id => $id,
        answer => $ww_return_hash->{answers}{$id} // {},
        score  => $ww_return_hash->{answers}{$id}{score} // 0,
      };
    }
    my $responseHash = {
      score => $scoreHash,
      problemJWT => $inputs_ref->{problemJWT},
      sessionJWT => 'placeholder',
    };
    my $answerJWT = encode_jwt(
      payload => $responseHash,
      alg => 'HS256',
      key => $ENV{problemJWTsecret}, # no answerJWTsecret? problemJWTsecret?
      auto_iat => 1,
    );
    my $reqBody = {
      Accept => 'application/json',
      answerJWT => $answerJWT,
      Host => $ENV{JWTanswerHost},
    };
    await $c->ua->post_p($ENV{JWTanswerURL}, $reqBody)->
    then(sub {$c->log->info(shift)})->
    catch(sub {$c->log->error(shift)});
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