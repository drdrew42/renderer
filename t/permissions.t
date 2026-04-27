use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping permission tests';
}

use Test::Mojo;
use Crypt::JWT qw(decode_jwt encode_jwt);

# Renderer startup refuses placeholder secrets; supply test values.
$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';

# Helper: mint an upstream-style problemJWT carrying JWTanswerURL. Required
# for any test that expects sessionJWT/answerJWT to be produced — sessionJWT
# minting is now gated on JWTanswerURL presence (caller asks for persistence).
sub upstream_problem_jwt {
	my %extra = @_;
	return encode_jwt(
		payload => {
			aud          => $ENV{SITE_HOST},
			iss          => $ENV{SITE_HOST},
			JWTanswerURL => 'https://upstream.example.test/answer',
			%extra,
		},
		key      => $ENV{problemJWTsecret},
		alg      => 'HS256',
		auto_iat => 1,
	);
}

my $t = Test::Mojo->new('Renderer');
my $render_root = $ENV{RENDER_ROOT};

make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

# A problem with hints and solutions for permission testing.
my $pg_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$answer = Compute("42");
$showHint = 1;
TEXT(beginproblem());
BEGIN_PGML
What is the answer? [___]{$answer}
END_PGML
BEGIN_PGML_HINT
The answer is a number.
END_PGML_HINT
BEGIN_PGML_SOLUTION
The answer is 42.
END_PGML_SOLUTION
ENDDOCUMENT();
PG

# ─── Permission model ──────────────────────────────────────────────────────

# ─── Instructor defaults ──────────────────────────────────────────────────

subtest 'instructor: solutions and answers visible by default' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource => $pg_source,
		outputFormat  => 'default',
		problemSeed   => 1234,
		isInstructor  => 1,
	})->status_is(200);
	my $body = $t->tx->res->body;
	like($body, qr/solution accordion/, 'solutions visible by default for instructor');
};

subtest 'instructor: showSolutions=0 suppresses solutions' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource => $pg_source,
		outputFormat  => 'default',
		problemSeed   => 1234,
		isInstructor  => 1,
		showSolutions => 0,
	})->status_is(200);
	my $body = $t->tx->res->body;
	unlike($body, qr/solution accordion/, 'instructor can suppress solutions');
};

# ─── Student defaults ────────────────────────────────────────────────────

subtest 'student: no solutions without showCorrectAnswers' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource => $pg_source,
		outputFormat  => 'default',
		problemSeed   => 1234,
	})->status_is(200);
	my $body = $t->tx->res->body;
	unlike($body, qr/solution accordion/, 'no solutions for student by default');
};

subtest 'student: showCorrectAnswers implies solutions' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource      => $pg_source,
		outputFormat       => 'default',
		problemSeed        => 1234,
		showCorrectAnswers => 1,
	})->status_is(200);
	my $body = $t->tx->res->body;
	like($body, qr/solution accordion/, 'showCorrectAnswers reveals solutions too');
};

subtest 'student: showCorrectAnswers + showSolutions=0 suppresses solutions' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource      => $pg_source,
		outputFormat       => 'default',
		problemSeed        => 1234,
		showCorrectAnswers => 1,
		showSolutions      => 0,
	})->status_is(200);
	my $body = $t->tx->res->body;
	unlike($body, qr/solution accordion/, 'explicit showSolutions=0 suppresses even with showCorrectAnswers');
};

subtest 'student: showSolutions=1 without showCorrectAnswers is ignored' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource => $pg_source,
		outputFormat  => 'default',
		problemSeed   => 1234,
		showSolutions => 1,
	})->status_is(200);
	my $body = $t->tx->res->body;
	unlike($body, qr/solution accordion/, 'showSolutions alone does nothing for student');
};

subtest 'hints are ungated passthrough' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource => $pg_source,
		outputFormat  => 'default',
		problemSeed   => 1234,
		showHints     => 1,
	})->status_is(200);
	my $body = $t->tx->res->body;
	like($body, qr/hint accordion/, 'hints visible without isInstructor');
};

subtest 'hints suppressed by explicit showHints=0' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource => $pg_source,
		outputFormat  => 'default',
		problemSeed   => 1234,
		isInstructor  => 1,
		showHints     => 0,
	})->status_is(200);
	my $body = $t->tx->res->body;
	unlike($body, qr/hint accordion/, 'hints suppressed by showHints=0 even for instructor');
};

# ─── Instructor JWT suppression ────────────────────────────────────────────

subtest 'instructor gets no sessionJWT or answerJWT' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource => $pg_source,
		outputFormat  => 'raw',
		problemSeed   => 1234,
		isInstructor  => 1,
	})->status_is(200);
	my $json = $t->tx->res->json;
	ok(!$json->{rh_result}{sessionJWT}, 'no sessionJWT for instructor');
	ok(!$json->{rh_result}{answerJWT},  'no answerJWT for instructor');
};

# ─── Debug format ──────────────────────────────────────────────────────────

subtest 'debug outputFormat returns diagnostic JSON' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource      => $pg_source,
		outputFormat       => 'debug',
		problemSeed        => 1234,
		isInstructor       => 1,
		showCorrectAnswers => 1,
	})->status_is(200)->json_has('/permissions')
		->json_has('/problem')
		->json_has('/macros')
		->json_has('/result')
		->json_is('/permissions/isInstructor' => 1)
		->json_is('/permissions/showCorrectAnswers' => 1)
		->json_is('/render_error' => 0);
};

# ─── Session lock ──────────────────────────────────────────────────────────

