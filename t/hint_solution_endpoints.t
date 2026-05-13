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
$ENV{SITE_HOST}        //= 'test.local';
delete $ENV{STRICT_JWT};
delete $ENV{OPL_API_URL};

my $t = Test::Mojo->new('Renderer');

# Mint a problemJWT carrying a `typ` claim. Per Content Fetch Token Model,
# the /solution and /hint endpoints accept a problemJWT (same secret, same
# aud) with typ='solution' or typ='hint'.
use Renderer::Util::JWT qw(mint_jwt);
sub mint_typed {
	my ($typ, %extra) = @_;
	mint_jwt($ENV{problemJWTsecret}, {
		typ => $typ,
		aud => $ENV{SITE_HOST},
		%extra,
	});
}
my $jwt_solution = mint_typed('solution');
my $jwt_hint     = mint_typed('hint');

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
		problemJWT    => $jwt_solution,
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
		problemJWT    => $jwt_solution,
		problemSource => $pg_hints_only,
		problemSeed   => 1234,
	})->status_is(200);
	is($t->tx->res->json->{solution}, undef,
		'problem with no solution returns solution=null');
};

subtest 'POST /render-api/solution: bare problem → solution=null' => sub {
	$t->post_ok('/render-api/solution' => form => {
		problemJWT    => $jwt_solution,
		problemSource => $pg_bare,
		problemSeed   => 1234,
	})->status_is(200);
	is($t->tx->res->json->{solution}, undef,
		'problem with neither hints nor solutions returns solution=null');
};

# ─── Hint endpoint ────────────────────────────────────────────────────────

subtest 'POST /render-api/hint returns hints array' => sub {
	$t->post_ok('/render-api/hint' => form => {
		problemJWT    => $jwt_hint,
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
		problemJWT    => $jwt_hint,
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
		problemJWT    => $jwt_hint,
		problemSource => $pg_bare,
		problemSeed   => 1234,
	})->status_is(200);
	my $hints = $t->tx->res->json->{hints};
	is(ref($hints), 'ARRAY', 'still an array');
	is(scalar @$hints, 0, 'empty array when no hints in problem');
};

# ─── Token gate ───────────────────────────────────────────────────────────

