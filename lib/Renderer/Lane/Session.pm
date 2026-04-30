package Renderer::Lane::Session;

# Session prefix lane. Combines with any body lane (Problem/Challenge/Peer/
# Ungrounded). When a sessionJWT is present, this runs before body-lane
# dispatch and applies the renderer's continuation-state contract:
#
#   * Decode + verify_iss against $SITE_HOST under webworkJWTsecret.
#   * Security-sensitive claims always win over raw params (prevents
#     student-side claw-back of isLocked / isInstructor / answersRevealed
#     / answersSubmitted, plus showCorrectAnswers backward-compat).
#   * For all other claims, raw params win (current responses vs prior).
#   * problemJWT must come from session (deleted from raw params first).
#   * Hoist embedded challenge_jwt → challengeJWT so the body-lane
#     dispatcher recognizes form-submit re-renders as challengeJWT-lane.
#
# answersRevealed / solutionsRevealed propagate as session state (visible
# to LMS via answerJWT, sticky across renders) but do NOT auto-fire any
# directive on subsequent renders. Cross-render directive-persistence is
# a caller concern. The cumulative ratchet semantics live in
# WeBWorK::RenderProblem::generateJWTs (WW3-R29 dual-state model).

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Crypt::JWT qw(decode_jwt);

use Exporter qw(import);
our @EXPORT_OK = qw(apply_prefix);

# apply_prefix($c, $params)
#
# Runs only when $params->{sessionJWT} is defined. Decodes and merges into
# $params. Returns 1 on success, returns the result of $c->croak(...) on
# decode failure (which short-circuits the controller).
sub apply_prefix ($c, $params) {
	my $sessionJWT = $params->{sessionJWT};
	$c->log->info("Received JWT: using sessionJWT");

	my $claims;
	eval {
		$claims = decode_jwt(
			token      => $sessionJWT,
			key        => $ENV{webworkJWTsecret},
			verify_iss => $ENV{SITE_HOST},
		);
		1;
	} or do {
		return $c->croak($@, 3);
	};

	# Security-sensitive claims always win over raw params.
	for (qw(isLocked isInstructor showCorrectAnswers answersRevealed solutionsRevealed answersSubmitted)) {
		$params->{$_} = $claims->{$_} if exists $claims->{$_};
	}

	# Bulk merge: raw params win for everything else (current responses
	# beat prior). problemJWT must come from session for consistency.
	delete $params->{problemJWT};
	foreach my $key (keys %$claims) {
		$params->{$key} //= $claims->{$key};
	}

	# Hoist embedded challenge_jwt (snake_case JWT claim) → challengeJWT
	# (camelCase form param) so the body-lane dispatcher recognizes
	# form-submit re-renders as challengeJWT-lane. Without this, sessionJWT
	# carries challenge_jwt as a claim but the dispatch falls through to
	# the entry gate, pg_hash never resolves.
	if (!defined $params->{challengeJWT} && defined $params->{challenge_jwt}) {
		$params->{challengeJWT} = $params->{challenge_jwt};
	}

	return 1;
}

1;
