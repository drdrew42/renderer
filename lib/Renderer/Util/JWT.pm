package Renderer::Util::JWT;

# One-stop helper for the renderer's JWT minting AND problemJWT verification.
# Wraps Crypt::JWT::encode_jwt with sensible defaults (HS256 + auto_iat=1) and
# named-arg ergonomics, so each mint site is a one-liner and the alg/enc/auto_iat
# policy lives in one place. If signing policy ever changes (e.g., the Theme 2
# hint at moving inbound LMS-readable JWTs to Ed25519), this is the single hook
# point.
#
# verify_problem_jwt is the mirror on the decode side: the single problemJWT
# verify entry point every problemJWT-keyed lane calls (Lane::Problem /
# Challenge / Review / ContentFetch + RevealSidecar). Before this, each lane
# ran its own decode_jwt and the copies diverged — Lane::Problem carried
# verify_exp and provider-hoist while the others omitted the alg pin — which is
# how Challenge and Review ended up unprotected while Problem was hardened. One
# decoder, one alg policy, per-lane behaviour expressed as options.
#
# Usage:
#   use Renderer::Util::JWT qw(mint_jwt);
#
#   # HS256 (default alg, auto_iat=1)
#   my $jwt = mint_jwt($secret, $payload);
#
#   # JWE (alg + enc opts override defaults)
#   my $jwe = mint_jwt($secret, $payload,
#       alg => 'PBES2-HS512+A256KW',
#       enc => 'A256GCM',
#   );
#
#   # Suppress auto-iat (rare; existing call sites all want it)
#   my $jwt = mint_jwt($secret, $payload, auto_iat => 0);

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Exporter   qw(import);
use Crypt::JWT qw(encode_jwt decode_jwt);

our @EXPORT_OK = qw(mint_jwt self_mint_problem_jwt verify_problem_jwt PROBLEM_JWT_ALGS);

# The allow-list of acceptable `alg` header values for an inbound problemJWT.
# HS256 is the LMS/orchestrator mint (VerdictJWT.pm pins the same value on the
# verdict/session tokens); PBES2-HS512+A256KW is the JWE the self-mint and peer
# lanes produce (Lane/{Ungrounded,Peer}.pm) and which re-decodes here as a
# continuation problemJWT — so a single-value pin would break self-mint
# continuations. A 2-element allow-list still rejects `none` and every
# alg-confusion variant (e.g. HS384), which is the whole point of pinning it:
# omitting accepted_alg honours whatever alg the token declares as long as it
# validates.
use constant PROBLEM_JWT_ALGS => [qw(HS256 PBES2-HS512+A256KW)];

sub mint_jwt ($secret, $payload, %opts) {
	return encode_jwt(
		payload  => $payload,
		key      => $secret,
		alg      => $opts{alg}      // 'HS256',
		auto_iat => $opts{auto_iat} // 1,
		($opts{enc} ? (enc => $opts{enc}) : ()),
	);
}

# self_mint_problem_jwt($params) — wrap the (already-trusted) %$params in a JWE
# problemJWT so the rendered HTML can carry continuation without the consumer
# re-mailing every parameter. Sets the baseline mint claims (aud, isInstructor
# default, sessionID) on $params in place, then stores the token under
# $params->{problemJWT} and returns it. Shared by the ungrounded self-mint UX
# (Lane::Ungrounded) and the peer-verified body lane (Lane::Peer), which mint
# identically.
sub self_mint_problem_jwt ($params) {
	$params->{aud} = $ENV{SITE_HOST};
	$params->{isInstructor} //= 0;
	$params->{sessionID} ||= time;
	$params->{problemJWT}   = mint_jwt(
		$ENV{problemJWTsecret}, $params,
		alg => 'PBES2-HS512+A256KW',
		enc => 'A256GCM',
	);
	return $params->{problemJWT};
}

# verify_problem_jwt($token, %opts) → (\%claims, undef) | (undef, $err)
#
# Decode + verify a problemJWT under problemJWTsecret with verify_aud =>
# SITE_HOST and the PROBLEM_JWT_ALGS allow-list. Returns the error string
# rather than croaking so each caller decides how to short-circuit (a
# credential_error, a typed 401, or a silent no-grant on the sidecar).
#
# Options:
#   verify_exp     — passed through to decode_jwt when supplied. Omitted by
#                    default, which is Crypt::JWT's verify-if-present behaviour
#                    (an exp claim, if the token carries one, must not be past;
#                    a token with no exp is fine) — what Challenge / Review /
#                    ContentFetch / RevealSidecar have always relied on. NOT the
#                    same as passing an explicit 1, which would additionally
#                    REQUIRE an exp claim. Lane::Problem passes 0 to ignore exp
#                    outright: the renderer is not the issuer of a problemJWT's
#                    exp (the LMS is), and a nested problemJWT rides verbatim
#                    inside our sessionJWT, so it must outlive its own launch-TTL
#                    across a continuing session.
#   hoist_provider — when true, unwrap a LibreTexts `webwork` provider envelope
#                    ($claims = $claims->{webwork}) after a successful decode.
sub verify_problem_jwt ($token, %opts) {
	my $claims;
	eval {
		$claims = decode_jwt(
			token        => $token,
			key          => $ENV{problemJWTsecret},
			verify_aud   => $ENV{SITE_HOST},
			accepted_alg => PROBLEM_JWT_ALGS,
			(exists $opts{verify_exp} ? (verify_exp => $opts{verify_exp}) : ()),
		);
		1;
	} or do {
		return (undef, $@);
	};

	$claims = $claims->{webwork} if $opts{hoist_provider} && defined $claims->{webwork};
	return ($claims, undef);
}

1;
