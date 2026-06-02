package Renderer::Lane::Session;

# Session prefix lane. Combines with any body lane (Problem/Challenge/Peer/
# Ungrounded). When a sessionJWT is present, this runs before body-lane
# dispatch and applies the renderer's continuation-state contract:
#
#   * Decode under webworkJWTsecret. No issuer check — a valid HMAC under
#     the shared secret IS the provenance proof; iss was only ever a
#     hostname coupling (see LibreTexts Decisions D-003 / v2.0.4).
#   * Security-sensitive claims always win over raw params (prevents
#     student-side claw-back of isInstructor / answersRevealed /
#     solutionsRevealed / answersSubmitted, plus showCorrectAnswers
#     backward-compat).
#   * For all other claims, raw params win (current responses vs prior).
#   * The body problemJWT comes from the session's nested ("matryoshka")
#     claim. A sidecar problemJWT submitted top-level in tandem is NOT
#     discarded: if it differs from the nested token it is stashed and its
#     problem-SOURCE fields override the nested ones atomically after the
#     body lane runs (apply_source_override, LTW-088). Source only —
#     trust/routing/state claims never cross from a sidecar.
#   * Hoist embedded challenge_jwt → challengeJWT so the body-lane
#     dispatcher recognizes form-submit re-renders as challengeJWT-lane.
#
# answersRevealed / solutionsRevealed propagate as session state (visible
# to LMS via answerJWT, sticky across renders) but do NOT auto-fire any
# directive on subsequent renders. Cross-render directive-persistence is
# a caller concern. The cumulative ratchet semantics live in
# WeBWorK::RenderProblem::generateJWTs (WW3-R29 dual-state model).

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Crypt::JWT qw(decode_jwt);

use Renderer::Lane::Problem qw(decode_claims);
use Renderer::Constants qw(SOURCE_OVERRIDE_FIELDS);

use Exporter qw(import);
our @EXPORT_OK = qw(apply_prefix apply_source_override);

# apply_prefix($c, $params)
#
# Runs only when $params->{sessionJWT} is defined. Decodes and merges into
# $params. Returns 1 on success, returns the result of $c->croak(...) on
# decode failure (which short-circuits the controller).
sub apply_prefix ($c, $params) {
	my $sessionJWT = $params->{sessionJWT};
	$c->log->info("Received JWT: using sessionJWT");

	my $claims;
	eval {
		$claims = decode_jwt(
			token      => $sessionJWT,
			key        => $ENV{webworkJWTsecret},
		);
		1;
	} or do {
		return $c->croak($@, 3);
	};

	# Security-sensitive claims always win over raw params.
	for (qw(isInstructor showCorrectAnswers answersRevealed solutionsRevealed answersSubmitted)) {
		$params->{$_} = $claims->{$_} if exists $claims->{$_};
	}

	# Capture any sidecar (top-level) problemJWT before the nested one takes
	# over the body slot. The nested ("matryoshka") problemJWT is the body
	# token for consistency; a sidecar that differs carries a source
	# adjustment for an in-flight session (LTW-088).
	my $sidecar = delete $params->{problemJWT};
	my $nested  = $claims->{problemJWT};

	# Bulk merge: raw params win for everything else (current responses
	# beat prior). problemJWT must come from session for consistency.
	foreach my $key (keys %$claims) {
		$params->{$key} //= $claims->{$key};
	}

	if (defined $sidecar && defined $nested && $sidecar ne $nested) {
		# Override case: nested stays the body token; the sidecar's source
		# fields are applied atomically after the body lane decodes it.
		$c->stash(_sidecar_problemJWT => $sidecar);
	} elsif (defined $sidecar && !defined $nested) {
		# Session carried no problem context; the sidecar simply IS the body
		# problem (no override, no nested source to replace).
		$params->{problemJWT} = $sidecar;
	}

	# Hoist embedded challenge_jwt (snake_case JWT claim) → challengeJWT
	# (camelCase form param) so the body-lane dispatcher recognizes
	# form-submit re-renders as challengeJWT-lane. Without this, sessionJWT
	# carries challenge_jwt as a claim but the dispatch falls through to
	# the entry gate, pg_hash never resolves.
	if (!defined $params->{challengeJWT} && defined $params->{challenge_jwt}) {
		$params->{challengeJWT} = $params->{challenge_jwt};
	}

	return 1;
}

# apply_source_override($c, $params)
#
# Runs after the problem body lane when apply_prefix stashed a sidecar
# problemJWT (LTW-088). Decodes the sidecar through the same path as the body
# lane and, if it carries ANY problem-source field, replaces the nested
# problem's entire source bundle with the sidecar's.
#
# Atomic by construction: every SOURCE_OVERRIDE_FIELDS key is cleared from
# $params first, then only the sidecar's are set. A sidecar carrying just
# problemSourceURL therefore drops the nested pg_hash / sourceFilePath /
# problemSource, forcing the SourceResolver to re-derive — never a stale
# pg_hash riding alongside a new URL. Source fields only; trust/routing/state
# claims in the sidecar are ignored (future scope).
#
# Returns 1 (incl. the no-sidecar no-op). A sidecar that fails to decode is a
# malformed request → croak (short-circuits the controller).
sub apply_source_override ($c, $params) {
	my $sidecar = $c->stash('_sidecar_problemJWT') or return 1;

	my ($claims, $err) = decode_claims($c, $sidecar);
	return $c->croak($err, 3) if $err;

	# NB: assign to an array first — a bareword constant inside a {} hash
	# slice subscript autoquotes to a string instead of calling the sub.
	my @source_fields = SOURCE_OVERRIDE_FIELDS;
	my %bundle = map { $_ => $claims->{$_} }
		grep { defined $claims->{$_} } @source_fields;
	return 1 unless %bundle;

	delete @{$params}{@source_fields};
	@{$params}{ keys %bundle } = values %bundle;

	$c->log->info("sidecar source-override: " . join(',', sort keys %bundle));
	return 1;
}

1;
