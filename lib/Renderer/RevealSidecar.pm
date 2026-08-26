package Renderer::RevealSidecar;

# The permission sidecar (WW3-117). A `revealJWT` rides alongside a body token
# — the submissionJWT on reView, the challengeJWT on live-play inspection
# (WW3-119) — and carries the answer reveal as a signed CLAIM rather than a form
# field the student controls (the WW3-R46 class of hole). This module is the
# trust boundary: verify() decides whether the claim stands, and only then does
# a lane set `_reveal_grant`, which resolve_permissions expands to answers +
# solutions.
#
# Opposite rules to the SOURCE sidecar (Lane::Session, LTW-088): a source
# sidecar carries "what content" and trust claims NEVER cross from it; a
# permission sidecar carries "what may be revealed", and that crossing is its
# entire purpose. See WeBWorK3/Answer Reveal Model.
#
# The grant is play-scoped: bound to the play_id of the body token it rides
# beside, so a captured sidecar is not a master key. Signature
# (problemJWTsecret), aud (SITE_HOST), and exp (short TTL) are the renderer's
# checks; the mint owns who-may-reveal, resolved server-side by WW3.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Renderer::Util::JWT qw(verify_problem_jwt);

use Exporter qw(import);
our @EXPORT_OK = qw(verify);

# verify($c, $params, $expected_play_id) → 1 when a valid, play-bound revealJWT
# is present; a false value otherwise. Never dies: an absent, malformed,
# expired, mis-signed, or mis-bound sidecar simply does not grant, and the
# render falls to the student default.
#
# The grant is binary — a valid bound sidecar reveals answers AND solutions,
# one grant. The sidecar's own showCorrectAnswers/showSolutions claims are the
# mint's declared intent (both) and are reserved for a future granular reveal;
# the renderer does not distinguish them today.
sub verify ($c, $params, $expected_play_id) {
	my $token = $params->{revealJWT};
	return 0 unless defined $token && length $token;

	# No play to bind against ⇒ nothing to anchor the grant. A body token that
	# carries no play_id cannot host a play-scoped sidecar.
	return 0 unless defined $expected_play_id && length $expected_play_id;

	# exp is enforced (verify_problem_jwt defaults verify_exp => 1) — a lapsed
	# sidecar does not grant. A short TTL is the sidecar's replay window.
	my ($claims, $err) = verify_problem_jwt($token);
	if ($err) {
		$c->log->info("revealJWT rejected: $err");
		return 0;
	}

	# Binding: the sidecar must name the same play as the body token it rides
	# beside. A mismatch means it was minted for a different play — ignore it,
	# so a sidecar captured from one reView cannot unlock another.
	unless (defined $claims->{play_id} && $claims->{play_id} eq $expected_play_id) {
		$c->log->info("revealJWT play_id mismatch — not granting");
		return 0;
	}

	return 1;
}

1;
