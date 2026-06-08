use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping submissionJWT tests';
}

use Test::Mojo;
use Crypt::JWT qw(encode_jwt decode_jwt);
use Mojo::JSON qw(decode_json encode_json);

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

# ─── Helpers ────────────────────────────────────────────────────────────────

# Mirrors WeBWorK::RenderProblem::generateSubmissionJWT shape.
sub make_submission_jwt {
	my (%overrides) = @_;
	my $payload = {
		iss               => $ENV{SITE_HOST},
		aud               => $ENV{SITE_HOST},
		play_id           => '11111111-1111-1111-1111-111111111111',
		challenge_id      => 'sha256:abcdef',
		chain_student_id  => 'cafebabe',
		position          => 0,
		pg_hash           => 'sha256:p0',
		seed              => 11111,
		submitted_answers => {
			'AnSwEr0001'           => '42',
			'MaThQuIlL_AnSwEr0001' => '42',
		},
		part_scores  => [1],
		score        => 1,
		submitted_at => '2026-05-04T12:00:00Z',
		%overrides,
	};
	return encode_jwt(payload => $payload, key => $ENV{problemJWTsecret}, alg => 'HS256');
}

# Tiny PGML problem — answer is 42. Passing problemSource alongside the
# submissionJWT lets us bypass OPL fetch (the JWT carries pg_hash, but
# raw source wins per the lane contract — Lane::Review.pm only synthesizes
# problemSourceURL when problemSource is absent).
my $pg_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$ans = Compute("42");
TEXT(beginproblem());
BEGIN_PGML
What is the answer? [___]{$ans}
END_PGML
ENDDOCUMENT();
PG

sub post_json {
	my ($form) = @_;
	return $t->post_ok('/render-api', { Accept => 'application/json' }, form => $form);
}

# ─── Replay rendering ───────────────────────────────────────────────────────

subtest 'submissionJWT renders the historical problem with prefilled answers' => sub {
	my $jwt = make_submission_jwt();
	post_json({
		submissionJWT => $jwt,
		problemSource => $pg_source,
	})->status_is(200);

	my $resp = decode_json($t->tx->res->body);
	like($resp->{renderedHTML}, qr/What is the answer\?/, 'problem rendered');
	# PG natively prefills <input value="..."> from inputs_ref->{AnSwEr0001}.
	# The submitted answer '42' is the historical value; reView shows it.
	like($resp->{renderedHTML}, qr/value="42"/, 'historical answer prefilled into input');
};

subtest 'submissionJWT triggers graded-view rendering (submitAnswers forced)' => sub {
	# Replay contract: original submission set submitAnswers, so reView does
	# too. The graded view exposes per-answer feedback (correct/incorrect
	# state in the rendered JSON envelope) — proves PG ran the grading path.
	my $jwt = make_submission_jwt();
	post_json({
		submissionJWT => $jwt,
		problemSource => $pg_source,
	})->status_is(200);

	my $resp = decode_json($t->tx->res->body);
	# answers section in the response includes per-answer state when graded.
	like(encode_json($resp), qr/score/, 'graded view (score data) present in response');
};

# ─── No-emission contract ───────────────────────────────────────────────────

subtest 'submissionJWT path mints no continuation tokens' => sub {
	# reView is read-only. No new sessionJWT, no answerJWT, no fresh
	# submissionJWT — the lane sets neither _can_emit_answer_jwt nor
	# JWTanswerURL, so the late emission gate naturally short-circuits.
	my $jwt = make_submission_jwt();
	post_json({
		submissionJWT => $jwt,
		problemSource => $pg_source,
	})->status_is(200);

	my $resp = decode_json($t->tx->res->body);
	ok(!$resp->{JWT}{session},    'no sessionJWT minted');
	ok(!$resp->{JWT}{answer},     'no answerJWT minted');
	ok(!$resp->{JWT}{submission}, 'no submissionJWT minted (lane is read-only)');
};

# ─── Mutual exclusion with sibling body lanes ───────────────────────────────

