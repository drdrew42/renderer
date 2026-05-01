package Renderer::Render::ParseRequest;
use Mojo::Base -signatures;

# Envelope parser + lane dispatcher for /render-api requests.
#
# Single entry point: `dispatch($c) → \%params` (or undef on error, with
# $c->exception already rendered). Internally split into two phases that
# match the conceptual shape:
#
#   _parse_envelope  — raw form → normalized %params + %ctx (originIP,
#                      peer-signed parent_origin) + pre-dispatch validations
#                      + verdict-fold + peer-signature verify + sensitive-
#                      params strip.
#   _apply_lanes     — sessionJWT prefix, body-lane dispatch (problemJWT /
#                      challengeJWT / peer-signed / ungrounded), post-
#                      dispatch finalize (originIP/parent_origin restore,
#                      emission gate).
#
# Three knobs govern access (see Lane::Ungrounded for STRICT_JWT and
# SELF_MINT_DISABLED, this dispatcher's tail for the emission gate):
#   1. Entry gate    (STRICT_JWT)            — may an ungrounded request render at all?
#   2. Session UX    (SELF_MINT_DISABLED)    — wrap an admitted ungrounded request in a self-minted JWT?
#   3. Emission gate (_can_emit_answer_jwt)  — may this request produce an answerJWT?
# See WeBWorK3/Config and Secrets Evolution for rationale.
#
# Moved out of Renderer::Controller::Render in WW3-R33.

use Mojo::JSON qw(decode_json);

use WeBWorK::VerdictJWT qw(verifyAndFoldVerdict);
use Renderer::Lane::Session;
use Renderer::Lane::Problem;
use Renderer::Lane::Challenge;
use Renderer::Lane::Peer;
use Renderer::Lane::Ungrounded;
use Renderer::Constants qw(SENSITIVE_PARAMS);

use Exporter qw(import);
our @EXPORT_OK = qw(dispatch);

sub dispatch ($c) {
	my %params = %{ $c->req->params->to_hash };
	my %ctx;

	_parse_envelope($c, \%params, \%ctx) or return;
	_apply_lanes   ($c, \%params, \%ctx) or return;

	return \%params;
}

