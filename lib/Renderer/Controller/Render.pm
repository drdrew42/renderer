package Renderer::Controller::Render;
use Mojo::Base 'Mojolicious::Controller', -async_await, -signatures;

use Mojo::JSON   qw(encode_json decode_json);
use Crypt::JWT   qw(encode_jwt decode_jwt);
use Time::HiRes  qw(time);
use Digest::SHA  qw(sha256_hex);

use Crypt::Ed25519;
use MIME::Base64 qw(decode_base64);
use File::Spec;
use WeBWorK::PreTeXt;
use Renderer::ContentCache;
use Renderer::Registration;
use Renderer::Telemetry;

sub parseRequest ($c) {
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

	# Normalize common lowercase query params to camelCase before JWT processing.
	$params{outputFormat}  //= delete $params{outputformat}  if exists $params{outputformat};
	$params{displayMode}   //= delete $params{displaymode}   if exists $params{displaymode};
	$params{problemSeed}   //= delete $params{problemseed}   if exists $params{problemseed};

	# Stash first-render flag for seed diversity telemetry (LT-010).
	# A request without sessionJWT is the student's first view of this problem.
	$c->stash(_is_first_render => !defined $params{sessionJWT} ? 1 : 0);

	# Force-reload: skip content cache and re-fetch from OPL.
	# Useful after macro updates or to diagnose cache issues.
	$c->stash(_no_cache => $params{noCache} ? 1 : 0);

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

sub fetchRemoteSource_p ($c, $url, $pg_hash_hint = undef) {

	# Content-addressed mode: check disk cache first (unless noCache)
	if ($ENV{CONTENT_ADDRESSED}) {
		my $no_cache = $c->stash('_no_cache');

		# Try to resolve pg_hash from hint or url_index
		my $pg_hash = $pg_hash_hint || Renderer::ContentCache::pg_hash_for_url($url);

		if (!$no_cache && $pg_hash && Renderer::ContentCache::has_problem($pg_hash)) {
			my $cached_source = Renderer::ContentCache::read_problem($pg_hash);
			if ($cached_source) {
				$c->log->info("ContentCache HIT: $pg_hash (zero network)");
				$c->stash(_cache_status => 'hit');
				return Mojo::Promise->resolve($cached_source, $pg_hash);
			}
		}

		# Cache miss (or noCache forced) — fetch with conditional GET
		$c->log->info("ContentCache BYPASS (noCache)") if $no_cache;
		return _fetch_content_addressed_p($c, $url, $no_cache ? undef : $pg_hash);
	}

	# Legacy mode: unchanged behavior
	return _fetch_legacy_p($c, $url)->then(sub { return (shift, undef) });
}

# Content-addressed fetch: conditional GET, stage problem + macros on 200.
# Returns promise resolving to ($raw_source, $pg_hash).
sub _fetch_content_addressed_p ($c, $url, $pg_hash) {

	my $req_origin   = $c->req->headers->origin   || 'no origin';
	my $req_referrer = $c->req->headers->referrer || 'no referrer';
	my $header       = {
		Accept    => 'application/json;charset=utf-8',
		Requester => $req_origin,
		Referrer  => $req_referrer,
	};
	$header->{'If-None-Match'} = $pg_hash if $pg_hash;

	return $c->ua->max_redirects(5)->request_timeout(10)->get_p($url => $header)->then(sub {
		my $tx  = shift;
		my $res = $tx->result;

		# 304 Not Modified — use cached source
		if ($res->code == 304 && $pg_hash) {
			my $cached_source = Renderer::ContentCache::read_problem($pg_hash);
			if ($cached_source) {
				$c->log->info("ContentCache 304: $pg_hash");
				$c->stash(_cache_status => 'miss_304');
				return ($cached_source, $pg_hash);
			}
			# Shouldn't happen, but fall through to error
			$c->log->warn("ContentCache 304 but disk miss for $pg_hash — re-fetching");
		}

		unless ($res->is_success) {
			$c->log->error("fetchRemoteSource: Request to $url failed - " . $res->message);
			return (undef, undef);
		}

		# Parse enriched JSON response
		my $obj;
		eval { $obj = decode_json($res->body); 1; } or do {
			$c->log->error('fetchRemoteSource: Failed to parse JSON', $res->body);
			return (undef, undef);
		};

		my $raw_source   = $obj->{raw_source};
		my $fetched_hash = $obj->{pg_hash} || $res->headers->header('ETag');

		unless ($raw_source && $fetched_hash) {
			$c->log->warn("ContentCache: response missing raw_source or pg_hash");
			return ($raw_source, undef);
		}

		# Stage macros first (they must exist before problem symlinks)
		my @macros_to_link;
		for my $macro (@{ $obj->{macros} // [] }) {
			next unless $macro->{hash} && $macro->{source_type}
				&& ($macro->{source_type} eq 'custom' || $macro->{source_type} eq 'override');

			my $cache_hash = $macro->{hash};

			# Fetch macro if not already cached
			unless (-f "$ENV{RENDER_ROOT}/private/macros/$cache_hash") {
				if ($macro->{url}) {
					# Macro URL may be relative (/api/macros/...) — resolve against OPL base
					my $macro_url = $macro->{url};
					if ($macro_url =~ m{^/}) {
						my $opl_base = $ENV{OPL_API_URL} || 'http://webwork-opl:3000';
						$macro_url = $opl_base . $macro_url;
					}
					$c->log->info("Fetching macro $macro->{name}: $macro_url");
					my $macro_tx = $c->ua->get($macro_url);
					if ($macro_tx->result->is_success) {
						# If OPL redirected us, extract the canonical hash from the final URL
						my $final_url = $macro_tx->req->url->to_string;
						if ($final_url =~ m{/api/macros/(sha256:[0-9a-f]+)$}) {
							my $redirected_hash = $1;
							if ($redirected_hash ne $macro->{hash}) {
								$c->log->info("Macro $macro->{name}: redirected $macro->{hash} → $redirected_hash");
								$cache_hash = $redirected_hash;
							}
						}
						Renderer::ContentCache::stage_macro($cache_hash, $macro_tx->result->body);
					} else {
						$c->log->warn("ContentCache: failed to fetch macro $macro->{name}");
					}
				}
			}

			push @macros_to_link, { name => $macro->{name}, hash => $cache_hash };
		}

		# Stage the problem
		Renderer::ContentCache::stage_problem($fetched_hash, $raw_source, \@macros_to_link);
		Renderer::ContentCache::save_url_index($url, $fetched_hash);
		$c->log->info("ContentCache STAGED: $fetched_hash from $url");
		$c->stash(_cache_status => 'miss_200');

		return ($raw_source, $fetched_hash);
	})->catch(sub {
		my $err = shift;
		$c->stash(message => $err);
		$c->log->error("Problem source: Request to $url failed with error - $err");
		return (undef, undef);
	});
}

# Legacy fetch: returns promise resolving to $raw_source only.
sub _fetch_legacy_p ($c, $url) {

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

sub resolveSourceFilePath_p ($c, $file_path, $pg_hash_hint = undef) {

	# Normalize: strip leading private/ if present (Problem.pm adds it)
	my $normalized = $file_path;
	$normalized =~ s!^private/!!;

	# 1. Disk check — graceful transition while volume is still mounted
	my $disk_path = "$ENV{RENDER_ROOT}/private/$normalized";
	if (-f $disk_path) {
		$c->log->info("sourceFilePath disk HIT: $normalized");
		$c->stash(_cache_status => 'disk');
		return Mojo::Promise->resolve(undef, undef, "private/$normalized");
	}

	# 2. Path index + cache — zero network (unless noCache)
	my $no_cache = $c->stash('_no_cache');
	my $pg_hash = $no_cache ? undef : ($pg_hash_hint || Renderer::ContentCache::pg_hash_for_path($normalized));
	if (!$no_cache && $pg_hash && Renderer::ContentCache::has_problem($pg_hash)) {
		my $cached_source = Renderer::ContentCache::read_problem($pg_hash);
		if ($cached_source) {
			$c->log->info("ContentCache PATH HIT: $pg_hash (zero network)");
			$c->stash(_cache_status => 'hit');
			return Mojo::Promise->resolve($cached_source, $pg_hash, undef);
		}
	}

	# 3. OPL lookup — construct URL and delegate to existing fetch flow
	my $opl_base = $ENV{OPL_API_URL} || 'http://webwork-opl:3000';
	my $opl_url  = "$opl_base/api/problems/path/$normalized";

	$c->log->info("sourceFilePath OPL lookup: $opl_url");

	return _fetch_content_addressed_p($c, $opl_url, $pg_hash)->then(sub {
		my ($source, $fetched_hash) = @_;
		if ($source && $fetched_hash) {
			Renderer::ContentCache::save_path_index($normalized, $fetched_hash);
		}
		return ($source, $fetched_hash, undef);
	});
}

async sub problem ($c) {
	my $render_start = time;
	my $inputs_ref = $c->parseRequest;
	return unless $inputs_ref;

	$inputs_ref->{problemSource} = fetchRemoteSource_p($c, $inputs_ref->{problemSourceURL}, $inputs_ref->{pg_hash})
		if $inputs_ref->{problemSourceURL};

	# Content-addressed sourceFilePath resolution
	if ($ENV{CONTENT_ADDRESSED}
		&& !$inputs_ref->{problemSourceURL}
		&& !$inputs_ref->{problemSource}
		&& $inputs_ref->{sourceFilePath})
	{
		my ($source, $pg_hash, $disk_path) = await resolveSourceFilePath_p(
			$c, $inputs_ref->{sourceFilePath}, $inputs_ref->{pg_hash}
		);
		if ($disk_path) {
			# Legacy disk — let Problem.pm handle normally
			$inputs_ref->{sourceFilePath} = $disk_path;
		} elsif ($source && $pg_hash) {
			$inputs_ref->{problemSource}  = $source;
			$inputs_ref->{sourceFilePath} = Renderer::ContentCache::problem_path($pg_hash);
			$inputs_ref->{pg_hash}        = $pg_hash;
		} else {
			return $c->exception("Cannot resolve sourceFilePath: $inputs_ref->{sourceFilePath}", 404);
		}
	}

	my $file_path   = $inputs_ref->{sourceFilePath};
	my $random_seed = $inputs_ref->{problemSeed};

	my $problem_contents;
	if ($inputs_ref->{problemSource} && $inputs_ref->{problemSource} =~ /Mojo::Promise/) {
		my $pg_hash;
		($problem_contents, $pg_hash) = await $inputs_ref->{problemSource};
		$file_path = $inputs_ref->{problemSourceURL};
		if ($problem_contents) {
			# Content-addressed mode: route through cache directory
			if ($pg_hash) {
				$file_path = Renderer::ContentCache::problem_path($pg_hash);
				$inputs_ref->{sourceFilePath} = $file_path;
				$inputs_ref->{pg_hash}        = $pg_hash;
			} else {
				$c->log->info("Problem source fetched from $inputs_ref->{problemSourceURL}");
			}
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

	# Inject cached custom macro source into envir for PG's loadMacros().
	# PGloadfiles.pm checks envir{injectedMacros}{$fileName} before searching disk.
	if ($inputs_ref->{pg_hash}) {
		my $injected = Renderer::ContentCache::get_injected_macros($inputs_ref->{pg_hash});
		if (%$injected) {
			$inputs_ref->{injectedMacros} = $injected;
			$c->log->info("Injecting " . scalar(keys %$injected) . " macro(s) via envir for $inputs_ref->{pg_hash}");
		}
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

	# ─── Telemetry ──────────────────────────────────────────────────────────
	if ($ENV{CONTENT_ADDRESSED} && $inputs_ref->{pg_hash} && !$inputs_ref->{isInstructor}) {
		my $render_ms = int((time - $render_start) * 1000);
		my $outcome   = $problem->success()
			? (@{ $return_object->{warning_messages} // [] } ? 'warning' : 'success')
			: 'error';
		my $is_first  = $c->stash('_is_first_render');

		# LT-010: compute html_hash on first successful render for seed diversity
		my $html_hash;
		if ($is_first && $outcome eq 'success' && defined $return_object->{text}) {
			$html_hash = Renderer::Telemetry::content_hash(
				$return_object->{text}, $return_object->{answers});
		}

		Renderer::Telemetry::record_render(
			pg_hash        => $inputs_ref->{pg_hash},
			outcome        => $outcome,
			warnings       => scalar(@{ $return_object->{warning_messages} // [] }),
			render_ms      => $render_ms,
			cache_status   => $c->stash('_cache_status') // 'unknown',
			is_first_render => $is_first,
			seed           => $inputs_ref->{problemSeed},
			html_hash      => $html_hash,
		);

		if ($inputs_ref->{submitAnswers}) {
			Renderer::Telemetry::record_interaction(
				pg_hash => $inputs_ref->{pg_hash},
				action  => 'submit',
				score   => $return_object->{problem_result}{score},
				attempt => ($inputs_ref->{numIncorrect} // 0) + 1,
			);
		} elsif ($inputs_ref->{previewAnswers}) {
			Renderer::Telemetry::record_interaction(
				pg_hash => $inputs_ref->{pg_hash},
				action  => 'preview',
			);
		} elsif ($inputs_ref->{showCorrectAnswers}) {
			Renderer::Telemetry::record_interaction(
				pg_hash => $inputs_ref->{pg_hash},
				action  => 'show_answers',
			);
		}
	}

	return $c->format($return_object);
}

# ─── LT-016: Callback endpoint ──────────────────────────────────────────
# Accepts signed render requests from the OPL and returns html_hash.
# POST /render-api/callback
# Request: { pg_source, seed, pg_hash? } signed by OPL identity
# Response: { html_hash, outcome, warnings }

my $CALLBACK_SEMAPHORE = 0;
my $CALLBACK_MAX_CONCURRENT = $ENV{CALLBACK_MAX_CONCURRENT} // 4;

async sub callback ($c) {
	# Verify OPL signature
	unless (Renderer::Registration::has_opl_public_key()) {
		return $c->render(json => { error => 'registration not completed' }, status => 503);
	}

	my $raw_body = $c->req->body;
	my $sig_b64  = $c->req->headers->header('X-Telemetry-Signature');
	unless ($sig_b64 && length($sig_b64)) {
		return $c->render(json => { error => 'missing signature' }, status => 401);
	}

	my $sig = decode_base64($sig_b64);
	my $opl_key = Renderer::Registration::opl_public_key();
	my $valid = eval { Crypt::Ed25519::verify($raw_body, $opl_key, $sig); 1 } // 0;
	unless ($valid) {
		return $c->render(json => { error => 'invalid signature' }, status => 401);
	}

	# Parse request and dispatch by action
	my $req = $c->req->json;
	unless ($req) {
		return $c->render(json => { error => 'missing JSON body' }, status => 400);
	}

	# Dispatch: invalidate_macro doesn't need the render pipeline
	if (($req->{action} // '') eq 'invalidate_macro') {
		my $hash = $req->{hash};
		unless ($hash) {
			return $c->render(json => { error => 'missing hash' }, status => 400);
		}
		my $deleted = eval { unlink File::Spec->catfile("$ENV{RENDER_ROOT}/private/macros", $hash) } // 0;
		$c->log->info("Macro invalidated: $hash (deleted=$deleted)");
		return $c->render(json => { invalidated => $hash, deleted => $deleted ? \1 : \0 });
	}

	# Default action: render (original callback behavior)
	unless (defined $req->{pg_source} && defined $req->{seed}) {
		return $c->render(json => { error => 'missing pg_source or seed' }, status => 400);
	}

	# Concurrency guard
	if ($CALLBACK_SEMAPHORE >= $CALLBACK_MAX_CONCURRENT) {
		return $c->render(json => { error => 'callback queue full' }, status => 429);
	}
	$CALLBACK_SEMAPHORE++;

	# Build minimal inputs_ref and render via the full pipeline
	$c->render_later;

	my %inputs = (
		problemSource => $req->{pg_source},
		problemSeed   => $req->{seed} + 0,
		outputFormat  => 'json',
		isInstructor  => 0,
	);

	my $problem = eval {
		$c->newProblem({
			log              => $c->log,
			read_path        => 'callback',
			random_seed      => $inputs{problemSeed},
			problem_contents => $inputs{problemSource},
		});
	};

	unless ($problem && $problem->success()) {
		$CALLBACK_SEMAPHORE--;
		my $msg = $problem ? $problem->{_message} : $@;
		return $c->render(json => { outcome => 'error', warnings => 0, error => "$msg" }, status => 200);
	}

	my $ww_return_json = eval { await $problem->render(\%inputs) };
	$CALLBACK_SEMAPHORE--;

	unless ($problem->success()) {
		return $c->render(json => { outcome => 'error', warnings => 0, error => $problem->{_message} }, status => 200);
	}

	my $return_object;
	eval { $return_object = decode_json($ww_return_json); 1; } or do {
		return $c->render(json => { outcome => 'error', warnings => 0, error => 'JSON decode failed' }, status => 200);
	};

	my $warnings = scalar(@{ $return_object->{warning_messages} // [] });
	my $outcome  = $warnings ? 'warning' : 'success';

	# Compute html_hash using the same normalization as telemetry
	my $html_hash = Renderer::Telemetry::content_hash(
		$return_object->{text}, $return_object->{answers});

	return $c->render(json => {
		html_hash => $html_hash,
		outcome   => $outcome,
		warnings  => $warnings,
	});
}

async sub render_ptx ($c) {

	$c->render_later;
	my $res = await WeBWorK::PreTeXt::render_ptx($c->req->params->to_hash);

	return $c->render(text => $res) unless ref($res) eq 'HASH';

	$c->res->headers->content_type('text/xml; charset=utf-8');
	return $c->render(template => 'RPCRenderFormats/ptx', %$res);
}

async sub sendAnswerJWT ($c, $JWTanswerURL, $answerJWT) {

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

sub exception ($c, $message, $status, @extra) {
	my $id = $c->logID;
	$message = "[$id] " . (ref $message eq 'ARRAY' ? join "\n", @$message : $message);
	$c->log->error("($status) EXCEPTION: $message");
	return $c->respond_to(
		json => {
			json => {
				message => $message,
				status  => $status,
				@extra
			},
			status => $status
		},
		html => { template => 'exception', message => $message, status => $status }
	);
}

sub croak ($c, $exception, $depth) {
	my $err_stack = $exception->message;

	my @err = split("\n", $err_stack);
	splice(@err, $depth, $#err) if ($depth <= scalar @err);
	$c->log->error(join "\n", @err);

	my $pretty_error = $err[0] =~ s/^(.*?) at .*$/$1/r;

	$c->exception($pretty_error, 500);
	return;
}

sub jweFromRequest ($c) {
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

sub jwtFromRequest ($c) {
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
