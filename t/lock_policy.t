use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping lock_policy tests';
}

use Test::Mojo;
use Crypt::JWT qw(decode_jwt encode_jwt);

$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';
$ENV{SITE_HOST}        //= 'https://test.example.com';

delete $ENV{STRICT_JWT};
delete $ENV{OPL_API_URL};

my $t = Test::Mojo->new('Renderer');
my $render_root = $ENV{RENDER_ROOT};
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

# Mint an upstream-style problemJWT carrying JWTanswerURL — required for
# sessionJWT/answerJWT minting (mirrors permissions.t pattern).
sub upstream_problem_jwt {
	return encode_jwt(
		payload => {
			aud          => $ENV{SITE_HOST},
			iss          => $ENV{SITE_HOST},
			JWTanswerURL => 'https://upstream.example.test/answer',
		},
		key      => $ENV{problemJWTsecret},
		alg      => 'HS256',
		auto_iat => 1,
	);
}

my $pg_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$answer = Compute("42");
TEXT(beginproblem());
BEGIN_PGML
What is the answer? [___]{$answer}
END_PGML
BEGIN_PGML_SOLUTION
The answer is 42.
END_PGML_SOLUTION
ENDDOCUMENT();
PG

# Helper: submit and return the decoded session claims (or undef if no session).
sub submit_and_decode {
	my (%form) = @_;
	$t->post_ok('/render-api' => form => {
		problemJWT    => upstream_problem_jwt(),
		problemSource => $pg_source,
		outputFormat  => 'raw',
		problemSeed   => 1234,
		submitAnswers => 1,
		%form,
	})->status_is(200);
	my $session = $t->tx->res->json->{rh_result}{sessionJWT};
	return undef unless $session;
	return decode_jwt(token => $session, key => $ENV{webworkJWTsecret});
}

# ─── Defaults: both knobs on (preserves historical lock-on-reveal behavior) ─

subtest 'defaults: perfect score → isLocked=1, no reveal' => sub {
	my $claims = submit_and_decode(AnSwEr0001 => '42');
	is($claims->{isLocked},        1,     'perfect score locks');
	ok(!$claims->{answersRevealed}, 'perfect score alone does not set answersRevealed');
};

subtest 'defaults: showCorrectAnswers → answersRevealed=1 AND isLocked=1' => sub {
	my $claims = submit_and_decode(
		AnSwEr0001         => '41',
		showCorrectAnswers => 1,
	);
	is($claims->{answersRevealed}, 1, 'reveal sets the soft ratchet');
	is($claims->{isLocked},        1, 'reveal also triggers the hard ratchet under default config');
};

# ─── LOCK_ON_PERFECT=0 ─────────────────────────────────────────────────────

subtest 'LOCK_ON_PERFECT=0: perfect score does NOT lock' => sub {
	local $ENV{LOCK_ON_PERFECT} = 0;
	my $claims = submit_and_decode(AnSwEr0001 => '42');
	ok(!$claims->{isLocked}, 'perfect score leaves session unlocked');
};

subtest 'LOCK_ON_PERFECT=0: showCorrectAnswers still sets both ratchets' => sub {
	# Knobs are independent — only the perfect-trigger is suppressed; reveal
	# semantics under LOCK_ON_SHOW_ANSWERS=1 default are unaffected.
	local $ENV{LOCK_ON_PERFECT} = 0;
	my $claims = submit_and_decode(
		AnSwEr0001         => '41',
		showCorrectAnswers => 1,
	);
	is($claims->{answersRevealed}, 1, 'soft ratchet still fires');
	is($claims->{isLocked},        1, 'hard ratchet still fires (LOCK_ON_SHOW_ANSWERS still on)');
};

# ─── LOCK_ON_SHOW_ANSWERS=0 ────────────────────────────────────────────────

subtest 'LOCK_ON_SHOW_ANSWERS=0: reveal sets soft ratchet only (no lock)' => sub {
	# The fact of reveal is independent of LOCK policy. answersRevealed
	# fires; the LMS sees the signal in the answerJWT and decides what to
	# do next. The session remains writable for further interaction.
	local $ENV{LOCK_ON_SHOW_ANSWERS} = 0;
	my $claims = submit_and_decode(
		AnSwEr0001         => '41',
		showCorrectAnswers => 1,
	);
	is($claims->{answersRevealed}, 1, 'soft ratchet fires regardless of LOCK policy');
	ok(!$claims->{isLocked},          'hard ratchet does not fire under LOCK_ON_SHOW_ANSWERS=0');
};

