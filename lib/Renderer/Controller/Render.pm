package Renderer::Controller::Render;
use Mojo::Base 'Mojolicious::Controller', -async_await, -signatures;

# Core /render-api action plus the small content-fetch endpoints (hint,
# solution, render_ptx) and the legacy JWT-mint helpers (jwtFromRequest,
# jweFromRequest, used by the dev-mode supplementalRoutes).
#
# The heavy lifting lives in dedicated modules (extracted in WW3-R33):
#
#   * Renderer::Render::ParseRequest   — envelope parse + lane dispatch
#   * Renderer::Render::SourceResolver — problem source + cache flow
#   * Renderer::Render::AnswerURL      — answer-URL postback + verdict fold
#   * Renderer::Controller::Callback   — OPL callback endpoint
#
# This controller is the route-bound thin layer that orchestrates them.

use Mojo::JSON qw(encode_json decode_json);
use Time::HiRes qw(time);

use WeBWorK::PreTeXt;
use WeBWorK::HintSolution;
use Renderer::ContentCache;
use Renderer::Telemetry;
use Renderer::Render::Subprocess qw(render_in_subprocess);
use Renderer::Render::SourceResolver;
use Renderer::Render::AnswerURL;
use Renderer::Lane::ContentFetch;
use Renderer::Util::JWT qw(mint_jwt);

