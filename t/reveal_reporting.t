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
$ENV{problemJWTsecret}      //= 'test-problem-secret';
$ENV{webworkJWTsecret}      //= 'test-session-secret';
$ENV{SITE_HOST}             //= 'https://test.example.com';
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
# Answers show in a render only under isInstructor or a verified reveal sidecar
# (WW3-R67); on the problem lane that is the isInstructor claim.
sub submit_and_decode {
	my (%form) = @_;
	my $instructor = delete $form{isInstructor};
	$t->post_ok(
		'/render-api' => form => {
			problemJWT => upstream_problem_jwt(
				problemSource => $pg_source,
				problemSeed   => 1234,
				$instructor ? (isInstructor => 1) : ()
			),
			outputFormat  => 'debug',
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
	# Wrong submit under a trusted isInstructor claim: revealAll exposes the
	# answer and the solution.
	my $r = submit_and_decode(AnSwEr0001 => '41', isInstructor => 1);
	is($r->{answer}{answers_shown},   1, 'answerJWT.answers_shown = 1');
	is($r->{answer}{solutions_shown}, 1, 'answerJWT.solutions_shown = 1 (revealAll)');
};

subtest 'answers_shown = 0 when the render does not show answers' => sub {
	my $r = submit_and_decode(AnSwEr0001 => '41');
	is($r->{answer}{answers_shown},   0, 'answerJWT.answers_shown = 0');
	is($r->{answer}{solutions_shown}, 0, 'answerJWT.solutions_shown = 0');
};

subtest 'answers_shown = 0 with a retired showCorrectAnswers (WW3-R67)' => sub {
	my $r = submit_and_decode(AnSwEr0001 => '41', showCorrectAnswers => 1);
	is($r->{answer}{answers_shown}, 0, 'a raw showCorrectAnswers shows nothing');
};

subtest 'answers_shown reflects the effective permission, not a correct score' => sub {
	# Correct submit under revealAll: the answer is still SHOWN this render —
	# the plain fact reports what was displayed.
	my $r = submit_and_decode(AnSwEr0001 => '42', isInstructor => 1);
	is($r->{answer}{answers_shown}, 1, 'answers_shown = 1 even on a correct submit');
};

done_testing;
