use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping integrator settings tests';
}

# Integrator settings — baseURL, formURL / formAction, extra_header_text,
# noCache, hideElements — land from a token claim or a peer body and are stripped from raw
# input on every other lane. answers_submitted, PG's grader argument, is
# stripped from every source (WW3-R69).
#
# Loose posture: STRICT_JWT is unset so the ungrounded lane is admitted.

use Test::Mojo;
use Crypt::JWT qw(encode_jwt);
use Crypt::Ed25519;
use MIME::Base64 qw(encode_base64);
use Mojo::JSON   qw(encode_json);
use Mojo::Parameters;

use lib 't/lib';
use TestHelper qw(launch_verdict stage_fixture_problems);

my ($peer_pub, $peer_sec) = Crypt::Ed25519::generate_keypair();

$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';
$ENV{SITE_HOST}        //= 'https://test.example.com';
$ENV{RENDERER_PEERS} = encode_json([ { name => 'test-editor', public_key => encode_base64($peer_pub, '') } ]);

delete $ENV{STRICT_JWT};
delete $ENV{OPL_API_URL};

my $t           = Test::Mojo->new('Renderer');
my $render_root = $ENV{RENDER_ROOT};
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

# The content-cache bypass flag ParseRequest hands SourceResolver.
my $no_cache;
$t->app->hook(after_dispatch => sub { $no_cache = shift->stash('_no_cache') });

# ─── Helpers ────────────────────────────────────────────────────────────────

my $pg_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$ans = Compute("42");
BEGIN_PGML
What is the answer? [___]{$ans}
END_PGML
ENDDOCUMENT();
PG

# The challenge and review lanes name their problem by pg_hash; the content
# cache holds the fixture under each.
$ENV{CONTENT_ADDRESSED} = 1;
stage_fixture_problems('sha256:p0' => $pg_source, 'sha256:rev' => $pg_source);

