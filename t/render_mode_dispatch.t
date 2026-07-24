use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Integration tests for Renderer::RenderMode hooked into
# Renderer::Render::ParseRequest::dispatch. Exercises the full dispatch path
# and verifies that the mode resolver runs in the parent process (so the
# format-layer primitives are visible) AND that the override list lands on
# $c->stash('_mode_overrides'). The debug outputFormat surfaces both values
# so we can assert on them without controller introspection.
#
# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping render_mode_dispatch tests';
}

use Test::Mojo;
use Crypt::JWT qw(encode_jwt);

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

sub make_problem_jwt {
	my (%claims) = @_;
	return encode_jwt(
		payload => {
			aud => $ENV{SITE_HOST},
			iss => $ENV{SITE_HOST},
			%claims,
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

my $pg_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "MathObjects.pl", "PGML.pl");
$ans = Real(2);
BEGIN_PGML
What is 1 + 1?  [_]{$ans}
END_PGML
ENDDOCUMENT();
PG

# ─── ungrounded lane (raw form) ────────────────────────────────────────────

subtest 'ungrounded: renderMode echoed back in debug; empty overrides when caller agrees' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource => $pg_source,
		problemSeed   => 1234,
		outputFormat  => 'debug',
		renderMode    => 'default',
	})->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode}, 'default', 'renderMode surfaced in debug');
	is_deeply($debug->{mode_overrides}, [], 'no overrides — caller supplied nothing conflicting');
};

subtest 'ungrounded: no-feedback overrides conflicting caller primitives' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource      => $pg_source,
		problemSeed        => 1234,
		outputFormat       => 'debug',
		renderMode         => 'no-feedback',
		hideFeedback       => 0,    # mode forces to 1
		showCorrectAnswers => 1,    # mode forces to 0
	})->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode}, 'no-feedback', 'mode preserved');
	is_deeply(
		[ sort @{ $debug->{mode_overrides} } ],
		[ sort qw(hideFeedback showCorrectAnswers) ],
		'both conflicting caller primitives recorded as overrides',
	);
	# Permission resolver downstream of mode: showCorrectAnswers should be 0.
	is($debug->{permissions}{showCorrectAnswers}, 0,
		'mode-forced showCorrectAnswers=0 visible to permission resolver');
};

subtest 'ungrounded: custom mode is pure passthrough' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource => $pg_source,
		problemSeed   => 1234,
		outputFormat  => 'debug',
		renderMode    => 'custom',
		hideFeedback  => 1,    # caller value should survive
	})->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode}, 'custom', 'mode preserved');
	is_deeply($debug->{mode_overrides}, [], 'custom mode never overrides');
};

subtest 'ungrounded: absent renderMode → custom (no overrides)' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource => $pg_source,
		problemSeed   => 1234,
		outputFormat  => 'debug',
	})->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode}, undef, 'no renderMode in inputs_ref');
	is_deeply($debug->{mode_overrides}, [], 'absent mode → no overrides');
};

subtest 'ungrounded: unknown mode treated as custom (forward-compat)' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource => $pg_source,
		problemSeed   => 1234,
		outputFormat  => 'debug',
		renderMode    => 'totally-fake-mode-name',
		hideFeedback  => 1,
	})->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode}, 'totally-fake-mode-name', 'unknown mode echoed back unchanged');
	is_deeply($debug->{mode_overrides}, [], 'unknown mode acts as custom — no overrides');
};

# ─── problemJWT lane (claim-wins via bulk merge) ───────────────────────────

subtest 'problemJWT: renderMode claim wins over raw form renderMode' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
		renderMode    => 'no-feedback',
	);

	$t->post_ok('/render-api' => form => {
		problemJWT   => $jwt,
		outputFormat => 'debug',
		renderMode   => 'default',    # raw form tries 'default'; claim should win
	})->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode}, 'no-feedback',
		'JWT claim wins over raw form param (Lane::Problem bulk merge)');
};

subtest 'problemJWT: preview claim overrides caller isInstructor=0 in form' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
		renderMode    => 'preview',
	);

	$t->post_ok('/render-api' => form => {
		problemJWT   => $jwt,
		outputFormat => 'debug',
	})->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode}, 'preview', 'preview mode applied');
	is($debug->{permissions}{isInstructor}, 1,
		'preview mode promoted to instructor → revealAll');
	is($debug->{permissions}{showCorrectAnswers}, 1, 'showCorrectAnswers revealed');
	is($debug->{permissions}{showHints},          1, 'showHints revealed');
	is($debug->{permissions}{showSolutions},      1, 'showSolutions revealed');
};

# ─── Format-layer primitives must survive the subprocess fork ──────────────

# Pre-WW3-R43-hoist, resolve_render_mode lived inside the rendering
# subprocess. Mutations to $inputs_ref made in the child were lost across
# the fork boundary, so FormatRenderedProblem (which runs in the parent
# post-subprocess) saw the un-mutated values. Symptom: preview rendered
# without the Show Correct Answers button. This subtest pins the fix —
# format-layer button-visibility flags must reflect the mode bundle.

subtest 'preview mode: Show Correct Answers button reaches the format layer' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
		renderMode    => 'preview',
	);

	$t->post_ok('/render-api' => form => {
		problemJWT   => $jwt,
		outputFormat => 'default',
	})->status_is(200)
	  ->content_like(
		qr/Show Correct Answers/,
		'preview-mode showCorrectAnswersButton=1 visible to template after fork',
	);
};

subtest 'review mode: Check Answers button hidden in the format layer' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
		renderMode    => 'review',
	);

	$t->post_ok('/render-api' => form => {
		problemJWT   => $jwt,
		outputFormat => 'default',
	})->status_is(200)
	  ->content_unlike(
		qr/Check Answers/,
		'review-mode hideCheckAnswersButton=1 visible to template after fork',
	);
};

done_testing();
