use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping hint/solution endpoint tests';
}

use Test::Mojo;

# Renderer startup refuses placeholder secrets; supply test values.
$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';
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

# A problem with both hints and solutions for endpoint testing.
my $pg_with_both = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$answer = Compute("42");
TEXT(beginproblem());
BEGIN_PGML
What is the answer? [___]{$answer}
END_PGML
BEGIN_PGML_HINT
The answer is a small even number.
END_PGML_HINT
BEGIN_PGML_SOLUTION
The answer is 42 because of arithmetic.
END_PGML_SOLUTION
ENDDOCUMENT();
PG

# A problem with only hints (no solution).
my $pg_hints_only = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$answer = Compute("7");
TEXT(beginproblem());
BEGIN_PGML
Pick a number. [___]{$answer}
END_PGML
BEGIN_PGML_HINT
Try a single digit.
END_PGML_HINT
ENDDOCUMENT();
PG

# A problem with neither.
my $pg_bare = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$answer = Compute("100");
TEXT(beginproblem());
BEGIN_PGML
What is 10 squared? [___]{$answer}
END_PGML
ENDDOCUMENT();
PG

# A problem with multiple hints.
my $pg_multi_hints = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$answer = Compute("12");
TEXT(beginproblem());
BEGIN_PGML
Two times what equals 24? [___]{$answer}
END_PGML
BEGIN_PGML_HINT
First hint: think about division.
END_PGML_HINT
BEGIN_PGML_HINT
Second hint: 24 divided by 2.
END_PGML_HINT
ENDDOCUMENT();
PG

# ─── Solution endpoint ────────────────────────────────────────────────────

subtest 'POST /render-api/solution returns solution body' => sub {
	$t->post_ok('/render-api/solution' => form => {
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(200)
	  ->json_has('/solution');
	my $body = $t->tx->res->json->{solution};
	ok($body, 'solution body is non-empty');
	like($body, qr/42/, 'solution body contains expected content');
};

subtest 'POST /render-api/solution: no solution → solution=null' => sub {
	$t->post_ok('/render-api/solution' => form => {
		problemSource => $pg_hints_only,
		problemSeed   => 1234,
	})->status_is(200);
	is($t->tx->res->json->{solution}, undef,
		'problem with no solution returns solution=null');
};

subtest 'POST /render-api/solution: bare problem → solution=null' => sub {
	$t->post_ok('/render-api/solution' => form => {
		problemSource => $pg_bare,
		problemSeed   => 1234,
	})->status_is(200);
	is($t->tx->res->json->{solution}, undef,
		'problem with neither hints nor solutions returns solution=null');
};

# ─── Hint endpoint ────────────────────────────────────────────────────────

subtest 'POST /render-api/hint returns hints array' => sub {
	$t->post_ok('/render-api/hint' => form => {
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(200)
	  ->json_has('/hints');
	my $hints = $t->tx->res->json->{hints};
	is(ref($hints), 'ARRAY', 'hints field is an array');
	is(scalar @$hints, 1, 'one hint returned');
	like($hints->[0], qr/small even number/, 'hint body contains expected content');
};

subtest 'POST /render-api/hint: multiple hints all returned' => sub {
	$t->post_ok('/render-api/hint' => form => {
		problemSource => $pg_multi_hints,
		problemSeed   => 1234,
	})->status_is(200);
	my $hints = $t->tx->res->json->{hints};
	is(scalar @$hints, 2, 'both hints returned');
	like($hints->[0], qr/division/, 'first hint correct');
	like($hints->[1], qr/24 divided by 2/, 'second hint correct');
};

subtest 'POST /render-api/hint: no hints → hints=[]' => sub {
	$t->post_ok('/render-api/hint' => form => {
		problemSource => $pg_bare,
		problemSeed   => 1234,
	})->status_is(200);
	my $hints = $t->tx->res->json->{hints};
	is(ref($hints), 'ARRAY', 'still an array');
	is(scalar @$hints, 0, 'empty array when no hints in problem');
};

# ─── Validation ───────────────────────────────────────────────────────────

subtest 'missing problemSource → 400' => sub {
	$t->post_ok('/render-api/hint' => form => {
		problemSeed => 1234,
	})->status_is(400);
	$t->post_ok('/render-api/solution' => form => {
		problemSeed => 1234,
	})->status_is(400);
};

subtest 'missing problemSeed → 400' => sub {
	$t->post_ok('/render-api/hint' => form => {
		problemSource => $pg_with_both,
	})->status_is(400);
	$t->post_ok('/render-api/solution' => form => {
		problemSource => $pg_with_both,
	})->status_is(400);
};

# ─── Dumb-fetch contract: no minting, no answerURL POST ───────────────────

subtest 'solution endpoint mints no JWTs' => sub {
	$t->post_ok('/render-api/solution' => form => {
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(200);
	my $json = $t->tx->res->json;
	# Response shape is { solution => "..." } only — no JWT block, no
	# session_jwt, no answer_jwt. Anything else would be a violation of
	# the dumb-fetch contract.
	my @keys = sort keys %$json;
	is_deeply(\@keys, ['solution'],
		'response carries only the solution field — no JWTs, no extras');
};

subtest 'hint endpoint mints no JWTs' => sub {
	$t->post_ok('/render-api/hint' => form => {
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(200);
	my $json = $t->tx->res->json;
	my @keys = sort keys %$json;
	is_deeply(\@keys, ['hints'],
		'response carries only the hints field — no JWTs, no extras');
};

# ─── Endpoints are independent of the main /render-api lane plumbing ─────

subtest 'endpoints work without lane dispatch (no JWT, no STRICT_JWT trip)' => sub {
	# These endpoints bypass parseRequest entirely (PTX precedent). Even
	# with STRICT_JWT on, the dumb-fetch endpoints accept raw problemSource
	# because they aren't subject to the lane dispatcher's grounded-JWT
	# requirement.
	local $ENV{STRICT_JWT} = 1;
	$t->post_ok('/render-api/solution' => form => {
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(200, 'STRICT_JWT does not block hint/solution endpoints');
};

done_testing();
