package Renderer::Render::ParseRequest;
use Mojo::Base -signatures;

# Envelope parser + lane dispatcher for /render-api requests.
#
# Single entry point: `dispatch($c) → \%params` (or undef on error, with
# $c->exception already rendered). Internally split into two phases that
# match the conceptual shape:
#
#   _parse_envelope  — raw form → normalized %params + %ctx (originIP)
#                      + pre-dispatch validations + verdict-fold +
#                      peer-signature verify + sensitive-params strip
#                      (skipped for verified peer-signed bodies).
#   _apply_lanes     — sessionJWT prefix, body-lane dispatch (problemJWT /
#                      challengeJWT / peer-signed / ungrounded), post-
#                      dispatch finalize (originIP/parent_origin restore,
#                      emission gate).
#
# Three knobs govern access (see Lane::Ungrounded for STRICT_JWT and
# SELF_MINT_DISABLED, this dispatcher's tail for the emission gate):
#   1. Entry gate    (STRICT_JWT)            — may an ungrounded request render at all?
#      Applies to EVERY ungrounded request, whatever its output format
#      (WW3-R44 — ptx used to slip past it).
#   2. Session UX    (SELF_MINT_DISABLED)    — wrap an admitted ungrounded request in a self-minted JWT?
#   3. Emission gate (_can_emit_answer_jwt)  — may this request produce an answerJWT?
# The emission gate is enforced at the emission site (Render.pm), not here:
# the renderer's job is to validate and render, not to refuse renders based
# on what the caller might or might not be allowed to emit.
# See WeBWorK3/Config and Secrets Evolution for rationale.
#
# Moved out of Renderer::Controller::Render in WW3-R33.

use WeBWorK::VerdictJWT qw(verifyAndFoldVerdict verifyAndFoldLaunchVerdict);
use Renderer::Util::JWT qw(verify_problem_jwt);
use Renderer::Lane::Session;
use Renderer::Lane::Problem;
use Renderer::Lane::Challenge;
use Renderer::Lane::Review;
use Renderer::Lane::Peer;
use Renderer::Lane::Ungrounded;
use Renderer::Constants qw(
	SENSITIVE_PARAMS ELEVATION_PARAMS RENDER_MODE_PARAMS TOKEN_CONTENT_PARAMS DEBUG_PARAMS
);
use Renderer::Seed       qw(resolve_seed MALFORMED_SEED_MESSAGE);
use Renderer::RenderMode qw(resolve_render_mode RATCHET);

use Exporter qw(import);
our @EXPORT_OK = qw(dispatch);

