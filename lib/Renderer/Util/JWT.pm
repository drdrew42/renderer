package Renderer::Util::JWT;

# One-stop helper for the renderer's JWT minting. Wraps Crypt::JWT::encode_jwt
# with sensible defaults (HS256 + auto_iat=1) and named-arg ergonomics, so
# each mint site is a one-liner and the alg/enc/auto_iat policy lives in one
# place. If signing policy ever changes (e.g., the Theme 2 hint at moving
# inbound LMS-readable JWTs to Ed25519), this is the single hook point.
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

use Exporter qw(import);
use Crypt::JWT qw(encode_jwt);

our @EXPORT_OK = qw(mint_jwt);

sub mint_jwt ($secret, $payload, %opts) {
	return encode_jwt(
		payload  => $payload,
		key      => $secret,
		alg      => $opts{alg}      // 'HS256',
		auto_iat => $opts{auto_iat} // 1,
		($opts{enc} ? (enc => $opts{enc}) : ()),
	);
}

1;