async sub problem ($c) {
	my $render_start = time;
	my $inputs_ref = $c->parseRequest;
	return unless $inputs_ref;

	# Resolve problemSourceURL / sourceFilePath / problemSource into a
	# concrete (problemSource, sourceFilePath, pg_hash) tuple on $inputs_ref.
	my $resolved = await Renderer::Render::SourceResolver::resolve_source($c, $inputs_ref);
	return unless $resolved;

	my $problem_contents = $inputs_ref->{problemSource};
	my $file_path        = $inputs_ref->{sourceFilePath};
	my $random_seed      = $inputs_ref->{problemSeed};

	unless (defined $problem_contents && $problem_contents =~ /\S/) {
		return $c->exception('Cannot render without problem source.', 400);
	}
	unless (defined $random_seed && $random_seed =~ /^\d+$/) {
		return $c->exception('You must provide a positive integer for the random seed.', 400);
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
	my $log_id = $inputs_ref->{pg_hash} || $file_path || '(no-source-id)';
	my $ww_return_json = await render_in_subprocess(\$problem_contents, $inputs_ref, $log_id, $c->log);

	if (ref $ww_return_json eq 'HASH' && $ww_return_json->{_error}) {
		return $c->exception($ww_return_json->{_error}{message}, $ww_return_json->{_error}{status});
	}

	my $return_object;
	eval { $return_object = decode_json($ww_return_json); 1; } or do {
		$c->log->error('problem.render: Failed to parse JSON', $ww_return_json);
		return $c->croak($@, 3);
	};
	$return_object->{inputs_ref} = $inputs_ref;

	# If answerURL provided and this is a submit, send the answerJWT (legacy
	# problemJWT path) or submissionJWT envelope (challengeJWT path). The
	# renderer is dumb here: a JWT-declared answerURL means "report back" —
	# isInstructor is the orchestrator's concern, not ours.
	if ($inputs_ref->{JWTanswerURL} && $inputs_ref->{submitAnswers}) {
		# Emission gate. The renderer's contract is validate-then-render; we
		# do NOT refuse to render based on grounding shape. What we DO refuse
		# is to emit a signed answerJWT without upstream grounding — that's a
		# statement about what the renderer signs, not about which requests
		# render. Self-minted and peer-signed lanes never set the flag.
		# Orthogonal to STRICT_JWT (which governs whether ungrounded requests
		# are admitted at all). Ref: WeBWorK3/Config and Secrets Evolution.
		unless ($c->stash('_can_emit_answer_jwt')) {
			$c->log->error('Student submit without upstream JWT — rejecting answer emission.');
			return $c->exception('Submit requires a problemJWT, challengeJWT, or sessionJWT.', 403);
		}
		await Renderer::Render::AnswerURL::process($c, $inputs_ref, $return_object);
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

	# ─── Telemetry (LT-057) ─────────────────────────────────────────────────
	# Three event types, three gates. See vault: WeBWorK/Render Telemetry.md.
	#   * render            — universal; code-path health (warnings/errors/ms)
	#   * seed_observation  — first-render only; deterministic content property
	#   * interaction       — non-instructor only; student-experience signal
	if ($ENV{CONTENT_ADDRESSED} && $inputs_ref->{pg_hash}) {
		my $render_ms     = int((time - $render_start) * 1000);
		my $warning_count = scalar(@{ $return_object->{warning_messages} // [] });
		# PG's error surface: flags.error_flag is the boolean; $errors is the
		# blob string. Either signals "this render errored." Count as 0/1 today;
		# LT-050 can bump to a real count.
		my $error_count = ($return_object->{flags}{error_flag}
			|| $return_object->{errors}) ? 1 : 0;

		Renderer::Telemetry::record_render(
			pg_hash   => $inputs_ref->{pg_hash},
			warnings  => $warning_count,
			errors    => $error_count,
			render_ms => $render_ms,
		);

		# Seed diversity: first-render only, error-free (an errored render's
		# html_hash carries the error template, not a content variant).
		if ($c->stash('_is_first_render') && !$error_count && defined $return_object->{text}) {
			my $html_hash = Renderer::Telemetry::content_hash(
				$return_object->{text}, $return_object->{answers});
			Renderer::Telemetry::record_seed_observation(
				pg_hash   => $inputs_ref->{pg_hash},
				seed      => $inputs_ref->{problemSeed},
				html_hash => $html_hash,
			) if $html_hash;
		}

		unless ($inputs_ref->{isInstructor}) {
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
	}

	return $c->format($return_object);
}

async sub render_ptx ($c) {

	$c->render_later;
	my $res = await WeBWorK::PreTeXt::render_ptx($c->req->params->to_hash);

	return $c->render(text => $res) unless ref($res) eq 'HASH';

	$c->res->headers->content_type('text/xml; charset=utf-8');
	return $c->render(template => 'RPCRenderFormats/ptx', %$res);
}

# POST /render-api/hint and POST /render-api/solution (WW3-R28).
# Content fetches gated by a typed problemJWT (typ='hint' or typ='solution').
# Same secret, same aud as any other problemJWT — only typ and the endpoint
# differ. The LMS makes the policy decision ("display this solution to this
# user now"); the renderer verifies the token and returns content.
#
# Pipeline mirrors the main /render-api lane but skips the trust mesh:
#   1. Lane::ContentFetch — verify+typ-check, merge claims onto params.
#   2. SourceResolver     — turn problemSourceURL / sourceFilePath /
#                           problemSource into resolved problemSource bytes.
#   3. HintSolution       — render-and-filter to extract hint/solution blocks.
#
# See WeBWorK::HintSolution for the render+filter pipeline,
# WeBWorK/Renderer/Content Fetch Token Model.md for the gate's design.
async sub _content_fetch ($c, $expected_typ, $renderer) {
	$c->render_later;

	my $params = $c->req->params->to_hash;
	Renderer::Lane::ContentFetch::apply($c, $params, $expected_typ) or return;

	# Resolve any of problemSourceURL / sourceFilePath / problemSource into
	# concrete bytes on $params->{problemSource}. Reuses the same content-cache
	# and OPL-lookup machinery the main render lane uses.
	my $resolved = await Renderer::Render::SourceResolver::resolve_source($c, $params);
	return unless $resolved;

	return $c->exception('Cannot render without problem source.', 400)
		unless defined $params->{problemSource} && length $params->{problemSource};
	return $c->exception('Missing required parameter: problemSeed', 400)
		unless defined $params->{problemSeed};

	my $res = await $renderer->({
		problemSource => $params->{problemSource},
		problemSeed   => $params->{problemSeed},
	});

	if (ref($res) eq 'HASH' && $res->{error}) {
		return $c->exception($res->{error}, $res->{status} // 500);
	}
	return $c->render(json => $res);
}

async sub hint ($c) {
	return await _content_fetch($c, 'hint', \&WeBWorK::HintSolution::render_hint);
}

async sub solution ($c) {
	return await _content_fetch($c, 'solution', \&WeBWorK::HintSolution::render_solution);
}

sub exception ($c, $message, $status, @extra) {
	my $id = $c->logID;
	$message = "[$id] " . (ref $message eq 'ARRAY' ? join "\n", @$message : $message);
	$c->log->error("($status) EXCEPTION: $message");
	$c->respond_to(
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
	# Return undef so `return $c->exception(...)` from a helper/lane causes
	# the caller's `or return` / `return unless $result` to bail. Without this,
	# respond_to's truthy return propagates up and the action continues past
	# the rendered exception, double-rendering. See WW3-R40.
	return undef;
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
	return $c->render(text => mint_jwt(
		$ENV{problemJWTsecret}, $inputs_ref,
		alg => 'PBES2-HS512+A256KW',
		enc => 'A256GCM',
	));
}

sub jwtFromRequest ($c) {
	my $inputs_ref = $c->parseRequest;
	return unless $inputs_ref;
	$inputs_ref->{aud} = $ENV{SITE_HOST};
	return $c->render(text => mint_jwt($ENV{problemJWTsecret}, $inputs_ref));
}

1;
