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

# ─── Default: both knobs on (preserves historical behavior) ────────────────

subtest 'defaults: perfect score → isLocked=1' => sub {
	# No env override. Default LOCK_ON_PERFECT=1.
	my $claims = submit_and_decode(AnSwEr0001 => '42');
	is($claims->{isLocked}, 1, 'perfect score locks under default config');
};

subtest 'defaults: showCorrectAnswers → isLocked=1' => sub {
	my $claims = submit_and_decode(
		AnSwEr0001         => '41',
		showCorrectAnswers => 1,
	);
	is($claims->{isLocked}, 1, 'showCorrectAnswers locks under default config');
};

# ─── LOCK_ON_PERFECT=0 ─────────────────────────────────────────────────────

subtest 'LOCK_ON_PERFECT=0: perfect score does NOT lock' => sub {
	local $ENV{LOCK_ON_PERFECT} = 0;
	my $claims = submit_and_decode(AnSwEr0001 => '42');
	ok(!$claims->{isLocked}, 'perfect score leaves session unlocked');
};

subtest 'LOCK_ON_PERFECT=0: showCorrectAnswers still locks' => sub {
	# Knob is independent — only perfect-trigger is suppressed.
	local $ENV{LOCK_ON_PERFECT} = 0;
	my $claims = submit_and_decode(
		AnSwEr0001         => '41',
		showCorrectAnswers => 1,
	);
	is($claims->{isLocked}, 1, 'showCorrectAnswers still triggers lock');
};

# ─── LOCK_ON_SHOW_ANSWERS=0 ────────────────────────────────────────────────

subtest 'LOCK_ON_SHOW_ANSWERS=0: reveal is ephemeral (no lock, no session persistence)' => sub {
	# Under this config, showCorrectAnswers applies to the current request
	# only — neither the lock side-effect nor the session-state persistence
	# carries forward. Next render with no claim returns to normal.
	local $ENV{LOCK_ON_SHOW_ANSWERS} = 0;
	my $claims = submit_and_decode(
		AnSwEr0001         => '41',
		showCorrectAnswers => 1,
	);
	ok(!$claims->{isLocked}, 'reveal does not lock');
	ok(!$claims->{showCorrectAnswers}, 'reveal does not persist into session state');
};

subtest 'LOCK_ON_SHOW_ANSWERS=0: perfect score still locks' => sub {
	local $ENV{LOCK_ON_SHOW_ANSWERS} = 0;
	my $claims = submit_and_decode(AnSwEr0001 => '42');
	is($claims->{isLocked}, 1, 'perfect-trigger independent of reveal-trigger');
};

# ─── Both knobs flipped ───────────────────────────────────────────────────

subtest 'both knobs off: renderer never auto-locks' => sub {
	local $ENV{LOCK_ON_PERFECT}      = 0;
	local $ENV{LOCK_ON_SHOW_ANSWERS} = 0;

	my $perfect = submit_and_decode(AnSwEr0001 => '42');
	ok(!$perfect->{isLocked}, 'perfect score does not lock');

	my $reveal = submit_and_decode(
		AnSwEr0001         => '41',
		showCorrectAnswers => 1,
	);
	ok(!$reveal->{isLocked}, 'showCorrectAnswers does not lock');
};

done_testing();
