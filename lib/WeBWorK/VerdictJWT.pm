package WeBWorK::VerdictJWT;

# Verdict-fold primitive for the challengeJWT trust lane.
#
# Per WeBWorK3/Tasks/backlog/WW3-053, the renderer mints sessionJWT_{k+1}
# from the orchestrator's signed verdict. This module is the single source
# of truth for that operation — both the render-time fold (when the portal
# threads verdict_signed through a render request on the RESUME path) and
# the post-answer-URL fold (when sendSubmissionEnvelope returns a verdict
# in its response body) call into it.
#
# # The fold contract
#
# Input:
#   - $base_session_jwt    — the renderer-minted sessionJWT we're folding
#                            into. For render-time fold this is the inbound
#                            session_jwt from the portal; for post-POST it
#                            is the pre-POST mint we just sent.
#   - $verdict_signed      — orchestrator-signed JWS wrapping a Verdict.
#   - $orchestrator_secret — HS256 secret used to verify $verdict_signed
#                            (problemJWTsecret — same trust foundation as
#                            challengeJWT verification).
#   - $renderer_secret     — HS256 secret used to verify $base_session_jwt
#                            and sign the new sessionJWT (webworkJWTsecret).
#
# Output:
#   - ($new_session_jwt, undef) on success
#   - (undef, $error_string)    on any verification or shape failure
#
# # Verification gates (in order)
#
#   1. $verdict_signed signature verifies under $orchestrator_secret (HS256).
#   2. Required claims present: play_id, mint_sequence_basis, verdict.
#   3. $base_session_jwt signature verifies under $renderer_secret (HS256).
#   4. $base_session_jwt has an embedded challenge_jwt (carries play_id).
#   5. verdict.play_id == base_session_jwt.embedded_challenge_jwt.play_id
#      (replay-prevention: a verdict for a different play cannot be folded
#      into this session).
#   6. verdict.mint_sequence_basis >= base_session_jwt.mint_sequence
#      (replay-prevention: a stale verdict computed against an older session
#      cannot be folded into a newer one — would silently regress state).
#
# # The fold itself
#
#   - state.current_focus  ← verdict.current_focus
#   - state.next_available ← verdict.next_available  (defaults to [])
#   - state.draws[]        ← base.state.draws ∪ verdict.draw_next  (open mode)
#   - state.finalization   ← verdict.finalization
#   - state.started_at     ← base.state.started_at  (preserved — duration
#                            anchor doesn't move under verdict folding)
#   - mint_sequence        ← base.mint_sequence + 1
#   - challenge_jwt        ← base.challenge_jwt   (re-embed verbatim)
#   - iss/aud              ← $ENV{SITE_HOST}      (same as generatePlaySessionJWT)
#
# # Why a separate module
#
# Two callsites share this exact logic — one in parseRequest (render-time
# fold of a portal-supplied verdict) and one in the submit handler (fold
# of the answer-URL response body). Embedding the logic in either site
# would duplicate the verification gates and create drift risk. The
# primitive lives here, exported, and both sites call into it identically.

use strict;
use warnings;

use Crypt::JWT qw(encode_jwt decode_jwt);
use Exporter qw(import);

our @EXPORT_OK = qw(verifyAndFoldVerdict);

