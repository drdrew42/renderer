package Renderer::Lane::Review;

# submissionJWT body lane — read-only replay (WW3-038b).
#
# The submissionJWT is itself the complete reView artifact: orchestrator-
# signed, self-audienced, carries pg_hash + seed + position + identity +
# submitted_answers + part_scores + score. Renders a faithful, read-only
# replay of a historical submission. No challengeJWT, no answer_url, no
# continuation state — reView is retrieval, not session machinery.
#
#   * Decode + verify_aud against $SITE_HOST under problemJWTsecret
#     (matches the mint key in WeBWorK::RenderProblem::generateSubmissionJWT).
#   * Extract pg_hash / seed / position / identity claims.
#   * Synthesize problemSourceURL from pg_hash. Raw source, address and seed
#     are stripped before the lane (WW3-R68).
#   * Merge submitted_answers (AnSwEr* + MaThQuIlL_AnSwEr*) into %params for
#     PG's native input-prefill path.
#   * Force submitAnswers=1 so PG renders the graded view (per-answer
#     feedback) the student saw at submit time.
#   * Lock outputFormat to 'static' (iframe-only, read-only replay).
#   * Do NOT set _can_emit_answer_jwt, do NOT plumb JWTanswerURL — reView
#     is read-only; the late emission gate naturally short-circuits because
#     no JWTanswerURL is ever set.
#
# Button-hide flags (hideCheckAnswersButton / showCorrectAnswersButton) ride
# as raw form params from the portal — display preferences, not security
# claims.
#
# showCorrectAnswers is a security claim: on reView the student holds their
# own submissionJWT, so a raw form field would be the only thing between them
# and the answers. The lane hard-zeroes it, and the reveal arrives only
# through the verified permission sidecar (_reveal_grant, WW3-117) — see
# apply below.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Renderer::RevealSidecar ();
use Renderer::Util::JWT     qw(verify_problem_jwt);

use Exporter qw(import);
our @EXPORT_OK = qw(apply);

sub apply ($c, $params) {
	$c->log->info("Received JWT: using submissionJWT (reView)");

	my ($claims, $err) = verify_problem_jwt($params->{submissionJWT});
	return $c->credential_error($err) if $err;

	# Required claims to reproduce the rendered state. Any of these missing
	# means the JWT wasn't minted by generateSubmissionJWT — refuse rather
	# than render against a partial artifact.
	for my $k (qw(pg_hash seed position)) {
		return $c->exception("submissionJWT missing $k.", 400)
			unless defined $claims->{$k};
	}

	# Render context — JWT wins outright. Faithful replay is the whole
	# point; no scenario where a caller-supplied pg_hash/seed/position
	# should override what was historically submitted.
	$params->{pg_hash}     = $claims->{pg_hash};
	$params->{problemSeed} = $claims->{seed};
	$params->{position}    = $claims->{position};

	# Identity claims propagate (logging, telemetry).
	for my $k (qw(play_id challenge_id chain_student_id)) {
		$params->{$k} = $claims->{$k} if defined $claims->{$k};
	}

	# WW3-117: a WW3-minted reveal sidecar (revealJWT) may ride alongside the
	# submissionJWT to deliver the answer reveal out of band — verified by
	# signature, aud, play-binding, and TTL, so it is a trusted grant rather
	# than a form field the student controls. On a valid, play-bound sidecar,
	# _reveal_grant is set and resolve_permissions expands it to answers +
	# solutions. Absent/invalid ⇒ no grant, and the raw showCorrectAnswers
	# interim below still applies until the portal migrates (slices 3-4).
	if (Renderer::RevealSidecar::verify($c, $params, $claims->{play_id})) {
		$params->{_reveal_grant} = 1;
	}

	# Synthesize problemSourceURL from pg_hash. A raw problemSource never
	# reaches this lane (TOKEN_CONTENT_PARAMS, WW3-R68); a verified peer body's
	# signed source renders as sent.
	unless (defined $params->{problemSource}) {
		$params->{problemSourceURL} = $c->opl_client->problem_url_by_hash($claims->{pg_hash});
	}

	# Prefill: merge historical answers into the form. PG natively renders
	# `<input value="...">` from $inputs_ref->{AnSwEr*}. submitted_answers
	# carries both AnSwEr* (plain) and MaThQuIlL_AnSwEr* (LaTeX) per the
	# mint contract. JWT wins for the same reason as render context.
	if (ref $claims->{submitted_answers} eq 'HASH') {
		my $ans = $claims->{submitted_answers};
		$params->{$_} = $ans->{$_} for keys %$ans;
	}

	# Replay contract: original submission set submitAnswers, so reView
	# does too — PG renders the graded view (per-answer green/red) the
	# student saw on submit.
	$params->{submitAnswers} = 1;

	# outputFormat lock — reView renders `static`: iframe-only, and a read-only
	# replay rather than a live attempt. `static` hides the submit/reveal
	# buttons (WW3-R21) and, critically, marks the render as "display, don't
	# count" — Render.pm records no interaction telemetry for a static render,
	# which is what stops a reView from logging a phantom submit (WW3-R49).
	# A static render also swaps PG's editable MathQuill init for the read-only
	# static-mathquill.js (WW3-121; see WeBWorK::FormatRenderedProblem).
	$params->{outputFormat} = 'static';

	# Elevation params (WW3-R46). isInstructor lands on the student default
	# and is NOT recoverable here: the submissionJWT carries no role claim,
	# and nothing in the reView flow has ever legitimately supplied one.
	$params->{isInstructor} = 0;

	# showCorrectAnswers is hard-zeroed on this lane (WW3-117): the reView reveal
	# now arrives only through the verified permission sidecar above
	# (_reveal_grant), never a raw form field the student controls. A student
	# adding showCorrectAnswers to their own POST reveals nothing — the sidecar
	# is the sole reveal path, which closes the R46-class interim. The claim
	# path mirrors Lane::Challenge: hard-zero here, re-enable via the trusted
	# grant in resolve_permissions.
	$params->{showCorrectAnswers} = 0;

	$c->stash(_trust_lane => 'review');
	return 1;
}

1;