subtest 'submissionJWT + challengeJWT → 400 ambiguous' => sub {
	my $sub_jwt = make_submission_jwt();
	# Minimal challengeJWT shape — just enough to parse.
	my $ch_jwt = encode_jwt(
		payload => {
			aud      => $ENV{SITE_HOST},
			iss      => $ENV{SITE_HOST},
			problems => [ { pg_hash => 'sha256:p0', seed => 11111 } ],
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
	$t->post_ok(
		'/render-api' => form => {
			submissionJWT => $sub_jwt,
			challengeJWT  => $ch_jwt,
		}
	)->status_is(400);
	like($t->tx->res->body, qr/Ambiguous/i, 'response mentions ambiguous envelope');
};

subtest 'submissionJWT + problemJWT → 400 ambiguous' => sub {
	my $sub_jwt  = make_submission_jwt();
	my $prob_jwt = encode_jwt(
		payload => { aud => $ENV{SITE_HOST}, iss => $ENV{SITE_HOST} },
		key     => $ENV{problemJWTsecret},
		alg     => 'HS256',
	);
	$t->post_ok(
		'/render-api' => form => {
			submissionJWT => $sub_jwt,
			problemJWT    => $prob_jwt,
		}
	)->status_is(400);
	like($t->tx->res->body, qr/Ambiguous/i);
};

# ─── Required claims ────────────────────────────────────────────────────────

subtest 'submissionJWT missing pg_hash → 400' => sub {
	my $jwt = make_submission_jwt(pg_hash => undef);
	$t->post_ok(
		'/render-api' => form => {
			submissionJWT => $jwt,
			problemSource => $pg_source,
		}
	)->status_is(400);
	like($t->tx->res->body, qr/pg_hash/i, 'error names the missing claim');
};

subtest 'submissionJWT missing seed → 400' => sub {
	my $jwt = make_submission_jwt(seed => undef);
	$t->post_ok(
		'/render-api' => form => {
			submissionJWT => $jwt,
			problemSource => $pg_source,
		}
	)->status_is(400);
	like($t->tx->res->body, qr/seed/i, 'error names the missing claim');
};

subtest 'submissionJWT missing position → 400' => sub {
	my $jwt = make_submission_jwt(position => undef);
	$t->post_ok(
		'/render-api' => form => {
			submissionJWT => $jwt,
			problemSource => $pg_source,
		}
	)->status_is(400);
	like($t->tx->res->body, qr/position/i, 'error names the missing claim');
};

# ─── outputFormat lock ──────────────────────────────────────────────────────

subtest 'outputFormat hardcoded to default on submissionJWT path (URL ignored)' => sub {
	# Same lock as Lane::Challenge — reView is iframe-only.
	my $jwt = make_submission_jwt();
	post_json({
		submissionJWT => $jwt,
		problemSource => $pg_source,
		outputFormat  => 'debug',
	})->status_is(200);
	my $resp = decode_json($t->tx->res->body);
	ok(exists $resp->{renderedHTML}, 'response is the standard JSON envelope (default)');
	ok(!exists $resp->{permissions}, 'no debug-format leak');
};

# ─── Empty-string handling (parity with sibling lanes) ──────────────────────

subtest 'empty-string submissionJWT treated as not-present' => sub {
	# Symmetric with empty-string handling for problemJWT/sessionJWT/
	# challengeJWT/verdict_signed. An empty value should fall through to
	# the next dispatch branch, not 400 on a JWT decode error.
	post_json({
		submissionJWT => '',
		problemSource => $pg_source,
		problemSeed   => 1234,
	})->status_is(200);
};

# ─── Forged signature → reject ─────────────────────────────────────────────

subtest 'submissionJWT with bad signature → croak' => sub {
	my $payload = {
		iss               => $ENV{SITE_HOST},
		aud               => $ENV{SITE_HOST},
		play_id           => '11111111-1111-1111-1111-111111111111',
		position          => 0,
		pg_hash           => 'sha256:p0',
		seed              => 11111,
		submitted_answers => { 'AnSwEr0001' => '42' },
	};
	my $bogus = encode_jwt(payload => $payload, alg => 'HS256', key => 'totally-different-secret___');

	$t->post_ok(
		'/render-api' => form => {
			submissionJWT => $bogus,
			problemSource => $pg_source,
		}
	);
	# croak() returns the standard renderer error envelope; status is the
	# renderer's croak-code (3) → 500-class. Just verify it didn't render
	# successfully against the forged token.
	ok($t->tx->res->code != 200, 'forged submissionJWT does not render');
};

done_testing;
