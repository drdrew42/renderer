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
#   * Bulk merge for everything else: claims override raw params — the whole
#     point of carrying an upstream JWT is that the upstream's view of the
#     problem context wins.
#   * `showCorrectAnswers` is mode-gated (WW3-R51): honoured only when the
#     resolved mode offers the button (no-stakes / preview). On the `custom`
#     default it does not reveal, so a student cannot self-inject it; ADAPT
#     takes reveal out of band (/answer, /solution) and drives instructor
#     reveal through isInstructor -> revealAll, so nothing legitimate needs it.
#   * Sets _can_emit_answer_jwt — this lane is upstream-grounded and may
#     produce answerJWTs.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Crypt::JWT qw(decode_jwt);
use Renderer::RenderMode qw(mode_bundle);

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

	# Bulk merge: claims override raw params (claims-always-win precedence —
	# the whole point of carrying an upstream JWT is the upstream's view of
	# the problem context wins).
	@{$params}{ keys %$claims } = values %$claims;

	# Defensive default for the permission family — fires when the claim
	# was silent on isInstructor. Without it, an LMS that mints an
	# incomplete JWT would leave $params->{isInstructor} undef (resolved to
	# 0 downstream anyway, but setting it explicitly documents intent).
	$params->{isInstructor} //= 0;

	# WW3-R51: a showCorrectAnswers reveals only when the resolved mode offers
	# the button (no-stakes / preview). On the `custom` default it does not —
	# ADAPT never sends the flag (reveal is out of band via /answer, /solution)
	# and drives instructor reveal through isInstructor -> revealAll, so a
	# lingering showCorrectAnswers here is a student self-inject on the last raw
	# reveal path left open on this lane. renderMode is claim-only on a grounded
	# lane (WW3-R51 elevation strip), so the mode is trusted — a student cannot
	# opt into an offering bundle. Mirrors Lane::Challenge's hard-zero, gated by
	# mode so an offering context keeps the button's own mechanism intact.
	$params->{showCorrectAnswers} = 0
		unless mode_bundle($params->{renderMode} // 'custom')->{showCorrectAnswersButton};

	$c->stash(_can_emit_answer_jwt => 1);
	$c->stash(_trust_lane          => 'problem');
	return 1;
}

1;
