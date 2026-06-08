use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping reveal-reporting tests';
}

use Test::Mojo;
use Crypt::JWT qw(decode_jwt encode_jwt);

# WW3-R29 dual-state model coverage:
#   *Requested — per-render fact (answerJWT + submissionJWT)
#   *Revealed  — cumulative sticky one-way; ratchet 0→1 fires only when
#                *Requested && post-render recorded_score < 1
#   answerJWT carries INBOUND cumulative (state-at-submission-time)
#   sessionJWT carries OUTBOUND cumulative (sticky-rolled forward)

$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';
$ENV{SITE_HOST}        //= 'https://test.example.com';
delete $ENV{STRICT_JWT};

my $t           = Test::Mojo->new('Renderer');
my $render_root = $ENV{RENDER_ROOT};
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

# A problem with answer "42" and both hints + solution.
our $pg_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$answer = Compute("42");
TEXT(beginproblem());
BEGIN_PGML
What is the answer? [___]{$answer}
END_PGML
BEGIN_PGML_HINT
The answer is 42.
END_PGML_HINT
BEGIN_PGML_SOLUTION
The answer is 42 by definition.
END_PGML_SOLUTION
ENDDOCUMENT();
PG

# ─── Helpers ─────────────────────────────────────────────────────────────

sub upstream_problem_jwt {
	my (%extra_claims) = @_;
	return encode_jwt(
		payload => {
			aud          => $ENV{SITE_HOST},
			iss          => $ENV{SITE_HOST},
			JWTanswerURL => 'https://upstream.example.test/answer',
			%extra_claims,
		},
		key      => $ENV{problemJWTsecret},
		alg      => 'HS256',
		auto_iat => 1,
	);
}

# Submit and decode both JWTs (sessionJWT and answerJWT) so we can assert
# the dual-state model directly. showCorrectAnswers flows as a raw form
# param (per-render directive) — Lane::Problem's bulk merge honors it when
# the JWT claim is silent.
sub submit_and_decode {
	my (%form) = @_;
	$t->post_ok(
		'/render-api' => form => {
			problemJWT    => upstream_problem_jwt(),
			problemSource => $pg_source,
			outputFormat  => 'debug',
			problemSeed   => 1234,
			submitAnswers => 1,
			%form,
		}
	)->status_is(200);
	my $resp = $t->tx->res->json;
	return {
		session => $resp->{tokens}{sessionJWT}
		? decode_jwt(token => $resp->{tokens}{sessionJWT}, key => $ENV{webworkJWTsecret})
		: undef,
		answer => $resp->{tokens}{answerJWT}
		? decode_jwt(token => $resp->{tokens}{answerJWT}, key => $ENV{problemJWTsecret})
		: undef,
		raw => $resp,
	};
}

# ─── Scenario 1: peek-before-earn ──────────────────────────────────────────

subtest 'peek-before-earn: wrong submit + showCorrectAnswers' => sub {
	# Wrong answer, requested correct answers. Post-render: incomplete.
	# Ratchet should fire (peek-while-incomplete).
	#
	# Dual-state expectations:
	#   answerJWT.answersRequested = 1 (this render exposed)
	#   answerJWT.answersRevealed  = 0 (this submit was attempted blind)
	#   sessionJWT.answersRevealed = 1 (newly ratcheted; carries forward)
	my $r = submit_and_decode(
		AnSwEr0001         => 'wrong',
		showCorrectAnswers => 1,
	);

	is($r->{answer}{answersRequested}, 1, 'answerJWT.answersRequested = 1 (this render asked)');
	is($r->{answer}{answersRevealed},  0, 'answerJWT.answersRevealed = 0 (submit was attempted blind)');
	is($r->{session}{answersRevealed}, 1, 'sessionJWT.answersRevealed = 1 (ratchet fired post-incomplete)');
};

subtest 'solutions: showSolutions hardwired off in student render → no ratchet' => sub {
	# Solutions are no longer rendered in the main response for students;
	# they must be fetched via /render-api/solution. The solutionsRequested
	# field on the answerJWT therefore stays 0 regardless of what the form
	# carries, and the solutionsRevealed ratchet never fires via this path.
	# (If/when "did the student fetch a solution" needs to be signaled, it
	# will be a separate channel — see Reveal Reporting Model open questions.)
	my $r = submit_and_decode(
		AnSwEr0001         => 'wrong',
		showCorrectAnswers => 1,
		showSolutions      => 1,         # ignored — students cannot trigger in-render solutions
	);

	is($r->{answer}{solutionsRequested}, 0, 'answerJWT.solutionsRequested = 0 (hardwired off for students)');
	is($r->{answer}{solutionsRevealed},  0, 'answerJWT.solutionsRevealed = 0 (ratchet does not fire)');
	ok(!$r->{session}{solutionsRevealed}, 'sessionJWT.solutionsRevealed unset (no in-render path to fire it)');
};

