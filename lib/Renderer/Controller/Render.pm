package Renderer::Controller::Render;
use Mojo::Base 'Mojolicious::Controller', -async_await, -signatures;

# Core /render-api action plus the small content-fetch endpoints (hint,
# solution, answer, render_ptx).
#
# The heavy lifting lives in dedicated modules (extracted in WW3-R33):
#
#   * Renderer::Render::ParseRequest   — envelope parse + lane dispatch
#   * Renderer::Render::SourceResolver — problem source + cache flow
#   * Renderer::Render::AnswerURL      — answer-URL postback + verdict fold
#   * Renderer::Controller::Callback   — OPL callback endpoint
#
# This controller is the route-bound thin layer that orchestrates them.

use Mojo::JSON  qw(encode_json decode_json);
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
	my $inputs_ref   = $c->parseRequest;
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
	my $log_id         = $inputs_ref->{pg_hash} || $file_path || '(no-source-id)';
	my $ww_return_json = await render_in_subprocess(\$problem_contents, $inputs_ref, $log_id, $c->log);

	if (ref $ww_return_json eq 'HASH' && $ww_return_json->{_error}) {
		return $c->exception($ww_return_json->{_error}{message}, $ww_return_json->{_error}{status});
	}

	my $return_object;
	eval { $return_object = decode_json($ww_return_json); 1; } or do {
		$c->log->error('problem.render: Failed to parse JSON', $ww_return_json);
		# The renderer's own subprocess returned unparseable JSON — a server
		# fault, not a caller error, so this one stays a 500.
		return $c->exception(_pretty_error($@), 500);
	};
	$return_object->{inputs_ref} = $inputs_ref;

	# If answerURL provided, send the answerJWT (problem-lane) or submissionJWT
	# envelope (challenge-lane) back to the LMS on a graded submission.
	#
	# This used to also fire on a "ratchet flip" — a peek (showCorrectAnswers
	# without submit) reported to the LMS at render time. That path is gone: it
	# only ever fired on the problem lane (the challenge lane hard-zeroes
	# showCorrectAnswers), and ADAPT hides the reveal button so it never fired
	# there either. Reveals are recorded by WW3 at mint now, not inferred from
	# a render-time report. So the trigger is submit, full stop.
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
		my $displayScore = $return_object->{problem_result}{score};
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
		my $error_count =
			($return_object->{flags}{error_flag} || $return_object->{errors}) ? 1 : 0;

		Renderer::Telemetry::record_render(
			pg_hash   => $inputs_ref->{pg_hash},
			warnings  => $warning_count,
			errors    => $error_count,
			render_ms => $render_ms,
		);

		# `static` = "display, don't count." reView renders static (a read-only
		# replay of acts that already happened), so it is neither a fresh
		# content observation nor an interaction. One signal, both exclusions —
		# and the thing that stops reView logging phantom submits to OPL
		# (WW3-R49). record_render above is left universal: a reView IS an
		# honest render for code-path health, whoever asked for it.
		my $is_static = ($inputs_ref->{outputFormat} // '') eq 'static';

		# Seed diversity: first-render only, error-free (an errored render's
		# html_hash carries the error template, not a content variant), and
		# never a static replay. _is_first_render (no sessionJWT) already
		# excludes the play loop's resume/submit re-renders; `static` excludes
		# reView, which carries no sessionJWT and would otherwise read as first.
		if ($c->stash('_is_first_render') && !$error_count && !$is_static && defined $return_object->{text}) {
			my $html_hash = Renderer::Telemetry::content_hash($return_object->{text}, $return_object->{answers});
			Renderer::Telemetry::record_seed_observation(
				pg_hash   => $inputs_ref->{pg_hash},
				seed      => $inputs_ref->{problemSeed},
				html_hash => $html_hash,
			) if $html_hash;
		}

		# An interaction is an ACT — a graded submit, or a give-up (peeking at
		# the correct answer instead of finishing, which lumps with the
		# never-finished tail in the per-problem outcome distribution). A
		# reView is neither, so a static render records none.
		unless ($inputs_ref->{isInstructor} || $is_static) {
			if ($inputs_ref->{submitAnswers}) {
				Renderer::Telemetry::record_interaction(
					pg_hash => $inputs_ref->{pg_hash},
					action  => 'submit',
					score   => $return_object->{problem_result}{score},
					attempt => ($inputs_ref->{numIncorrect} // 0) + 1,
				);
			} elsif ($inputs_ref->{showCorrectAnswers}) {
				Renderer::Telemetry::record_interaction(
					pg_hash => $inputs_ref->{pg_hash},
					action  => 'show_answers',
				);
			}
		}
	}

	# If the client disconnected during the PG fork / async chain, Mojo has
	# already destroyed the transaction. Calling format() would invoke
	# url_for_file helpers that touch $c->req and croak "Transaction already
	# destroyed". No one is on the other end to receive the response anyway —
	# just drop the abandoned render quietly so the worker stays clean.
	return unless $c->tx;
	return $c->format($return_object);
}

