use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait.
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping seed-rule tests';
}

use Test::Mojo;
use Crypt::Ed25519;
use Crypt::JWT   qw(encode_jwt decode_jwt);
use MIME::Base64 qw(encode_base64);
use Mojo::JSON   qw(decode_json encode_json);
use Mojo::Parameters;

use lib 't/lib';
use TestHelper qw(launch_verdict stage_fixture_problems);

# ─── One seed rule on every lane (WW3-R73) ───────────────────────────────────
#
# A request whose seed is absent or empty renders the variant seed 1234
# renders, logs it, and carries a seed_defaulted warning. A present seed that
# is not a non-negative integer is a 400 on every lane.
#
# Loose posture: asserts on the _format=json shape (RENDERER_DEBUG_FORMAT),
# runs STRICT_JWT unset for the ungrounded lane, and CONTENT_ADDRESSED on
# against a staged content cache for the challenge and review lanes.

my ($peer_pub, $peer_sec) = Crypt::Ed25519::generate_keypair();

$ENV{RENDERER_DEBUG_FORMAT} //= 1;
$ENV{problemJWTsecret}      //= 'test-problem-secret';
$ENV{webworkJWTsecret}      //= 'test-session-secret';
$ENV{RENDERER_PEERS} = encode_json([ { name => 'test-editor', public_key => encode_base64($peer_pub, '') } ]);
delete $ENV{STRICT_JWT};
delete $ENV{OPL_API_URL};
$ENV{CONTENT_ADDRESSED} = 1;

my $t = Test::Mojo->new('Renderer');
$t->ua->on(start => sub { my (undef, $tx) = @_; $tx->req->headers->accept('application/json') });

my $render_root = $ENV{RENDER_ROOT};
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

my @log;
$t->app->log->level('warn');
$t->app->log->unsubscribe('message');
$t->app->log->on(message => sub { my (undef, $level, @lines) = @_; push @log, "$level: @lines" });

# The variant shows in the statement, the hint, the solution and the answer.
my $pg = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$v = random(1, 100000, 1);
BEGIN_PGML
VALUE [$v] [___]{Compute($v)}
END_PGML
BEGIN_PGML_HINT
HINTVAL [$v]
END_PGML_HINT
BEGIN_PGML_SOLUTION
SOLVAL [$v]
END_PGML_SOLUTION
ENDDOCUMENT();
PG

my $HASH = 'sha256:r73seeded';
stage_fixture_problems($HASH => $pg);

my @MALFORMED = ('abc', '-3', '12.5');

sub jwt {
	my (%claims) = @_;
	return encode_jwt(payload => { aud => $ENV{SITE_HOST}, %claims }, key => $ENV{problemJWTsecret}, alg => 'HS256');
}

sub seed_claim { my ($label) = @_; return $label eq 'absent' ? () : (problemSeed => $label eq 'empty' ? '' : $label) }

