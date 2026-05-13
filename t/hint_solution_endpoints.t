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

# Content-fetch endpoints are JSON-only API endpoints; real callers
# (LibreTexts, ADAPT, WW3) send Accept: application/json. $c->exception
# honors content negotiation, so without this header Mojolicious falls back
# to the HTML 'exception' template — which would defeat the body-shape
# assertions below. This default mirrors production client behavior.
$t->ua->on(start => sub {
	my ($ua, $tx) = @_;
	$tx->req->headers->accept('application/json')
		unless $tx->req->headers->accept;
});

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

# Response contract: { status, message } across both success and error.
#   Success with content: status=200, message=<html>
#   Success no content:   status=200, message=""
#   Any error:            status=<code>, message=<error string>
# Consumers can rely on a single shape regardless of outcome.

subtest 'POST /render-api/solution returns solution body in message' => sub {
	$t->post_ok('/render-api/solution' => form => {
		problemJWT    => $jwt_solution,
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(200)
	  ->json_is('/status' => 200);
	my $body = $t->tx->res->json->{message};
	ok($body, 'message is non-empty');
	like($body, qr/42/, 'message contains expected solution content');
};

subtest 'POST /render-api/solution: no solution block → empty message' => sub {
	$t->post_ok('/render-api/solution' => form => {
		problemJWT    => $jwt_solution,
		problemSource => $pg_hints_only,
		problemSeed   => 1234,
	})->status_is(200)
	  ->json_is('/status'  => 200)
	  ->json_is('/message' => '');
};

subtest 'POST /render-api/solution: bare problem → empty message' => sub {
	$t->post_ok('/render-api/solution' => form => {
		problemJWT    => $jwt_solution,
		problemSource => $pg_bare,
		problemSeed   => 1234,
	})->status_is(200)
	  ->json_is('/status'  => 200)
	  ->json_is('/message' => '');
};

# ─── Hint endpoint ────────────────────────────────────────────────────────

subtest 'POST /render-api/hint returns hint body in message' => sub {
	$t->post_ok('/render-api/hint' => form => {
		problemJWT    => $jwt_hint,
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(200)
	  ->json_is('/status' => 200);
	like($t->tx->res->json->{message}, qr/small even number/,
		'message contains expected hint content');
};

subtest 'POST /render-api/hint: multiple hints concatenated' => sub {
	$t->post_ok('/render-api/hint' => form => {
		problemJWT    => $jwt_hint,
		problemSource => $pg_multi_hints,
		problemSeed   => 1234,
	})->status_is(200);
	my $message = $t->tx->res->json->{message};
	like($message, qr/division/,        'first hint present in message');
	like($message, qr/24 divided by 2/, 'second hint present in message');
};

subtest 'POST /render-api/hint: no hints → empty message' => sub {
	$t->post_ok('/render-api/hint' => form => {
		problemJWT    => $jwt_hint,
		problemSource => $pg_bare,
		problemSeed   => 1234,
	})->status_is(200)
	  ->json_is('/status'  => 200)
	  ->json_is('/message' => '');
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
	# Response shape is { status, message } only — no JWT block, no
	# session_jwt, no answer_jwt. Anything else would be a violation of
	# the dumb-fetch contract.
	my @keys = sort keys %{ $t->tx->res->json };
	is_deeply(\@keys, ['message', 'status'],
		'response carries only status+message — no JWTs, no extras');
};

subtest 'hint endpoint mints no JWTs' => sub {
	$t->post_ok('/render-api/hint' => form => {
		problemJWT    => $jwt_hint,
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(200);
	my @keys = sort keys %{ $t->tx->res->json };
	is_deeply(\@keys, ['message', 'status'],
		'response carries only status+message — no JWTs, no extras');
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
	like($t->tx->res->json->{message}, qr/42/,
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
	like($t->tx->res->json->{message}, qr/42/,
		'rendered the claim-bound source, not the form-data override');
};

subtest 'sourceFilePath claim resolves via content cache' => sub {
	# Claim binds the token to a content-cache path. Endpoint should
	# resolve through SourceResolver — no problemSource in body, no
	# problemSource claim either.
	require Renderer::ContentCache;
	my $cached_hash = 'test_hint_solution_cached_hash';
	Renderer::ContentCache::stage_problem($cached_hash, $pg_with_both);
	Renderer::ContentCache::save_path_index('test/hint_solution.pg', $cached_hash);

	local $ENV{CONTENT_ADDRESSED} = 1;

	my $jwt = mint_jwt($ENV{problemJWTsecret}, {
		typ     => 'solution',
		aud     => $ENV{SITE_HOST},
		webwork => {
			sourceFilePath => 'test/hint_solution.pg',
			problemSeed    => 1234,
		},
	});
	$t->post_ok('/render-api/solution' => form => { problemJWT => $jwt })
		->status_is(200);
	like($t->tx->res->json->{message}, qr/42/,
		'solution resolved from sourceFilePath claim via content cache');
};

subtest 'unresolvable sourceFilePath → 404' => sub {
	local $ENV{CONTENT_ADDRESSED} = 1;
	my $jwt = mint_jwt($ENV{problemJWTsecret}, {
		typ     => 'solution',
		aud     => $ENV{SITE_HOST},
		webwork => {
			sourceFilePath => 'nonexistent/path/to/problem.pg',
			problemSeed    => 1234,
		},
	});
	$t->post_ok('/render-api/solution' => form => { problemJWT => $jwt })
		->status_is(404);
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

# ─── injectedMacros wiring (regression guard for ADAPT outage) ────────────

subtest 'cache-only macro renders via injectedMacros' => sub {
	# The load-bearing fix from the ADAPT-side outage: when a problem
	# loadMacros() a custom/override macro whose source lives only in the
	# content cache (never on disk), the hint/solution path must populate
	# envir{injectedMacros} so PGloadfiles.pm resolves from memory. Without
	# this wiring the response silently degrades to message: "".
	require Renderer::ContentCache;

	my $macro_name   = 'testInjectedMacro.pl';
	my $macro_source = <<'PERL';
sub injected_test_sentinel { return "INJECTED_OK"; }
1;
PERL
	my $macro_hash = 'sha256:test_injected_macro_hash';
	Renderer::ContentCache::stage_macro($macro_hash, $macro_source);

	my $pg_with_custom_macro = <<"PG";
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl", "$macro_name");
Context("Numeric");
\$answer = Compute("1");
\$sentinel = injected_test_sentinel();
TEXT(beginproblem());
BEGIN_PGML
Trivial. [___]{\$answer}
END_PGML
BEGIN_PGML_SOLUTION
[\$sentinel]*
END_PGML_SOLUTION
ENDDOCUMENT();
PG

	my $pg_hash = 'sha256:test_problem_with_injected_macro';
	Renderer::ContentCache::stage_problem($pg_hash, $pg_with_custom_macro, [
		{ name => $macro_name, hash => $macro_hash, source_type => 'custom' },
	]);
	Renderer::ContentCache::save_path_index('test/injected_macro.pg', $pg_hash);

	local $ENV{CONTENT_ADDRESSED} = 1;

	my $jwt = mint_jwt($ENV{problemJWTsecret}, {
		typ     => 'solution',
		aud     => $ENV{SITE_HOST},
		webwork => {
			sourceFilePath => 'test/injected_macro.pg',
			problemSeed    => 1234,
		},
	});

	$t->post_ok('/render-api/solution' => form => { problemJWT => $jwt })
		->status_is(200);
	like($t->tx->res->json->{message}, qr/INJECTED_OK/,
		'cache-only macro loaded via injectedMacros — sentinel rendered into solution');
};

# ─── PG render failure surfaces as 5xx (not silent 200) ───────────────────

subtest 'PG render failure → 500 with error in message' => sub {
	# Pre-ca3336e0, a Translator-level failure (uncompilable problem,
	# loadMacros failure for a disk-missing macro) left $pg->{body_text}
	# empty, hintExists/solutionExists at 0, and the endpoint returned 200
	# with empty content — indistinguishable from "no SOLUTION block."
	# error_flag check now surfaces these as 500 with $pg->{errors}.
	my $pg_broken = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl");
this is not valid Perl ($$ %% &&;
ENDDOCUMENT();
PG

	$t->post_ok('/render-api/solution' => form => {
		problemJWT    => $jwt_solution,
		problemSource => $pg_broken,
		problemSeed   => 1234,
	})->status_is(500)
	  ->json_is('/status' => 500);
	ok($t->tx->res->json->{message}, 'error message present on 500 (not empty body)');
};

# ─── Error response shape parity with success ─────────────────────────────

subtest 'error responses follow { status, message } shape' => sub {
	# 8a7d913b unified success and failure on a single contract. Verify the
	# error half — 401 (token gate) and 400 (post-resolve body validation)
	# both carry status + message just like 200 does.
	$t->post_ok('/render-api/solution' => form => {
		problemSource => $pg_with_both,
		problemSeed   => 1234,
	})->status_is(401)
	  ->json_is('/status' => 401);
	ok($t->tx->res->json->{message}, '401 carries message field');

	$t->post_ok('/render-api/solution' => form => {
		problemJWT  => $jwt_solution,
		problemSeed => 1234,
	})->status_is(400)
	  ->json_is('/status' => 400);
	ok($t->tx->res->json->{message}, '400 carries message field');
};

done_testing();
