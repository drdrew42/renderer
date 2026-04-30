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
		outputFormat  => 'debug',
		problemSeed   => 1234,
		isInstructor  => 1,
	})->status_is(200);
	my $json = $t->tx->res->json;
	ok(!$json->{tokens}{sessionJWT}, 'no sessionJWT for instructor');
	ok(!$json->{tokens}{answerJWT},  'no answerJWT for instructor');
};

# ─── Debug format ──────────────────────────────────────────────────────────

subtest 'debug outputFormat returns diagnostic JSON' => sub {
	# Post-R31: isLocked is gone entirely. The debug envelope still carries
	# the top-level `lane` field (R27) and the resolved permissions; the
	# lane-conditional isLocked block retired alongside the field.
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
		->json_is('/lane' => 'ungrounded')
		->json_is('/permissions/isInstructor' => 1)
		->json_is('/permissions/showCorrectAnswers' => 1)
		->json_is('/render_error' => 0)
		->json_hasnt('/permissions/isLocked',
			'isLocked retired (WW3-R31) — never appears in debug output');
};

subtest 'debug outputFormat: problem lane reports its lane identity' => sub {
	my $jwt = upstream_problem_jwt();
	$t->post_ok('/render-api' => form => {
		problemJWT    => $jwt,
		problemSource => $pg_source,
		outputFormat  => 'debug',
		problemSeed   => 1234,
	})->status_is(200)
	  ->json_is('/lane' => 'problem')
	  ->json_hasnt('/permissions/isLocked',
		'isLocked retired across all lanes (WW3-R31)');
};

# ─── Reveal reporting (post-R31; renderer never terminates) ───────────────

subtest 'perfect score: renderer keeps emitting answerJWTs (no terminal state)' => sub {
	# Pre-R31 the renderer locked sessions on perfect score (LOCK_ON_PERFECT
	# default on) and refused to emit subsequent answerJWTs. R31 retired that
	# machinery — the renderer is dumb, the LMS decides scoring policy. A
	# correct submit produces an answerJWT; a re-submit also produces an
	# answerJWT. The LMS reads (numCorrect+numIncorrect) for replay defense.
	my $problemJWT = upstream_problem_jwt();

	$t->post_ok('/render-api' => form => {
		problemJWT    => $problemJWT,
		problemSource => $pg_source,
		outputFormat  => 'debug',
		problemSeed   => 1234,
		submitAnswers => 1,
		AnSwEr0001    => '42',
	})->status_is(200);

	my $first = $t->tx->res->json;
	ok($first->{tokens}{sessionJWT}, 'sessionJWT minted after correct submission');
	ok($first->{tokens}{answerJWT},  'answerJWT minted after correct submission');

	# Re-submit with the post-earn sessionJWT — renderer keeps emitting.
	$t->post_ok('/render-api' => form => {
		problemJWT    => $problemJWT,
		problemSource => $pg_source,
		sessionJWT    => $first->{tokens}{sessionJWT},
		outputFormat  => 'debug',
		problemSeed   => 1234,
		submitAnswers => 1,
		AnSwEr0001    => '42',
	})->status_is(200);

	my $second = $t->tx->res->json;
	ok($second->{tokens}{answerJWT},
		'subsequent submit still produces answerJWT (renderer never terminates post-R31)');
};

subtest 'showCorrectAnswers: answersRevealed ratchets, renderer keeps emitting' => sub {
	my $problemJWT = upstream_problem_jwt();

	# Wrong answer + reveal → peek-before-earn → ratchet fires
	$t->post_ok('/render-api' => form => {
		problemJWT         => $problemJWT,
		problemSource      => $pg_source,
		outputFormat       => 'debug',
		problemSeed        => 9999,
		submitAnswers      => 1,
		showCorrectAnswers => 1,
		AnSwEr0001         => '41',
	})->status_is(200);

	my $submit = $t->tx->res->json;
	my $sessionJWT = $submit->{tokens}{sessionJWT};
	my $session_claims = decode_jwt(token => $sessionJWT, key => $ENV{webworkJWTsecret});
	is($session_claims->{answersRevealed}, 1,
		'sessionJWT carries the answersRevealed ratchet (peek-before-earn fired)');

	# Subsequent submit — renderer keeps emitting; the answerJWT carries the
	# inbound cumulative so the LMS sees this submission was post-reveal.
	$t->post_ok('/render-api' => form => {
		problemJWT    => $problemJWT,
		problemSource => $pg_source,
		sessionJWT    => $sessionJWT,
		outputFormat  => 'debug',
		problemSeed   => 9999,
		submitAnswers => 1,
		AnSwEr0001    => '42',
	})->status_is(200);

	my $follow_up = $t->tx->res->json;
	my $answer = $follow_up->{tokens}{answerJWT};
	ok($answer, 'follow-up submit still produces answerJWT (no terminal state)');
	my $answer_claims = decode_jwt(token => $answer, key => $ENV{problemJWTsecret});
	is($answer_claims->{answersRevealed}, 1,
		'answerJWT carries inbound cumulative — LMS sees the submission was post-reveal');
};

done_testing();