subtest 'LOCK_ON_SHOW_ANSWERS=0: perfect score still locks' => sub {
	local $ENV{LOCK_ON_SHOW_ANSWERS} = 0;
	my $claims = submit_and_decode(AnSwEr0001 => '42');
	is($claims->{isLocked}, 1, 'perfect-trigger independent of reveal-trigger');
};

# ─── Both knobs flipped ───────────────────────────────────────────────────

subtest 'both knobs off: renderer never auto-locks; soft ratchet still fires' => sub {
	local $ENV{LOCK_ON_PERFECT}      = 0;
	local $ENV{LOCK_ON_SHOW_ANSWERS} = 0;

	my $perfect = submit_and_decode(AnSwEr0001 => '42');
	ok(!$perfect->{isLocked}, 'perfect score does not lock');

	my $reveal = submit_and_decode(
		AnSwEr0001         => '41',
		showCorrectAnswers => 1,
	);
	ok(!$reveal->{isLocked},          'showCorrectAnswers does not lock');
	is($reveal->{answersRevealed}, 1, 'soft ratchet still fires (independent of LOCK policy)');
};

# ─── Round-trip: answersRevealed in sessionJWT forces reveal next render ───

subtest 'answersRevealed: ratchet persists, hoist does NOT force showCorrectAnswers (WW3-R18)' => sub {
	# Under LOCK_ON_SHOW_ANSWERS=0 we get a session with answersRevealed=1
	# but no isLocked — so a follow-up submit can flow. The R18 model says:
	# the fact-of-reveal propagates as session state (visible to LMS, sticky)
	# but the showCorrectAnswers DIRECTIVE does NOT auto-fire from session
	# state — cross-render directive-persistence is a caller concern. If
	# the LMS wants persistent reveal it re-sets showCorrectAnswers in form
	# data. See [[Reveal Persistence Model]].
	local $ENV{LOCK_ON_SHOW_ANSWERS} = 0;

	# First submit: reveal (no lock under this config).
	my $first = submit_and_decode(
		AnSwEr0001         => '41',
		showCorrectAnswers => 1,
	);
	is($first->{answersRevealed}, 1, 'first submit sets answersRevealed');
	ok(!$first->{isLocked},          'first submit does not lock');
	my $first_session = $t->tx->res->json->{rh_result}{sessionJWT};

	# Second submit: same session, NO showCorrectAnswers form-data this round.
	# Pre-R18: the hoist re-fired showCorrectAnswers from the session.
	# Post-R18: it does not — the directive must come from form-data fresh.
	$t->post_ok('/render-api' => form => {
		problemJWT    => upstream_problem_jwt(),
		problemSource => $pg_source,
		sessionJWT    => $first_session,
		outputFormat  => 'raw',
		problemSeed   => 1234,
		submitAnswers => 1,
		AnSwEr0001    => '40',
	})->status_is(200);
	my $second_raw     = $t->tx->res->json->{rh_result};
	my $second_inputs  = $second_raw->{inputs_ref};
	my $second_session = $second_raw->{sessionJWT};
	my $second_claims  = decode_jwt(token => $second_session, key => $ENV{webworkJWTsecret});

	# Hoist gone: parseRequest no longer synthesizes showCorrectAnswers from
	# the session ratchet, so the directive is absent on the second render.
	ok(!$second_inputs->{showCorrectAnswers},
		'showCorrectAnswers directive is NOT auto-fired from session ratchet (hoist removed)');

	# Soft ratchet still rides forward (session-state property).
	is($second_claims->{answersRevealed}, 1,
		'answersRevealed persists across renders (sticky session state)');

	# Answer-emission gate: answerJWT carries answersRevealed at top level
	# (R18 addition) — the LMS sees the reveal-happened signal on every
	# subsequent answerJWT, not just the first one after reveal.
	my $second_answer = $second_raw->{answerJWT};
	ok($second_answer, 'second submit produces an answerJWT (LOCK_ON_SHOW_ANSWERS=0 keeps session writable)');
	my $second_answer_claims = decode_jwt(
		token => $second_answer,
		key   => $ENV{problemJWTsecret},
	);
	is($second_answer_claims->{answersRevealed}, 1,
		'answerJWT carries answersRevealed=1 at top level after reveal');
};

done_testing();