subtest 'session locks on 100% score (non-instructor)' => sub {
	# Use an upstream-minted problemJWT carrying JWTanswerURL so the renderer
	# mints session+answer JWTs (the persistence path).
	my $problemJWT = upstream_problem_jwt();

	# Submit the correct answer
	$t->post_ok('/render-api' => form => {
		problemJWT    => $problemJWT,
		problemSource => $pg_source,
		outputFormat  => 'raw',
		problemSeed   => 1234,
		submitAnswers => 1,
		AnSwEr0001    => '42',
	})->status_is(200);

	my $submit_raw = $t->tx->res->json;
	my $sessionJWT = $submit_raw->{rh_result}{sessionJWT};
	ok($sessionJWT, 'got sessionJWT after correct submission');

	# Decode the sessionJWT to verify isLocked
	my $session_claims = decode_jwt(
		token => $sessionJWT,
		key   => $ENV{webworkJWTsecret},
	);
	is($session_claims->{isLocked}, 1, 'session is locked after 100% score');

	# Verify answerJWT was still generated (this is the locking submit)
	my $answerJWT = $submit_raw->{rh_result}{answerJWT};
	ok($answerJWT, 'answerJWT present on the locking submit');

	# Decode answerJWT to verify isLocked is exposed
	my $answer_claims = decode_jwt(
		token => $answerJWT,
		key   => $ENV{problemJWTsecret},
	);
	is($answer_claims->{isLocked}, 1, 'answerJWT contains isLocked=1');

	# Now submit again with the locked session — should get no answerJWT
	$t->post_ok('/render-api' => form => {
		problemJWT    => $problemJWT,
		problemSource => $pg_source,
		sessionJWT    => $sessionJWT,
		outputFormat  => 'raw',
		problemSeed   => 1234,
		submitAnswers => 1,
		AnSwEr0001    => '42',
	})->status_is(200);

	my $locked_raw = $t->tx->res->json;
	ok(!$locked_raw->{rh_result}{answerJWT}, 'no answerJWT from already-locked session');
};

subtest 'session locks on showCorrectAnswers (non-instructor)' => sub {
	my $problemJWT = upstream_problem_jwt();

	# Submit a wrong answer but request correct answers (implies solutions)
	$t->post_ok('/render-api' => form => {
		problemJWT         => $problemJWT,
		problemSource      => $pg_source,
		outputFormat       => 'raw',
		problemSeed        => 9999,
		submitAnswers      => 1,
		showCorrectAnswers => 1,
		AnSwEr0001         => '41',
	})->status_is(200);

	my $submit = $t->tx->res->json;
	my $sessionJWT = $submit->{rh_result}{sessionJWT};
	ok($sessionJWT, 'got sessionJWT after showCorrectAnswers request');

	my $claims = decode_jwt(
		token => $sessionJWT,
		key   => $ENV{webworkJWTsecret},
	);
	is($claims->{isLocked},            1, 'session locked by showCorrectAnswers');
	is($claims->{showCorrectAnswers},  1, 'showCorrectAnswers claim persisted');

	# Subsequent request should not produce an answerJWT
	$t->post_ok('/render-api' => form => {
		problemJWT    => $problemJWT,
		problemSource => $pg_source,
		sessionJWT    => $sessionJWT,
		outputFormat  => 'raw',
		problemSeed   => 9999,
		submitAnswers => 1,
		AnSwEr0001    => '42',
	})->status_is(200);

	my $locked = $t->tx->res->json;
	ok(!$locked->{rh_result}{answerJWT}, 'no answerJWT after showCorrectAnswers lock');
};

subtest 'showSolutions alone does NOT lock session (non-instructor)' => sub {
	my $problemJWT = upstream_problem_jwt();

	# Submit wrong answer with showSolutions but NOT showCorrectAnswers
	$t->post_ok('/render-api' => form => {
		problemJWT    => $problemJWT,
		problemSource => $pg_source,
		outputFormat  => 'raw',
		problemSeed   => 8888,
		submitAnswers => 1,
		showSolutions => 1,
		AnSwEr0001    => '41',
	})->status_is(200);

	my $submit = $t->tx->res->json;
	my $sessionJWT = $submit->{rh_result}{sessionJWT};
	ok($sessionJWT, 'got sessionJWT');

	my $claims = decode_jwt(
		token => $sessionJWT,
		key   => $ENV{webworkJWTsecret},
	);
	ok(!$claims->{isLocked}, 'session NOT locked by showSolutions alone');
};

# ─── Raw param injection blocked ──────────────────────────────────────────

subtest 'raw isLocked=0 cannot override locked sessionJWT' => sub {
	my $problemJWT = upstream_problem_jwt();

	# Submit correct answer to lock
	$t->post_ok('/render-api' => form => {
		problemJWT    => $problemJWT,
		problemSource => $pg_source,
		outputFormat  => 'raw',
		problemSeed   => 5678,
		submitAnswers => 1,
		AnSwEr0001    => '42',
	})->status_is(200);

	my $locked_session = $t->tx->res->json->{rh_result}{sessionJWT};
	ok($locked_session, 'got locked sessionJWT');

	# Try to bypass with raw isLocked=0
	$t->post_ok('/render-api' => form => {
		problemJWT    => $problemJWT,
		problemSource => $pg_source,
		sessionJWT    => $locked_session,
		outputFormat  => 'raw',
		problemSeed   => 5678,
		submitAnswers => 1,
		isLocked      => 0,
		AnSwEr0001    => '42',
	})->status_is(200);

	my $bypass_raw = $t->tx->res->json;
	ok(!$bypass_raw->{rh_result}{answerJWT}, 'raw isLocked=0 did NOT bypass locked session');
};

done_testing();
