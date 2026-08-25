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
# outputFormat=debug is a deployment affordance gated on this env var
# (WW3-R45). The test suite is its intended consumer.
$ENV{RENDERER_DEBUG_FORMAT} //= 1;
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

my $t           = Test::Mojo->new('Renderer');
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
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			outputFormat  => 'default',
			problemSeed   => 1234,
			isInstructor  => 1,
		}
	)->status_is(200);
	my $body = $t->tx->res->body;
	like($body, qr/solution accordion/, 'solutions visible by default for instructor');
};

subtest 'instructor: showSolutions inbound ignored (revealAll forces on)' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			outputFormat  => 'default',
			problemSeed   => 1234,
			isInstructor  => 1,
			showSolutions => 0,
		}
	)->status_is(200);
	my $body = $t->tx->res->body;
	like($body, qr/solution accordion/, 'instructor sees solutions regardless of inbound showSolutions=0');
};

subtest 'instructor: hints visible regardless of inbound showHints' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			outputFormat  => 'default',
			problemSeed   => 1234,
			isInstructor  => 1,
			showHints     => 0,
		}
	)->status_is(200);
	my $body = $t->tx->res->body;
	like($body, qr/hint accordion/, 'instructor sees hints regardless of inbound showHints=0');
};

# ─── Student defaults ────────────────────────────────────────────────────

subtest 'student: no solutions without showCorrectAnswers' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			outputFormat  => 'default',
			problemSeed   => 1234,
		}
	)->status_is(200);
	my $body = $t->tx->res->body;
	unlike($body, qr/solution accordion/, 'no solutions for student by default');
};

subtest 'student: showCorrectAnswers does NOT imply solutions (hardwired off)' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource      => $pg_source,
			outputFormat       => 'default',
			problemSeed        => 1234,
			showCorrectAnswers => 1,
		}
	)->status_is(200);
	my $body = $t->tx->res->body;
	unlike($body, qr/solution accordion/, 'solutions hardwired off for students; fetch via /render-api/solution');
};

subtest 'student: inbound showSolutions=1 is ignored (hardwired off)' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			outputFormat  => 'default',
			problemSeed   => 1234,
			showSolutions => 1,
		}
	)->status_is(200);
	my $body = $t->tx->res->body;
	unlike($body, qr/solution accordion/, 'showSolutions=1 from student form ignored');
};

subtest 'student: inbound showHints=1 is ignored (hardwired off)' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			outputFormat  => 'default',
			problemSeed   => 1234,
			showHints     => 1,
		}
	)->status_is(200);
	my $body = $t->tx->res->body;
	unlike($body, qr/hint accordion/, 'hints hardwired off for students; fetch via /render-api/hint');
};

# ─── Instructor JWT suppression ────────────────────────────────────────────

subtest 'instructor gets no sessionJWT or answerJWT' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			outputFormat  => 'debug',
			problemSeed   => 1234,
			isInstructor  => 1,
		}
	)->status_is(200);
	my $json = $t->tx->res->json;
	ok(!$json->{tokens}{sessionJWT}, 'no sessionJWT for instructor');
	ok(!$json->{tokens}{answerJWT},  'no answerJWT for instructor');
};

# ─── Debug format ──────────────────────────────────────────────────────────

subtest 'debug outputFormat returns diagnostic JSON' => sub {
	# Post-R31: isLocked is gone entirely. The debug envelope still carries
	# the top-level `lane` field (R27) and the resolved permissions; the
	# lane-conditional isLocked block retired alongside the field.
	$t->post_ok(
		'/render-api' => form => {
			problemSource      => $pg_source,
			outputFormat       => 'debug',
			problemSeed        => 1234,
			isInstructor       => 1,
			showCorrectAnswers => 1,
		}
	)->status_is(200)->json_has('/permissions')->json_has('/problem')->json_has('/macros')->json_has('/result')
		->json_is('/lane'                           => 'ungrounded')->json_is('/permissions/isInstructor' => 1)
		->json_is('/permissions/showCorrectAnswers' => 1)->json_is('/render_error' => 0)
		->json_hasnt('/permissions/isLocked', 'isLocked retired (WW3-R31) — never appears in debug output');
};

subtest 'debug outputFormat: problem lane reports its lane identity' => sub {
	my $jwt = upstream_problem_jwt();
	$t->post_ok(
		'/render-api' => form => {
			problemJWT    => $jwt,
			problemSource => $pg_source,
			outputFormat  => 'debug',
			problemSeed   => 1234,
		}
	)->status_is(200)->json_is('/lane' => 'problem')
		->json_hasnt('/permissions/isLocked', 'isLocked retired across all lanes (WW3-R31)');
};

# ─── Reveal reporting (post-R31; renderer never terminates) ───────────────

