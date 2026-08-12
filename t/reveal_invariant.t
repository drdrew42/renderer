use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping reveal_invariant tests';
}

use Test::Mojo;
use Crypt::JWT qw(encode_jwt);

# ─── The reveal invariant ────────────────────────────────────────────────────
#
# Enforces the reveal-flag end-state decision (vault:
# WeBWorK/Renderer/Decisions/current, 2026-08-11):
#
#   Reveal — the canonical answer or worked solution shown inline in a render —
#   fires from exactly two sources:
#     (a) a TRUSTED isInstructor claim (signed, un-forgeable since WW3-R46), or
#     (b) a typed reveal-endpoint token (/render-api/{hint,solution,answer}).
#   NO raw request input grants reveal on any lane.
#
# This is WW3-R46's outstanding regression-guard + drift-test, generalized to
# the whole taxonomy. It pins the enforcement at the LANE level, which is where
# it lives: resolve_permissions itself trusts its input (it passes a student's
# showCorrectAnswers=1 straight through — see permissions_resolver.t); the lanes
# are what strip / hard-zero / claim-gate before the resolver ever runs. "Care
# does not generalize; structure does."
#
# Runs without a live OPL or a content-cache fixture because it feeds raw
# problemSource — but only because SourceResolver was fixed to honor that. The
# challenge/reView lanes carry a pg_hash on every render, and WW3-089's
# pg_hash-alone resolver branch used to fetch over any provided source, so the
# lanes' "use this verbatim" bypass silently did not work (raw problemSource
# 404'd on those lanes — the entry_gate.t TODO was correct, not stale). The
# guard now sits on that branch (SourceResolver: pg_hash-alone fires only when
# no problemSource is in hand), which restored the standalone raw-source path
# and un-broke challenge_jwt.t's render subtests at the same time.
#
# Docker-only, like every render-pipeline test. Byte-LENGTH is the reveal signal:
# a re-mint changes a JWT's iat but not its length, so a length delta means
# content (a solution accordion / correct-answer block) was added — the same
# robust comparison entry_gate.t uses. correct_ans / the solution text confirm
# WHICH reveal surface lit.

# Control the environment like entry_gate.t. These tests assert lane-level flag
# handling, which is env-independent — so neutralize the deployment env and the
# test runs identically in a CI container or the live one. Without this,
# STRICT_JWT=1 would gate admission, and CONTENT_ADDRESSED=1 + a real OPL would
# 404 the fixture's fake pg_hash before the lane's problemSource bypass fires.
delete $ENV{STRICT_JWT};
delete $ENV{OPL_API_URL};
delete $ENV{CONTENT_ADDRESSED};

$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';

my $t           = Test::Mojo->new('Renderer');
my $render_root = $ENV{RENDER_ROOT};
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

# A problem with a SOLUTION block, so both reveal surfaces are detectable:
# showCorrectAnswers → correct_ans in the graded response; showSolutions → the
# solution body. revealAll (isInstructor) lights both.
my $pg_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$ans = Compute("42");
TEXT(beginproblem());
BEGIN_PGML
What is the answer? [___]{$ans}
END_PGML
BEGIN_PGML_SOLUTION
The canonical solution text is forty-two.
END_PGML_SOLUTION
ENDDOCUMENT();
PG

my $SOLUTION_MARK = qr/canonical solution text is forty-two/;   # only present when a solution renders
my $ANSWER_MARK   = qr/correct_ans/;                            # only present when correct answers reveal

