package Renderer::Constants;
use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
	SENSITIVE_PARAMS
	ELEVATION_PARAMS
	SOURCE_OVERRIDE_FIELDS
	ANSWER_RESPONSE_SUBJECT
	ANSWER_RESPONSE_DEFAULT_MESSAGE
	PLATFORM_NAME
);

# Parameters that may only arrive from a trusted source. Stripped from raw
# inputs in Renderer::Render::ParseRequest before lane dispatch so that an
# unauthenticated caller cannot self-declare them. Verified peer-signed
# bodies are EXEMPT from the strip — a valid peer signature is itself the
# trust gate, and the signed body is as trustworthy as a JWT claim. JWT-
# bearing requests recover stripped values via the lane claim merges.
# Also consulted by the self-mint payload builder — the self-mint wraps
# %params wholesale, so any sensitive key not stripped here would leak
# back in as a trusted claim.
use constant SENSITIVE_PARAMS => qw(
	JWTanswerURL
	sessionID
	numCorrect
	numIncorrect
	parent_origin
	answersRequested
	solutionsRequested
	answersRevealed
	solutionsRevealed
);

# Params that ELEVATE what a render reveals. Stripped from raw inputs
# alongside SENSITIVE_PARAMS, with the same peer-signed exemption, so that
# a caller cannot self-declare their way into content (WW3-R46).
#
# Why a second list rather than more SENSITIVE_PARAMS entries: these are
# recovered differently. A SENSITIVE_PARAM is restored by a lane's claim
# merge and is otherwise simply absent. An elevation param has a MEANINGFUL
# DEFAULT — 0, the student view — and every lane must land on it rather
# than leave the key undef for resolve_permissions to interpret. Keeping
# the lists separate keeps that asymmetry visible instead of encoding it in
# which of nine names you happen to be looking at.
#
# WW3-R41 hardened Lane::Problem by hand (`delete $params->{isInstructor}`,
# then claim-only). Lane::Challenge and Lane::Review never got the same
# treatment: both carry only `//= 0`, which assigns when the value is
# UNDEF and therefore does nothing to a form-supplied 1. Measured
# 2026-08-05 on the homelab — a student's own challengeJWT plus
# `isInstructor=1` resolved to revealAll (canonical answer AND worked
# solution) mid-play, 8,451 bytes against a 6,583-byte baseline.
#
# Care does not generalize; structure does. Stripping here means a new
# lane inherits the protection by existing, rather than by its author
# remembering.
#
# showCorrectAnswers is deliberately NOT in this list. It is the "Show
# Correct Answers" BUTTON's own mechanism — the rendered form posts it back
# when a student presses the button the mode bundle chose to display. So
# stripping it does not close a hole, it breaks the affordance; the tests
# that exercise the reveal ratchet fail for exactly that reason.
#
# The real defect there is narrower and lives elsewhere: the mode bundle
# decides whether to OFFER the reveal (`showCorrectAnswersButton` is 0 in
# default / no-feedback / review, 1 only in no-stakes / preview), and
# nothing enforces that a caller who was not offered it cannot send the
# param anyway. Hiding a button is not refusing an action. See WW3-R46 for
# the proposal to honour showCorrectAnswers only when the resolved bundle
# offers it.
use constant ELEVATION_PARAMS => qw(
	isInstructor
);

# Problem-source fields a sidecar problemJWT may override on an in-flight
# sessionJWT (LTW-088). Whitelist — trust/routing/state claims (JWTanswerURL,
# parent_origin, isInstructor, the reveal/submit ratchet) never cross from a
# sidecar; only "what content" does. Applied ATOMICALLY: any sidecar source
# field triggers replacement of the entire nested source bundle, so a stale
# pg_hash can never ride alongside a freshly-pointed problemSourceURL (the
# SourceResolver serves cached content by hash, zero-network).
use constant SOURCE_OVERRIDE_FIELDS => qw(
	problemSourceURL
	sourceFilePath
	pg_hash
	problemSource
);

# answerJWT response envelope defaults (legacy lane sendAnswerJWT and
# challengeJWT lane sendSubmissionEnvelope). Subject identifies the message
# type; default message is overwritten by the upstream answerURL response.
use constant ANSWER_RESPONSE_SUBJECT         => 'webwork.result';
use constant ANSWER_RESPONSE_DEFAULT_MESSAGE => 'initial message';

# Platform claim on the answerJWT — identifies the renderer to downstream
# consumers (LMS, ADAPT). Distinct from the standaloneRenderer() sub name in
# WeBWorK::RenderProblem, which is the PG entry-point function.
use constant PLATFORM_NAME => 'standaloneRenderer';

1;
