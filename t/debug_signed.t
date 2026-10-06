use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping debug_signed tests';
}

use Test::Mojo;
use Crypt::Ed25519;
use Crypt::JWT   qw(encode_jwt);
use MIME::Base64 qw(encode_base64);
use Mojo::JSON   qw(encode_json);
use Mojo::Parameters;

use lib 't/lib';
use TestHelper qw(launch_verdict stage_fixture_problems);

# ─── view_problem_debugging_info is honored only when signed (WW3-R58) ──────
#
# On a problem that errors, the flag prints PG's caught error text and the
# problem's full source ("Input Read", Translator.pm), which carries the answer
# computation. It reaches the render from a signed source only:
#
#   problem lane      — the problemJWT claim (ADAPT's webwork envelope)
#   challenge, review — the reveal sidecar's `debug` grant
#   peer              — the signed body
#   ungrounded        — raw, the STRICT_JWT=0 editor posture
#
# Two fixtures: a broken problem is the witness for the dump, a working one
# with a solution is the witness for the reveal.
#
# Loose posture: STRICT_JWT is off so the ungrounded lane admits.

my ($peer_pub, $peer_sec) = Crypt::Ed25519::generate_keypair();
$ENV{RENDERER_PEERS} = encode_json([ { name => 'test-editor', public_key => encode_base64($peer_pub, '') } ]);

delete $ENV{STRICT_JWT};
delete $ENV{OPL_API_URL};
$ENV{CONTENT_ADDRESSED} = 1;

$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';

my $t           = Test::Mojo->new('Renderer');
my $render_root = $ENV{RENDER_ROOT};
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

my $broken_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
# DEBUG-SOURCE-MARKER: the answer is Compute("42")
$ans = Compute("42");
$broken = ;
ENDDOCUMENT();
PG

my $working_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$ans = Compute("42");
TEXT(beginproblem());
BEGIN_PGML
What is the answer? [___]{$ans}
END_PGML
BEGIN_PGML_SOLUTION
The canonical solution text is forty-two.
END_PGML_SOLUTION
ENDDOCUMENT();
PG

stage_fixture_problems('sha256:dbg-working' => $working_source, 'sha256:dbg-broken' => $broken_source);

my $PLAY_ID     = '11111111-1111-1111-1111-111111111111';
my $DUMP_MARK   = qr/Input Read/;                              # the source dump's header
my $SOURCE      = qr/DEBUG-SOURCE-MARKER/;                     # a line of the problem's source
my $REVEAL      = qr/canonical solution text is forty-two/;    # only present under a reveal
my %POSITION    = (working => 0,                    broken => 1);
my %HASH        = (working => 'sha256:dbg-working', broken => 'sha256:dbg-broken');
my %JSON_ACCEPT = (Accept  => 'application/json');