subtest 'perfect score: renderer keeps emitting answerJWTs (no terminal state)' => sub {
	# Pre-R31 the renderer locked sessions on perfect score (LOCK_ON_PERFECT
	# default on) and refused to emit subsequent answerJWTs. R31 retired that
	# machinery — the renderer is dumb, the LMS decides scoring policy. A
	# correct submit produces an answerJWT; a re-submit also produces an
	# answerJWT. The LMS reads (numCorrect+numIncorrect) for replay defense.
	my $problemJWT = upstream_problem_jwt();

	$t->post_ok(
		'/render-api' => form => {
			problemJWT    => $problemJWT,
			problemSource => $pg_source,
			outputFormat  => 'debug',
			problemSeed   => 1234,
			submitAnswers => 1,
			AnSwEr0001    => '42',
		}
	)->status_is(200);

	my $first = $t->tx->res->json;
	ok($first->{tokens}{sessionJWT}, 'sessionJWT minted after correct submission');
	ok($first->{tokens}{answerJWT},  'answerJWT minted after correct submission');

	# Re-submit with the post-earn sessionJWT — renderer keeps emitting.
	$t->post_ok(
		'/render-api' => form => {
			problemJWT    => $problemJWT,
			problemSource => $pg_source,
			sessionJWT    => $first->{tokens}{sessionJWT},
			outputFormat  => 'debug',
			problemSeed   => 1234,
			submitAnswers => 1,
			AnSwEr0001    => '42',
		}
	)->status_is(200);

	my $second = $t->tx->res->json;
	ok($second->{tokens}{answerJWT},
		'subsequent submit still produces answerJWT (renderer never terminates post-R31)');
};

subtest 'showCorrectAnswers: per-render answers_shown, no sticky carry-forward' => sub {
	# no-stakes is an OFFERING mode (WW3-R51): it lets a student render honour
	# showCorrectAnswers. It rides the JWT claim because renderMode is stripped
	# from raw form input on grounded lanes. Without it the flag is gated off on
	# the `custom` default and answers_shown would stay 0.
	my $problemJWT = upstream_problem_jwt(renderMode => 'no-stakes');

	# Wrong answer + reveal → this render showed the answer.
	$t->post_ok(
		'/render-api' => form => {
			problemJWT         => $problemJWT,
			problemSource      => $pg_source,
			outputFormat       => 'debug',
			problemSeed        => 9999,
			submitAnswers      => 1,
			showCorrectAnswers => 1,
			AnSwEr0001         => '41',
		}
	)->status_is(200);

	my $submit        = $t->tx->res->json;
	my $answer1       = decode_jwt(token => $submit->{tokens}{answerJWT}, key => $ENV{problemJWTsecret});
	is($answer1->{answers_shown}, 1, 'answerJWT.answers_shown = 1 (this render showed answers)');

	# Subsequent submit WITHOUT reveal → answers_shown = 0. There is no sticky
	# carry-forward: each render reports its own fact. The old ratchet would
	# have kept answersRevealed=1 here; the plain fact does not, because WW3
	# owns reveal history in the chain, not the wire.
	$t->post_ok(
		'/render-api' => form => {
			problemJWT    => $problemJWT,
			problemSource => $pg_source,
			sessionJWT    => $submit->{tokens}{sessionJWT},
			outputFormat  => 'debug',
			problemSeed   => 9999,
			submitAnswers => 1,
			AnSwEr0001    => '42',
		}
	)->status_is(200);

	my $follow_up = $t->tx->res->json;
	ok($follow_up->{tokens}{answerJWT}, 'follow-up submit still produces answerJWT');
	my $answer2 = decode_jwt(token => $follow_up->{tokens}{answerJWT}, key => $ENV{problemJWTsecret});
	is($answer2->{answers_shown}, 0, 'answers_shown = 0 on the follow-up (no sticky carry-forward)');
};

# ─── WW3-R56: debug permission half is isInstructor-gated ─────────────────
#
# RENDERER_DEBUG_FORMAT is set for this file, so outputFormat=debug returns the
# diagnostic JSON envelope, which serializes the resolver's `permissions` block.
# The show_* flags are the PERMISSION half of PG's debug gate and now come from
# the resolver, not raw input — so a student who self-declares them stays 0 and
# an instructor gets 1. (WW3-R57 removes the format entirely on a deployment
# that has NOT set RENDERER_DEBUG_FORMAT — a different gate, tested in entry_gate.t.)

subtest 'student cannot self-grant the debug permission half' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource         => $pg_source,
			outputFormat          => 'debug',
			problemSeed           => 1234,
			isInstructor          => 0,
			show_answer_hash_info => 1,
			showAnsHashInfo       => 1,
			show_pg_info          => 1,
			showPGInfo            => 1,
		}
	)->status_is(200);
	my $perms = $t->tx->res->json->{permissions};
	is($perms->{show_answer_hash_info},  0, 'student: show_answer_hash_info stays 0 despite self-declaration');
	is($perms->{show_pg_info},           0, 'student: show_pg_info stays 0');
	is($perms->{show_answer_group_info}, 0, 'student: show_answer_group_info stays 0');
	is($perms->{show_resource_info},     0, 'student: show_resource_info stays 0');
};

subtest 'instructor gets the debug permission half' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			outputFormat  => 'debug',
			problemSeed   => 1234,
			isInstructor  => 1,
		}
	)->status_is(200);
	my $perms = $t->tx->res->json->{permissions};
	is($perms->{show_answer_hash_info},  1, 'instructor: show_answer_hash_info granted');
	is($perms->{show_pg_info},           1, 'instructor: show_pg_info granted');
	is($perms->{show_answer_group_info}, 1, 'instructor: show_answer_group_info granted');
	is($perms->{show_resource_info},     1, 'instructor: show_resource_info granted');
};

done_testing();
