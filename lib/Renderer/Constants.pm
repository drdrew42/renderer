package Renderer::Constants;
use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
	SENSITIVE_PARAMS
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