sub problem_jwt {
	my (%claims) = @_;
	return encode_jwt(
		payload => {
			aud           => $ENV{SITE_HOST},
			iss           => $ENV{SITE_HOST},
			problemSource => $pg_source,
			problemSeed   => 1234,
			%claims
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

sub challenge_jwt {
	my (%claims) = @_;
	return encode_jwt(
		payload => {
			aud              => $ENV{SITE_HOST},
			iss              => 'https://ww3.example.edu',
			version          => '1',
			play_id          => '11111111-1111-1111-1111-111111111111',
			challenge_id     => 'sha256:abcdef',
			assignment_id    => '22222222-2222-2222-2222-222222222222',
			chain_student_id => 'cafebabe',
			shape            => 'closed',
			problems         => [ { position => 0, pg_hash => 'sha256:p0', seed => 4242 } ],
			mode             => {
				next_available => [ { name => 'position_in_pool' } ],
				is_done        => [ { name => 'student_finalized' } ],
				selection      => 'student_picks',
			},
			render_permissions => { isInstructor => 0, showCorrectAnswers => 0 },
			answer_url         => 'http://127.0.0.1:9999/fake-answer-callback',
			%claims,
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

sub submission_jwt {
	return encode_jwt(
		payload => {
			aud               => $ENV{SITE_HOST},
			iss               => $ENV{SITE_HOST},
			pg_hash           => 'sha256:rev',
			seed              => 4242,
			position          => 0,
			play_id           => '11111111-1111-1111-1111-111111111111',
			submitted_answers => { AnSwEr0001 => '42' },
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

sub peer_post {
	my (%fields)  = @_;
	my $body      = Mojo::Parameters->new(%fields)->to_string;
	my $ts        = time;
	my $canonical = "POST\n/render-api\n$ts\n$body";
	utf8::encode($canonical);
	my $sig = Crypt::Ed25519::sign($canonical, $peer_pub, $peer_sec);
	return $t->post_ok(
		'/render-api',
		{
			'Content-Type'     => 'application/x-www-form-urlencoded',
			'X-Peer-Name'      => 'test-editor',
			'X-Peer-Timestamp' => $ts,
			'X-Peer-Signature' => encode_base64($sig, ''),
		},
		$body
	)->status_is(200);
}

sub form_post {
	my (%fields) = @_;
	return $t->post_ok('/render-api' => form => { outputFormat => 'default', %fields })->status_is(200);
}

my %lane = (
	problem   => sub { (problemJWT => problem_jwt()) },
	challenge => sub { (
		challengeJWT   => challenge_jwt(),
		verdict_signed => launch_verdict(),
		position       => 0,
	) },
	review     => sub { (submissionJWT => submission_jwt()) },
	ungrounded => sub { (problemSource => $pg_source, problemSeed => 1234) },
);

my $evil = 'https://example.invalid';
my %raw  = (
	baseURL           => "$evil/",
	formURL           => "$evil/post",
	extra_header_text => '<script>/*probe*/</script>',
	noCache           => 1,
);

sub score_of { ($t->tx->res->body =~ /<input[^>]*name="problem-result-score"[^>]*value="([^"]*)"/)[0] }

# ─── Raw input is inert on every non-peer lane ─────────────────────────────

for my $name (sort keys %lane) {
	subtest "$name lane: raw integrator settings are inert" => sub {
		form_post($lane{$name}->(), %raw);
		$t->content_unlike(qr{<base href="\Q$evil\E}, 'raw baseURL does not reach <base href>');
		$t->content_unlike(qr{action="\Q$evil\E},     'raw formURL does not reach the form action');
		$t->content_unlike(qr{/\*probe\*/},           'raw extra_header_text does not reach <head>');
		is($no_cache, 0, 'raw noCache does not bypass the content cache');

		form_post($lane{$name}->(), formAction => "$evil/post");
		$t->content_unlike(qr{action="\Q$evil\E}, 'raw formAction does not reach the form action');

		form_post($lane{$name}->(), formAction => "$evil/post", formURL => "$evil/other");
		$t->content_unlike(qr{action="\Q$evil\E},
			'raw formAction alongside formURL does not reach the form action');
	};
}

# ─── Claim and peer values land ────────────────────────────────────────────

subtest 'problem lane: integrator claims land' => sub {
	form_post(problemJWT => problem_jwt(%raw));
	$t->content_like(qr{<base href="\Q$evil\E/"},      'baseURL claim sets <base href>');
	$t->content_like(qr{action="\Q$evil\E/post"},      'formURL claim sets the form action');
	$t->content_like(qr{<script>/\*probe\*/</script>}, 'extra_header_text claim reaches <head>');
	is($no_cache, 1, 'noCache claim bypasses the content cache');
};

subtest 'peer lane: integrator settings in the signed body land' => sub {
	peer_post(problemSource => $pg_source, problemSeed => 1234, outputFormat => 'default', %raw);
	$t->content_like(qr{<base href="\Q$evil\E/"},      'baseURL sets <base href>');
	$t->content_like(qr{action="\Q$evil\E/post"},      'formURL sets the form action');
	$t->content_like(qr{<script>/\*probe\*/</script>}, 'extra_header_text reaches <head>');
	is($no_cache, 1, 'noCache bypasses the content cache');

	peer_post(
		problemSource => $pg_source,
		problemSeed   => 1234,
		outputFormat  => 'default',
		formAction    => "$evil/peer"
	);
	$t->content_like(qr{action="\Q$evil\E/peer"}, 'formAction is renamed to formURL and sets the form action');
};

# ─── hideElements: claim-only on every non-peer lane ───────────────────────

my $hide_probe = qr{<style>[^<]*\.hide-probe[^<]*display:\s*none};
my @hide       = (hideElements => [ '.hide-probe', '.hide-probe-2' ]);

for my $name (sort keys %lane) {
	subtest "$name lane: raw hideElements is inert" => sub {
		form_post($lane{$name}->(), @hide);
		$t->content_unlike($hide_probe, 'repeated raw hideElements keys do not reach the hide-style block');
	};
}

subtest 'hideElements: claim and peer values land' => sub {
	form_post(problemJWT => problem_jwt(@hide));
	$t->content_like($hide_probe, 'problem-lane claim');

	form_post(
		challengeJWT   => challenge_jwt(@hide),
		verdict_signed => launch_verdict(),
		position       => 0,
	);
	$t->content_like($hide_probe, 'challenge-lane claim');

	peer_post(problemSource => $pg_source, problemSeed => 1234, outputFormat => 'default', @hide);
	$t->content_like($hide_probe, 'peer body');
};

# ─── answers_submitted is stripped from every source ───────────────────────

my %graded = (submitAnswers => 1, showScoreSummary => 1, AnSwEr0001 => '42', answers_submitted => 0);

subtest 'answers_submitted: raw value cannot zero a correct submission' => sub {
	form_post(problemJWT => problem_jwt(), %graded);
	is(score_of(), 1, 'problem lane grades the correct answer 1');

	form_post(problemSource => $pg_source, problemSeed => 1234, %graded);
	is(score_of(), 1, 'ungrounded lane grades the correct answer 1');
};

subtest 'answers_submitted: peer and claim values are stripped too' => sub {
	peer_post(problemSource => $pg_source, problemSeed => 1234, outputFormat => 'default', %graded);
	is(score_of(), 1, 'peer body value does not reach the grader');

	form_post(
		problemJWT       => problem_jwt(answers_submitted => 0),
		submitAnswers    => 1,
		showScoreSummary => 1,
		AnSwEr0001       => '42'
	);
	is(score_of(), 1, 'claim value does not reach the grader');
};

done_testing();
