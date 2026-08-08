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
#   * Synthesize problemSourceURL from pg_hash (skip if caller supplied raw source).
#   * Merge submitted_answers (AnSwEr* + MaThQuIlL_AnSwEr*) into %params for
#     PG's native input-prefill path.
#   * Force submitAnswers=1 so PG renders the graded view (per-answer
#     feedback) the student saw at submit time.
#   * Lock outputFormat to 'default' (iframe-only).
#   * Do NOT set _can_emit_answer_jwt, do NOT plumb JWTanswerURL — reView
#     is read-only; the late emission gate naturally short-circuits because
#     no JWTanswerURL is ever set.
#
# Button-hide flags (hideCheckAnswersButton / showCorrectAnswersButton) ride
# as raw form params from the portal — display preferences, not security
# claims.
#
# showCorrectAnswers is NOT a display preference, and the comment that used
# to say so here was wrong (WW3-R46). Its reasoning was "the orchestrator
# already gated whether to release the submissionJWT to the caller;
# everything past that is presentation." That holds only if releasing the
# submissionJWT is the decision that matters. On reView it is not — the
# student is SUPPOSED to hold their own submissionJWT; that is the whole
# feature. showCorrectAnswers is the only thing between them and the
# answers, and it arrived in their own POST body.
#
# It is stripped with the other elevation params now, and restored here
# from the pre-strip stash. That restore is a deliberate, bounded interim:
#
#   * WW3 genuinely needs it today. Instructor reView shows correct answers
#     via this field (play/service.go sets it from `grade.read.all`), so
#     stripping it outright regresses a live v1 feature.
#   * The exposure it leaves is bounded. reView is post-finalization: the
#     play is over and the score is locked, so a student flipping this
#     cannot improve their own result. What they gain is early sight of
#     answers — a fairness/parity problem (sharing with classmates who have
#     not finished), not a self-scoring exploit. The severe case was the
#     CHALLENGE lane, mid-play, live scoring, and that one is now closed
#     outright.
#   * WW3-117 deletes it. Once the reveal is minted server-side and fetched
#     out of band, no in-render reveal flag exists on any lane and this
#     restore goes with it.
#
# The alternative considered and rejected for now: a WW3-minted "reView
# options" token carrying the flag as a claim. Correct, and thrown away by
# WW3-117 a ticket later.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Crypt::JWT qw(decode_jwt);

use Exporter qw(import);
our @EXPORT_OK = qw(apply);

sub apply ($c, $params) {
	$c->log->info("Received JWT: using submissionJWT (reView)");

	my $claims;
	eval {
		$claims = decode_jwt(
			token      => $params->{submissionJWT},
			key        => $ENV{problemJWTsecret},
			verify_aud => $ENV{SITE_HOST},
		);
		1;
	} or do {
		return $c->croak($@, 3);
	};

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

	# Synthesize problemSourceURL from pg_hash unless caller supplied raw
	# source (editor preview / test bypass — "use this verbatim").
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
	# (Genuinely non-interactive inputs — MathQuill as static divs — is a
	# separate follow-up; static hides the buttons today.)
	$params->{outputFormat} = 'static';

	# Elevation params (WW3-R46). isInstructor lands on the student default
	# and is NOT recoverable here: the submissionJWT carries no role claim,
	# and nothing in the reView flow has ever legitimately supplied one.
	$params->{isInstructor} = 0;

	# showCorrectAnswers still rides as a raw form param here — see the
	# header. Not stripped, because it is the button's own mechanism; the
	# gap is that reView's bundle never offers the button and nothing
	# refuses the param anyway. WW3-117 removes the flag entirely.

	$c->stash(_trust_lane => 'review');
	return 1;
}

1;
