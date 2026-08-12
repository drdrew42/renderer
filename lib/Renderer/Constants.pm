package Renderer::Constants;
use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
	SENSITIVE_PARAMS
	ELEVATION_PARAMS
	RENDER_MODE_PARAMS
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
	_reveal_grant
);

# _reveal_grant is the internal "a verified reveal sidecar granted this" flag
# (WW3-117). It must arrive only from a lane that verified a revealJWT, never
# from raw input — stripping it here is what makes it un-self-declarable, the
# same structure that closed the WW3-R46 flags.

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
# Each lane handles it according to what that lane is for:
#
#   Lane::Challenge — hard-zeroed, claim-or-nothing. Mid-play, live
#     scoring; the severe case, and shut outright.
#   Lane::Review    — still raw-form, a documented interim. WW3-117
#     replaces it with a WW3-minted permission sidecar and the flag goes
#     away entirely.
#   Lane::Problem   — LibreTexts', and unchanged. There isInstructor is an
#     AUTHORING AND BROWSING mode switch rather than a student-facing
#     permission: reveal content reaches ADAPT out of band via
#     /render-api/hint, /solution and /answer, so a student interaction
#     never needs these flags at all.
use constant ELEVATION_PARAMS => qw(
	isInstructor
);

# Render-MODE selectors — a renderMode picks a primitive-flag bundle
# (Renderer::RenderMode), and two bundles ELEVATE: `preview` sets
# isInstructor=1 (→ revealAll) and `preview`/`no-stakes` set
# showCorrectAnswersButton=1. So a raw `renderMode=preview` re-derives the very
# isInstructor that ELEVATION_PARAMS strips — the WW3-R46 defect class, one
# indirection over. Measured 2026-08-12 on the homelab: a student's own
# challengeJWT plus a raw `renderMode=preview` resolved to revealAll mid-play
# (8452 bytes against a 6584 baseline — the R46 footprint).
#
# So renderMode is trusted-claim-only on grounded lanes: stripped from raw input
# alongside ELEVATION_PARAMS, with the SAME grounded-only exemption (an
# ungrounded STRICT_JWT=0 editor legitimately previews with renderMode=preview;
# STRICT_JWT=1 refuses ungrounded requests at the entry gate regardless). A lane
# carrying a renderMode CLAIM recovers it (Lane::Challenge reads it,
# Lane::Problem bulk-merges it); otherwise it is simply absent and
# resolve_render_mode maps undef → 'custom', the student passthrough.
#
# A separate list, not more ELEVATION_PARAMS entries: an elevation param has a
# meaningful default of 0 that every lane must land on, and renderMode does not
# — absence IS its safe default, so it needs no per-lane landing and is not
# stashed for restoration.
use constant RENDER_MODE_PARAMS => qw(
	renderMode
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