async sub render_ptx ($c) {

	$c->render_later;
	my $res = await WeBWorK::PreTeXt::render_ptx($c->req->params->to_hash);

	# Client disconnect during the PreTeXt await tears down the tx; subsequent
	# $c->render / $c->res would croak. Drop the abandoned response.
	return unless $c->tx;

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

	# Custom/override macro injection — the source we just resolved may
	# loadMacros() files that live only in the content cache (e.g. ADAPT
	# problems pulling chemQuillMath.pl). Without this, PG's loadMacros
	# falls back to disk, fails for cache-only macros, and the response
	# silently degrades to solution: null. Mirrors the wiring at
	# Render::problem (Renderer/Controller/Render.pm in the main lane).
	my $injectedMacros;
	if ($params->{pg_hash}) {
		$injectedMacros = Renderer::ContentCache::get_injected_macros($params->{pg_hash});
		$c->log->info("Injecting " . scalar(keys %$injectedMacros) . " macro(s) via envir for $params->{pg_hash}")
			if $injectedMacros && %$injectedMacros;
	}

	my $res = await $renderer->({
		problemSource => $params->{problemSource},
		problemSeed   => $params->{problemSeed},
		($injectedMacros && %$injectedMacros ? (injectedMacros => $injectedMacros) : ()),
	});

	if (ref($res) eq 'HASH' && $res->{error}) {
		return $c->exception($res->{error}, $res->{status} // 500);
	}

	# Unified response shape: { status, message }. Matches $c->exception's
	# error shape so consumers can rely on a single contract across success
	# and failure — check `status`, read `message`. For solution, message is
	# the body HTML (or "" when the problem has no SOLUTION block). For hint,
	# message is the concatenation of all hint bodies in source order (or ""
	# when there are no HINT blocks).
	#
	# `answer` (WW3-R47) is the one shape that cannot use `message`: it is
	# per-blank structured data, not a body of HTML. It keeps `status` so
	# the error contract is still uniform — check `status`, then read
	# whichever payload key this endpoint documents.
	if ($expected_typ eq 'answer') {
		return unless $c->tx;
		return $c->render(json => { status => 200, answers => $res->{answers} // {} });
	}

	my $message = $expected_typ eq 'solution' ? ($res->{solution} // '') : join('', @{ $res->{hints} // [] });
	# Client disconnect during the renderer await tears down the tx; drop.
	return unless $c->tx;
	return $c->render(json => { status => 200, message => $message });
}

async sub hint ($c) {
	return await _content_fetch($c, 'hint', \&WeBWorK::HintSolution::render_hint);
}

async sub solution ($c) {
	return await _content_fetch($c, 'solution', \&WeBWorK::HintSolution::render_solution);
}

# POST /render-api/answer (WW3-R47). Same gate, same source binding, same
# error contract as its two siblings — only the payload differs.
#
# This is the route that lets an orchestrator stop asking the RENDER to
# reveal anything. `showCorrectAnswers` as a render flag has to be trusted
# from the request, which is how WW3-R46 happened; a typed token minted by
# whoever holds the policy cannot be self-declared, and the mint is a
# chokepoint the orchestrator can record against. See WW3-117.
async sub answer ($c) {
	return await _content_fetch($c, 'answer', \&WeBWorK::HintSolution::render_answer);
}

sub exception ($c, $message, $status, @extra) {
	my $id = $c->logID;
	$message = "[$id] " . (ref $message eq 'ARRAY' ? join "\n", @$message : $message);
	# Server faults (5xx) log at error; client refusals (4xx) at info. A bad
	# token or wrong audience is the caller's problem — logging it at error
	# buries real renderer faults under other people's mistakes (WW3-R50).
	my $level = $status >= 500 ? 'error' : 'info';
	$c->log->$level("($status) EXCEPTION: $message");
	# If the client disconnected during an async chain, the transaction is
	# already torn down. respond_to / res below would croak. Log the error
	# (which we already did above) and bail — no one is on the line.
	return undef unless $c->tx;
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

# _pretty_error($err) — the human-facing first line of a die/exception, with the
# Perl "at FILE line N" location stripped. $err may be a plain string or a
# Mojo::Exception (whose ->message carries the same first line).
sub _pretty_error ($err) {
	my $str = (ref $err && $err->can('message')) ? $err->message : "$err";
	my ($first) = split /\n/, $str;
	$first =~ s/\s+at\s+\S+\s+line\s+\d+.*$//;
	$first =~ s/^\s+|\s+$//g;
	return $first;
}

# credential_error($c, $err) — a caller presented a token the renderer will not
# accept. Always 401: a bad signature, wrong audience, expired, or malformed
# token is "fix your credential", never "the renderer broke" (WW3-R50). The four
# failures read differently to an operator, so the response names which one it
# is; the info-level log falls out of exception()'s status-aware logging.
sub credential_error ($c, $err) {
	my $msg  = _pretty_error($err);
	my $kind =
		  $msg =~ /\baud\b|audience/i     ? 'audience'
		: $msg =~ /signature|\bJW[SE]\b/i ? 'signature'
		: $msg =~ /expired|\bexp\b/i      ? 'expired'
		:                                   'malformed';
	return $c->exception("$msg ($kind)", 401);
}

1;