sub challenge_jwt {
	my (%overrides) = @_;
	return encode_jwt(
		payload => {
			aud              => $ENV{SITE_HOST},
			iss              => 'https://ww3.example.edu',
			version          => '1',
			play_id          => '11111111-1111-1111-1111-111111111111',
			challenge_id     => 'sha256:abcdef',
			assignment_id    => '22222222-2222-2222-2222-222222222222',
			chain_student_id => 'cafebabe',
			shape            => 'closed',
			problems         => [ { position => 0, pg_hash => 'sha256:p0', seed => 4242 } ],
			mode             => {
				next_available => [ { name => 'position_in_pool' } ],
				is_done        => [ { name => 'student_finalized' } ],
				selection      => 'student_picks',
			},
			answer_url => 'http://127.0.0.1:9999/fake-answer-callback',
			# Baseline: reveal fully off. Overridable to install a trusted claim.
			render_permissions => { isInstructor => 0, showCorrectAnswers => 0, showHints => 0, showSolutions => 0 },
			%overrides,
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

sub submission_jwt {
	# A reView submissionJWT: decoded under problemJWTsecret with verify_aud
	# against SITE_HOST (Review.pm:73-76); needs pg_hash/seed/position.
	return encode_jwt(
		payload => {
			aud               => $ENV{SITE_HOST},
			iss               => $ENV{SITE_HOST},
			pg_hash           => 'sha256:rev',
			seed              => 4242,
			position          => 0,
			play_id           => '11111111-1111-1111-1111-111111111111',
			submitted_answers => { AnSwEr0001 => '42' },
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

sub problem_jwt {
	# A LibreTexts/ADAPT-style problemJWT: decoded under problemJWTsecret with
	# verify_aud against SITE_HOST (Lane::Problem). JWTanswerURL so a graded
	# submit produces an answerJWT.
	my (%extra) = @_;
	return encode_jwt(
		payload => {
			aud          => $ENV{SITE_HOST},
			iss          => $ENV{SITE_HOST},
			JWTanswerURL => 'http://127.0.0.1:9999/fake-answer-callback',
			%extra,
		},
		key      => $ENV{problemJWTsecret},
		alg      => 'HS256',
		auto_iat => 1,
	);
}

sub body { return $t->tx->res->body }

# ─── Challenge lane (WW3 play) ───────────────────────────────────────────────

subtest 'Challenge lane: raw isInstructor=1 does not reveal (stripped)' => sub {
	my $jwt  = challenge_jwt();
	my %base = (
		challengeJWT  => $jwt, position => 0, problemSource => $pg_source,
		submitAnswers => 1,    'AnSwEr0001' => '0',    # a wrong submit, so feedback is identical either way
	);

	$t->post_ok('/render-api', { Accept => 'application/json' }, form => {%base})->status_is(200);
	my $baseline = body();

	$t->post_ok('/render-api', { Accept => 'application/json' }, form => { %base, isInstructor => 1 })->status_is(200);
	my $elevated = body();

	unlike($elevated, $SOLUTION_MARK, 'no solution from a self-declared isInstructor');
	unlike($elevated, $ANSWER_MARK,   'no correct answer either');
	is(length($elevated), length($baseline), 'byte-length identical to the un-elevated render');
};

subtest 'Challenge lane: raw showCorrectAnswers=1 does not reveal (hard-zeroed)' => sub {
	my $jwt  = challenge_jwt();
	my %base = (
		challengeJWT  => $jwt, position => 0, problemSource => $pg_source,
		submitAnswers => 1,    'AnSwEr0001' => '0',
	);

	$t->post_ok('/render-api', { Accept => 'application/json' }, form => {%base})->status_is(200);
	my $baseline = body();

	$t->post_ok('/render-api', { Accept => 'application/json' }, form => { %base, showCorrectAnswers => 1 })
		->status_is(200);
	my $elevated = body();

	unlike($elevated, $ANSWER_MARK, 'showCorrectAnswers is hard-zeroed on the challenge lane');
	is(length($elevated), length($baseline), 'byte-length identical');
};

subtest 'Challenge lane: a TRUSTED isInstructor claim DOES reveal (the convenience path stays)' => sub {
	# The other half of the invariant — reveal is not gone, it is gated. A
	# claim in render_permissions is signed by the orchestrator; a student
	# cannot mint it. isInstructor resolves to revealAll, so the authored
	# SOLUTION renders inline — the signal that the trusted-claim reveal path
	# works. (correct_ans lives in the graded-submission answer table, populated
	# by an explicit showCorrectAnswers on a student submit — see
	# challenge_jwt.t — not by an instructor preview, which reveals the
	# solution.)
	my $jwt = challenge_jwt(render_permissions => { isInstructor => 1 });

	$t->post_ok(
		'/render-api', { Accept => 'application/json' },
		form => {
			challengeJWT => $jwt, position => 0, problemSource => $pg_source,
			submitAnswers => 1, 'AnSwEr0001' => '0',
		}
	)->status_is(200);

	like(body(), $SOLUTION_MARK, 'trusted instructor claim reveals the solution (revealAll)');
};

# ─── Review lane (WW3 reView) ────────────────────────────────────────────────

subtest 'Review lane: raw isInstructor=1 is hard-zeroed (no reveal)' => sub {
	my $sub  = submission_jwt();
	my %base = (submissionJWT => $sub, problemSource => $pg_source);

	$t->post_ok('/render-api', form => {%base})->status_is(200);
	my $baseline = body();

	$t->post_ok('/render-api', form => { %base, isInstructor => 1 })->status_is(200);
	my $elevated = body();

	unlike($elevated, $SOLUTION_MARK, 'reView hard-zeroes isInstructor — no solution revealed');
	is(length($elevated), length($baseline), 'byte-length identical');
};

subtest 'Review lane: raw showCorrectAnswers=1 does not reveal (WW3-117 end-state)' => sub {
	# The one pin that is not yet green: reView still honors a raw
	# showCorrectAnswers as a bounded interim (Review.pm:137). WW3-117 removes
	# the flag. Written as the end-state and marked TODO so the suite documents
	# the target and flips green when 117 lands — do not "fix" by deleting it.
	my $sub  = submission_jwt();
	my %base = (submissionJWT => $sub, problemSource => $pg_source);

	$t->post_ok('/render-api', form => {%base})->status_is(200);
	my $baseline = length(body());

	$t->post_ok('/render-api', form => { %base, showCorrectAnswers => 1 })->status_is(200);
	my $with = length(body());

	TODO: {
		local $TODO = 'until WW3-117 removes the reView showCorrectAnswers interim (Review.pm:137)';
		is($with, $baseline, 'showCorrectAnswers must not change the reView render');
	}
};

# ─── Problem lane (LibreTexts) — showCorrectAnswers mode-gate ────────────────

subtest 'Problem lane: raw showCorrectAnswers does not reveal on the custom default (WW3-R51)' => sub {
	# The last raw reveal path left open on this lane: on the `custom` default
	# (ADAPT's mode) a student could POST showCorrectAnswers=1 and read the
	# canonical answer. Now gated on the resolved mode offering the button. Same
	# mode, with and without the flag, isolates the reveal from any chrome delta.
	my %base = (
		problemJWT    => problem_jwt(), problemSource => $pg_source, problemSeed => 1234,
		submitAnswers => 1, 'AnSwEr0001' => '0',    # wrong submit
	);

	$t->post_ok('/render-api', { Accept => 'application/json' }, form => {%base})->status_is(200);
	my $baseline = body();

	$t->post_ok('/render-api', { Accept => 'application/json' }, form => { %base, showCorrectAnswers => 1 })
		->status_is(200);
	my $injected = body();

	unlike($injected, $ANSWER_MARK, 'raw showCorrectAnswers does not reveal on custom (no offering bundle)');
	is(length($injected), length($baseline), 'byte-length identical to the un-revealed render');
};

subtest 'Problem lane: an offering-mode CLAIM keeps showCorrectAnswers working' => sub {
	# The other half — the button's mechanism is not broken, only mode-gated. A
	# no-stakes CLAIM (renderMode is claim-only on a grounded lane, WW3-R51 §0,
	# so the mode is trusted) offers the button, and a student pressing it
	# reveals. Compared under the SAME mode so the delta is the reveal, not the
	# no-stakes chrome.
	my $jwt = problem_jwt(renderMode => 'no-stakes');
	my %base = (
		problemJWT    => $jwt, problemSource => $pg_source, problemSeed => 1234,
		submitAnswers => 1, 'AnSwEr0001' => '0',
	);

	$t->post_ok('/render-api', { Accept => 'application/json' }, form => {%base})->status_is(200);
	my $ns_baseline = body();

	$t->post_ok('/render-api', { Accept => 'application/json' }, form => { %base, showCorrectAnswers => 1 })
		->status_is(200);
	my $revealed = body();

	# Same mode, so the only difference is the flag: a content delta is the
	# reveal, isolated. (reveal_reporting.t asserts the authoritative
	# answerJWT.answers_shown=1 for the no-stakes case; here we pin that the
	# affordance still lights on the render itself.)
	cmp_ok(length($revealed), '>', length($ns_baseline), 'no-stakes honours showCorrectAnswers — the reveal renders');
};

# ─── Feedback flags are NOT reveal — do not over-retire them ─────────────────

subtest 'Feedback flags do not leak reveal content' => sub {
	# showPartialCorrectAnswers / showScoreSummary drive scoring feedback
	# (per-blank styling, the numeric score) — never the canonical answer. The
	# retention guard: a future reveal-retirement sweep must not treat these as
	# reveal. Presence-of-feedback is covered in permissions.t; here we pin the
	# direction that matters — accepted, and no reveal surface lit.
	my $jwt = challenge_jwt();
	$t->post_ok(
		'/render-api', { Accept => 'application/json' },
		form => {
			challengeJWT => $jwt, position => 0, problemSource => $pg_source,
			submitAnswers => 1, 'AnSwEr0001' => '42',
			showPartialCorrectAnswers => 1, showScoreSummary => 1,
		}
	)->status_is(200);

	unlike(body(), $SOLUTION_MARK, 'feedback flags do not leak the solution');
	unlike(body(), $ANSWER_MARK,   'feedback flags do not leak the correct answer');
};

# ─── Notes on siblings, so the coverage map is explicit ──────────────────────
#
# * Problem lane (LibreTexts). Its raw-isInstructor-stripped reveal-negative and
#   its trusted-claim / VPC-editor reveal-positive live in entry_gate.t (:188,
#   :239). Its showCorrectAnswers mode-gate — the last raw reveal path here — is
#   pinned above (WW3-R51). It KEEPS in-render reveal for a trusted isInstructor
#   claim (Tier B): instructor reveal is revealAll, not this student flag.
# * The typed reveal endpoints (/hint, /solution, /answer) — source (b) of the
#   invariant — are pinned in hint_solution_endpoints.t and answer_endpoint.t
#   (valid typed token → content; wrong/absent typ → 401).
# * The emission gate (an instructor render emits no answerJWT — _can_emit_answer_jwt
#   on isInstructor==0) is WW3-117's build. When it lands, add its pin beside the
#   existing emission_gate.t coverage, and correct the stale RenderProblem.pm:153-156
#   comment that already claims that gate exists.

done_testing();
