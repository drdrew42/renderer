package Renderer::Controller::Render;
use Mojo::Base 'Mojolicious::Controller', -async_await, -signatures;

use Mojo::JSON   qw(encode_json decode_json);
use Time::HiRes  qw(time);
use Digest::SHA  qw(sha256_hex);

use Crypt::Ed25519;
use MIME::Base64 qw(decode_base64);
use File::Spec;
use WeBWorK::PreTeXt;
use WeBWorK::HintSolution;
use WeBWorK::VerdictJWT qw(verifyAndFoldVerdict);
use Renderer::ContentCache;
use Renderer::Registration;
use Renderer::Telemetry;
use Renderer::Render::Subprocess qw(render_in_subprocess);
use Renderer::Util::JWT qw(mint_jwt);
use Renderer::Lane::Session;
use Renderer::Lane::Problem;
use Renderer::Lane::Challenge;
use Renderer::Lane::Peer;
use Renderer::Lane::Ungrounded;
use Renderer::Constants qw(
	SENSITIVE_PARAMS
	ANSWER_RESPONSE_SUBJECT
	ANSWER_RESPONSE_DEFAULT_MESSAGE
);

sub parseRequest ($c) {
	my %params = %{ $c->req->params->to_hash };

	my $originIP = $c->req->headers->header('X-Forwarded-For')
		// '' =~ s!^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}).*$!$1!r;
	$originIP ||= $c->tx->remote_address || 'unknown-origin';

	# Three knobs govern renderer access (see Lane::Ungrounded for STRICT_JWT
	# and SELF_MINT_DISABLED, parseRequest's tail for the emission gate):
	#   1. Entry gate    (STRICT_JWT)            — may an ungrounded request render at all?
	#   2. Session UX    (SELF_MINT_DISABLED)    — wrap an admitted ungrounded request in a self-minted JWT?
	#   3. Emission gate (_can_emit_answer_jwt)  — may this request produce an answerJWT?
	# See WeBWorK3/Config and Secrets Evolution for rationale.

	# ─── Pre-dispatch validations ───────────────────────────────────────────

	# Protect against DOM manipulation.
	if (defined $params{submitAnswers} && defined $params{previewAnswers}) {
		$c->log->error('Simultaneous submit and preview! JWT: ', $params{problemJWT} // {});
		return $c->exception('Malformed request.', 400);
	}

	# Treat empty-string JWT params as not-present. Hidden form fields whose
	# backing value was undef render as `value=""`, which is `defined` but empty;
	# Crypt::JWT::decode_jwt rejects empty tokens with "missing token". Strip
	# them up front so the dispatcher below sees a clean envelope shape.
	for my $k (qw(problemJWT sessionJWT challengeJWT verdict_signed initial_state)) {
		delete $params{$k} if defined $params{$k} && !length $params{$k};
	}

	# initial_state: portal-supplied JSON serialization of the play's initial
	# navigation state (next_available, current_focus, draws[], finalization,
	# started_at). Per Lifecycle.md, the portal hands challenge_jwt +
	# initial_state to the renderer for sessionJWT_0 minting on first render.
	# Decoded into $params{state} so generatePlaySessionJWT picks it up
	# uniformly with the sessionJWT-decoded path.
	if (defined $params{initial_state} && !defined $params{sessionJWT}) {
		eval {
			my $decoded = decode_json($params{initial_state});
			$params{state} = $decoded if ref $decoded eq 'HASH';
			1;
		} or do {
			$c->log->warn("initial_state parse failed: $@");
		};
		delete $params{initial_state};
	}

	# challengeJWT and problemJWT are sibling trust lanes — never both at once.
	if (defined $params{challengeJWT} && defined $params{problemJWT}) {
		return $c->exception('Ambiguous envelope: both challengeJWT and problemJWT present.', 400);
	}

	# Render-time verdict fold (WW3-053). When the portal threads
	# verdict_signed through a render request — typically on the RESUME path
	# where /play/launch handed the portal session_jwt + verdict_signed — the
	# renderer mints sessionJWT_{k+1} folding the verdict before downstream
	# processing reads state. Replaces $params{sessionJWT} so Lane::Session's
	# decode below sees the verdict-folded state.
	#
	# Lives in parseRequest rather than Lane::Challenge because the fold
	# mutates sessionJWT (which Lane::Session decodes), so the operation
	# must run before the session prefix. It's a session-state concern that
	# requires challengeJWT for the play_id cross-check, not a challenge-
	# lane operation per se.
	if (defined $params{verdict_signed}) {
		return $c->exception('verdict_signed requires sessionJWT.', 400)
			unless defined $params{sessionJWT};
		return $c->exception('verdict_signed requires challengeJWT.', 400)
			unless defined $params{challengeJWT};

		my ($folded, $err) = verifyAndFoldVerdict(
			$params{sessionJWT},
			$params{verdict_signed},
			$ENV{problemJWTsecret},
			$ENV{webworkJWTsecret},
		);
		if ($err) {
			$c->log->error("verdict_signed fold rejected: $err");
			return $c->exception("verdict_signed: $err", 400);
		}
		$params{sessionJWT} = $folded;
		$c->stash(_verdict_folded => 1);
		delete $params{verdict_signed};
	}

	# Reject raw-param pg_hash + problemSource without an upstream JWT —
	# legitimate callers carry pg_hash inside the JWT; the bare combo is
	# attacker-shaped (rendering chosen source under a cached identity).
	if (defined $params{pg_hash} && defined $params{problemSource}
		&& !defined $params{problemJWT} && !defined $params{sessionJWT})
	{
		$c->log->error('pg_hash + problemSource without JWT — rejecting.');
		return $c->exception('Malformed request.', 400);
	}

	# Peer-signed verification. Runs early (before SENSITIVE_PARAMS strip and
	# Lane::Session) so peer-signed parent_origin can be captured before the
	# strip. On bad signature, returns a 401 exception.
	Renderer::Lane::Peer::verify($c) or return;

	# Translate the peer-facing `formAction` field to the internal `formURL`
	# name honored by FormatRenderedProblem. Editor-providers specify "send
	# form submits back to me" in their mental model.
	if (defined $params{formAction}) {
		$params{formURL} //= delete $params{formAction};
	}

	# parent_origin: peer-signed lane carries it in the signed body; capture
	# before the SENSITIVE_PARAMS strip and restore after dispatch. JWT lane
	# recovers it via Lane::Problem's claim merge (claim wins) — no special
	# handling needed there.
	my $peer_parent_origin = $c->stash('_peer_signed') ? delete $params{parent_origin} : undef;

	# Normalize common lowercase query params to camelCase before JWT processing.
	$params{outputFormat}  //= delete $params{outputformat}  if exists $params{outputformat};
	$params{displayMode}   //= delete $params{displaymode}   if exists $params{displaymode};
	$params{problemSeed}   //= delete $params{problemseed}   if exists $params{problemseed};

	# Stash flags consumed by downstream phases.
	$c->stash(_is_first_render => !defined $params{sessionJWT} ? 1 : 0);
	$c->stash(_no_cache        => $params{noCache} ? 1 : 0);

	# Strip security-sensitive params. Anything in this list can ONLY be
	# (re)introduced via a trusted source (JWT claim, peer-signed body).
	for (SENSITIVE_PARAMS) {
		delete $params{$_};
	}

	# ─── Session prefix ─────────────────────────────────────────────────────
	# sessionJWT decode + claim merge. Combines with any body lane.

	if (defined $params{sessionJWT}) {
		Renderer::Lane::Session::apply_prefix($c, \%params) or return;
	}

	# ─── Body-lane dispatch ─────────────────────────────────────────────────
	# Envelope shape selects the body lane. Order matches the historical
	# elsif chain: problemJWT and challengeJWT are mutually exclusive
	# (rejected pre-dispatch); peer-signed body fires when peer-verified
	# AND no JWT body; ungrounded covers the rest unless outputFormat=ptx
	# (PTX path skips body-lane entirely — no JWT minted, no defaults).

	if (defined $params{problemJWT}) {
		Renderer::Lane::Problem::apply($c, \%params) or return;
	} elsif (defined $params{challengeJWT}) {
		Renderer::Lane::Challenge::apply($c, \%params) or return;
	} elsif ($c->stash('_peer_signed')) {
		Renderer::Lane::Peer::apply_body($c, \%params) or return;
	} elsif ($params{outputFormat} ne 'ptx') {
		Renderer::Lane::Ungrounded::apply($c, \%params) or return;
	}

	# ─── Post-dispatch ──────────────────────────────────────────────────────

	$params{originIP} = $originIP if $originIP;

	# Restore peer-signed parent_origin (captured before the strip above).
	# The JWT lane recovers parent_origin via the generic claim merge;
	# the peer-signed lane has no such merge, so we reapply explicitly.
	$params{parent_origin} //= $peer_parent_origin if defined $peer_parent_origin;

	# Emission gate, fail-fast (WW3-R03). Reject submits that arrived without
	# upstream grounding before the PG fork, rather than after a full render.
	# _can_emit_answer_jwt is set only by problemJWT / challengeJWT / sessionJWT
	# carrying upstream context — self-mint and peer-signed lanes never set it.
	# A late belt-and-suspenders check survives at the dispatch site; this one
	# is the primary gate.
	if ($params{submitAnswers} && !$c->stash('_can_emit_answer_jwt')) {
		return $c->exception(
			'Submit requires a problemJWT, challengeJWT, or sessionJWT.', 403,
		);
	}

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
	my %meta = (
		origin   => $c->req->headers->origin,
		referrer => $c->req->headers->referrer,
	);

	my $client = $c->opl_client;
	return $client->fetch_problem_p($url, etag => $pg_hash, request_meta => \%meta)->then(sub {
		my $result = shift;

		# 304 Not Modified — use cached source.
		if ($result->{not_modified} && $pg_hash) {
			my $cached_source = Renderer::ContentCache::read_problem($pg_hash);
			if ($cached_source) {
				$c->log->info("ContentCache 304: $pg_hash");
				$c->stash(_cache_status => 'miss_304');
				return ($cached_source, $pg_hash);
			}
			# Cache index thought we had it (we sent If-None-Match) but the
			# bytes are missing on disk. Force an unconditional re-fetch.
			$c->log->warn("ContentCache 304 but disk miss for $pg_hash — retrying unconditional");
			return $client->fetch_problem_p($url, request_meta => \%meta)->then(sub {
				my $retry = shift;
				return (undef, undef) if $retry->{error} || $retry->{not_modified};
				return _stage_problem_response($c, $retry, $url);
			});
		}

		if ($result->{error}) {
			return (undef, undef);
		}

		return _stage_problem_response($c, $result, $url);
	});
}

# Stage the OPL response into the disk cache and return (raw_source, hash).
# Filters macros by source_type before staging — current renderer-side semantic
# is "inject custom + override only." The filtering rule lives here, not in
# OPLClient (per R12 design: client captures verbatim, controller decides what
# to do with it).
sub _stage_problem_response ($c, $result, $url) {
	my $raw_source   = $result->{raw_source};
	my $fetched_hash = $result->{pg_hash};
	my $client       = $c->opl_client;

	my @macros_to_link;
	for my $macro (@{ $result->{macros} // [] }) {
		next unless $macro->{hash} && $macro->{source_type}
			&& ($macro->{source_type} eq 'custom' || $macro->{source_type} eq 'override');

		my $cache_hash = $macro->{hash};

		unless (-f "$ENV{RENDER_ROOT}/private/macros/$cache_hash") {
			if ($macro->{url}) {
				$c->log->info("Fetching macro $macro->{name}: $macro->{url}");
				my ($source_bytes, $canonical_hash) = $client->fetch_macro($macro->{url});
				if (defined $source_bytes) {
					if ($canonical_hash && $canonical_hash ne $macro->{hash}) {
						$c->log->info("Macro $macro->{name}: redirected $macro->{hash} → $canonical_hash");
						$cache_hash = $canonical_hash;
					}
					Renderer::ContentCache::stage_macro($cache_hash, $source_bytes);
				} else {
					$c->log->warn("ContentCache: failed to fetch macro $macro->{name}");
				}
			}
		}

		push @macros_to_link, {
			name        => $macro->{name},
			hash        => $cache_hash,
			source_type => $macro->{source_type},
		};
	}

	Renderer::ContentCache::stage_problem($fetched_hash, $raw_source, \@macros_to_link);
	Renderer::ContentCache::save_url_index($url, $fetched_hash);
	$c->log->info("ContentCache STAGED: $fetched_hash from $url");
	$c->stash(_cache_status => 'miss_200');

	return ($raw_source, $fetched_hash);
}

# Legacy fetch: no caching, no macro staging — just the raw_source field
# from a JSON response. Returns a promise resolving to source bytes or undef.
sub _fetch_legacy_p ($c, $url) {
	my %meta = (
		origin   => $c->req->headers->origin,
		referrer => $c->req->headers->referrer,
	);
	return $c->opl_client->fetch_problem_p($url, request_meta => \%meta)->then(sub {
		my $result = shift;
		return undef if $result->{error} || $result->{not_modified};
		return $result->{raw_source};
	});
}

sub resolveSourceFilePath_p ($c, $file_path, $pg_hash_hint = undef) {

	# Normalize: strip leading private/ if present (Problem.pm adds it)
	my $normalized = $file_path;
	$normalized =~ s!^private/!!;

	# 1. Path index + cache — zero network (unless noCache)
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

	# 2. OPL lookup — delegate to existing fetch flow with client-built URL
	my $opl_url = $c->opl_client->problem_url_by_path($normalized);

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
		&& $inputs_ref->{sourceFilePath})
	{
		if ($inputs_ref->{problemSource}) {
			# Editor preview: use the editor's source but resolve the path
			# for macro dependencies (pg_hash → injectedMacros at render time).
			my (undef, $pg_hash) = await resolveSourceFilePath_p(
				$c, $inputs_ref->{sourceFilePath}, $inputs_ref->{pg_hash}
			);
			if ($pg_hash) {
				$inputs_ref->{pg_hash} = $pg_hash;
				$inputs_ref->{sourceFilePath} = Renderer::ContentCache::problem_path($pg_hash);
			}
			# problemSource stays as-is (the editor's live edit)
		} else {
			# Normal content-addressed render: fetch source + macros from OPL.
			my ($source, $pg_hash) = await resolveSourceFilePath_p(
				$c, $inputs_ref->{sourceFilePath}, $inputs_ref->{pg_hash}
			);
			if ($source && $pg_hash) {
				$inputs_ref->{problemSource}  = $source;
				$inputs_ref->{sourceFilePath} = Renderer::ContentCache::problem_path($pg_hash);
				$inputs_ref->{pg_hash}        = $pg_hash;
			} else {
				return $c->exception("Cannot resolve sourceFilePath: $inputs_ref->{sourceFilePath}", 404);
			}
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
		# Emission gate (belt-and-suspenders). The primary guard fires earlier
		# in parseRequest (WW3-R03) so ungrounded submits don't pay the PG-fork
		# cost; this re-check survives as defense-in-depth in case some future
		# lane plumbs JWTanswerURL into %params without setting the stash flag.
		# Self-minted JWTs do not qualify — see parseRequest. This gate is
		# orthogonal to STRICT_JWT, which governs whether ungrounded requests
		# are accepted at all. Ref: WeBWorK3/Config and Secrets Evolution.
		unless ($c->stash('_can_emit_answer_jwt')) {
			$c->log->error('Student submit without upstream JWT — rejecting answer emission.');
			return $c->exception('Submit requires a problemJWT, challengeJWT, or sessionJWT.', 403);
		}
		if ($return_object->{submissionJWT}) {
			# challengeJWT path: POST {type, session_jwt, submission_jwt} envelope
			# to challengeJWT.answer_url (per Answer-URL Contract).
			my $envelope_body = encode_json({
				type           => 'submission',
				session_jwt    => $return_object->{sessionJWT},
				submission_jwt => $return_object->{submissionJWT},
			});
			my $resp = await post_to_answer_url($c, $inputs_ref->{JWTanswerURL}, $envelope_body);

			# Post-answer-URL verdict fold (WW3-053). When the orchestrator
			# returns verdict_signed alongside the verdict, mint
			# sessionJWT_{k+1} folding it. Same primitive as the render-time
			# fold in parseRequest — different source of verdict_signed (HTTP
			# response body vs form param), identical fold semantics. The
			# result replaces $return_object->{sessionJWT} so the rendered
			# JSON envelope's JWT.session carries the verdict-folded mint.
			#
			# Skip the fold on:
			#   - rejected/error responses (no verdict to fold; keep the
			#     pre-POST mint as the surfaced session)
			#   - missing verdict_signed (orchestrator below WW3-053 cutover,
			#     or non-WW3 answer_url targets — graceful degradation: the
			#     pre-POST mint stays surfaced, system catches up on next
			#     interaction via stale-recovery)
			if ($resp->{verdict_signed}) {
				my ($folded, $err) = verifyAndFoldVerdict(
					$return_object->{sessionJWT},
					$resp->{verdict_signed},
					$ENV{problemJWTsecret},
					$ENV{webworkJWTsecret},
				);
				if ($err) {
					$c->log->error("post-answer-URL verdict fold rejected: $err");
					# Don't fail the whole render — the submission landed and
					# the pre-POST mint is still a valid sessionJWT (just one
					# verdict behind). Stale-recovery handles the catch-up.
				} else {
					$return_object->{sessionJWT} = $folded;
				}
			}

			$return_object->{JWTanswerURLstatus} = encodeAnswerStatus($resp);
		} else {
			# Legacy problemJWT path: POST raw answerJWT to JWTanswerURL as
			# text/plain. The body is the JWT string itself (not a JSON envelope).
			my $resp = await post_to_answer_url(
				$c,
				$inputs_ref->{JWTanswerURL},
				$return_object->{answerJWT},
				content_type => 'text/plain',
			);
			$return_object->{JWTanswerURLstatus} = encodeAnswerStatus($resp);
		}
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
		# By this point we've passed the render's _error early-return, so the
		# only remaining outcome distinction is "warning" vs "success" based on
		# whether PG emitted warning_messages during the run.
		my $outcome = @{ $return_object->{warning_messages} // [] } ? 'warning' : 'success';
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

	unless (defined $inputs{problemSource} && $inputs{problemSource} =~ /\S/) {
		$CALLBACK_SEMAPHORE--;
		return $c->render(json => { outcome => 'error', warnings => 0, error => 'missing pg_source' }, status => 200);
	}

	my $ww_return_json = eval {
		await render_in_subprocess(\$inputs{problemSource}, \%inputs, 'callback', $c->log);
	};
	my $eval_err = $@;
	$CALLBACK_SEMAPHORE--;

	if ($eval_err) {
		return $c->render(json => { outcome => 'error', warnings => 0, error => "$eval_err" }, status => 200);
	}
	if (ref $ww_return_json eq 'HASH' && $ww_return_json->{_error}) {
		return $c->render(json => { outcome => 'error', warnings => 0, error => $ww_return_json->{_error}{message} }, status => 200);
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

# POST /render-api/hint and POST /render-api/solution (WW3-R28).
# Pure dumb content fetches: render with the appropriate flag, extract
# just the hint/solution divs, return as JSON. Bypasses parseRequest;
# mints nothing, POSTs nothing, emits no events. The LMS/orchestrator
# gates user access at its own UI layer — the renderer is dumb about
# who's allowed to read what. See WeBWorK::HintSolution for the
# implementation and lib/WeBWorK/Renderer/Render-Only Hint and Solution
# Modes.md for the design rationale.
async sub hint ($c) {
	$c->render_later;

	my $params = $c->req->params->to_hash;
	return $c->exception('Missing required parameter: problemSource', 400)
		unless defined $params->{problemSource} && length $params->{problemSource};
	return $c->exception('Missing required parameter: problemSeed', 400)
		unless defined $params->{problemSeed};

	my $res = await WeBWorK::HintSolution::render_hint({
		problemSource => $params->{problemSource},
		problemSeed   => $params->{problemSeed},
	});

	if (ref($res) eq 'HASH' && $res->{error}) {
		return $c->exception($res->{error}, $res->{status} // 500);
	}
	return $c->render(json => $res);
}

async sub solution ($c) {
	$c->render_later;

	my $params = $c->req->params->to_hash;
	return $c->exception('Missing required parameter: problemSource', 400)
		unless defined $params->{problemSource} && length $params->{problemSource};
	return $c->exception('Missing required parameter: problemSeed', 400)
		unless defined $params->{problemSeed};

	my $res = await WeBWorK::HintSolution::render_solution({
		problemSource => $params->{problemSource},
		problemSeed   => $params->{problemSeed},
	});

	if (ref($res) eq 'HASH' && $res->{error}) {
		return $c->exception($res->{error}, $res->{status} // 500);
	}
	return $c->render(json => $res);
}

# Single helper for the renderer's answer-URL POSTs. Both lanes — legacy
# problemJWT (raw JWT body, text/plain) and challengeJWT (JSON envelope,
# application/json) — share the same UA setup, default-response shape, and
# success/failure handling. The only differences are the body format and
# content-type, both controlled by callers.
#
# Always resolves to a hashref. Caller decides what to do with it:
# legacy lane runs encodeAnswerStatus and stores the JS-safe string in
# JWTanswerURLstatus; challengeJWT lane consults $resp->{verdict_signed}
# for the post-POST fold before encoding.
async sub post_to_answer_url ($c, $url, $body, %opts) {
	my $headers = {
		Origin         => $ENV{SITE_HOST},
		'Content-Type' => $opts{content_type} // 'application/json',
	};

	my $response = {
		subject => ANSWER_RESPONSE_SUBJECT,
		message => ANSWER_RESPONSE_DEFAULT_MESSAGE,
	};

	$c->log->info("POSTing to $url");
	await $c->ua->max_redirects(5)->request_timeout(7)->post_p($url, $headers, $body)->then(sub {
		my $tx = shift->result;
		$response->{status} = int($tx->code);
		# answerURL responses are expected to be JSON; fall back to body-as-message.
		if ($tx->json) {
			$response = { %$response, %{ $tx->json } };
		} else {
			$response->{message} = $tx->body;
		}
	})->catch(sub {
		my $err = shift;
		$c->log->error($err);
		$response->{status}  = 500;
		$response->{message} = '[' . $c->logID . '] ' . $err;
	});

	$c->log->info("answer-URL response " . encode_json($response));
	return $response;
}

# Encode a response hashref as the JSON string that goes into the
# JWTanswerURLstatus hidden form field. Mojo's `hidden_field` helper handles
# HTML-attribute escaping in default.html.ep — no JS-source-literal escape
# is needed: the client reads `.value` and JSON.parses, so single quotes in
# the payload round-trip unmolested.
sub encodeAnswerStatus ($response) {
	return encode_json($response);
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
