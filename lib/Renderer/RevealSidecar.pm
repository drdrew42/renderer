package Renderer::RevealSidecar;

# The permission sidecar (WW3-117). A `revealJWT` rides alongside a body token
# — the submissionJWT on reView, the challengeJWT on live-play inspection
# (WW3-119) — and carries its grants as signed CLAIMS rather than form fields
# the student controls (the WW3-R46 class of hole). This module is the trust
# boundary: verify() decides which grants stand, and only then does a lane act
# on them — `reveal` sets `_reveal_grant`, which resolve_permissions expands to
# answers + solutions; `debug` sets view_problem_debugging_info (WW3-R58).
#
# Opposite rules to the SOURCE sidecar (Lane::Session, LTW-088): a source
# sidecar carries "what content" and trust claims NEVER cross from it; a
# permission sidecar carries "what this render may show", and that crossing is
# its entire purpose. See WeBWorK3/Answer Reveal Model.
#
# The sidecar is play-scoped: bound to the play_id of the body token it rides
# beside, so a captured sidecar is not a master key. Signature
# (problemJWTsecret), aud (SITE_HOST), and exp (short TTL) are the renderer's
# checks; the mint owns who may hold which grant, resolved server-side by WW3.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Renderer::Util::JWT qw(verify_problem_jwt);

use Exporter qw(import);
our @EXPORT_OK = qw(verify);

# The grant names a sidecar may carry, in the order the mint lists them.
our @GRANTS = qw(reveal debug);

# verify($c, $params, $expected_play_id) → hashref of the granted names, e.g.
# { reveal => 1, debug => 1 }; an empty hashref when nothing is granted. Never
# dies: an absent, malformed, expired, mis-signed, or mis-bound sidecar grants
# nothing, and the render falls to the student default.
#
#   reveal — answers AND solutions, one grant.
#   debug  — PG's debugging view (view_problem_debugging_info).
#
# The `grants` claim lists what the sidecar unlocks. A sidecar without one, or
# with names outside @GRANTS, grants nothing.
sub verify ($c, $params, $expected_play_id) {
	my $token = $params->{revealJWT};
	return {} unless defined $token && length $token;

	# No play to bind against ⇒ nothing to anchor the grant. A body token that
	# carries no play_id cannot host a play-scoped sidecar.
	return {} unless defined $expected_play_id && length $expected_play_id;

	# exp is enforced (verify_problem_jwt defaults verify_exp => 1) — a lapsed
	# sidecar does not grant. A short TTL is the sidecar's replay window.
	my ($claims, $err) = verify_problem_jwt($token);
	if ($err) {
		$c->log->info("revealJWT rejected: $err");
		return {};
	}

	# Binding: the sidecar must name the same play as the body token it rides
	# beside. A mismatch means it was minted for a different play — ignore it,
	# so a sidecar captured from one reView cannot unlock another.
	unless (defined $claims->{play_id} && $claims->{play_id} eq $expected_play_id) {
		$c->log->info("revealJWT play_id mismatch — not granting");
		return {};
	}

	my $grants = $claims->{grants};
	unless (ref $grants eq 'ARRAY') {
		$c->log->info("revealJWT grants is absent or not a list — not granting");
		return {};
	}
	my %named = map { $_ => 1 } grep { defined && !ref } @$grants;
	return { map { $_ => 1 } grep { $named{$_} } @GRANTS };
}

1;