# ─── Scenario 2: peek-on-earn ─────────────────────────────────────────────

subtest 'peek-on-earn: correct submit + showCorrectAnswers (same render)' => sub {
	# Student got it right AND requested answers in the same render.
	# Post-render: earned (recorded_score=1). Ratchet should NOT fire —
	# they earned the score before peeking; no scoring concern.
	#
	# Dual-state expectations:
	#   answerJWT.answersRequested = 1 (yes, this render exposed them)
	#   answerJWT.answersRevealed  = 0 (peek didn't help; they got it right)
	#   sessionJWT.answersRevealed = 0 (no ratchet — earned-before-peek)
	my $r = submit_and_decode(
		AnSwEr0001         => '42',
		showCorrectAnswers => 1,
	);

	is($r->{answer}{answersRequested}, 1, 'answerJWT.answersRequested = 1');
	is($r->{answer}{answersRevealed},  0, 'answerJWT.answersRevealed = 0 (was 0 inbound)');
	ok(!$r->{session}{answersRevealed}, 'sessionJWT.answersRevealed unset (no ratchet — earned the score)');
};

# ─── Scenario 3: post-completion peek ─────────────────────────────────────

subtest 'post-completion peek: prior earned, then showCorrectAnswers-only render' => sub {
	# Step 1: correct submit, no peek. Earns the score.
	# Step 2: same student requests answers (post-mortem study).
	# Result: no ratchet ever fires — student earned it on their own.
	#
	# Dual-state expectations on step 2:
	#   answerJWT.answersRequested = 1
	#   answerJWT.answersRevealed  = 0 (inbound was 0; no prior peek)
	#   sessionJWT.answersRevealed = 0 (still unset; earned protects)

	# Post-R31 the renderer no longer locks sessions on perfect score — the
	# earned session stays writable, so the peek-only re-render works without
	# any env knob. (Pre-R31 this required LOCK_ON_PERFECT=0; that env var
	# is retired.)
	my $earn = submit_and_decode(AnSwEr0001 => '42');
	ok(!$earn->{session}{answersRevealed}, 'no peek on earn render → no ratchet');

	# Step 2: re-render with the earned sessionJWT, request answers
	# without resubmitting.
	$t->post_ok(
		'/render-api' => form => {
			problemJWT         => upstream_problem_jwt(),
			problemSource      => $pg_source,
			sessionJWT         => $earn->{raw}{tokens}{sessionJWT},
			outputFormat       => 'debug',
			problemSeed        => 1234,
			submitAnswers      => 1,
			showCorrectAnswers => 1,
			AnSwEr0001         => '42',
		}
	)->status_is(200);

	my $peek         = $t->tx->res->json;
	my $peek_session = decode_jwt(
		token => $peek->{tokens}{sessionJWT},
		key   => $ENV{webworkJWTsecret}
	);
	my $peek_answer = decode_jwt(
		token => $peek->{tokens}{answerJWT},
		key   => $ENV{problemJWTsecret}
	);

	is($peek_answer->{answersRequested}, 1, 'peek render: answersRequested=1');
	is($peek_answer->{answersRevealed},  0, 'peek render: answersRevealed=0 inbound');
	ok(!$peek_session->{answersRevealed}, 'post-completion peek does NOT ratchet (student already earned)');
};

# ─── Scenario 4: sticky once set ──────────────────────────────────────────

subtest 'sticky once set: peek-before-earn → next render carries it' => sub {
	# Step 1: peek-before-earn (ratchet fires).
	# Step 2: next render. Inbound carries answersRevealed=1.
	#
	# Expectations on step 2:
	#   answerJWT.answersRevealed  = 1 (inbound: state-at-submission was post-prior-reveal)
	#   sessionJWT.answersRevealed = 1 (sticky-carried)
	#
	# Post-R31 the renderer never terminates a session — step 1's peek
	# doesn't lock anything, so step 2 produces an answerJWT normally.
	my $first = submit_and_decode(
		AnSwEr0001         => 'wrong',
		showCorrectAnswers => 1,
	);
	is($first->{session}{answersRevealed}, 1, 'step 1: ratchet fired');

	# Step 2 — re-render with the post-peek sessionJWT, this time without
	# requesting answers again. Inbound cumulative is 1.
	$t->post_ok(
		'/render-api' => form => {
			problemJWT    => upstream_problem_jwt(),
			problemSource => $pg_source,
			sessionJWT    => $first->{raw}{tokens}{sessionJWT},
			outputFormat  => 'debug',
			problemSeed   => 1234,
			submitAnswers => 1,
			AnSwEr0001    => 'still-wrong',
		}
	)->status_is(200);

	my $second         = $t->tx->res->json;
	my $second_session = decode_jwt(
		token => $second->{tokens}{sessionJWT},
		key   => $ENV{webworkJWTsecret}
	);
	my $second_answer = decode_jwt(
		token => $second->{tokens}{answerJWT},
		key   => $ENV{problemJWTsecret}
	);

	is($second_answer->{answersRequested}, 0, 'step 2: answersRequested=0 (no peek this render)');
	is($second_answer->{answersRevealed}, 1,
		'step 2: answersRevealed=1 (state-at-submission carries prior reveal)');
	is($second_session->{answersRevealed}, 1, 'step 2: sessionJWT carries sticky=1 forward');
};

