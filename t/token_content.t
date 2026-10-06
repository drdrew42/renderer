use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait.
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping token-content tests';
}

use Test::Mojo;
use Crypt::JWT qw(encode_jwt decode_jwt);
use Mojo::JSON qw(decode_json);

use lib 't/lib';
use TestHelper qw(launch_verdict stage_fixture_problems);

# ─── The token names the content (WW3-R68) ───────────────────────────────────
#
# On a token-bearing request, what is rendered and at which seed comes only from
# the token: raw problemSource, problemSourceURL, sourceFilePath, pg_hash and
# problemSeed are identical to omitting them. A signed source (a claim) renders
# and emits. A grounded token whose seed is absent or empty renders at the
# default seed and its outbound answerJWT / submissionJWT carries a warning.
#
# Loose posture: asserts on the _format=json shape (RENDERER_DEBUG_FORMAT) and
# runs STRICT_JWT unset, CONTENT_ADDRESSED on against a staged content cache.

$ENV{RENDERER_DEBUG_FORMAT} //= 1;
$ENV{problemJWTsecret}      //= 'test-problem-secret';
$ENV{webworkJWTsecret}      //= 'test-session-secret';
delete $ENV{STRICT_JWT};
delete $ENV{OPL_API_URL};
$ENV{CONTENT_ADDRESSED} = 1;

my $t           = Test::Mojo->new('Renderer');
my $render_root = $ENV{RENDER_ROOT};
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

# Capture warn-level log lines in place of printing them.
my @log;
$t->app->log->level('warn');
$t->app->log->unsubscribe('message');
$t->app->log->on(message => sub { my (undef, $level, @lines) = @_; push @log, "$level: @lines" });

# The content a token names: answer 42.
my $named = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$ans = Compute("42");
BEGIN_PGML
NAMED CONTENT: the answer is [___]{$ans}
END_PGML
BEGIN_PGML_SOLUTION
The named solution.
END_PGML_SOLUTION
ENDDOCUMENT();
PG

# The content a caller would substitute: answer 1.
my $forged = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$ans = Compute("1");
BEGIN_PGML
FORGED CONTENT: one is [___]{$ans}
END_PGML
BEGIN_PGML_SOLUTION
The forged solution.
END_PGML_SOLUTION
ENDDOCUMENT();
PG

my $NAMED_HASH = 'sha256:r68named';
stage_fixture_problems($NAMED_HASH => $named, 'sha256:r68forged' => $forged);
Renderer::ContentCache::save_path_index('test/r68/named.pg',  $NAMED_HASH);
Renderer::ContentCache::save_path_index('test/r68/forged.pg', 'sha256:r68forged');

# Every raw content field a caller could send beside a token.
my %raw_content = (
	problemSource    => $forged,
	problemSourceURL => 'http://127.0.0.1:9/forged.pg',
	sourceFilePath   => 'test/r68/forged.pg',
	pg_hash          => 'sha256:r68forged',
	problemSeed      => 777,
);

my %graded = (submitAnswers => 1, AnSwEr0001 => '1');

