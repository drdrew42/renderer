use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping entry_gate tests';
}

use Test::Mojo;
use Crypt::JWT qw(encode_jwt);

# NOTE: RENDERER_DEBUG_FORMAT is deliberately NOT set in this file. Several
# assertions below are precisely that the debug shapes are unreachable, and
# setting it would make them vacuous.
$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';
delete $ENV{STRICT_JWT};
delete $ENV{OPL_API_URL};

my $t           = Test::Mojo->new('Renderer');
my $render_root = $ENV{RENDER_ROOT};
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";

my $pg_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "MathObjects.pl", "PGML.pl");
Context("Numeric");
$a = Compute("42");
BEGIN_PGML
What is the answer? [_]{$a}
END_PGML
BEGIN_PGML_SOLUTION
The answer is 42.
END_PGML_SOLUTION
ENDDOCUMENT();
PG

sub problem_jwt {
	return encode_jwt(
		payload => {
			aud           => $ENV{SITE_HOST},
			iss           => $ENV{SITE_HOST},
			problemSource => $pg_source,
			problemSeed   => 1234,
		},
		alg => 'HS256',
		key => $ENV{problemJWTsecret},
	);
}

# ─── WW3-R44: the entry gate applies to every output format ───────────────
#
# The gate used to live inside an `elsif (outputFormat ne 'ptx')` arm, so
# `outputFormat=ptx` skipped it entirely and answerhashXML handed back
# correct_ans for any problem, unauthenticated, on a STRICT_JWT=1 box.

subtest 'STRICT_JWT=1: ungrounded HTML is refused' => sub {
	local $ENV{STRICT_JWT} = 1;
	$t->post_ok('/render-api' => form => { problemSource => $pg_source, problemSeed => 1234 })->status_is(401);
};

subtest 'STRICT_JWT=1: ungrounded PTX is refused too (WW3-R44)' => sub {
	local $ENV{STRICT_JWT} = 1;
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			problemSeed   => 1234,
			outputFormat  => 'ptx',
		}
	)->status_is(401);

	unlike($t->tx->res->body, qr/answerhashes/, 'no answer hash in a refused response');
	unlike($t->tx->res->body, qr/correct_ans/,  'no correct_ans in a refused response');
};

subtest 'STRICT_JWT=1: ungrounded debug format is refused as well' => sub {
	local $ENV{STRICT_JWT} = 1;
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			problemSeed   => 1234,
			outputFormat  => 'debug',
		}
	)->status_is(401);
};

subtest 'STRICT_JWT=0: ungrounded PTX still renders (editor posture intact)' => sub {
	local $ENV{STRICT_JWT} = 0;
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			problemSeed   => 1234,
			outputFormat  => 'ptx',
		}
	)->status_is(200);

	like($t->tx->res->body, qr/answerhashes/, 'PTX still produces its answer hash on a trusted-network box');
};

# ─── WW3-R45: the response shape is not negotiable ────────────────────────

subtest 'Accept: application/json does not change the shape' => sub {
	local $ENV{STRICT_JWT} = 0;
	$t->post_ok(
		'/render-api' => { Accept => 'application/json' } => form => {
			problemSource => $pg_source,
			problemSeed   => 1234,
		}
	)->status_is(200);

	like($t->tx->res->headers->content_type, qr{text/html}, 'still HTML despite an Accept: application/json header');
	unlike($t->tx->res->body, qr/^\s*\{/, 'body is not a JSON document');
};

subtest 'format=json as a form param does not change the shape' => sub {
	local $ENV{STRICT_JWT} = 0;
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			problemSeed   => 1234,
			format        => 'json',
		}
	)->status_is(200);

	like($t->tx->res->headers->content_type, qr{text/html}, 'still HTML despite format=json');
};

subtest 'outputFormat=debug is unreachable without the deployment flag' => sub {
	local $ENV{STRICT_JWT} = 0;
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			problemSeed   => 1234,
			outputFormat  => 'debug',
		}
	)->status_is(200);

	unlike($t->tx->res->body, qr/"tokens"/,     'no token block leaks');
	unlike($t->tx->res->body, qr/"inputs_ref"/, 'no resolved-input echo leaks');
	like($t->tx->res->headers->content_type, qr{text/html}, 'falls back to an ordinary HTML render');
};

# ─── WW3-R46: isInstructor is not self-declarable on a grounded request ───
#
# Measured on the homelab 2026-08-05: a student's own challengeJWT plus
# isInstructor=1 resolved to revealAll mid-play — 8,451 bytes against a
# 6,583-byte baseline, with a solution div and the canonical answer.

subtest 'grounded request: raw isInstructor=1 is stripped' => sub {
	local $ENV{STRICT_JWT} = 1;
	my $jwt = problem_jwt();

	$t->post_ok('/render-api' => form => { problemJWT => $jwt })->status_is(200);
	my $baseline = $t->tx->res->body;

	$t->post_ok('/render-api' => form => { problemJWT => $jwt, isInstructor => 1 })->status_is(200);
	my $elevated = $t->tx->res->body;

	unlike($elevated, qr/solution accordion/, 'no solution revealed by a self-declared isInstructor');
	is(length($elevated), length($baseline), 'byte-identical to the un-elevated render');
};

subtest 'mode bundles: default and review refuse the reveal, not just the button' => sub {
	# The bundle-level half of WW3-R46. Kept here rather than only in
	# render_mode.t because the bundles are only half the story: they bite
	# only when a caller opts into a mode, and WW3 sends renderMode only
	# for library preview. The challenge lane's own hard-zero is what
	# closes it for play — see Lane::Challenge.
	require Renderer::RenderMode;

	for my $mode (qw(default review)) {
		my $i = { renderMode => $mode, showCorrectAnswers => 1 };
		Renderer::RenderMode::resolve_render_mode($i);
		is($i->{showCorrectAnswers}, 0, "$mode bundle refuses a caller-supplied reveal");
	}

	for my $mode (qw(no-stakes preview)) {
		my $i = { renderMode => $mode, showCorrectAnswers => 1 };
		Renderer::RenderMode::resolve_render_mode($i);
		is($i->{showCorrectAnswers}, 1, "$mode still offers it");
	}
};

# TODO(WW3-R46) — the CHALLENGE and REVIEW lanes still have no END-TO-END guard here,
# and they are the two lanes the bug was actually measured on. The subtest
# above exercises Lane::Problem, which WW3-R41 had already hardened, so it
# passes against the pre-fix tree and proves nothing about the regression.
#
# Both lanes resolve their source through pg_hash, and unlike the challenge
# lane's own tests, passing raw problemSource does not bypass that on
# review — the request 404s with "Cannot resolve pg_hash" before any
# permission resolution happens. Writing this guard needs a content-cache
# or mocked-OPL fixture that this file does not currently stand up.
#
# Until then the evidence for the fix is the homelab measurement recorded
# in the ticket (8,451 bytes with isInstructor=1 against a 6,583-byte
# baseline, solution div plus canonical answer), which is a measurement and
# not a regression guard. Do not close R46 on the strength of this file.

subtest 'ungrounded under STRICT_JWT=0: isInstructor still honoured (VPC editor)' => sub {
	local $ENV{STRICT_JWT} = 0;
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			problemSeed   => 1234,
			isInstructor  => 1,
		}
	)->status_is(200);

	like($t->tx->res->body, qr/solution accordion/,
		'a deployment that trusts its network keeps the editor preview working');
};

done_testing();
