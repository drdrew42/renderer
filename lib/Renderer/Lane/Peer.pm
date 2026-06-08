package Renderer::Lane::Peer;

# Peer-signed lane (Stage 1 of the trust mesh). Two entry points:
#
#   * verify($c) — runs early, before sessionJWT decode and SENSITIVE_PARAMS
#     strip. Reads X-Peer-Name / X-Peer-Timestamp / X-Peer-Signature headers.
#     If any are present, verifies the Ed25519 signature over the canonical
#     request form. Sets the _peer_signed stash to the peer name on success;
#     returns a 401 exception via $c on bad signature; returns 1 if no
#     peer headers were present (caller continues with non-peer flow).
#
#   * apply_body($c, $params) — runs at body-lane dispatch when no JWT body
#     is present and _peer_signed is set. Sets defaults, then self-mints a
#     problemJWT wrapping the (already-trusted) inputs. The signed body is
#     not subject to SENSITIVE_PARAMS strip (handled in ParseRequest), so
#     JWTanswerURL and other sensitive params survive into the mint. The
#     HTML's hidden problemJWT field then carries continuation through
#     subsequent submits, which arrive as Lane::Problem requests — claim-
#     merge sets _can_emit_answer_jwt=1 there, so answerJWT emission works
#     normally without the editor backend re-signing every interaction.
#     See [[Trust Model and Editor Flow]].

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Renderer::Registration;
use Renderer::Util::JWT qw(mint_jwt);

use Exporter qw(import);
our @EXPORT_OK = qw(verify apply_body);

# verify($c) → 1 on continue (no peer headers OR peer verified), or the
# result of $c->exception(...) on bad signature (which short-circuits).
sub verify ($c) {
	my $peer_name = $c->req->headers->header('X-Peer-Name');
	my $peer_ts   = $c->req->headers->header('X-Peer-Timestamp');
	my $peer_sig  = $c->req->headers->header('X-Peer-Signature');

	# No peer-sig headers — not a peer-signed request. Continue to JWT/etc.
	return 1 unless defined $peer_name || defined $peer_ts || defined $peer_sig;

	my %result = Renderer::Registration::verify_peer_signature(
		method    => $c->req->method,
		path      => $c->req->url->path->to_string,
		timestamp => $peer_ts // '',
		body      => $c->req->body,
		peer_name => $peer_name // '',
		signature => $peer_sig  // '',
	);
	unless ($result{ok}) {
		$c->log->error("Peer signature verification failed: $result{reason}");
		return $c->exception("Peer signature rejected: $result{reason}", 401);
	}
	$c->log->info("Peer-signed request accepted from '$peer_name'");
	$c->stash(_peer_signed => $peer_name);
	$c->stash(_trust_lane  => 'peer');
	return 1;
}

# apply_body($c, $params) — body-lane handler when peer-verified and no
# JWT body present. Sets defaults, then self-mints a JWE problemJWT wrapping
# %params so the rendered HTML can carry continuation. Subsequent submits
# arrive as Lane::Problem requests and emit answerJWTs normally via the
# claim-merge / emission-gate path.
sub apply_body ($c, $params) {
	$params->{aud} = $ENV{SITE_HOST};
	$params->{isInstructor} //= 0;
	$params->{sessionID} ||= time;
	$params->{problemJWT} = mint_jwt(
		$ENV{problemJWTsecret}, $params,
		alg => 'PBES2-HS512+A256KW',
		enc => 'A256GCM',
	);
	return 1;
}

1;
