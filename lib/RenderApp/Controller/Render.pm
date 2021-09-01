package RenderApp::Controller::Render;
use Mojo::Base 'Mojolicious::Controller', -async_await;
use Mojo::JSON qw(encode_json decode_json);
use Crypt::JWT qw(encode_jwt decode_jwt);
use MIME::Base64 qw(encode_base64);
use RenderApp::Model::JWT;
use WeBWorK::Form;

sub parseRequest {
	my $c = shift;
	my %params = WeBWorK::Form->new_from_paramable($c->req)->Vars;
	if ($c->app->mode eq 'production' && !( defined $params{problemJWT} || defined $params{sessionJWT} )) {
		$c->exception('Not allowed to request problems with raw data.', 403);
		return undef;
	}

	delete $params{JWTanswerURL}; # may ONLY be set by a JWT...

	# set session-specific info (previous attempts, correct/incorrect count)
	if (defined $params{sessionJWT}) {
		$c->log->info("Received JWT: using sessionJWT");
		my $session = {};
		eval {
			$session = $c->decodeJWT($params{sessionJWT}, key => $ENV{sessionJWTsecret}, verify_iss => $ENV{SITE_HOST});
			1;
		} or do {
			$c->exception($@->message, 403);
			return undef;
		};

		# if a sessionJWT doesn't have a problemJWT - something is VERY wrong
		if ( !defined($session->{problemJWT}) ) {
			$c->exception("Session does not include problemJWT", 403);
			return undef;
		} else {
			# TODO: think about authorizing replacement if sessionJWT
			# is accompanied by separate problemJWT...
			$params{problemJWT} = $session->{problemJWT};
		}

		# if this request isn't 'submit' or 'preview',
		# load key-values from session
		if ( !$params{submitAnswers} && !$params{previewAnswers}) {
			my %latest = %{$session->{submitted}->[-1]};
			foreach my $key (keys %latest) {
				$params{$key} ||= $latest{$key};
			}
		}

		my $numCorrect = scalar(@{$session->{correct}});
		my $numSubmissions = scalar(@{$session->{submitted}});
		if ( $numCorrect ) {
			$params{numCorrect} = 1;
			$params{numIncorrect} = $numSubmissions - 1;
		} else {
			$params{numCorrect} = 0;
			$params{numIncorrect} = $numSubmissions;
		}
	}

	# problemJWT sets basic problem request configuration and rendering options
	if (defined $params{problemJWT}) {
		$c->log->info("Received JWT: using problemJWT");
		my $problem = {};
		eval {
			$problem = $c->decodeJWT($params{problemJWT}, key => $ENV{problemJWTsecret}, verify_aud => $ENV{SITE_HOST});
			1;
		} or do {
			$c->exception($@->message, 403);
			return undef;
		};

		# support problemJWT with data for more than just webwork
		$problem = $problem->{webwork} if defined $problem->{webwork};

		# override key-values in params with those provided in the JWT
		@params{ keys %$problem } = values %$problem;
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
		Requester => $req_origin,
		Referrer  => $req_referrer,
	};

	# don't worry about overriding problemSource - it *shouldn't exist* if problemSourceURL is present
	return $c->ua->max_redirects(5)->request_timeout(10)->get_p( $url => $header )->
		then(
		sub {
			my $tx = shift;
			# TODO: do we expect that the response is ALREADY b64 encoded?
			return encode_base64($tx->result->body);
		})->
		catch(
		sub {
			my $err = shift;
			$c->stash( message => $err );
			$c->log->error("Problem source: Request to $url failed with error - $err");
			return;
		}
	);
}

