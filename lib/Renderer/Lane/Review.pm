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
#     feedback) the student saw at submit time. previewAnswers cleared
#     defensively (mutually exclusive with submit).
#   * Lock outputFormat to 'default' (iframe-only).
#   * Do NOT set _can_emit_answer_jwt, do NOT plumb JWTanswerURL — reView
#     is read-only; the late emission gate naturally short-circuits because
#     no JWTanswerURL is ever set.
#
# Button-hide flags (hidePreviewButton / hideCheckAnswersButton /
# showCorrectAnswersButton) and showCorrectAnswers ride as raw form params
# from the portal — display preferences, not security claims, so no
# SENSITIVE_PARAMS protection is required. The orchestrator already gated
# whether to release the submissionJWT to the caller; everything past that
# is presentation.

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
	# student saw on submit. Clear previewAnswers defensively.
	$params->{submitAnswers} = 1;
	delete $params->{previewAnswers};

	# outputFormat lock — reView is iframe-only.
	$params->{outputFormat} = 'default';

	$c->stash(_trust_lane => 'review');
	return 1;
}

1;
