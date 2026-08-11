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
			# The renderer is not the issuer of a problemJWT's `exp` — the LMS
			# (ADAPT/LibreTexts) is. We must not enforce it: the nested
			# ("matryoshka") problemJWT is embedded verbatim in our sessionJWT
			# and is meant to outlive its own launch-TTL across a continuing
			# session, so honoring `exp` here breaks every render past the
			# launch window (and instructor review). Once a problemJWT is
			# accepted into our session, the session — not the launch token —
			# governs continuation lifetime. Provenance is still the HMAC under
			# problemJWTsecret; persistence/scoring is still gated by the
			# JWTanswerURL POST the LMS controls.
			verify_exp => 0,
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

	# `isInstructor` claim-only. The raw-form value is stripped centrally in
	# ParseRequest now (ELEVATION_PARAMS, WW3-R46), so the hand-rolled
	# `delete` that used to sit here is gone — two mechanisms for one rule
	# is how the next lane's author picks the wrong one by proximity, which
	# is exactly how Lane::Challenge and Lane::Review ended up unprotected
	# while this lane was hardened in WW3-R41.

	# `showCorrectAnswers` is kept out of ELEVATION_PARAMS deliberately — it is
	# the self-reveal button's own mechanism on the modes that offer it. But this
	# lane's callers (ADAPT/LibreTexts) never offer that button and never send
	# the flag, so a raw student `showCorrectAnswers=1` here is pure self-reveal:
	# the WW3-R46 class of hole, previously unpatched on this lane. Strip the raw
	# value so a student cannot inject it; a signed claim below may still set it
	# (LMS-controlled reveal), and instructors reveal via the isInstructor claim
	# regardless. Lane-local, so the legitimate no-stakes/preview button on other
	# lanes is untouched.
	delete $params->{showCorrectAnswers};

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
	$c->stash(_trust_lane          => 'problem');
	return 1;
}

1;
