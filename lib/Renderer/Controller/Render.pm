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
use WeBWorK::VerdictJWT qw(verifyAndFoldVerdict);
use Renderer::ContentCache;
use Renderer::Registration;
use Renderer::Telemetry;

sub parseRequest ($c) {
	my %params = %{ $c->req->params->to_hash };

	my $originIP = $c->req->headers->header('X-Forwarded-For')
		// '' =~ s!^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}).*$!$1!r;
	$originIP ||= $c->tx->remote_address || 'unknown-origin';

	# Three knobs govern renderer access:
	#   1. Entry gate    (STRICT_JWT)            — may this ungrounded request render at all?
	#   2. Session UX    (SELF_MINT_DISABLED)    — should we wrap this render in a self-minted JWT?
	#   3. Emission gate (_can_emit_answer_jwt)  — may this request produce an answerJWT?
	#
	# (1) STRICT_JWT=1 rejects ungrounded requests at the door (public/student instances
	# that expect all callers to arrive with a peer-minted problemJWT or sessionJWT).
	# STRICT_JWT=0 admits ungrounded requests — typically paired with a network-isolated
	# deployment (e.g. ADAPT's VPC-only editor renderer) that treats the network as the
	# trust boundary.
	#
	# (2) Self-minting is the renderer's UX opinion: when an ungrounded request is
	# admitted, encapsulate its inputs in a problemJWT so subsequent renders flow
	# through the standard sessionJWT round-trip without the consumer re-mailing
	# every parameter (isInstructor, sessionID, etc.). Default ON. Set
	# SELF_MINT_DISABLED=1 for raw-passthrough deployments that don't want a JWT
	# materialized on their behalf.
	#
	# (3) The emission gate is always active: only requests carrying an upstream JWT
	# can produce answerJWTs. Self-minted JWTs cannot carry JWTanswerURL (it's
	# stripped from raw params and only re-injected from upstream claims), so they
	# can't ground answer emission even after a sessionJWT round-trip.
	#
	# See WeBWorK3/Config and Secrets Evolution for rationale.

	# protect against DOM manipulation
	if (defined $params{submitAnswers} && defined $params{previewAnswers}) {
		$c->log->error('Simultaneous submit and preview! JWT: ', $params{problemJWT} // {});
		return $c->exception('Malformed request.', 400);
	}

	# Treat empty-string JWT params as not-present. Hidden form fields whose
	# backing value was undef render as `value=""`, which is `defined` but empty;
	# Crypt::JWT::decode_jwt rejects empty tokens with "missing token". Strip
	# them up front so the elsif chain below dispatches as if they weren't sent.
	for my $k (qw(problemJWT sessionJWT challengeJWT verdict_signed)) {
		delete $params{$k} if defined $params{$k} && !length $params{$k};
	}

	# challengeJWT and problemJWT are sibling trust lanes — never both at once.
	# challengeJWT is the play-level definition (WW3 orchestrator-minted);
	# problemJWT is the legacy per-problem envelope (LibreTexts/ADAPT).
	# Pick one.
	if (defined $params{challengeJWT} && defined $params{problemJWT}) {
		return $c->exception('Ambiguous envelope: both challengeJWT and problemJWT present.', 400);
	}

	# Render-time verdict fold (WW3-053). When the portal threads
	# verdict_signed through a render request — typically on the RESUME path,
	# where /play/launch handed the portal session_jwt + verdict_signed — the
	# renderer mints sessionJWT_{k+1} folding the verdict before downstream
	# processing reads state. This is essential for open-mode plays where
	# state.draws[] must include the just-allocated draw before the renderer
	# can resolve the seed for current_focus. For closed-mode it keeps the
	# trust envelope coherent: sessionJWT.state matches the position the
	# portal asked us to render. The fold replaces $params{sessionJWT} so
	# the existing sessionJWT decode (below) sees verdict-folded state.
	#
	# Requires both challengeJWT and sessionJWT to be present alongside
	# verdict_signed — verdict_signed is meaningful only on the challengeJWT
	# lane and only against an existing base session.
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
		# verdict_signed was a one-shot input; remove from params so it
		# doesn't accidentally shadow downstream reads or get logged.
		delete $params{verdict_signed};
	}

	# Reject raw-param pg_hash paired with raw-param problemSource when no upstream
	# JWT is present. Legitimate callers carry pg_hash inside the JWT; this combo
	# in the clear suggests an attempt to render attacker-chosen source under a
	# cached problem's identity.
	if (defined $params{pg_hash} && defined $params{problemSource}
		&& !defined $params{problemJWT} && !defined $params{sessionJWT})
	{
		$c->log->error('pg_hash + problemSource without JWT — rejecting.');
		return $c->exception('Malformed request.', 400);
	}

	# Peer-signed lane (Stage 1): verify X-Peer-Signature header over the canonical
	# request form. On success, this request is trusted as coming from a registered
	# mesh peer — it bypasses the JWT entry gate but NOT the answerJWT emission gate.
	# Raw problemSource arriving on this lane is one-shot: no sessionJWT, no
	# answerJWT, no pg_hash leak to the browser. See
	# [[WeBWorK/Renderer/Trust Model and Editor Flow]].
	{
		my $peer_name = $c->req->headers->header('X-Peer-Name');
		my $peer_ts   = $c->req->headers->header('X-Peer-Timestamp');
		my $peer_sig  = $c->req->headers->header('X-Peer-Signature');
		if (defined $peer_name || defined $peer_ts || defined $peer_sig) {
			my %result = Renderer::Registration::verify_peer_signature(
				method    => $c->req->method,
				path      => $c->req->url->path->to_string,
				timestamp => $peer_ts // '',
				body      => $c->req->body,
				peer_name => $peer_name // '',
				signature => $peer_sig // '',
			);
			unless ($result{ok}) {
				$c->log->error("Peer signature verification failed: $result{reason}");
				return $c->exception("Peer signature rejected: $result{reason}", 401);
			}
			$c->log->info("Peer-signed request accepted from '$peer_name'");
			$c->stash(_peer_signed => $peer_name);
		}
	}

	# Translate the peer-facing `formAction` field to the internal `formURL` name
	# honored by FormatRenderedProblem. This lets editor-providers specify
	# "send form submits back to me" in a name that matches their mental model.
	# Applies to any request; unused formAction would otherwise leak into
	# downstream params / telemetry.
	if (defined $params{formAction}) {
		$params{formURL} //= delete $params{formAction};
	}

	# parent_origin declares where the rendered iframe's postMessage broadcasts
	# are authorized to target (portal URL / editor-provider origin). Only
	# accepted from trusted sources:
	#   - Peer-signed lane: carried in the signed body form-data; captured here
	#     before the param strip below and restored after JWT processing.
	#   - JWT lane: carried as a claim; merged into $params via the generic
	#     claim merge below (no special handling needed).
	# Raw URL/body params without a trust signal are stripped alongside the
	# other security-sensitive claims below.
	my $peer_parent_origin = $c->stash('_peer_signed') ? delete $params{parent_origin} : undef;

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
	for (qw(JWTanswerURL sessionID numCorrect numIncorrect parent_origin)) {
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

		# Security-sensitive claims from the session always win over raw params.
		# Prevents students from injecting isLocked=0 or isInstructor=1 via POST.
		# showCorrectAnswers is the reveal trigger (solutions ride along);
		# once the session records a reveal, the caller can't claw it back.
		for (qw(isLocked isInstructor showCorrectAnswers answersSubmitted)) {
			$params{$_} = $claims->{$_} if exists $claims->{$_};
		}

		# For all other claims, raw params win (e.g. current responses vs prior).
		# problemJWT must come from session to maintain consistency.
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
		# Mark this request as upstream-JWT-bearing — required to produce answerJWTs.
		$c->stash(_can_emit_answer_jwt => 1);
	} elsif (defined $params{challengeJWT}) {
		# challengeJWT trust lane (WW3-032). The challengeJWT is the static play
		# definition minted by the WW3 orchestrator; we decode, locate the
		# requested position, and hoist its render context. Atom evaluation lives
		# orchestrator-side (Architecture B), so `mode` and `constraints` are
		# carried but not consumed here. The portal supplies `position` to pick
		# which problem in the pool to render.
		$c->log->info("Received JWT: using challengeJWT");
		my $claims;
		eval {
			$claims = decode_jwt(
				token      => $params{challengeJWT},
				key        => $ENV{problemJWTsecret},
				verify_aud => $ENV{SITE_HOST},
			);
			1;
		} or do {
			return $c->croak($@, 3);
		};

		my $position = $params{position};
		return $c->exception('challengeJWT requires a position parameter.', 400)
			unless defined $position && $position =~ /^\d+$/;

		my $problems = $claims->{problems} // [];
		return $c->exception("position $position out of range (have @{[ scalar @$problems ]} problems).", 400)
			if $position >= scalar @$problems;

		my $entry = $problems->[$position];
		my $pg_hash = $entry->{pg_hash}
			or return $c->exception('challengeJWT problem entry missing pg_hash.', 400);

		# Seed resolution: closed challenges carry the seed in the JWT;
		# open challenges carry "*" and the resolved seed lives in the
		# inbound sessionJWT's state.draws[draw_position == position] entry.
		my $seed = $entry->{seed};
		if (!defined $seed || $seed eq '*') {
			my $draws = $params{state} && ref $params{state} eq 'HASH'
				? ($params{state}{draws} // [])
				: [];
			my ($draw) = grep { defined $_->{draw_position} && $_->{draw_position} == $position } @$draws;
			return $c->exception("Open challenge: no draw recorded for position $position.", 400)
				unless $draw && defined $draw->{seed};
			$seed = $draw->{seed};
			# In open mode the active pg_hash also lives on the draw record
			# (the pool entry is one of many; the draw pinned which one).
			$pg_hash = $draw->{pg_hash} if defined $draw->{pg_hash};
		}

		# Hoist render context.
		$params{pg_hash}     = $pg_hash;
		$params{problemSeed} = $seed;

		# challengeJWT carries pg_hash but no source URL — synthesize one from
		# OPL's content-addressed hash route. Mirrors the problemJWT flow
		# (commit 2575e78 in ww3) which builds problemSourceURL from pg_hash
		# for the same reason. Without this, sub problem has neither
		# problemSourceURL nor sourceFilePath and can't fetch the source.
		# OPL exposes /api/problems/hash/<pg_hash> for content-hash lookup
		# (Library.pm:281-282). Caller can override OPL_API_URL via env.
		#
		# Skip when the caller supplied raw problemSource — that path is the
		# editor preview / test bypass and shouldn't trigger an OPL fetch.
		# Mirrors the existing precedence: $params{problemSource} present
		# means "use this source verbatim, don't go to network."
		unless (defined $params{problemSource}) {
			my $opl_base = $ENV{OPL_API_URL} || 'http://webwork-opl:3000';
			$params{problemSourceURL} = "$opl_base/api/problems/hash/$pg_hash";
		}

		# Render permissions are attempt-wide flags. Apply just the renderer-
		# visible fields; everything else (e.g. duration_anchor) is orchestrator
		# concern. Permission claims override raw form values — same precedence
		# as the problemJWT path.
		if (my $rp = $claims->{render_permissions}) {
			for my $k (qw(isInstructor showCorrectAnswers showHints showSolutions)) {
				$params{$k} = $rp->{$k} if defined $rp->{$k};
			}
		}
		$params{isInstructor} //= 0;

		# Identity claims propagate into the submissionJWT.
		for my $k (qw(play_id challenge_id chain_student_id assignment_id)) {
			$params{$k} = $claims->{$k} if defined $claims->{$k};
		}

		# Stamp the answer endpoint so submissionJWTs land at the orchestrator,
		# not at any legacy answerURL the client might have tried to inject.
		return $c->exception('challengeJWT missing answer_url.', 400)
			unless defined $claims->{answer_url};
		$params{JWTanswerURL} = $claims->{answer_url};

		# outputFormat lock: WW3-028 deliberately ships challengeJWT WITHOUT an
		# outputFormat claim (preserves the 99bc18f leak fix). The challengeJWT
		# path is iframe-render-only; "simple" is the only safe value. Lock it
		# here, overriding any URL-injected value.
		$params{outputFormat} = 'simple';

		# Mark this request as upstream-JWT-bearing — required to emit
		# submissionJWTs (the challengeJWT-path analog of answerJWTs).
		$c->stash(_can_emit_answer_jwt => 1);
	} elsif ($c->stash('_peer_signed')) {
		# Peer-signed lane: the peer authorized this render directly. No JWT needed
		# and none is minted — peer-signed raw-source renders are one-shot with no
		# browser-carried continuation token. _can_emit_answer_jwt stays unset.
		# Set aud for any downstream code that reads it.
		$params{aud} = $ENV{SITE_HOST};
		$params{isInstructor} //= 0;
		$params{sessionID} ||= time;
	} elsif ($params{outputFormat} ne 'ptx') {
		# Entry gate (STRICT_JWT): block ungrounded requests at the door for
		# instances that only serve authorized upstream consumers.
		if ($ENV{STRICT_JWT}) {
			return $c->exception('Request requires a problemJWT, sessionJWT, or X-Peer-Signature.', 401);
		}
		# Session UX (default on; SELF_MINT_DISABLED=1 to opt out): wrap the
		# inbound params in a self-minted problemJWT so the next render flows
		# through the standard sessionJWT round-trip without the consumer
		# re-mailing isInstructor / sessionID / etc. Self-minted JWTs carry no
		# JWTanswerURL, so _can_emit_answer_jwt stays unset and answerJWTs
		# cannot be produced even after round-tripping.
		unless ($ENV{SELF_MINT_DISABLED}) {
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
	}
	$params{originIP} = $originIP if $originIP;

	# Restore peer-signed parent_origin (captured before the strip above).
	# The JWT lane recovers parent_origin via the generic claim merge;
	# the peer-signed lane has no such merge, so we reapply explicitly.
	$params{parent_origin} //= $peer_parent_origin if defined $peer_parent_origin;

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
		&& $inputs_ref->{sourceFilePath})
	{
		if ($inputs_ref->{problemSource}) {
			# Editor preview: use the editor's source but resolve the path
			# for macro dependencies (pg_hash → injectedMacros at render time).
			my ($source, $pg_hash, $disk_path) = await resolveSourceFilePath_p(
				$c, $inputs_ref->{sourceFilePath}, $inputs_ref->{pg_hash}
			);
			if ($pg_hash) {
				$inputs_ref->{pg_hash} = $pg_hash;
				$inputs_ref->{sourceFilePath} = Renderer::ContentCache::problem_path($pg_hash);
			}
			# problemSource stays as-is (the editor's live edit)
		} else {
			# Normal content-addressed render: fetch source + macros from OPL.
			my ($source, $pg_hash, $disk_path) = await resolveSourceFilePath_p(
				$c, $inputs_ref->{sourceFilePath}, $inputs_ref->{pg_hash}
			);
			if ($disk_path) {
				$inputs_ref->{sourceFilePath} = $disk_path;
			} elsif ($source && $pg_hash) {
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

	# If answerURL provided and this is a student submit, send the answerJWT
	# (legacy problemJWT path) or submissionJWT envelope (challengeJWT path).
	# Instructors never produce answer JWTs — their interactions are exploratory.
	if ($inputs_ref->{JWTanswerURL} && $inputs_ref->{submitAnswers}
		&& !$inputs_ref->{isLocked} && !$inputs_ref->{isInstructor}) {
		# Emission gate: an answerJWT/submissionJWT is only produced when the
		# request arrived with an upstream-minted problemJWT, challengeJWT, or
		# sessionJWT carrying one. Self-minted JWTs do not qualify — see
		# parseRequest. This gate is orthogonal to STRICT_JWT, which governs
		# whether ungrounded requests are accepted at all.
		# Ref: WeBWorK3/Config and Secrets Evolution.
		unless ($c->stash('_can_emit_answer_jwt')) {
			$c->log->error('Student submit without upstream JWT — rejecting answer emission.');
			return $c->exception('Submit requires a problemJWT, challengeJWT, or sessionJWT.', 403);
		}
		if ($return_object->{submissionJWT}) {
			# challengeJWT path: POST {type, session_jwt, submission_jwt} envelope
			# to challengeJWT.answer_url (per Answer-URL Contract).
			my $resp = await sendSubmissionEnvelope(
				$c,
				$inputs_ref->{JWTanswerURL},
				$return_object->{sessionJWT},
				$return_object->{submissionJWT},
			);

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
			# Legacy problemJWT path: POST raw answerJWT to JWTanswerURL.
			$return_object->{JWTanswerURLstatus} =
				await sendAnswerJWT($c, $inputs_ref->{JWTanswerURL}, $return_object->{answerJWT});
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

# challengeJWT path: POST a JSON envelope { type, session_jwt, submission_jwt }
# to challengeJWT.answer_url. The orchestrator (WW3) runs atom evaluation and
# returns a verdict; we surface the response so the post-POST verdict fold
# (WW3-053) can mint sessionJWT_{k+1} in the caller, and the JS-safe encoded
# form ends up in JWTanswerURLstatus for the rendered HTML.
#
# Returns a response HASHREF. Caller is responsible for encoding it for
# downstream consumers (see encodeAnswerStatus). This contract differs from
# sendAnswerJWT (legacy lane), which returns a pre-encoded string — the
# challengeJWT lane needs structured access to verdict_signed for the fold.
async sub sendSubmissionEnvelope ($c, $answer_url, $session_jwt, $submission_jwt) {
	my $envelope = {
		type           => 'submission',
		session_jwt    => $session_jwt,
		submission_jwt => $submission_jwt,
	};
	my $body   = encode_json($envelope);
	my $header = {
		Origin         => $ENV{SITE_HOST},
		'Content-Type' => 'application/json',
	};

	my $response = {
		subject => 'webwork.result',
		message => 'initial message',
	};

	$c->log->info("sending submissionJWT envelope to $answer_url");
	await $c->ua->max_redirects(5)->request_timeout(7)->post_p($answer_url, $header, $body)->then(sub {
		my $tx = shift->result;
		$response->{status} = int($tx->code);
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

	$c->log->info("submission envelope response " . encode_json($response));
	return $response;
}

# Encode a response hashref as the JS-safe JSON string that goes into
# JWTanswerURLstatus. The single-quote escape is required because the value
# is later embedded as a JS string literal in default.html.ep.
sub encodeAnswerStatus ($response) {
	my $encoded = encode_json($response);
	$encoded =~ s/'/\\'/g;
	return $encoded;
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
