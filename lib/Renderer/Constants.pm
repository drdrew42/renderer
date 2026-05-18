package Renderer::Constants;
use strict;
use warnings;

use Exporter 'import';

our @EXPORT_OK = qw(
	SENSITIVE_PARAMS
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
