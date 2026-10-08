package Renderer::Constants;
use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
	SENSITIVE_PARAMS
	ELEVATION_PARAMS
	RENDER_MODE_PARAMS
	TOKEN_CONTENT_PARAMS
	DEBUG_PARAMS
	RETIRED_PARAMS
	DEFAULT_SEED
	SEED_DEFAULTED_WARNING
	SOURCE_OVERRIDE_FIELDS
	SESSION_STATE_CLAIMS
	ANSWER_RESPONSE_SUBJECT
	ANSWER_RESPONSE_DEFAULT_MESSAGE
	PLATFORM_NAME
	OPL_SIGNATURE_HEADER
	OPL_PUBLICKEY_HEADER
	OPL_SIGNATURE_HEADER_LEGACY
	OPL_PUBLICKEY_HEADER_LEGACY
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
	_reveal_grant
	baseURL
	formURL
	formAction
	extra_header_text
	noCache
	hideElements
	interactLabel
);

# baseURL, formURL (formAction, its peer-facing name), extra_header_text,
# noCache, hideElements and interactLabel are INTEGRATOR settings: a proxying
# LMS routes form posts and assets through itself, adds head markup, forces a
# fresh fetch, hides page elements, or names the interact button. They arrive
# in a token claim or a peer body. From raw input they would let whoever built
# the URL set the page's <base href>, its form target, unescaped <head>
# markup, an OPL fetch on every render, which elements the page hides
# (WW3-R69), or the words on the page's one action (WW3-R70). Both formURL and formAction are
# listed because _parse_envelope renames formAction before the strip.

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
use constant ELEVATION_PARAMS => qw(
	isInstructor
);

# Render-MODE selectors — a renderMode picks a primitive-flag bundle
# (Renderer::RenderMode), and the `preview` bundle ELEVATES: it sets
# isInstructor=1 (→ revealAll). So a raw `renderMode=preview` re-derives the very
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

# What is rendered and at which seed: on a token-bearing request these come
# only from the token (WW3-R68). Stripped from raw input on grounded requests
# (ParseRequest) and on the content-fetch lane (Lane::ContentFetch), with the
# same verified-peer exemption as the lists above. A lane recovers each from its
# claim — Lane::Problem's bulk merge, Lane::Session's pg_hash and nested
# problemJWT, Lane::Challenge's problems[] entry, Lane::Review's claims.
#
# Raw input here would let a student holding their own token render a source of
# their choosing — or the same content at a seed of their choosing — while the
# outbound answerJWT / submissionJWT reports that score against the content the
# token named. Measured 2026-10-06 on the homelab: a student challengeJWT plus a
# raw problemSource whose answer is 1 recorded score 1, counted, under the
# claim's pg_hash and seed; the same submit without it scored 0.
#
# Ungrounded requests (STRICT_JWT=0) keep raw source: that deployment admitted
# them on network position, the editor-preview posture.
use constant TOKEN_CONTENT_PARAMS => qw(
	problemSource
	problemSourceURL
	sourceFilePath
	pg_hash
	problemSeed
);

# PG's debugging view: on a problem that errors, view_problem_debugging_info
# prints the caught error text, backend warnings, and the problem's full source
# (Translator.pm "Input Read"), which carries the answer computation. Stripped
# from raw input on grounded requests (ParseRequest), with the same
# verified-peer exemption as the lists above. A lane recovers it from a signed
# source: Lane::Problem's bulk merge of the problemJWT claim, and on
# Lane::Challenge and Lane::Review the reveal sidecar's `debug` grant
# (Renderer::RevealSidecar). Absent, it defaults to isInstructor in
# WeBWorK::RenderProblem.
#
# Ungrounded requests (STRICT_JWT=0) keep the raw flag: the caller sent the
# source.
use constant DEBUG_PARAMS => qw(
	view_problem_debugging_info
);

# Retired parameters (WW3-R67): the in-render answer reveal and its button.
# Answers reach a render through isInstructor or a verified reveal sidecar
# (Renderer::Permissions) and reach a student through /render-api/answer.
# Deleted after the lanes from every source — raw, token claim, session claim
# and peer body — so a sender that still includes them renders exactly as if
# it had not; LibreTexts, for one, signs showCorrectAnswersButton=0.
use constant RETIRED_PARAMS => qw(
	showCorrectAnswers
	showCorrectAnswersButton
);

# The seed a render uses when its request names none, absent or empty, on every
# lane (Renderer::Seed).
use constant DEFAULT_SEED => 1234;

# The `warnings` entry a render carries when its request named no seed and it
# used DEFAULT_SEED (WW3-R68, WW3-R73): on the outbound answerJWT /
# submissionJWT, and on the content-fetch JSON response. Integrators can send
# an empty seed, so this warns rather than refuses.
use constant SEED_DEFAULTED_WARNING => 'seed_defaulted';

# Problem-source fields a sidecar problemJWT may override on an in-flight
# sessionJWT (LTW-088). Whitelist — trust/routing/state claims (JWTanswerURL,
# parent_origin, isInstructor, answersSubmitted) never cross from this source
# sidecar; only "what content" does. Reveal permission arrives through the
# separate permission sidecar (Renderer::RevealSidecar, WW3-117). Applied ATOMICALLY: any sidecar source
# field triggers replacement of the entire nested source bundle, so a stale
# pg_hash can never ride alongside a freshly-pointed problemSourceURL (the
# SourceResolver serves cached content by hash, zero-network).
use constant SOURCE_OVERRIDE_FIELDS => qw(
	problemSourceURL
	sourceFilePath
	pg_hash
	problemSource
);

# The claims a renderer-minted sessionJWT carries as session state — every
# claim the two minters write (WeBWorK::RenderProblem generateJWTs for the
# problem lane, generatePlaySessionJWT and WeBWorK::VerdictJWT for the
# challenge lane) other than the answer labels generateJWTs copies from PG's
# KEPT_EXTRA_ANSWERS. isInstructor is the claim Lane::Session has always held
# over raw input. Lane::Session applies each of
# these over a raw param of the same name; any other session claim is a
# student answer field, and the current render's raw value for it wins
# (WW3-205). t/session_precedence.t pins this list to the minters.
use constant SESSION_STATE_CLAIMS => qw(
	iss
	aud
	iat
	sessionID
	problemUUID
	problemJWT
	pg_hash
	numCorrect
	numIncorrect
	answersSubmitted
	isInstructor
	challenge_jwt
	state
	mint_sequence
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

# OPL↔renderer Ed25519 request-auth headers. The "X-Telemetry-" prefix is
# HISTORICAL: these gate OPL-signed cache-invalidation callbacks and audit
# endpoints (Renderer::OPLAuthed) and the renderer's TOFU registration POST
# (Renderer::Registration) — NOT telemetry. The actual telemetry POST that
# earned the name lives in Renderer::Telemetry and keeps the legacy header.
#
# The neutral X-OPL- names are canonical. The legacy names stay accepted on
# the verify side and are still sent alongside the new ones, so an in-flight
# OPL that has not learned the new names is not broken during the rollover.
use constant OPL_SIGNATURE_HEADER        => 'X-OPL-Signature';
use constant OPL_PUBLICKEY_HEADER        => 'X-OPL-PublicKey';
use constant OPL_SIGNATURE_HEADER_LEGACY => 'X-Telemetry-Signature';
use constant OPL_PUBLICKEY_HEADER_LEGACY => 'X-Telemetry-PublicKey';

1;
