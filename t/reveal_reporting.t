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

# Reveal reporting is a plain per-render fact now: was each of answers /
# solutions shown this render. The former WW3-R29 dual-state ratchet (sticky
# one-way *_revealed_in/out, and the answer-URL peek-trigger it drove) was
# removed once WW3 began recording reveals to the chain at mint and gating
# them on the frontend — nothing consumed the cumulative state. This asserts
# the surviving fact on the answerJWT.

# outputFormat=debug is a deployment affordance gated on this env var
# (WW3-R45). The test suite is its intended consumer.
$ENV{RENDERER_DEBUG_FORMAT} //= 1;
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

# Submit and decode the answerJWT so we can assert the per-render reveal fact.
# showCorrectAnswers reveals only under an OFFERING mode now (WW3-R51): the
# problem lane gates the raw flag on the `custom` default. renderMode rides the
# JWT claim (it is stripped from raw form input on grounded lanes), so a reveal
# case passes `renderMode => 'no-stakes'` to open the affordance.
sub submit_and_decode {
	my (%form) = @_;
	my $render_mode = delete $form{renderMode};
	$t->post_ok(
		'/render-api' => form => {
			problemJWT    => upstream_problem_jwt($render_mode ? (renderMode => $render_mode) : ()),
			problemSource => $pg_source,
			outputFormat  => 'debug',
			problemSeed   => 1234,
			submitAnswers => 1,
			%form,
		}
	)->status_is(200);
	my $resp = $t->tx->res->json;
	return {
		answer => $resp->{tokens}{answerJWT}
		? decode_jwt(token => $resp->{tokens}{answerJWT}, key => $ENV{problemJWTsecret})
		: undef,
		raw => $resp,
	};
}

# ─── The per-render reveal fact ────────────────────────────────────────────

subtest 'answers_shown = 1 when the render shows correct answers' => sub {
	# Wrong submit + showCorrectAnswers under an offering mode: the render
	# exposes the answer.
	my $r = submit_and_decode(AnSwEr0001 => '41', showCorrectAnswers => 1, renderMode => 'no-stakes');
	is($r->{answer}{answers_shown}, 1, 'answerJWT.answers_shown = 1');
	# Solutions are hardwired off in a student render regardless of the flag.
	is($r->{answer}{solutions_shown}, 0, 'answerJWT.solutions_shown = 0 (student render)');
};

subtest 'answers_shown = 0 when the render does not show answers' => sub {
	my $r = submit_and_decode(AnSwEr0001 => '41');
	is($r->{answer}{answers_shown},   0, 'answerJWT.answers_shown = 0');
	is($r->{answer}{solutions_shown}, 0, 'answerJWT.solutions_shown = 0');
};

subtest 'answers_shown = 0 on the custom default even with showCorrectAnswers (WW3-R51 gate)' => sub {
	# The problem-lane mode-gate. On the `custom` default (no offering bundle,
	# ADAPT's mode) a raw showCorrectAnswers is dropped — a student cannot
	# self-reveal. The offering-mode case above is the other direction; together
	# they pin the gate both ways in an environment this file can run.
	my $r = submit_and_decode(AnSwEr0001 => '41', showCorrectAnswers => 1);    # no renderMode → custom
	is($r->{answer}{answers_shown}, 0, 'raw showCorrectAnswers on custom is gated off');
};

subtest 'answers_shown reflects the effective permission, not a correct score' => sub {
	# Correct submit + showCorrectAnswers under an offering mode: the answer is
	# still SHOWN this render (the old ratchet suppressed the flag on an earned
	# score; the plain fact does not — it reports what was displayed).
	my $r = submit_and_decode(AnSwEr0001 => '42', showCorrectAnswers => 1, renderMode => 'no-stakes');
	is($r->{answer}{answers_shown}, 1, 'answers_shown = 1 even on a correct submit');
};

done_testing;