sub value_of { my ($html) = @_; return ($html // '') =~ /VALUE (\d+)/ ? $1 : undef }

# ─── Content-fetch ───────────────────────────────────────────────────────────

sub fetch {
	my ($typ, @seed) = @_;
	$t->post_ok("/render-api/$typ" => form => { problemJWT => jwt(typ => $typ, problemSource => $pg, @seed) });
	return ($t->tx->res->code, $t->tx->res->json);
}

for my $typ (qw(solution hint answer)) {
	subtest "content-fetch $typ: absent or empty seed is the seed-1234 variant and warns" => sub {
		my ($code, $at_default) = fetch($typ, problemSeed => 1234);
		is($code, 200, 'seed 1234 renders');
		ok(!exists $at_default->{warnings}, 'a named seed carries no warnings');

		my (undef, $other) = fetch($typ, problemSeed => 99);
		isnt(encode_json($other), encode_json($at_default), 'the fixture varies with the seed');

		for my $label (qw(absent empty)) {
			@log = ();
			my ($code, $json) = fetch($typ, seed_claim($label));
			is($code, 200, "$label seed: 200");
			is_deeply($json->{warnings}, ['seed_defaulted'], "$label seed: warnings carries seed_defaulted");
			my %payload = %$json;
			delete $payload{warnings};
			is_deeply(\%payload, $at_default, "$label seed: the same body as seed 1234");
			ok((grep {/^warn: .*content_fetch request carries no seed/} @log), "$label seed: logged");
		}
	};
}

subtest 'content-fetch: a malformed seed is a 400' => sub {
	for my $seed (@MALFORMED) {
		my ($code, $json) = fetch('solution', problemSeed => $seed);
		is($code, 400, "seed '$seed': 400");
		like($json->{message}, qr/positive integer for the random seed/, "seed '$seed': says why");
	}
};

# ─── /render-api lanes ───────────────────────────────────────────────────────

sub render {
	my (%form) = @_;
	$t->post_ok('/render-api', form => \%form);
	return ($t->tx->res->code, $t->tx->res->json);
}

subtest 'ungrounded lane: absent or empty seed renders the seed-1234 variant' => sub {
	my (undef, $at_default) = render(problemSource => $pg, problemSeed => 1234);
	my (undef, $other)      = render(problemSource => $pg, problemSeed => 99);
	ok(defined value_of($at_default->{renderedHTML}), 'seed 1234 renders');
	isnt(
		value_of($other->{renderedHTML}),
		value_of($at_default->{renderedHTML}),
		'the fixture varies with the seed'
	);

	for my $label (qw(absent empty)) {
		@log = ();
		my ($code, $json) = render(problemSource => $pg, seed_claim($label));
		is($code, 200, "$label seed: 200");
		is(
			value_of($json->{renderedHTML}),
			value_of($at_default->{renderedHTML}),
			"$label seed: the seed-1234 variant"
		);
		ok((grep {/^warn: .*ungrounded request carries no seed/} @log), "$label seed: logged");
	}

	for my $seed (@MALFORMED) {
		my ($code) = render(problemSource => $pg, problemSeed => $seed);
		is($code, 400, "seed '$seed': 400");
	}
};

subtest 'problem lane: absent or empty seed renders the seed-1234 variant; malformed is 400' => sub {
	my $answer_url = 'http://127.0.0.1:9/fake-answer-callback';
	my (undef, $at_default) =
		render(problemJWT => jwt(problemSource => $pg, problemSeed => 1234, JWTanswerURL => $answer_url));
	for my $label (qw(absent empty)) {
		my ($code, $json) =
			render(problemJWT => jwt(problemSource => $pg, seed_claim($label), JWTanswerURL => $answer_url));
		is($code, 200, "$label seed: 200");
		is(
			value_of($json->{renderedHTML}),
			value_of($at_default->{renderedHTML}),
			"$label seed: the seed-1234 variant"
		);
	}
	for my $seed (@MALFORMED) {
		my ($code) = render(problemJWT => jwt(problemSource => $pg, problemSeed => $seed));
		is($code, 400, "seed '$seed': 400");
	}
};

sub challenge_jwt {
	my ($seed) = @_;
	return jwt(
		iss              => 'https://ww3.example.edu',
		play_id          => '11111111-1111-1111-1111-111111111111',
		challenge_id     => 'sha256:abcdef',
		chain_student_id => 'cafebabe',
		shape            => 'closed',
		problems         => [ { position => 0, pg_hash => $HASH, seed => $seed } ],
		answer_url       => 'http://127.0.0.1:9/fake-answer-callback',
	);
}

subtest 'challenge lane: empty seed renders the seed-1234 variant; malformed is 400' => sub {
	my %launch = (verdict_signed => launch_verdict(), position => 0);
	my (undef, $at_default) = render(challengeJWT => challenge_jwt(1234), %launch);
	my ($code, $json)       = render(challengeJWT => challenge_jwt(''),   %launch);
	is($code,                           200,                                   'empty seed: 200');
	is(value_of($json->{renderedHTML}), value_of($at_default->{renderedHTML}), 'empty seed: the seed-1234 variant');
	for my $seed (@MALFORMED) {
		my ($code) = render(challengeJWT => challenge_jwt($seed), %launch);
		is($code, 400, "seed '$seed': 400");
	}
};

sub submission_jwt {
	my ($seed) = @_;
	return jwt(
		iss               => $ENV{SITE_HOST},
		pg_hash           => $HASH,
		seed              => $seed,
		position          => 0,
		play_id           => '11111111-1111-1111-1111-111111111111',
		submitted_answers => { AnSwEr0001 => '1' },
	);
}

subtest 'review lane: empty seed renders the seed-1234 variant; malformed is 400' => sub {
	my (undef, $at_default) = render(submissionJWT => submission_jwt(1234));
	my ($code, $json)       = render(submissionJWT => submission_jwt(''));
	is($code,                           200,                                   'empty seed: 200');
	is(value_of($json->{renderedHTML}), value_of($at_default->{renderedHTML}), 'empty seed: the seed-1234 variant');
	for my $seed (@MALFORMED) {
		my ($code) = render(submissionJWT => submission_jwt($seed));
		is($code, 400, "seed '$seed': 400");
	}
};

sub peer_render {
	my (%fields)  = @_;
	my $body      = Mojo::Parameters->new(%fields, _format => 'json')->to_string;
	my $ts        = time;
	my $canonical = "POST\n/render-api\n$ts\n$body";
	utf8::encode($canonical);
	my $sig = Crypt::Ed25519::sign($canonical, $peer_pub, $peer_sec);
	$t->post_ok(
		'/render-api',
		{
			'Content-Type'     => 'application/x-www-form-urlencoded',
			'X-Peer-Name'      => 'test-editor',
			'X-Peer-Timestamp' => $ts,
			'X-Peer-Signature' => encode_base64($sig, ''),
		},
		$body
	);
	return ($t->tx->res->code, $t->tx->res->json);
}

subtest 'peer lane: absent or empty seed renders the seed-1234 variant; malformed is 400' => sub {
	my (undef, $at_default) = peer_render(problemSource => $pg, problemSeed => 1234);
	ok(defined value_of($at_default->{renderedHTML}), 'seed 1234 renders');
	for my $label (qw(absent empty)) {
		@log = ();
		my ($code, $json) = peer_render(problemSource => $pg, seed_claim($label));
		is($code, 200, "$label seed: 200");
		is(
			value_of($json->{renderedHTML}),
			value_of($at_default->{renderedHTML}),
			"$label seed: the seed-1234 variant"
		);
		ok((grep {/^warn: .*peer request carries no seed/} @log), "$label seed: logged");
	}
	for my $seed (@MALFORMED) {
		my ($code) = peer_render(problemSource => $pg, problemSeed => $seed);
		is($code, 400, "seed '$seed': 400");
	}
};

done_testing;