subtest 'missing problemJWT → 401' => sub {
	$t->post_ok('/render-api/solution' => form => {
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(401);
	$t->post_ok('/render-api/hint' => form => {
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(401);
};

subtest 'wrong typ → 401 (hint token at /solution and vice versa)' => sub {
	$t->post_ok('/render-api/solution' => form => {
		problemJWT    => $jwt_hint,
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(401);
	$t->post_ok('/render-api/hint' => form => {
		problemJWT    => $jwt_solution,
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(401);
};

subtest 'untyped problemJWT (regular /render-api token) → 401' => sub {
	my $jwt_no_typ = mint_jwt($ENV{problemJWTsecret}, {
		aud => $ENV{SITE_HOST},
		# No typ claim — same shape as a regular /render-api problemJWT.
	});
	$t->post_ok('/render-api/solution' => form => {
		problemJWT    => $jwt_no_typ,
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(401);
};

subtest 'wrong signing secret → 401' => sub {
	my $jwt_bad = mint_jwt('not-the-real-secret', {
		typ => 'solution',
		aud => $ENV{SITE_HOST},
	});
	$t->post_ok('/render-api/solution' => form => {
		problemJWT    => $jwt_bad,
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(401);
};

subtest 'wrong aud → 401' => sub {
	my $jwt_bad_aud = mint_jwt($ENV{problemJWTsecret}, {
		typ => 'solution',
		aud => 'other.example.com',
	});
	$t->post_ok('/render-api/solution' => form => {
		problemJWT    => $jwt_bad_aud,
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(401);
};

# ─── Body validation (assumes token passes) ───────────────────────────────

subtest 'missing problemSource → 400' => sub {
	$t->post_ok('/render-api/hint' => form => {
		problemJWT  => $jwt_hint,
		problemSeed => 1234,
	})->status_is(400);
	$t->post_ok('/render-api/solution' => form => {
		problemJWT  => $jwt_solution,
		problemSeed => 1234,
	})->status_is(400);
};

subtest 'missing problemSeed → 400' => sub {
	$t->post_ok('/render-api/hint' => form => {
		problemJWT    => $jwt_hint,
		problemSource => $pg_with_both,
	})->status_is(400);
	$t->post_ok('/render-api/solution' => form => {
		problemJWT    => $jwt_solution,
		problemSource => $pg_with_both,
	})->status_is(400);
};

# ─── Dumb-fetch contract: no minting, no answerURL POST ───────────────────

subtest 'solution endpoint mints no JWTs' => sub {
	$t->post_ok('/render-api/solution' => form => {
		problemJWT    => $jwt_solution,
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
		problemJWT    => $jwt_hint,
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(200);
	my $json = $t->tx->res->json;
	my @keys = sort keys %$json;
	is_deeply(\@keys, ['hints'],
		'response carries only the hints field — no JWTs, no extras');
};

# ─── Endpoints bypass /render-api lane plumbing ──────────────────────────

subtest 'typ at top level, problemSource/seed inside webwork envelope' => sub {
	# LibreTexts-shaped mint: typ as a sibling of aud/iss, problem-detail
	# claims inside the `webwork` envelope. Controller should accept typ
	# from the outer claims (before unwrap) and pull source/seed from the
	# inner envelope (preferred over form params).
	my $jwt = mint_jwt($ENV{problemJWTsecret}, {
		typ     => 'solution',
		aud     => $ENV{SITE_HOST},
		webwork => {
			problemSource => $pg_with_both,
			problemSeed   => 1234,
		},
	});
	$t->post_ok('/render-api/solution' => form => { problemJWT => $jwt })
		->status_is(200);
	like($t->tx->res->json->{solution}, qr/42/,
		'source+seed from webwork claims rendered without form params');
};

subtest 'typ inside webwork envelope also accepted' => sub {
	# Some mints put typ inside the envelope alongside problem detail.
	# Either placement should work.
	my $jwt = mint_jwt($ENV{problemJWTsecret}, {
		aud     => $ENV{SITE_HOST},
		webwork => {
			typ           => 'solution',
			problemSource => $pg_with_both,
			problemSeed   => 1234,
		},
	});
	$t->post_ok('/render-api/solution' => form => { problemJWT => $jwt })
		->status_is(200);
};

subtest 'claims win over form params for source+seed' => sub {
	# When both are present, the JWT-bound source+seed take precedence —
	# a typed token can only fetch what it was minted for.
	my $jwt = mint_jwt($ENV{problemJWTsecret}, {
		typ     => 'solution',
		aud     => $ENV{SITE_HOST},
		webwork => {
			problemSource => $pg_with_both,
			problemSeed   => 1234,
		},
	});
	$t->post_ok('/render-api/solution' => form => {
		problemJWT    => $jwt,
		problemSource => $pg_bare,    # would render nothing — claim wins
		problemSeed   => 9999,
	})->status_is(200);
	like($t->tx->res->json->{solution}, qr/42/,
		'rendered the claim-bound source, not the form-data override');
};

subtest 'endpoints bypass parseRequest (STRICT_JWT does not apply)' => sub {
	# The content-fetch endpoints have their own gate (typed problemJWT) and
	# do not flow through parseRequest. STRICT_JWT (which governs the main
	# /render-api lane's grounded-JWT requirement) has no effect here.
	local $ENV{STRICT_JWT} = 1;
	$t->post_ok('/render-api/solution' => form => {
		problemJWT    => $jwt_solution,
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(200, 'STRICT_JWT does not block content-fetch endpoints');
};

done_testing();
