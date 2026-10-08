use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all =>
		'Future::AsyncAwait not available (Docker-only) — skipping show_correct_answers_retired tests';
}

use Test::Mojo;
use Crypt::Ed25519;
use Crypt::JWT   qw(encode_jwt);
use MIME::Base64 qw(encode_base64);
use Mojo::JSON   qw(encode_json);
use Mojo::Parameters;

use lib 't/lib';
use TestHelper qw(launch_verdict stage_fixture_problems);

# ─── showCorrectAnswers and its button are retired (WW3-R67) ─────────────────
#
# Answers reach a render from two sources only: a trusted isInstructor and a
# verified reveal sidecar. `showCorrectAnswers` — raw, as a token claim, as a
# session claim, or in a signed peer body — and `showCorrectAnswersButton` are
# accepted and ignored on every lane: the render is byte-identical to the same
# request without them, and no lane draws a "Show Correct Answers" button.
#
# Each case renders a wrong submit twice under the same lane and mode, once
# with the retired key and once without. The tokens differ in length when the
# key rides in one (a claim, a self-mint that wraps the raw params), so the
# comparison drops JWTs from both bodies; any remaining length delta is reveal
# content. The no-stakes cases and the claim carriers revealed before WW3-R67.
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

my $pg_source = <<'PG';
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

stage_fixture_problems('sha256:scaret-p0' => $pg_source);

my $PLAY_ID     = '11111111-1111-1111-1111-111111111111';
my $ANSWER_MARK = qr/correct_ans|Correct Answer\b/;         # the answerJWT field, or the feedback popover header
my $BUTTON_MARK = qr/Show Correct Answers/;
my %JSON_ACCEPT = (Accept        => 'application/json');
my %WRONG       = (submitAnswers => 1, AnSwEr0001 => '0');

sub problem_jwt {
	my (%claims) = @_;
	return encode_jwt(
		payload => {
			aud           => $ENV{SITE_HOST},
			iss           => $ENV{SITE_HOST},
			JWTanswerURL  => 'http://127.0.0.1:9999/fake-answer-callback',
			problemSource => $pg_source,
			problemSeed   => 1234,
			%claims,
		},
		key      => $ENV{problemJWTsecret},
		alg      => 'HS256',
		auto_iat => 1,
	);
}

