package Renderer::Lane::Problem;

# problemJWT body lane — single-renderer integrators (LMS-minted; LibreTexts/
# ADAPT origin, but the shape suits any LMS or editor wanting a one-token,
# one-problem render without an orchestrator chain).
#
#   * Decode + verify_aud against $SITE_HOST under problemJWTsecret.
#   * LibreTexts wraps claims under a `webwork` provider key; hoist if present.
#   * `isInstructor` reads ONLY from claims — never from raw form params.
#     If the LMS omits the claim, defaults to 0 (student). This closes the
#     "LMS mints incomplete claims, raw form `isInstructor=1` wins" edge
#     case. Stable across renders; an LMS that wants instructor preview
#     mints with `isInstructor=1` once.
#   * Bulk merge for everything else: claims override raw params. This
#     includes per-render directives like `showCorrectAnswers` (the LMS's
#     "Show Correct Answers" toggle is render-time, not session-time —
#     keeping it claim-or-form lets the LMS update it per render without
#     re-establishing the session).
#   * Sets _can_emit_answer_jwt — this lane is upstream-grounded and may
#     produce answerJWTs.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Crypt::JWT qw(decode_jwt);

use Exporter qw(import);
our @EXPORT_OK = qw(apply decode_claims);

# decode_claims($c, $token) → (\%claims, undef) | (undef, $err)
#
# Decode a problemJWT under problemJWTsecret with verify_aud => SITE_HOST and
# hoist the LibreTexts `webwork` provider wrapper. Shared by apply() (body
# lane) and Renderer::Lane::Session's sidecar source-override (LTW-088) so
# both decode a problemJWT through exactly one path. Returns the error string
# rather than croaking so the caller decides how to short-circuit.
sub decode_claims ($c, $token) {
	my $claims;
	eval {
		$claims = decode_jwt(
			token      => $token,
			key        => $ENV{problemJWTsecret},
			verify_aud => $ENV{SITE_HOST},
		);
		1;
	} or do {
		return (undef, $@);
	};

	# LibreTexts wraps claims under a provider key.
	$claims = $claims->{webwork} if defined $claims->{webwork};
	return ($claims, undef);
}

sub apply ($c, $params) {
	$c->log->info("Received JWT: using problemJWT");

	my ($claims, $err) = decode_claims($c, $params->{problemJWT});
	return $c->croak($err, 3) if $err;

	# `isInstructor` claim-only: drop any raw-form value first so the claim
	# is the only possible source. Prevents form-param elevation when the
	# LMS mints a JWT without speaking to instructor identity.
	delete $params->{isInstructor};

	# Bulk merge: claims override raw params (claims-always-win precedence —
	# the whole point of carrying an upstream JWT is the upstream's view of
	# the problem context wins).
	@{$params}{ keys %$claims } = values %$claims;

	# Defensive default for the permission family — fires when the claim
	# was silent on isInstructor. Without it, an LMS that mints an
	# incomplete JWT would leave $params->{isInstructor} undef (resolved to
	# 0 downstream anyway, but setting it explicitly documents intent).
	$params->{isInstructor} //= 0;

	$c->stash(_can_emit_answer_jwt => 1);
	$c->stash(_trust_lane         => 'problem');
	return 1;
}

1;