sub challenge_jwt {
	my (%claims) = @_;
	return encode_jwt(
		payload => {
			aud              => $ENV{SITE_HOST},
			iss              => 'https://ww3.example.edu',
			play_id          => '11111111-1111-1111-1111-111111111111',
			challenge_id     => 'sha256:abcdef',
			chain_student_id => 'cafebabe',
			shape            => 'closed',
			problems         => [ { position => 0, pg_hash => $NAMED_HASH, seed => 4242 } ],
			answer_url       => 'http://127.0.0.1:9/fake-answer-callback',
			%claims,
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

sub submission_jwt {
	my (%claims) = @_;
	return encode_jwt(
		payload => {
			aud               => $ENV{SITE_HOST},
			iss               => $ENV{SITE_HOST},
			pg_hash           => $NAMED_HASH,
			seed              => 4242,
			position          => 0,
			play_id           => '11111111-1111-1111-1111-111111111111',
			submitted_answers => { AnSwEr0001 => '1' },
			%claims,
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

sub problem_jwt {
	my (%claims) = @_;
	return encode_jwt(
		payload => {
			aud          => $ENV{SITE_HOST},
			iss          => $ENV{SITE_HOST},
			JWTanswerURL => 'http://127.0.0.1:9/fake-answer-callback',
			%claims,
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

sub typed_jwt {
	my ($typ, %claims) = @_;
	return encode_jwt(
		payload => { aud => $ENV{SITE_HOST}, typ => $typ, %claims },
		key     => $ENV{problemJWTsecret},
		alg     => 'HS256',
	);
}

# POST for the JSON envelope; returns the decoded response.
sub render_json {
	my (%form) = @_;
	$t->post_ok('/render-api', { Accept => 'application/json' }, form => \%form)->status_is(200);
	return decode_json($t->tx->res->body);
}

sub claims_of { my ($jwt) = @_; return $jwt ? decode_jwt(token => $jwt, key => $ENV{problemJWTsecret}) : {} }

# ─── Challenge lane ──────────────────────────────────────────────────────────

subtest 'challenge lane: raw content fields are inert — the claim is rendered and recorded' => sub {
	my %base    = (challengeJWT => challenge_jwt(), verdict_signed => launch_verdict(), position => 0, %graded);
	my $omitted = claims_of(render_json(%base)->{JWT}{submission});

	# Each field alone (the probe shape is problemSource alone), then all together.
	for my $case ((map { [ $_ => { $_ => $raw_content{$_} } ] } sort keys %raw_content), [ all => \%raw_content ]) {
		my ($label, $raw) = @$case;
		my $resp = render_json(%base, %$raw);
		like($resp->{renderedHTML}, qr/NAMED CONTENT/, "raw $label: renders the content the token names");
		unlike($resp->{renderedHTML}, qr/FORGED CONTENT/, "raw $label: not the raw source");

		my $sub = claims_of($resp->{JWT}{submission});
		is($sub->{pg_hash}, $NAMED_HASH, "raw $label: submissionJWT pg_hash is the claim");
		is($sub->{seed},    4242,        "raw $label: submissionJWT seed is the claim");
		is($sub->{score},   0,           "raw $label: the forged answer scores 0 against the named content");
		ok(!exists $sub->{warnings}, "raw $label: no warnings when the token names a seed");
		is_deeply(
			[ @{$sub}{qw(pg_hash seed score part_scores)} ],
			[ @{$omitted}{qw(pg_hash seed score part_scores)} ],
			"raw $label: identical to a request that omitted it"
		);
	}
};

subtest 'challenge lane: an empty seed renders at the default seed and warns' => sub {
	@log = ();
	my $resp = render_json(
		challengeJWT   => challenge_jwt(problems => [ { position => 0, pg_hash => $NAMED_HASH, seed => '' } ]),
		verdict_signed => launch_verdict(),
		position       => 0,
		%graded,
	);
	like($resp->{renderedHTML}, qr/NAMED CONTENT/, 'renders');
	my $sub = claims_of($resp->{JWT}{submission});
	is($sub->{seed}, 1234, 'submissionJWT seed is the default seed');
	is_deeply($sub->{warnings}, ['seed_defaulted'], 'submissionJWT carries the warning');
	ok((grep {/^warn: .*challenge request carries no seed/} @log), 'and it is logged');
};

# ─── Review lane ─────────────────────────────────────────────────────────────

subtest 'review lane: raw content fields are inert — the claim is replayed' => sub {
	for my $case ((map { [ $_ => { $_ => $raw_content{$_} } ] } sort keys %raw_content), [ all => \%raw_content ]) {
		my ($label, $raw) = @$case;
		my $resp = render_json(submissionJWT => submission_jwt(), %$raw);
		like($resp->{renderedHTML}, qr/NAMED CONTENT/, "raw $label: replays the content the token names");
		unlike($resp->{renderedHTML}, qr/FORGED CONTENT/, "raw $label: not the raw source");
	}
};

subtest 'review lane: an empty seed renders at the default seed and logs it' => sub {
	@log = ();
	my $resp = render_json(submissionJWT => submission_jwt(seed => ''));
	like($resp->{renderedHTML}, qr/NAMED CONTENT/, 'renders');
	ok((grep {/^warn: .*review request carries no seed/} @log), 'logged');
};

# ─── Problem lane ────────────────────────────────────────────────────────────

subtest 'problem lane: raw source beside a claimed sourceFilePath is inert' => sub {
	my $jwt  = problem_jwt(sourceFilePath => 'test/r68/named.pg', problemSeed => 4242);
	my $resp = render_json(problemJWT => $jwt, %graded, %raw_content);
	like($resp->{renderedHTML}, qr/NAMED CONTENT/, 'renders the claimed path, not the editor-preview branch');
	unlike($resp->{renderedHTML}, qr/FORGED CONTENT/, 'not the raw source');
	my $answer = claims_of($resp->{JWT}{answer});
	is($answer->{score}{result}, 0, 'answerJWT reports the named content\'s score for the forged answer');
	ok(!exists $answer->{warnings}, 'no warnings when the token names a seed');
};

subtest 'problem lane: raw fields are identical to omitting them (debug view)' => sub {
	my $jwt = problem_jwt(sourceFilePath => 'test/r68/named.pg', problemSeed => 4242);
	$t->post_ok('/render-api' => form => { problemJWT => $jwt, outputFormat => 'debug', %raw_content })
		->status_is(200);
	my $with = $t->tx->res->json->{problem};
	$t->post_ok('/render-api' => form => { problemJWT => $jwt, outputFormat => 'debug' })->status_is(200);
	my $without = $t->tx->res->json->{problem};
	is($with->{pg_hash},     $NAMED_HASH, 'pg_hash resolved from the claim');
	is($with->{problemSeed}, 4242,        'seed from the claim');
	is_deeply($with, $without, 'the resolved problem block matches the request without raw fields');
};

subtest 'problem lane: a signed problemSource claim renders and emits' => sub {
	my $resp = render_json(problemJWT => problem_jwt(problemSource => $forged, problemSeed => 4242), %graded);
	like($resp->{renderedHTML}, qr/FORGED CONTENT/, 'the claimed source renders');
	is(claims_of($resp->{JWT}{answer})->{score}{result}, 1, 'and the answerJWT reports its score');
};

subtest 'problem lane: an absent or empty seed renders at the default seed and warns' => sub {
	for my $case ([ absent => () ], [ empty => (problemSeed => '') ]) {
		my ($label, @seed) = @$case;
		@log = ();
		my $resp =
			render_json(problemJWT => problem_jwt(problemSource => $named, @seed), %graded, problemSeed => 777);
		my $answer = claims_of($resp->{JWT}{answer});
		like($resp->{renderedHTML}, qr/NAMED CONTENT/, "$label seed: renders (a raw seed does not fill it)");
		is_deeply($answer->{warnings}, ['seed_defaulted'], "$label seed: answerJWT carries the warning");
		ok((grep {/^warn: .*problem request carries no seed/} @log), "$label seed: logged");
	}

	$t->post_ok('/render-api' => form =>
			{ problemJWT => problem_jwt(problemSource => $named), outputFormat => 'debug', problemSeed => 777 })
		->status_is(200)->json_is('/problem/problemSeed' => 1234, 'the default seed, not the raw one');
};

# ─── Ungrounded lane keeps raw source ────────────────────────────────────────

subtest 'ungrounded lane: raw source and seed are honored (STRICT_JWT=0)' => sub {
	my $resp = render_json(problemSource => $forged, problemSeed => 777);
	like($resp->{renderedHTML}, qr/FORGED CONTENT/, 'the raw source renders');
};

# ─── Content-fetch lane ──────────────────────────────────────────────────────

subtest 'content-fetch lane: raw content fields are inert' => sub {
	my $jwt = typed_jwt('solution', problemSource => $named, problemSeed => 4242);
	$t->post_ok('/render-api/solution' => form => { problemJWT => $jwt, %raw_content })->status_is(200);
	like($t->tx->res->json->{message}, qr/named solution/, 'the claimed source\'s solution');

	$t->post_ok('/render-api/solution' => form =>
			{ problemJWT => typed_jwt('solution', problemSeed => 4242), %raw_content })
		->status_is(400, 'a token naming no source does not fall back to the raw one');

	$t->post_ok('/render-api/solution' => form =>
			{ problemJWT => typed_jwt('solution', problemSource => $named), problemSeed => 777 })
		->status_is(200, 'a token naming no seed renders')
		->json_is('/warnings' => ['seed_defaulted'], 'at the default seed, not the raw one');
};

done_testing;