sub challenge_jwt {
	return encode_jwt(
		payload => {
			aud              => $ENV{SITE_HOST},
			iss              => 'https://ww3.example.edu',
			play_id          => $PLAY_ID,
			challenge_id     => 'sha256:abcdef',
			assignment_id    => '22222222-2222-2222-2222-222222222222',
			chain_student_id => 'cafebabe',
			shape            => 'closed',
			problems         => [
				{ position => 0, pg_hash => $HASH{working}, seed => 4242 },
				{ position => 1, pg_hash => $HASH{broken},  seed => 4242 },
			],
			answer_url => 'http://127.0.0.1:9999/fake-answer-callback',
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

sub submission_jwt {
	my ($which) = @_;
	return encode_jwt(
		payload => {
			aud               => $ENV{SITE_HOST},
			iss               => $ENV{SITE_HOST},
			pg_hash           => $HASH{$which},
			seed              => 4242,
			position          => $POSITION{$which},
			play_id           => $PLAY_ID,
			submitted_answers => { AnSwEr0001 => '0' },
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

# The WW3 sidecar: `grants` names what it unlocks. Pass grants => undef for a
# sidecar minted before `grants` existed, which carried showCorrectAnswers and
# showSolutions claims instead.
sub reveal_jwt {
	my (%opt) = @_;
	my %claims = (
		aud     => $ENV{SITE_HOST},
		iss     => $ENV{SITE_HOST},
		play_id => $opt{play_id} // $PLAY_ID,
		exp     => time + 300,
	);
	if (exists $opt{grants} && !defined $opt{grants}) {
		@claims{qw(showCorrectAnswers showSolutions)} = (1, 1);
	} else {
		$claims{grants} = $opt{grants};
	}
	return encode_jwt(payload => \%claims, key => $ENV{problemJWTsecret}, alg => 'HS256');
}

sub problem_jwt {
	my (%webwork) = @_;
	return encode_jwt(
		payload => {
			aud     => $ENV{SITE_HOST},
			iss     => $ENV{SITE_HOST},
			webwork => {
				JWTanswerURL  => 'http://127.0.0.1:9999/fake-answer-callback',
				problemSource => $broken_source,
				problemSeed   => 1234,
				%webwork,
			},
		},
		key      => $ENV{problemJWTsecret},
		alg      => 'HS256',
		auto_iat => 1,
	);
}

sub body { return $t->tx->res->body }

sub render_challenge {
	my ($which, %extra) = @_;
	$t->post_ok(
		'/render-api',
		{%JSON_ACCEPT},
		form => {
			challengeJWT   => challenge_jwt(),
			verdict_signed => launch_verdict(),
			position       => $POSITION{$which},
			%extra,
		}
	)->status_is(200);
	return body();
}

sub render_review {
	my ($which, %extra) = @_;
	$t->post_ok('/render-api', {%JSON_ACCEPT}, form => { submissionJWT => submission_jwt($which), %extra })
		->status_is(200);
	return body();
}

sub dumps {
	my ($out, $name) = @_;
	like($out, $DUMP_MARK, "$name: the error dump renders");
	like($out, $SOURCE,    "$name: the problem source renders");
}

sub no_dump {
	my ($out, $name) = @_;
	unlike($out, $DUMP_MARK, "$name: no error dump");
	unlike($out, $SOURCE,    "$name: no problem source");
}

# ─── Raw flag: stripped on grounded lanes ────────────────────────────────────

subtest 'Challenge lane: a raw flag does not dump' => sub {
	no_dump(render_challenge('broken', view_problem_debugging_info => 1), 'raw flag');
};

subtest 'Review lane: a raw flag does not dump' => sub {
	no_dump(render_review('broken', view_problem_debugging_info => 1), 'raw flag');
};

subtest 'Problem lane: a raw flag does not dump' => sub {
	$t->post_ok('/render-api', {%JSON_ACCEPT},
		form => { problemJWT => problem_jwt(), view_problem_debugging_info => 1 })->status_is(200);
	no_dump(body(), 'raw flag');
};

# ─── Signed sources: honored ─────────────────────────────────────────────────

subtest 'Problem lane: the claim dumps (ADAPT webwork envelope)' => sub {
	$t->post_ok('/render-api', {%JSON_ACCEPT},
		form => { problemJWT => problem_jwt(view_problem_debugging_info => 1) })->status_is(200);
	dumps(body(), 'claim');
};

subtest 'Ungrounded lane: the raw flag dumps' => sub {
	$t->post_ok('/render-api', {%JSON_ACCEPT}, form => { problemSource => $broken_source })->status_is(200);
	no_dump(body(), 'no flag');

	$t->post_ok('/render-api', {%JSON_ACCEPT},
		form => { problemSource => $broken_source, view_problem_debugging_info => 1 })->status_is(200);
	dumps(body(), 'raw flag');
};

subtest 'Peer lane: the signed body dumps' => sub {
	my $form      = Mojo::Parameters->new(problemSource => $broken_source, view_problem_debugging_info => 1)->to_string;
	my $ts        = time;
	my $canonical = "POST\n/render-api\n$ts\n$form";
	utf8::encode($canonical);
	my $sig = Crypt::Ed25519::sign($canonical, $peer_pub, $peer_sec);

	$t->post_ok(
		'/render-api',
		{
			%JSON_ACCEPT,
			'Content-Type'     => 'application/x-www-form-urlencoded',
			'X-Peer-Name'      => 'test-editor',
			'X-Peer-Timestamp' => $ts,
			'X-Peer-Signature' => encode_base64($sig, ''),
		},
		$form
	)->status_is(200);
	dumps(body(), 'signed body');
};

# ─── The sidecar's grants, per lane ──────────────────────────────────────────

my %render = (challenge => \&render_challenge, review => \&render_review);

for my $lane (qw(challenge review)) {
	my $r = $render{$lane};

	subtest "\u$lane lane: grants [debug] dumps and reveals nothing" => sub {
		my $sidecar = reveal_jwt(grants => ['debug']);
		dumps($r->('broken', revealJWT => $sidecar), 'debug grant');
		unlike($r->('working', revealJWT => $sidecar), $REVEAL, 'debug grant: no reveal');
	};

	subtest "\u$lane lane: grants [reveal] reveals and does not dump" => sub {
		my $sidecar = reveal_jwt(grants => ['reveal']);
		like($r->('working', revealJWT => $sidecar), $REVEAL, 'reveal grant: the solution renders');
		no_dump($r->('broken', revealJWT => $sidecar), 'reveal grant');
	};

	subtest "\u$lane lane: grants [reveal, debug] does both" => sub {
		my $sidecar = reveal_jwt(grants => [ 'reveal', 'debug' ]);
		like($r->('working', revealJWT => $sidecar), $REVEAL, 'both: the solution renders');
		dumps($r->('broken', revealJWT => $sidecar), 'both');
	};

	subtest "\u$lane lane: a sidecar with no grants claim is a reveal" => sub {
		my $sidecar = reveal_jwt(grants => undef);
		like($r->('working', revealJWT => $sidecar), $REVEAL, 'legacy sidecar: the solution renders');
		no_dump($r->('broken', revealJWT => $sidecar), 'legacy sidecar');
	};

	subtest "\u$lane lane: a sidecar bound to another play grants nothing" => sub {
		my $sidecar =
			reveal_jwt(grants => [ 'reveal', 'debug' ], play_id => '99999999-9999-9999-9999-999999999999');
		unlike($r->('working', revealJWT => $sidecar), $REVEAL, 'other play: no reveal');
		no_dump($r->('broken', revealJWT => $sidecar), 'other play');
	};

	subtest "\u$lane lane: an empty or unknown grants list grants nothing" => sub {
		for my $grants ([], ['peek']) {
			my $sidecar = reveal_jwt(grants => $grants);
			my $label   = '[' . join(',', @$grants) . ']';
			unlike($r->('working', revealJWT => $sidecar), $REVEAL, "$label: no reveal");
			no_dump($r->('broken', revealJWT => $sidecar), $label);
		}
	};
}

done_testing;