# verifyAndFoldVerdict( $base_session_jwt, $verdict_signed, $orch_secret, $renderer_secret )
#   → ($new_session_jwt, undef)  on success
#   → (undef, $error_string)     on failure
#
# See module-level docs for full contract.
sub verifyAndFoldVerdict {
	my ($base_session_jwt, $verdict_signed, $orch_secret, $renderer_secret) = @_;

	return (undef, 'base_session_jwt is required')    unless defined $base_session_jwt    && $base_session_jwt    ne '';
	return (undef, 'verdict_signed is required')      unless defined $verdict_signed      && $verdict_signed      ne '';
	return (undef, 'orchestrator_secret is required') unless defined $orch_secret         && $orch_secret         ne '';
	return (undef, 'renderer_secret is required')     unless defined $renderer_secret     && $renderer_secret     ne '';

	# 1. Verify and decode the signed verdict.
	my $verdict_claims = eval {
		decode_jwt(token => $verdict_signed, key => $orch_secret, accepted_alg => 'HS256');
	};
	if ($@) {
		return (undef, "verdict_signed: invalid signature ($@)");
	}

	# 2. Required claims present.
	my $verdict_play_id = $verdict_claims->{play_id};
	return (undef, 'verdict_signed: missing play_id claim') unless defined $verdict_play_id;

	my $verdict_basis = $verdict_claims->{mint_sequence_basis};
	return (undef, 'verdict_signed: missing mint_sequence_basis claim') unless defined $verdict_basis;

	my $verdict = $verdict_claims->{verdict};
	return (undef, 'verdict_signed: missing verdict claim') unless ref $verdict eq 'HASH';

	# 3. Verify and decode the base sessionJWT.
	my $base_claims = eval {
		decode_jwt(token => $base_session_jwt, key => $renderer_secret, accepted_alg => 'HS256');
	};
	if ($@) {
		return (undef, "base_session_jwt: invalid signature ($@)");
	}

	# 4. Embedded challengeJWT carries the play_id we cross-check against.
	my $embedded_cjwt = $base_claims->{challenge_jwt};
	return (undef, 'base_session_jwt: missing embedded challenge_jwt') unless defined $embedded_cjwt && $embedded_cjwt ne '';

	# Decode the embedded challengeJWT under the orchestrator's secret. The
	# renderer trusts orchestrator-signed claims; this is the standard verify.
	my $cjwt_claims = eval {
		decode_jwt(token => $embedded_cjwt, key => $orch_secret, accepted_alg => 'HS256');
	};
	if ($@) {
		return (undef, "embedded challenge_jwt: invalid signature ($@)");
	}

	my $session_play_id = $cjwt_claims->{play_id};
	return (undef, 'embedded challenge_jwt: missing play_id') unless defined $session_play_id;

	# 5. play_id cross-check.
	if ($verdict_play_id ne $session_play_id) {
		return (undef, "verdict_signed: play_id mismatch ($verdict_play_id vs $session_play_id)");
	}

	# 6. mint_sequence_basis cross-check.
	my $session_seq = defined $base_claims->{mint_sequence} ? $base_claims->{mint_sequence} + 0 : 0;
	if (($verdict_basis + 0) < $session_seq) {
		return (undef, "verdict_signed: mint_sequence_basis ($verdict_basis) < base.mint_sequence ($session_seq)");
	}

	# Fold: build new state by merging verdict into base state. Field-by-field
	# rather than hash-merge so we're explicit about which fields come from
	# which side and the architecture stays legible.
	my $base_state = ref $base_claims->{state} eq 'HASH' ? $base_claims->{state} : {};
	my @base_draws = ref $base_state->{draws} eq 'ARRAY' ? @{ $base_state->{draws} } : ();

	# verdict.draw_next, when present, appends one new draw to draws[]. Closed
	# mode never produces draw_next, so this is a no-op there. Open mode with
	# random_one selection emits a fresh draw entry per submission.
	if (ref $verdict->{draw_next} eq 'HASH') {
		push @base_draws, $verdict->{draw_next};
	}

	my $new_state = {
		started_at     => $base_state->{started_at},   # preserved
		current_focus  => $verdict->{current_focus},
		next_available => ref $verdict->{next_available} eq 'ARRAY' ? $verdict->{next_available} : [],
		draws          => \@base_draws,
		finalization   => $verdict->{finalization},
	};

	# answersSubmitted is the cumulative "this play has seen at least one
	# submit" flag. The base sessionJWT carries it forward via parseRequest's
	# claim merge; preserve it across the fold so warm-reload-to-completed-
	# problem renders see displayResults=true (green-feedback styling) rather
	# than degrading to blue-preview-i. Verdict-fold isn't a fresh play; it's
	# state advancement.
	my $answers_submitted = $base_claims->{answersSubmitted} ? 1 : 0;

	my $payload = {
		iss              => $ENV{SITE_HOST},
		aud              => $ENV{SITE_HOST},
		challenge_jwt    => $embedded_cjwt,
		state            => $new_state,
		mint_sequence    => $session_seq + 1,
		answersSubmitted => $answers_submitted,
	};

	my $new_session_jwt = eval {
		encode_jwt(
			payload  => $payload,
			alg      => 'HS256',
			key      => $renderer_secret,
			auto_iat => 1,
		);
	};
	if ($@) {
		return (undef, "encode_jwt failed ($@)");
	}

	return ($new_session_jwt, undef);
}

1;
