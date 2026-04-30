package Renderer::Lane::Ungrounded;

# Ungrounded body lane — no JWT body, no peer signature. Two configs
# govern behavior; both stay inside this lane (they're config responses,
# not structural lane differences):
#
#   * STRICT_JWT — entry gate. When truthy, reject ungrounded requests
#     outright (401). Public/student instances should set this; VPC-
#     isolated editor renderers can leave unset.
#
#   * SELF_MINT_DISABLED — UX opt-out. When falsy (the default), the
#     renderer wraps the inbound %params in a self-minted problemJWT
#     (JWE) so the next render flows through the standard sessionJWT
#     round-trip without the consumer re-mailing every parameter. Set
#     SELF_MINT_DISABLED=1 for raw-passthrough deployments.
#
# Self-minted JWTs cannot carry JWTanswerURL (stripped from raw params,
# only re-injected from upstream claims) so _can_emit_answer_jwt stays
# unset and answerJWTs cannot be produced even after round-tripping.
#
# Note: this lane fires only when outputFormat != 'ptx'. PTX renders skip
# the body-lane entirely (no JWT minted, no defaults applied) — handled
# by the dispatcher in parseRequest.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Renderer::Util::JWT qw(mint_jwt);

use Exporter qw(import);
our @EXPORT_OK = qw(apply);

sub apply ($c, $params) {
	$c->stash(_trust_lane => 'ungrounded');

	# Entry gate.
	if ($ENV{STRICT_JWT}) {
		return $c->exception('Request requires a problemJWT, sessionJWT, or X-Peer-Signature.', 401);
	}

	# Self-mint (UX opinion). Default on; SELF_MINT_DISABLED=1 to opt out.
	unless ($ENV{SELF_MINT_DISABLED}) {
		$params->{aud}            = $ENV{SITE_HOST};
		$params->{isInstructor} //= 0;
		$params->{sessionID}    ||= time;
		$params->{problemJWT} = mint_jwt(
			$ENV{problemJWTsecret}, $params,
			alg => 'PBES2-HS512+A256KW',
			enc => 'A256GCM',
		);
	}

	return 1;
}

1;