# ─── Inbound strip ────────────────────────────────────────────────────────

subtest 'raw param injection blocked: answersRevealed cannot be smuggled in' => sub {
	# A caller adding ?answersRevealed=1 as a raw form param shouldn't see
	# the claim land on the answerJWT. SENSITIVE_PARAMS strips before lane
	# dispatch; the only inbound path is via Lane::Session (which trusts
	# its own minted sessionJWT).
	my $r = submit_and_decode(
		AnSwEr0001        => 'wrong',
		answersRevealed   => 1,         # injection attempt
		solutionsRevealed => 1,
	);

	is($r->{answer}{answersRevealed},   0, 'raw answersRevealed param did not leak through');
	is($r->{answer}{solutionsRevealed}, 0, 'raw solutionsRevealed param did not leak through');
	ok(!$r->{session}{answersRevealed},   'session has no leaked answersRevealed');
	ok(!$r->{session}{solutionsRevealed}, 'session has no leaked solutionsRevealed');
};

# ─── Modern lane ──────────────────────────────────────────────────────────

subtest 'challenge lane: submissionJWT carries *_requested per render' => sub {
	# Modern lane: per-render reveal facts on submissionJWT only.
	# play_sessionJWT carries nothing reveal-related.
	my $challenge_jwt = encode_jwt(
		payload => {
			aud              => $ENV{SITE_HOST},
			iss              => 'https://ww3.example.edu',
			version          => '1',
			play_id          => '11111111-1111-1111-1111-111111111111',
			challenge_id     => 'sha256:abcdef',
			assignment_id    => '22222222-2222-2222-2222-222222222222',
			chain_student_id => 'cafebabe',
			shape            => 'closed',
			problems         => [ { position => 0, pg_hash => 'sha256:p0', seed => 11111 }, ],
			mode             => {
				next_available => [ { name => 'position_in_pool' } ],
				is_done        => [ { name => 'student_finalized' } ],
				selection      => 'student_picks',
			},
			constraints        => { duration_seconds => 3600 },
			render_permissions => { isInstructor     => 0, showCorrectAnswers => 1, showHints => 1 },
			answer_url         => 'http://127.0.0.1:9999/fake-answer-callback',
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);

	$t->post_ok(
		'/render-api' => { Accept => 'application/json' },
		form          => {
			challengeJWT  => $challenge_jwt,
			position      => 0,
			problemSource => $pg_source,
			problemSeed   => 1234,
			submitAnswers => 1,
			AnSwEr0001    => 'wrong',
		}
	)->status_is(200);

	my $resp           = $t->tx->res->json;
	my $submission_jwt = $resp->{JWT}{submission};
	ok($submission_jwt, 'submissionJWT minted');

	my $sub_claims = decode_jwt(token => $submission_jwt, key => $ENV{problemJWTsecret});
	is($sub_claims->{answers_requested},
		1, 'submissionJWT.answers_requested=1 (showCorrectAnswers fired via render_permissions)');
	is($sub_claims->{solutions_requested},
		0, 'submissionJWT.solutions_requested=0 (solutions hardwired off; fetch via /render-api/solution)');

	# play_sessionJWT carries no reveal claims (orchestrator handles cumulative).
	my $session_jwt = $resp->{JWT}{session};
	ok($session_jwt, 'play_sessionJWT minted');
	my $sess_claims = decode_jwt(token => $session_jwt, key => $ENV{webworkJWTsecret});
	ok(!exists $sess_claims->{answersRevealed},
		'play_sessionJWT carries no answersRevealed (orchestrator-owned history)');
	ok(!exists $sess_claims->{solutionsRevealed}, 'play_sessionJWT carries no solutionsRevealed');
	ok(!exists $sess_claims->{answers_requested},
		'play_sessionJWT carries no answers_requested (per-render, not session-state)');
};

done_testing();
