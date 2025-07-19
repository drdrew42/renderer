package Renderer::Controller::Render;
use Mojo::Base 'Mojolicious::Controller', -async_await;

use Mojo::JSON  qw(encode_json decode_json);
use Crypt::JWT  qw(encode_jwt decode_jwt);
use Time::HiRes qw/time/;

use WeBWorK::PreTeXt;

sub parseRequest {
	my $c      = shift;
	my %params = %{ $c->req->params->to_hash };

	my $originIP = $c->req->headers->header('X-Forwarded-For')
		// '' =~ s!^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}).*$!$1!r;
	$originIP ||= $c->tx->remote_address || 'unknown-origin';

	if ($ENV{STRICT_JWT} && !(defined $params{problemJWT} || defined $params{sessionJWT})) {
		return $c->exception('Not allowed to request problems with raw data.', 403);
	}

	# protect against DOM manipulation
	if (defined $params{submitAnswers} && defined $params{previewAnswers}) {
		$c->log->error('Simultaneous submit and preview! JWT: ', $params{problemJWT} // {});
		return $c->exception('Malformed request.', 400);
	}

	# TODO: ensure showCorrectAnswers does not appear without showCorrectAnswersButton
	# showCorrectAnswersButton cannot be checked until after pulling in problemJWT

	# ensure that these params are only provided by trusted source
	for (qw(JWTanswerURL sessionID numCorrect numIncorrect)) {
		delete $params{$_};
	}

	# set session-specific info (previous attempts, correct/incorrect count)
	if (defined $params{sessionJWT}) {
		$c->log->info("Received JWT: using sessionJWT");
		my $sessionJWT = $params{sessionJWT};
		my $claims;
		eval {
			$claims = decode_jwt(
				token      => $sessionJWT,
				key        => $ENV{webworkJWTsecret},
				verify_iss => $ENV{SITE_HOST},
			);
			1;
		} or do {
			return $c->croak($@, 3);
		};
		# only supply key-values that are not already provided
		# e.g. current responses vs. previously submitted responses
		# except for problemJWT which must remain consistent with session
		delete $params{problemJWT};
		foreach my $key (keys %$claims) {
			$params{$key} //= $claims->{$key};
		}
	}

	# problemJWT sets basic problem request configuration and rendering options
	if (defined $params{problemJWT}) {
		$c->log->info("Received JWT: using problemJWT");
		my $problemJWT = $params{problemJWT};
		my $claims;
		eval {
			$claims = decode_jwt(
				token      => $problemJWT,
				key        => $ENV{problemJWTsecret},
				verify_aud => $ENV{SITE_HOST},
			);
			1;
		} or do {
			return $c->croak($@, 3);
		};
		# LibreTexts uses provider name as key for problemJWT claims
		$claims = $claims->{webwork} if defined $claims->{webwork};
		# override key-values in params with those provided in the JWT
		@params{ keys %$claims } = values %$claims;
	} elsif ($params{outputFormat} ne 'ptx') {
		# if no JWT is provided, create one (unless this is a pretext request)
		$params{aud} = $ENV{SITE_HOST};
		$params{isInstructor} //= 0;
		$params{sessionID} ||= time;
		my $req_jwt = encode_jwt(
			payload  => \%params,
			key      => $ENV{problemJWTsecret},
			alg      => 'PBES2-HS512+A256KW',
			enc      => 'A256GCM',
			auto_iat => 1
		);
		$params{problemJWT} = $req_jwt;
	}
	$params{originIP} = $originIP if $originIP;
	return \%params;
}

sub fetchRemoteSource_p {
	my $c   = shift;
	my $url = shift;

	# tell the library who originated the request for pg source
	my $req_origin   = $c->req->headers->origin   || 'no origin';
	my $req_referrer = $c->req->headers->referrer || 'no referrer';
	my $header       = {
		Accept    => 'application/json;charset=utf-8',
		Requester => $req_origin,
		Referrer  => $req_referrer,
	};

	return $c->ua->max_redirects(5)->request_timeout(10)->get_p($url => $header)->then(sub {
		my $tx  = shift;
		my $res = $tx->result;
		unless ($res->is_success) {
			$c->log->error("fetchRemoteSource: Request to $url failed with error - " . $res->message);
			return;
		}
		# library responses are JSON formatted with expected 'raw_source'
		my $obj;
		eval { $obj = decode_json($res->body); 1; } or do {
			$c->log->error('fetchRemoteSource: Failed to parse JSON', $res->body);
			return $c->croak($@, 3);
		};
		return ($obj && $obj->{raw_source}) ? $obj->{raw_source} : undef;
	})->catch(sub {
		my $err = shift;
		$c->stash(message => $err);
		$c->log->error("Problem source: Request to $url failed with error - $err");
		return;
	});
}

async sub problem {
	my $c          = shift;
	my $inputs_ref = $c->parseRequest;
	return unless $inputs_ref;

	$inputs_ref->{problemSource} = fetchRemoteSource_p($c, $inputs_ref->{problemSourceURL})
		if $inputs_ref->{problemSourceURL};

	my $file_path   = $inputs_ref->{sourceFilePath};
	my $random_seed = $inputs_ref->{problemSeed};

	my $problem_contents;
	if ($inputs_ref->{problemSource} && $inputs_ref->{problemSource} =~ /Mojo::Promise/) {
		$problem_contents = await $inputs_ref->{problemSource};
		$file_path        = $inputs_ref->{problemSourceURL};
		if ($problem_contents) {
			$c->log->info("Problem source fetched from $inputs_ref->{problemSourceURL}");
			# $c->stash($problem_contents->{filename} => $problem_contents->{url});
			# $problem_contents = $problem_contents->{raw_source};
		} else {
			return $c->exception('Failed to retrieve problem source.', 500);
		}
	} else {
		$problem_contents = $inputs_ref->{problemSource};
	}

	my $problem = $c->newProblem({
		log              => $c->log,
		read_path        => $file_path,
		random_seed      => $random_seed,
		problem_contents => $problem_contents
	});
	unless ($problem->success()) {
		return $c->exception($problem->{_message}, $problem->{status});
	}

	$c->render_later;    # tell Mojo that this might take a while
	my $ww_return_json;
	{
		$ww_return_json = await $problem->render($inputs_ref);

		unless ($problem->success()) {
			return $c->exception($problem->{_message}, $problem->{status});
		}
	}

	my $return_object;
	eval { $return_object = decode_json($ww_return_json); 1; } or do {
		$c->log->error('problem.render: Failed to parse JSON', $ww_return_json);
		return $c->croak($@, 3);
	};
	$return_object->{inputs_ref} = $inputs_ref;

	# if answerURL provided and this is a submit, then send the answerJWT
	if ($inputs_ref->{JWTanswerURL} && $inputs_ref->{submitAnswers} && !$inputs_ref->{isLocked}) {
		# can this be 'await'ed later?
		$return_object->{JWTanswerURLstatus} =
			await sendAnswerJWT($c, $inputs_ref->{JWTanswerURL}, $return_object->{answerJWT});
	}

	# log interaction and format the response
	if ($c->app->config('INTERACTION_LOG')) {
		my $displayScore = $inputs_ref->{previewAnswers} ? 'preview' : $return_object->{problem_result}{score};
		$displayScore .= '*' if $inputs_ref->{showCorrectAnswers};
		$displayScore //= 'err';

		$c->logAttempt(
			$inputs_ref->{sessionID},
			$inputs_ref->{originIP},
			$inputs_ref->{isInstructor}     ? 'instructor'  : 'student',
			$inputs_ref->{answersSubmitted} ? $displayScore : 'init',
			$inputs_ref->{problemSeed},
			$inputs_ref->{sourceFilePath} || $inputs_ref->{problemSourceURL} || $inputs_ref->{problemSource},
			$inputs_ref->{essay} ? '"' . $inputs_ref->{essay} =~ s/"/\\"/gr . '"' : '""',
		);
	}

	return $c->format($return_object);
}

async sub render_ptx {
	my $c = shift;

	$c->render_later;
	my $res = await WeBWorK::PreTeXt::render_ptx($c->req->params->to_hash);

	return $c->render(text => $res) unless ref($res) eq 'HASH';

	$c->res->headers->content_type('text/xml; charset=utf-8');
	return $c->render(template => 'RPCRenderFormats/ptx', %$res);
}

async sub sendAnswerJWT {
	my $c            = shift;
	my $JWTanswerURL = shift;
	my $answerJWT    = shift;

	# default response hash
	my $answerJWTresponse = {
		subject => 'webwork.result',
		message => 'initial message'
	};
	my $header = {
		Origin         => $ENV{SITE_HOST},
		'Content-Type' => 'text/plain',
	};

	$c->log->info("sending answerJWT to $JWTanswerURL");
	await $c->ua->max_redirects(5)->request_timeout(7)->post_p($JWTanswerURL, $header, $answerJWT)->then(sub {
		my $response = shift->result;

		$answerJWTresponse->{status} = int($response->code);
		# answerURL responses are expected to be JSON
		if ($response->json) {
			# munge data with default response object
			$answerJWTresponse = { %$answerJWTresponse, %{ $response->json } };
		} else {
			# otherwise throw the whole body as the message
			$answerJWTresponse->{message} = $response->body;
		}
	})->catch(sub {
		my $err = shift;
		$c->log->error($err);

		$answerJWTresponse->{status}  = 500;
		$answerJWTresponse->{message} = '[' . $c->logID . '] ' . $err;
	});

	$answerJWTresponse = encode_json($answerJWTresponse);
	# this will become a string literal, so single-quote characters must be escaped
	$answerJWTresponse =~ s/'/\\'/g;
	$c->log->info("answerJWT response " . $answerJWTresponse);
	return $answerJWTresponse;
}

sub exception {
	my $c       = shift;
	my $id      = $c->logID;
	my $message = shift;
	$message = "[$id] " . (ref $message eq 'ARRAY' ? join "\n", @$message : $message);
	my $status = shift;
	$c->log->error("($status) EXCEPTION: $message");
	return $c->respond_to(
		json => {
			json => {
				message => $message,
				status  => $status,
				@_
			},
			status => $status
		},
		html => { template => 'exception', message => $message, status => $status }
	);
}

sub croak {
	my $c         = shift;
	my $exception = shift;
	my $err_stack = $exception->message;
	my $depth     = shift;

	my @err = split("\n", $err_stack);
	splice(@err, $depth, $#err) if ($depth <= scalar @err);
	$c->log->error(join "\n", @err);

	my $pretty_error = $err[0] =~ s/^(.*?) at .*$/$1/r;

	$c->exception($pretty_error, 500);
	return;
}

sub jweFromRequest {
	my $c          = shift;
	my $inputs_ref = $c->parseRequest;
	return unless $inputs_ref;
	$inputs_ref->{aud} = $ENV{SITE_HOST};
	my $req_jwt = encode_jwt(
		payload  => $inputs_ref,
		key      => $ENV{problemJWTsecret},
		alg      => 'PBES2-HS512+A256KW',
		enc      => 'A256GCM',
		auto_iat => 1
	);
	return $c->render(text => $req_jwt);
}

sub jwtFromRequest {
	my $c          = shift;
	my $inputs_ref = $c->parseRequest;
	return unless $inputs_ref;
	$inputs_ref->{aud} = $ENV{SITE_HOST};
	my $req_jwt = encode_jwt(
		payload  => $inputs_ref,
		key      => $ENV{problemJWTsecret},
		alg      => 'HS256',
		auto_iat => 1
	);
	return $c->render(text => $req_jwt);
}

1;