sub dispatch ($c) {
	my %params = %{ $c->req->params->to_hash };
	my %ctx;

	_parse_envelope($c, \%params, \%ctx) or return;
	_apply_lanes($c, \%params, \%ctx)    or return;

	# The seed rule (Renderer::Seed) on every lane. _render_warnings is set
	# here on every request, replacing any value that arrived in the params;
	# the outbound answerJWT / submissionJWT reports it.
	my $warnings = resolve_seed($c, \%params, $c->stash('_trust_lane') // 'ungrounded');
	return $c->exception(MALFORMED_SEED_MESSAGE, 400) unless $warnings;
	$params{_render_warnings} = $warnings;

	# noCache is an integrator setting: read after the lanes, so a claim or a
	# peer body sets it and the strip has removed any raw value.
	$c->stash(_no_cache => $params{noCache} ? 1 : 0);

	# answers_submitted is an argument PG passes its grader; PG spreads the
	# params after its own `answers_submitted => 1`, so a value from any source
	# would replace it and the stock graders would score the submission 0.
	delete $params{answers_submitted};

	# Mode resolution runs HERE — parent process, post-claim-merge, pre-fork.
	# Flattens the renderMode intent claim into the primitive flag bundle so
	# the resolved primitives are visible to both the rendering subprocess
	# (where PG and standaloneRenderer run) AND the format layer (which
	# runs back in the parent after the subprocess returns). Putting it
	# inside the subprocess would lose the format-layer flags across the
	# fork boundary — Storable serialization only carries return values back,
	# not mutated inputs_ref.
	#
	# The ratchet (WW3-R70): the bundle supplies defaults, the values the
	# lanes left in %params are claims and replace them, and the raw values
	# set aside below may only tighten. A grounded request's raw values were
	# set aside in _parse_envelope, before its lanes; an ungrounded request's
	# are set aside here, after the self-mint has carried them forward. The
	# ungrounded lane honours raw isInstructor (the STRICT_JWT=0 posture), so
	# that one stays in %params.
	my $raw = $c->stash('_raw_ratchet') // {};
	if (($c->stash('_trust_lane') // '') eq 'ungrounded') {
		$raw = {
			map  { $_ => delete $params{$_} }
			grep { $_ ne 'isInstructor' && exists $params{$_} } keys %{ +RATCHET }
		};
	}
	my $ignored = resolve_render_mode(\%params, $raw);
	$c->stash(_mode_overrides => $ignored) if @$ignored;

	# Every request that renders under a token — upstream or self-minted —
	# lands isInstructor on a defined value once the mode has supplied its
	# default (WW3-R46).
	$params{isInstructor} //= 0
		if grep { defined $params{$_} } qw(problemJWT challengeJWT submissionJWT);

	return \%params;
}

# First client IP from a (possibly multi-value) X-Forwarded-For header
# ("client, proxy1, proxy2…"): the leading dotted-quad. Returns the header
# unchanged when it carries no IPv4, or '' when absent, so the caller falls
# back to remote_address on an empty result. The parens around `// ''` are
# load-bearing — `=~` binds tighter than `//`, so without them the substitution
# runs on '' and the raw multi-value header leaks through.
sub _origin_ip_from_xff ($xff) {
	return (($xff // '') =~ s!^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}).*$!$1!r);
}

# Phase 1: raw form → normalized params + context. Runs all pre-dispatch
# validations, the render-time verdict fold, peer-sig verify, parent_origin
# capture, and the SENSITIVE_PARAMS strip. On any rejection, returns the
# result of $c->exception(...) (falsy).
sub _parse_envelope ($c, $params, $ctx) {

	$ctx->{originIP} = _origin_ip_from_xff($c->req->headers->header('X-Forwarded-For'));
	$ctx->{originIP} ||= $c->tx->remote_address || 'unknown-origin';

	# Treat empty-string JWT params as not-present. Hidden form fields whose
	# backing value was undef render as `value=""`, which is `defined` but empty;
	# Crypt::JWT::decode_jwt rejects empty tokens with "missing token". Strip
	# them up front so the dispatcher below sees a clean envelope shape.
	for my $k (qw(problemJWT sessionJWT challengeJWT submissionJWT verdict_signed)) {
		delete $params->{$k} if defined $params->{$k} && !length $params->{$k};
	}

	# Play state reaches the challenge lane only from signed sources: the
	# launch verdict on a first render, the sessionJWT after it (WW3-205).
	# A raw initial_state is never read, and a raw challenge_jwt is dropped
	# so the session's embedded claim is the only value Lane::Session hoists.
	delete @{$params}{qw(initial_state challenge_jwt)};

	# A first render is one that arrived without a sessionJWT — decided
	# before the launch fold below supplies one.
	my $is_first_render = !defined $params->{sessionJWT};

	# problemJWT / challengeJWT / submissionJWT are sibling body-lane trust
	# anchors — never more than one at a time. Each carries a complete
	# envelope intent (live LMS-grounded play, WW3 play definition, or
	# historical replay artifact respectively); combining them is ambiguous.
	{
		my @body = grep { defined $params->{$_} } qw(problemJWT challengeJWT submissionJWT);
		if (@body > 1) {
			return $c->exception('Ambiguous envelope: ' . join(' + ', @body) . ' present together.', 400,);
		}
	}

	# Render-time verdict fold (WW3-053). When the portal threads
	# verdict_signed through a render request — on the RESUME path, where
	# /play/status handed the portal session_jwt + verdict_signed — the
	# renderer mints sessionJWT_{k+1} folding the verdict before downstream
	# processing reads state. Replaces $params->{sessionJWT} so Lane::Session's
	# decode below sees the verdict-folded state.
	#
	# The FIRST render of a play carries the launch verdict and no sessionJWT
	# (WW3-205). The challengeJWT is verified as the lane verifies it, then the
	# verdict folds into an empty base: sessionJWT_0, embedding the raw
	# challengeJWT. A challengeJWT with neither a session nor a verdict has no
	# signed source for its play state and is refused.
	#
	# Lives here rather than Lane::Challenge because the fold mutates
	# sessionJWT (which Lane::Session decodes), so the operation must run
	# before the session prefix. It's a session-state concern that requires
	# challengeJWT for the play_id cross-check, not a challenge-lane operation
	# per se.
	if (defined $params->{verdict_signed}) {
		return $c->exception('verdict_signed requires challengeJWT.', 400)
			unless defined $params->{challengeJWT};

		my ($folded, $err);
		if (defined $params->{sessionJWT}) {
			($folded, $err) = verifyAndFoldVerdict($params->{sessionJWT}, $params->{verdict_signed},
				$ENV{problemJWTsecret}, $ENV{webworkJWTsecret},);
		} else {
			my (undef, $cjwt_err) = verify_problem_jwt($params->{challengeJWT});
			return $c->credential_error($cjwt_err) if $cjwt_err;

			($folded, $err) = verifyAndFoldLaunchVerdict(
				$params->{challengeJWT}, $params->{verdict_signed},
				$ENV{problemJWTsecret},  $ENV{webworkJWTsecret},
			);
		}
		if ($err) {
			$c->log->error("verdict_signed fold rejected: $err");
			return $c->exception("verdict_signed: $err", 400);
		}
		$params->{sessionJWT} = $folded;
		delete $params->{verdict_signed};
	} elsif (defined $params->{challengeJWT} && !defined $params->{sessionJWT}) {
		return $c->exception('challengeJWT requires sessionJWT or verdict_signed.', 400);
	}

	# Reject raw-param pg_hash + problemSource without a token —
	# legitimate callers carry pg_hash inside the JWT; the bare combo is
	# attacker-shaped (rendering chosen source under a cached identity). On a
	# token-bearing request both are stripped below (TOKEN_CONTENT_PARAMS).
	if (defined $params->{pg_hash}
		&& defined $params->{problemSource}
		&& !grep { defined $params->{$_} } qw(problemJWT challengeJWT submissionJWT sessionJWT))
	{
		$c->log->error('pg_hash + problemSource without JWT — rejecting.');
		return $c->exception('Malformed request.', 400);
	}

	# Peer-signed verification. Runs early — the result determines whether the
	# SENSITIVE_PARAMS strip below applies. On bad signature, returns a 401
	# exception (caller short-circuits).
	Renderer::Lane::Peer::verify($c) or return;

	# Translate the peer-facing `formAction` field to the internal `formURL`
	# name honored by FormatRenderedProblem. Editor-providers specify "send
	# form submits back to me" in their mental model.
	if (defined $params->{formAction}) {
		$params->{formURL} //= delete $params->{formAction};
	}

	# Normalize common lowercase query params to camelCase before JWT processing.
	$params->{outputFormat} //= delete $params->{outputformat} if exists $params->{outputformat};
	$params->{displayMode}  //= delete $params->{displaymode}  if exists $params->{displaymode};
	$params->{problemSeed}  //= delete $params->{problemseed}  if exists $params->{problemseed};

	# Stash flags consumed by downstream phases.
	$c->stash(_is_first_render => $is_first_render ? 1 : 0);

	# Strip security-sensitive params from untrusted inputs. Peer-signed
	# bodies are exempt — a verified peer signature IS the trust gate, and
	# the signed body is as trustworthy as a JWT claim. Anyone who can mint
	# a peer signature could equally mint a problemJWT carrying any of these
	# fields; stripping them from a verified body would be theatre and would
	# block legitimate flows (editor-provider with JWTanswerURL callback,
	# library browse with declared parent_origin, etc.).
	#
	# Non-peer-signed: JWT-bearing requests recover sensitive values via the
	# Lane::Session / Lane::Problem / Lane::Challenge claim merges. Ungrounded
	# requests have nothing to recover from and stay stripped — that's the
	# point.
	unless ($c->stash('_peer_signed')) {
		for (SENSITIVE_PARAMS) {
			delete $params->{$_};
		}

		# Elevation params (WW3-R46). Same exemption, separate list because
		# they carry a meaningful default rather than simply being absent —
		# see Renderer::Constants.
		#
		# Stripped only from GROUNDED requests. An ungrounded request that
		# renders at all is one a STRICT_JWT=0 deployment chose to admit on
		# network position — the VPC-editor posture, where the network IS
		# the trust boundary and a raw `isInstructor=1` from the editor is
		# exactly as trustworthy as that deployment decision. Stripping
		# there would break editor previews to protect a deployment that
		# has already declared it does not need protecting. Under
		# STRICT_JWT=1 the entry gate refuses ungrounded requests outright
		# (WW3-R44), so this exemption opens nothing on a student-facing
		# instance.
		#
		# Stashed before deletion so Lane::Review can restore
		# showCorrectAnswers, the one legitimate raw-form consumer left in
		# the tree — an interim closed by WW3-117; see Lane::Review.
		my $grounded =
			defined $params->{problemJWT}
			|| defined $params->{challengeJWT}
			|| defined $params->{submissionJWT}
			|| defined $params->{sessionJWT};

		if ($grounded) {
			my %elevation;
			for (ELEVATION_PARAMS) {
				$elevation{$_} = delete $params->{$_} if exists $params->{$_};
			}
			$c->stash(_stripped_elevation => \%elevation);

			# Render-mode selectors are trusted-claim-only on grounded lanes
			# (WW3-R51). A raw `renderMode=preview` would re-derive
			# isInstructor → revealAll through the bundle, AFTER the elevation
			# strip above — the R46 hole via the indirect param. Deleted, not
			# stashed: a lane recovers it from its claim, and absence resolves
			# to 'custom' (the student passthrough).
			for (RENDER_MODE_PARAMS) {
				delete $params->{$_};
			}

			# The token names the content and the seed (WW3-R68). A lane
			# recovers each from its claim; see TOKEN_CONTENT_PARAMS.
			for (TOKEN_CONTENT_PARAMS) {
				delete $params->{$_};
			}

			# The debugging view comes only from a signed source (WW3-R58); see
			# DEBUG_PARAMS.
			for (DEBUG_PARAMS) {
				delete $params->{$_};
			}

			# Raw ratchet primitives (WW3-R70) are set aside so the lanes see
			# only claims; dispatch re-applies them after the mode resolves,
			# where they may only tighten. The stripped isInstructor joins
			# them: a raw isInstructor=0 tightens, a raw 1 is ignored.
			my %raw = map { $_ => delete $params->{$_} } grep { exists $params->{$_} } keys %{ +RATCHET };
			$raw{isInstructor} = $elevation{isInstructor} if exists $elevation{isInstructor};
			$c->stash(_raw_ratchet => \%raw);
		}
	}

	return 1;
}

# Phase 2: lane application + post-dispatch finalize. Session prefix runs
# first (combines with any body lane). Body lane runs second (problemJWT /
# challengeJWT / submissionJWT / peer-signed). The entry gate then fires
# for anything that reached no lane, whatever its output format (WW3-R44).
# Finalize restores originIP/parent_origin.
sub _apply_lanes ($c, $params, $ctx) {

	# Session prefix — sessionJWT decode + claim merge. Combines with any body lane.
	if (defined $params->{sessionJWT}) {
		Renderer::Lane::Session::apply_prefix($c, $params) or return;
	}

	# Body-lane dispatch — envelope shape selects the lane. problemJWT,
	# challengeJWT, and submissionJWT are mutually exclusive (rejected
	# pre-dispatch); peer-signed fires when peer-verified AND no JWT body.
	# A sessionJWT alone reaches a lane via apply_prefix, which hoists the
	# nested problemJWT / challenge_jwt into the body slot.
	my $lane_applied = 0;

	if (defined $params->{problemJWT}) {
		Renderer::Lane::Problem::apply($c, $params) or return;
		# Sidecar source-override (LTW-088): no-op unless apply_prefix stashed
		# a differing sidecar problemJWT. Runs after the body lane merges the
		# nested claims so the source bundle is replaced last; pre-finalize so
		# it lands before the render subprocess forks.
		Renderer::Lane::Session::apply_source_override($c, $params) or return;
		$lane_applied = 1;
	} elsif (defined $params->{challengeJWT}) {
		Renderer::Lane::Challenge::apply($c, $params) or return;
		$lane_applied = 1;
	} elsif (defined $params->{submissionJWT}) {
		Renderer::Lane::Review::apply($c, $params) or return;
		$lane_applied = 1;
	} elsif ($c->stash('_peer_signed')) {
		Renderer::Lane::Peer::apply_body($c, $params) or return;
		$lane_applied = 1;
	}

	# Entry gate (WW3-R44). Fires whenever NO body lane was applied — i.e.
	# the request is ungrounded — regardless of what it renders to.
	#
	# It used to live inside an `elsif (outputFormat ne 'ptx')` arm, which
	# fused two unrelated concerns: "PTX skips body-lane dispatch" is a
	# RENDERING fact, and "ungrounded requests are refused" is an
	# AUTHORIZATION one. Nesting the second inside the first let the
	# authorization decision inherit the pipeline's exception, so
	# `outputFormat=ptx` with no credential walked straight past a
	# STRICT_JWT=1 deployment and `answerhashXML` handed back correct_ans
	# for any problem in the library, by path, at any seed. R37 moved this
	# check out of Lane::Ungrounded and into the dispatcher, which made it
	# pre-LANE but not pre-DISPATCH — one level too shallow.
	#
	# Public/student instances should set STRICT_JWT; VPC-isolated editor
	# renderers can leave it unset to opt into the self-mint UX — the same
	# trust boundary the editor posture already uses: the network, not the
	# token.
	#
	# WW3-R45 removed the `outputFormat ne 'ptx'` carve-out that used to wrap
	# the ungrounded lane here. PTX is no longer an output format of this
	# endpoint at all — it has its own route, POST /render-ptx — so there is
	# nothing left for the carve-out to except.
	unless ($lane_applied) {
		if ($ENV{STRICT_JWT}) {
			return $c->exception('Request requires a problemJWT, sessionJWT, or X-Peer-Signature.', 401,);
		}

		Renderer::Lane::Ungrounded::apply($c, $params) or return;
	}

	# Post-dispatch finalize.
	$params->{originIP} = $ctx->{originIP} if $ctx->{originIP};

	return 1;
}

1;