# Phase 1: raw form → normalized params + context. Runs all pre-dispatch
# validations, the render-time verdict fold, peer-sig verify, parent_origin
# capture, and the SENSITIVE_PARAMS strip. On any rejection, returns the
# result of $c->exception(...) (falsy).
sub _parse_envelope ($c, $params, $ctx) {

	$ctx->{originIP} = $c->req->headers->header('X-Forwarded-For')
		// '' =~ s!^\s*(\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}).*$!$1!r;
	$ctx->{originIP} ||= $c->tx->remote_address || 'unknown-origin';

	# Protect against DOM manipulation.
	if (defined $params->{submitAnswers} && defined $params->{previewAnswers}) {
		$c->log->error('Simultaneous submit and preview! JWT: ', $params->{problemJWT} // {});
		return $c->exception('Malformed request.', 400);
	}

	# Treat empty-string JWT params as not-present. Hidden form fields whose
	# backing value was undef render as `value=""`, which is `defined` but empty;
	# Crypt::JWT::decode_jwt rejects empty tokens with "missing token". Strip
	# them up front so the dispatcher below sees a clean envelope shape.
	for my $k (qw(problemJWT sessionJWT challengeJWT verdict_signed initial_state)) {
		delete $params->{$k} if defined $params->{$k} && !length $params->{$k};
	}

	# initial_state: portal-supplied JSON serialization of the play's initial
	# navigation state (next_available, current_focus, draws[], finalization,
	# started_at). Per Lifecycle.md, the portal hands challenge_jwt +
	# initial_state to the renderer for sessionJWT_0 minting on first render.
	# Decoded into $params->{state} so generatePlaySessionJWT picks it up
	# uniformly with the sessionJWT-decoded path.
	if (defined $params->{initial_state} && !defined $params->{sessionJWT}) {
		eval {
			my $decoded = decode_json($params->{initial_state});
			$params->{state} = $decoded if ref $decoded eq 'HASH';
			1;
		} or do {
			$c->log->warn("initial_state parse failed: $@");
		};
		delete $params->{initial_state};
	}

	# challengeJWT and problemJWT are sibling trust lanes — never both at once.
	if (defined $params->{challengeJWT} && defined $params->{problemJWT}) {
		return $c->exception('Ambiguous envelope: both challengeJWT and problemJWT present.', 400);
	}

	# Render-time verdict fold (WW3-053). When the portal threads
	# verdict_signed through a render request — typically on the RESUME path
	# where /play/launch handed the portal session_jwt + verdict_signed — the
	# renderer mints sessionJWT_{k+1} folding the verdict before downstream
	# processing reads state. Replaces $params->{sessionJWT} so Lane::Session's
	# decode below sees the verdict-folded state.
	#
	# Lives here rather than Lane::Challenge because the fold mutates
	# sessionJWT (which Lane::Session decodes), so the operation must run
	# before the session prefix. It's a session-state concern that requires
	# challengeJWT for the play_id cross-check, not a challenge-lane operation
	# per se.
	if (defined $params->{verdict_signed}) {
		return $c->exception('verdict_signed requires sessionJWT.', 400)
			unless defined $params->{sessionJWT};
		return $c->exception('verdict_signed requires challengeJWT.', 400)
			unless defined $params->{challengeJWT};

		my ($folded, $err) = verifyAndFoldVerdict(
			$params->{sessionJWT},
			$params->{verdict_signed},
			$ENV{problemJWTsecret},
			$ENV{webworkJWTsecret},
		);
		if ($err) {
			$c->log->error("verdict_signed fold rejected: $err");
			return $c->exception("verdict_signed: $err", 400);
		}
		$params->{sessionJWT} = $folded;
		$c->stash(_verdict_folded => 1);
		delete $params->{verdict_signed};
	}

	# Reject raw-param pg_hash + problemSource without an upstream JWT —
	# legitimate callers carry pg_hash inside the JWT; the bare combo is
	# attacker-shaped (rendering chosen source under a cached identity).
	if (defined $params->{pg_hash} && defined $params->{problemSource}
		&& !defined $params->{problemJWT} && !defined $params->{sessionJWT})
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
	if (defined $params->{formAction}) {
		$params->{formURL} //= delete $params->{formAction};
	}

	# parent_origin: peer-signed lane carries it in the signed body; capture
	# before the SENSITIVE_PARAMS strip and restore after dispatch. JWT lane
	# recovers it via Lane::Problem's claim merge (claim wins) — no special
	# handling needed there.
	$ctx->{peer_parent_origin} = $c->stash('_peer_signed') ? delete $params->{parent_origin} : undef;

	# Normalize common lowercase query params to camelCase before JWT processing.
	$params->{outputFormat} //= delete $params->{outputformat} if exists $params->{outputformat};
	$params->{displayMode}  //= delete $params->{displaymode}  if exists $params->{displaymode};
	$params->{problemSeed}  //= delete $params->{problemseed}  if exists $params->{problemseed};

	# Stash flags consumed by downstream phases.
	$c->stash(_is_first_render => !defined $params->{sessionJWT} ? 1 : 0);
	$c->stash(_no_cache        => $params->{noCache} ? 1 : 0);

	# Strip security-sensitive params. Anything in this list can ONLY be
	# (re)introduced via a trusted source (JWT claim, peer-signed body).
	for (SENSITIVE_PARAMS) {
		delete $params->{$_};
	}

	return 1;
}

# Phase 2: lane application + post-dispatch finalize. Session prefix runs
# first (combines with any body lane). Body lane runs second (problemJWT /
# challengeJWT / peer-signed / ungrounded; PTX skips body-lane entirely).
# Finalize restores originIP/parent_origin and runs the emission gate.
sub _apply_lanes ($c, $params, $ctx) {

	# Session prefix — sessionJWT decode + claim merge. Combines with any body lane.
	if (defined $params->{sessionJWT}) {
		Renderer::Lane::Session::apply_prefix($c, $params) or return;
	}

	# Body-lane dispatch — envelope shape selects the lane. problemJWT and
	# challengeJWT are mutually exclusive (rejected pre-dispatch); peer-signed
	# fires when peer-verified AND no JWT body; ungrounded covers the rest
	# unless outputFormat=ptx (PTX path skips body-lane entirely — no JWT
	# minted, no defaults).
	if (defined $params->{problemJWT}) {
		Renderer::Lane::Problem::apply($c, $params) or return;
	} elsif (defined $params->{challengeJWT}) {
		Renderer::Lane::Challenge::apply($c, $params) or return;
	} elsif ($c->stash('_peer_signed')) {
		Renderer::Lane::Peer::apply_body($c, $params) or return;
	} elsif (($params->{outputFormat} // '') ne 'ptx') {
		Renderer::Lane::Ungrounded::apply($c, $params) or return;
	}

	# Post-dispatch finalize.
	$params->{originIP} = $ctx->{originIP} if $ctx->{originIP};

	# Restore peer-signed parent_origin (captured before the strip in
	# _parse_envelope). The JWT lane recovers parent_origin via the generic
	# claim merge; the peer-signed lane has no such merge, so reapply explicitly.
	$params->{parent_origin} //= $ctx->{peer_parent_origin} if defined $ctx->{peer_parent_origin};

	# Emission gate, fail-fast (WW3-R03). Reject submits that arrived without
	# upstream grounding before the PG fork, rather than after a full render.
	# _can_emit_answer_jwt is set only by problemJWT / challengeJWT / sessionJWT
	# carrying upstream context — self-mint and peer-signed lanes never set it.
	# A late belt-and-suspenders check survives at the dispatch site; this one
	# is the primary gate.
	if ($params->{submitAnswers} && !$c->stash('_can_emit_answer_jwt')) {
		return $c->exception(
			'Submit requires a problemJWT, challengeJWT, or sessionJWT.', 403,
		);
	}

	return 1;
}

1;