async sub problem {
	my $c = shift;
	my $inputs_ref = $c->parseRequest;
	return unless $inputs_ref;
	$inputs_ref->{problemSource} = fetchRemoteSource_p($c, $inputs_ref->{problemSourceURL}) if $inputs_ref->{problemSourceURL};

	my $file_path = $inputs_ref->{sourceFilePath};
	my $random_seed = $inputs_ref->{problemSeed};
	$inputs_ref->{baseURL} ||= $ENV{baseURL};
	$inputs_ref->{formURL} ||= $ENV{formURL};

	my $problem_contents;
	if ( $inputs_ref->{problemSource} && $inputs_ref->{problemSource} =~ /Mojo::Promise/ ) {
		$problem_contents = await $inputs_ref->{problemSource};
		if ( $problem_contents ) {
			$c->log->info("Problem source fetched from $inputs_ref->{problemSourceURL}");
		} else {
			# TODO: should we let the promise handle this?
			return $c->exception('Failed to retrieve problem source.', 500);
		}
	} else {
		$problem_contents = $inputs_ref->{problemSource};
	}

	my $problem = $c->newProblem({ log => $c->log, read_path => $file_path, random_seed => $random_seed, problem_contents => $problem_contents });
	return $c->exception($problem->{_message}, status => $problem->{status}) unless $problem->success();

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

	# if answers are submitted and there is a provided answerURL...
	if ($inputs_ref->{JWTanswerURL} && $ww_return_hash->{answerJWT} && $inputs_ref->{submitAnswers}) {
		my $answerJWTresponse = {
			iss    => $ENV{SITE_HOST},
			subject => "webwork.result",
			status    => 502,
			message => "initial message"
		};
		my $reqBody = {
			Origin         => $ENV{SITE_HOST},
			"Content-Type" => 'text/plain',
		};

		$c->log->info("sending answerJWT to " . $inputs_ref->{JWTanswerURL});
		await $c->ua->max_redirects(5)->request_timeout(7)->post_p($inputs_ref->{JWTanswerURL}, $reqBody, $ww_return_hash->{answerJWT})->
		then(sub {
			my $response = shift->result;

			$answerJWTresponse->{status} = int($response->code);
			if ($response->is_success) {
				$answerJWTresponse->{message} = $response->body;
			}
			elsif ($response->is_error) {
				$answerJWTresponse->{message} = '[' . $c->logID . '] ' . $response->message;
			}

			$answerJWTresponse->{message} =~ s/"/\\"/g;
			$answerJWTresponse->{message} =~ s/'/\'/g;
		})->
		catch(sub {
			my $response = shift;
			$c->log->error($response);

			$answerJWTresponse->{status} = 500;
			$answerJWTresponse->{message} = '[' . $c->logID . '] ' . $response;
		});
		$answerJWTresponse = encode_json($answerJWTresponse);
		$c->log->info("answerJWT response ".$answerJWTresponse);

		$ww_return_hash->{renderedHTML} =~ s/JWTanswerURLstatus/$answerJWTresponse/g;
	} else {
		$ww_return_hash->{renderedHTML} =~ s/JWTanswerURLstatus//;
	}

	$c->respond_to(
		html => { text => $ww_return_hash->{renderedHTML} },
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

sub exception {
	my $c = shift;
	my $id = $c->logID;
	my $message = "[$id] " . shift =~ s/^(.*?) at .*$/$1/r;
	my $status = shift;
	return $c->respond_to(
		json => { json => {
			message => $message,
			status => $status,
		}, status => $status},
		html => { template => 'exception', message => $message, status => $status }
	);
}

sub croak {
	my $c         = shift;
	my $exception = shift;
	my $err_stack = $exception->message;
	my $depth     = shift;

	my @err = split( "\n", $err_stack );
	splice( @err, $depth, $#err ) if ( $depth <= scalar @err );
	$c->log->error( join "\n", @err );

	my $pretty_error = $err[0] =~ s/^(.*?) at .*$/$1/r;

	$c->exception( $pretty_error, 403 );
	return;
}

sub jweFromRequest {
	my $c          = shift;
	my $inputs_ref = $c->parseRequest;
	return unless $inputs_ref;
	my $req_jwe = RenderApp::Model::JWT->new(
		$inputs_ref,
		aud => $ENV{SITE_HOST},
		key => $ENV{problemJWTsecret}
	);
	return $c->render( text => $req_jwe->encode );
}

sub jwtFromRequest {
	my $c          = shift;
	my $inputs_ref = $c->parseRequest;
	return unless $inputs_ref;
	my $req_jwt = RenderApp::Model::JWT->new(
		$inputs_ref,
		aud => $ENV{SITE_HOST},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
		enc => ''
	);
	return $c->render( text => $req_jwt->encode );
}

1;