sub challenge_jwt {
	my (%claims) = @_;
	return encode_jwt(
		payload => {
			aud              => $ENV{SITE_HOST},
			iss              => 'https://ww3.example.edu',
			play_id          => $PLAY_ID,
			challenge_id     => 'sha256:abcdef',
			assignment_id    => '22222222-2222-2222-2222-222222222222',
			chain_student_id => 'cafebabe',
			shape            => 'closed',
			problems         => [ { position => 0, pg_hash => 'sha256:scaret-p0', seed => 4242 } ],
			answer_url       => 'http://127.0.0.1:9999/fake-answer-callback',
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
			pg_hash           => 'sha256:scaret-p0',
			seed              => 4242,
			position          => 0,
			play_id           => $PLAY_ID,
			submitted_answers => { AnSwEr0001 => '0' },
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

sub session_jwt {
	my (%claims) = @_;
	return encode_jwt(
		payload => { iss => $ENV{SITE_HOST}, problemJWT => problem_jwt(renderMode => 'no-stakes'), %claims },
		key     => $ENV{webworkJWTsecret},
		alg     => 'HS256',
	);
}

sub post_form {
	my (%form) = @_;
	$t->post_ok('/render-api', {%JSON_ACCEPT}, form => \%form)->status_is(200);
	return $t->tx->res->body;
}

sub post_peer {
	my (%form)    = @_;
	my $body      = Mojo::Parameters->new(%form)->to_string;
	my $ts        = time;
	my $canonical = "POST\n/render-api\n$ts\n$body";
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
		$body
	)->status_is(200);
	return $t->tx->res->body;
}

# A JWS has three dot-separated segments, the self-mint's JWE five.
sub without_tokens { return $_[0] =~ s/eyJ[\w-]+(?:\.[\w-]*)+//gr }

sub reveals_nothing {
	my ($name, $baseline, $with) = @_;
	subtest $name => sub {
		my $base = without_tokens($baseline->());
		my $out  = without_tokens($with->());
		unlike($out, $ANSWER_MARK, 'no correct answer');
		unlike($out, $BUTTON_MARK, 'no Show Correct Answers button');
		is(length($out), length($base), 'byte-length identical to the request without it, tokens aside');
	};
}

# ─── Raw form field, every lane ──────────────────────────────────────────────

reveals_nothing(
	'Problem lane, custom: raw showCorrectAnswers=1',
	sub { post_form(problemJWT => problem_jwt(), %WRONG) },
	sub { post_form(problemJWT => problem_jwt(), %WRONG, showCorrectAnswers => 1) },
);

reveals_nothing(
	'Problem lane, no-stakes claim: raw showCorrectAnswers=1',
	sub { post_form(problemJWT => problem_jwt(renderMode => 'no-stakes'), %WRONG) },
	sub { post_form(problemJWT => problem_jwt(renderMode => 'no-stakes'), %WRONG, showCorrectAnswers => 1) },
);

reveals_nothing(
	'Challenge lane: raw showCorrectAnswers=1',
	sub { post_form(challengeJWT => challenge_jwt(), verdict_signed => launch_verdict(), position => 0, %WRONG) },
	sub {
		post_form(
			challengeJWT   => challenge_jwt(),
			verdict_signed => launch_verdict(),
			position       => 0,
			%WRONG,
			showCorrectAnswers => 1
		);
	},
);

reveals_nothing(
	'Review lane: raw showCorrectAnswers=1',
	sub { post_form(submissionJWT => submission_jwt()) },
	sub { post_form(submissionJWT => submission_jwt(), showCorrectAnswers => 1) },
);

reveals_nothing(
	'Ungrounded lane, no-stakes: raw showCorrectAnswers=1',
	sub { post_form(problemSource => $pg_source, renderMode => 'no-stakes', %WRONG) },
	sub { post_form(problemSource => $pg_source, renderMode => 'no-stakes', %WRONG, showCorrectAnswers => 1) },
);

# ─── Signed carriers ─────────────────────────────────────────────────────────

reveals_nothing(
	'Problem lane: a showCorrectAnswers claim',
	sub { post_form(problemJWT => problem_jwt(renderMode => 'no-stakes'),                          %WRONG) },
	sub { post_form(problemJWT => problem_jwt(renderMode => 'no-stakes', showCorrectAnswers => 1), %WRONG) },
);

reveals_nothing(
	'Challenge lane: render_permissions.showCorrectAnswers',
	sub {
		post_form(
			challengeJWT   => challenge_jwt(render_permissions => { isInstructor => 0 }),
			verdict_signed => launch_verdict(),
			position       => 0,
			%WRONG
		);
	},
	sub {
		post_form(
			challengeJWT   => challenge_jwt(render_permissions => { isInstructor => 0, showCorrectAnswers => 1 }),
			verdict_signed => launch_verdict(),
			position       => 0,
			%WRONG
		);
	},
);

reveals_nothing(
	'Session lane: a showCorrectAnswers session claim',
	sub { post_form(sessionJWT => session_jwt(),                        %WRONG) },
	sub { post_form(sessionJWT => session_jwt(showCorrectAnswers => 1), %WRONG) },
);

reveals_nothing(
	'Peer lane: showCorrectAnswers in the signed body',
	sub { post_peer(problemSource => $pg_source, %WRONG) },
	sub { post_peer(problemSource => $pg_source, %WRONG, showCorrectAnswers => 1) },
);

# ─── The button ──────────────────────────────────────────────────────────────

subtest 'No lane or mode draws the Show Correct Answers button' => sub {
	for my $mode (qw(no-stakes preview custom)) {
		unlike(post_form(problemJWT => problem_jwt(renderMode => $mode, showCorrectAnswersButton => 1)),
			$BUTTON_MARK, "problem lane, $mode claim with showCorrectAnswersButton claim");
	}
	unlike(post_form(problemJWT    => problem_jwt(isInstructor => 1)), $BUTTON_MARK, 'problem lane, instructor claim');
	unlike(post_form(problemSource => $pg_source, isInstructor => 1, showCorrectAnswersButton => 1),
		$BUTTON_MARK, 'ungrounded lane, raw instructor and button');

	# ADAPT signs showCorrectAnswersButton=0 inside its webwork envelope.
	my $adapt = encode_jwt(
		payload => {
			aud     => $ENV{SITE_HOST},
			iss     => $ENV{SITE_HOST},
			webwork => { problemSource => $pg_source, problemSeed => 1234, showCorrectAnswersButton => 0 },
		},
		key      => $ENV{problemJWTsecret},
		alg      => 'HS256',
		auto_iat => 1,
	);
	my $out = post_form(problemJWT => $adapt);
	like($out, qr/What is the answer/, 'ADAPT shape: the problem renders');
	unlike($out, $BUTTON_MARK, 'ADAPT shape: no button');
};

done_testing();
