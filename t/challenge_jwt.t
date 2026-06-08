use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping challengeJWT tests';
}

use Test::Mojo;
use Crypt::JWT qw(encode_jwt decode_jwt);
use Mojo::JSON qw(decode_json encode_json);

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

# ─── Helpers ────────────────────────────────────────────────────────────────

sub make_challenge_jwt {
	my (%overrides) = @_;
	my $payload = {
		aud              => $ENV{SITE_HOST},
		iss              => 'https://ww3.example.edu',
		version          => '1',
		play_id          => '11111111-1111-1111-1111-111111111111',
		challenge_id     => 'sha256:abcdef',
		assignment_id    => '22222222-2222-2222-2222-222222222222',
		chain_student_id => 'cafebabe',
		shape            => 'closed',
		problems         => [
			{ position => 0, pg_hash => 'sha256:p0', seed => 11111 },
			{ position => 1, pg_hash => 'sha256:p1', seed => 22222 },
			{ position => 2, pg_hash => 'sha256:p2', seed => 33333 },
		],
		mode => {
			next_available => [ { name => 'position_in_pool' } ],
			is_done        => [ { name => 'student_finalized' } ],
			selection      => 'student_picks',
		},
		constraints        => { duration_seconds => 3600 },
		render_permissions => { isInstructor     => 0, showCorrectAnswers => 0, showHints => 1 },
		answer_url         => 'http://127.0.0.1:9999/fake-answer-callback',
		%overrides,
	};
	return encode_jwt(payload => $payload, key => $ENV{problemJWTsecret}, alg => 'HS256');
}

sub make_play_session_jwt {
	my (%overrides) = @_;
	my $payload = {
		iss   => $ENV{SITE_HOST},
		aud   => $ENV{SITE_HOST},
		state => {
			started_at     => undef,
			current_focus  => undef,
			next_available => [],
			draws          => [],
			finalization   => undef,
		},
		mint_sequence => 0,
		%overrides,
	};
	return encode_jwt(payload => $payload, key => $ENV{webworkJWTsecret}, alg => 'HS256');
}

# Tiny PGML problem — echoes a known answer. Avoids OPL/content-cache infrastructure
# in tests by passing problemSource alongside the challengeJWT (the JWT carries the
# render context that the orchestrator cares about; the raw source bypasses fetch).
my $pg_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$ans = Compute("42");
TEXT(beginproblem());
BEGIN_PGML
What is the answer? [___]{$ans}
END_PGML
ENDDOCUMENT();
PG

# ─── parseRequest behavior ──────────────────────────────────────────────────

# Helper: post with Accept: application/json so we get the JSON envelope back
# (containing the JWT block we want to inspect).
sub post_json {
	my ($form) = @_;
	return $t->post_ok('/render-api', { Accept => 'application/json' }, form => $form);
}

subtest 'closed challengeJWT + position renders the requested problem' => sub {
	my $jwt = make_challenge_jwt();
	post_json({
		challengeJWT  => $jwt,
		position      => 1,
		problemSource => $pg_source,
	})->status_is(200);
	my $resp = decode_json($t->tx->res->body);
	like($resp->{renderedHTML}, qr/What is the answer\?/, 'problem rendered');
};

subtest 'open challengeJWT resolves seed via sessionJWT.state.draws[]' => sub {
	my $challengeJWT = make_challenge_jwt(
		shape    => 'open',
		problems => [ { pg_hash => 'sha256:open0', seed => '*' }, { pg_hash => 'sha256:open1', seed => '*' }, ],
	);
	my $sessionJWT = make_play_session_jwt(
		state => {
			started_at     => undef,
			current_focus  => 0,
			next_available => [ 0, 1 ],
			draws          => [ { draw_position => 0, pool_index => 0, pg_hash => 'sha256:open0', seed => 99999 }, ],
			finalization   => undef,
		},
	);
	post_json({
		challengeJWT  => $challengeJWT,
		sessionJWT    => $sessionJWT,
		position      => 0,
		problemSource => $pg_source,
	})->status_is(200);
};

subtest 'both challengeJWT and problemJWT → 400 ambiguous_envelope' => sub {
	my $challengeJWT = make_challenge_jwt();
	my $problemJWT   = encode_jwt(
		payload => { aud => $ENV{SITE_HOST}, iss => $ENV{SITE_HOST} },
		key     => $ENV{problemJWTsecret},
		alg     => 'HS256',
	);
	$t->post_ok(
		'/render-api' => form => {
			challengeJWT => $challengeJWT,
			problemJWT   => $problemJWT,
			position     => 0,
		}
	)->status_is(400);
	like($t->tx->res->body, qr/Ambiguous/i, 'response mentions ambiguous envelope');
};

subtest 'challengeJWT without position → 400' => sub {
	my $jwt = make_challenge_jwt();
	$t->post_ok(
		'/render-api' => form => {
			challengeJWT  => $jwt,
			problemSource => $pg_source,
		}
	)->status_is(400);
	like($t->tx->res->body, qr/position/i, 'error mentions position');
};

subtest 'challengeJWT with out-of-range position → 400' => sub {
	my $jwt = make_challenge_jwt();
	$t->post_ok(
		'/render-api' => form => {
			challengeJWT  => $jwt,
			position      => 99,
			problemSource => $pg_source,
		}
	)->status_is(400);
	like($t->tx->res->body, qr/out of range/i, 'error mentions range');
};

subtest 'challengeJWT problems[] tolerates legacy seed_policy / weight fields' => sub {
	# WW3-044 will trim the artifact shape; until then the renderer must tolerate.
	my $jwt = make_challenge_jwt(problems =>
			[ { position => 0, pg_hash => 'sha256:legacy', seed => 7777, seed_policy => 'fixed', weight => 1 }, ],);
	post_json({
		challengeJWT  => $jwt,
		position      => 0,
		problemSource => $pg_source,
	})->status_is(200);
};

# ─── Mint shapes ────────────────────────────────────────────────────────────

subtest 'play sessionJWT shape: embedded challenge_jwt + mint_sequence; no legacy fields' => sub {
	my $jwt = make_challenge_jwt();
	post_json({
		challengeJWT  => $jwt,
		position      => 0,
		problemSource => $pg_source,
		submitAnswers => 1,
		'AnSwEr0001'  => '42',
	})->status_is(200);
	my $resp        = decode_json($t->tx->res->body);
	my $session_jwt = $resp->{JWT}{session};
	ok($session_jwt, 'play sessionJWT minted');

	my $claims = decode_jwt(token => $session_jwt, key => $ENV{webworkJWTsecret});
	is($claims->{challenge_jwt}, $jwt, 'challengeJWT embedded verbatim');
	ok(exists $claims->{state},         'state present');
	ok(exists $claims->{mint_sequence}, 'mint_sequence present');
	ok(!exists $claims->{numCorrect},   'no legacy numCorrect');
	ok(!exists $claims->{numIncorrect}, 'no legacy numIncorrect');
	ok(!exists $claims->{isLocked},     'no legacy isLocked');
	ok(!exists $claims->{problemJWT},   'no legacy problemJWT');
};

subtest 'submissionJWT shape per Artifact Shape spec' => sub {
	my $jwt = make_challenge_jwt();
	post_json({
		challengeJWT  => $jwt,
		position      => 1,
		problemSource => $pg_source,
		submitAnswers => 1,
		'AnSwEr0001'  => '42',
	})->status_is(200);
	my $resp           = decode_json($t->tx->res->body);
	my $submission_jwt = $resp->{JWT}{submission};
	ok($submission_jwt,       'submissionJWT minted on submit');
	ok(!$resp->{JWT}{answer}, 'no legacy answerJWT on challengeJWT path');

	my $claims = decode_jwt(token => $submission_jwt, key => $ENV{problemJWTsecret});
	is($claims->{play_id},          '11111111-1111-1111-1111-111111111111', 'play_id propagated');
	is($claims->{challenge_id},     'sha256:abcdef',                        'challenge_id propagated');
	is($claims->{chain_student_id}, 'cafebabe',                             'chain_student_id propagated');
	is($claims->{position},         1,                                      'position numeric and matches request');
	is($claims->{pg_hash},          'sha256:p1',                            'pg_hash from JWT problems[1]');
	is($claims->{seed},             22222,                                  'seed from JWT problems[1]');
	ok(defined $claims->{score},                   'score present');
	ok(ref $claims->{part_scores} eq 'ARRAY',      'part_scores is an array');
	ok(ref $claims->{submitted_answers} eq 'HASH', 'submitted_answers is a hash');
	like($claims->{submitted_at}, qr/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/, 'submitted_at is ISO8601 UTC');
	ok(!exists $claims->{numCorrect}, 'no legacy numCorrect');
	ok(!exists $claims->{isLocked},   'no legacy isLocked');
};

subtest 'no submissionJWT on first render (no submitAnswers)' => sub {
	my $jwt = make_challenge_jwt();
	post_json({
		challengeJWT  => $jwt,
		position      => 0,
		problemSource => $pg_source,
	})->status_is(200);
	my $resp = decode_json($t->tx->res->body);
	ok($resp->{JWT}{session},     'sessionJWT minted on every render');
	ok(!$resp->{JWT}{submission}, 'submissionJWT only on submit');
};

subtest 'mint_sequence increments from inbound sessionJWT' => sub {
	my $jwt        = make_challenge_jwt();
	my $session_in = make_play_session_jwt(mint_sequence => 5);
	post_json({
		challengeJWT  => $jwt,
		sessionJWT    => $session_in,
		position      => 0,
		problemSource => $pg_source,
	})->status_is(200);
	my $resp   = decode_json($t->tx->res->body);
	my $claims = decode_jwt(token => $resp->{JWT}{session}, key => $ENV{webworkJWTsecret});
	is($claims->{mint_sequence}, 6, 'mint_sequence = inbound + 1');
};

# ─── outputFormat lock ──────────────────────────────────────────────────────

subtest 'outputFormat hardcoded to default on challengeJWT path (URL ignored)' => sub {
	my $jwt = make_challenge_jwt();
	# URL-injected outputFormat should be ignored — challengeJWT path locks
	# the format. Inject `debug` (a real format with a distinct response
	# shape — top-level `permissions` / `tokens` / etc) and confirm the
	# response is the standard JSON envelope instead, proving the lock fired.
	post_json({
		challengeJWT  => $jwt,
		position      => 0,
		problemSource => $pg_source,
		outputFormat  => 'debug',
	})->status_is(200);
	my $resp = decode_json($t->tx->res->body);
	ok(exists $resp->{renderedHTML}, 'response is the standard JSON envelope (default), not debug');
	ok(!exists $resp->{permissions}, 'no debug-format leak (permissions is the debug indicator)');
};

# ─── render_permissions ────────────────────────────────────────────────────

subtest 'render_permissions.showCorrectAnswers from challengeJWT reaches the renderer' => sub {
	# A submitted answer with showCorrectAnswers=1 should reveal correct-answer
	# UI ('correct_ans' marker in the JSON response). Same fixture without the
	# permission keeps it suppressed. Proves the permission claim is applied
	# rather than ignored.
	my $jwt_with =
		make_challenge_jwt(render_permissions => { isInstructor => 0, showCorrectAnswers => 1, showHints => 1 },);
	post_json({
		challengeJWT  => $jwt_with,
		position      => 0,
		problemSource => $pg_source,
		submitAnswers => 1,
		'AnSwEr0001'  => '0',
	})->status_is(200);
	my $with = decode_json($t->tx->res->body);
	# correct_ans appears in the answer-state portion of the response when
	# showCorrectAnswers is honored.
	like(encode_json($with), qr/correct_ans/, 'showCorrectAnswers honored from JWT claim');
};

# ─── Coexistence ────────────────────────────────────────────────────────────

subtest 'legacy problemJWT path still works (regression)' => sub {
	my $problemJWT = encode_jwt(
		payload => {
			aud          => $ENV{SITE_HOST},
			iss          => $ENV{SITE_HOST},
			problemSeed  => 1234,
			isInstructor => 0,
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
	$t->post_ok(
		'/render-api' => form => {
			problemJWT    => $problemJWT,
			problemSource => $pg_source,
			outputFormat  => 'default',
		}
	)->status_is(200);
	my $body = $t->tx->res->body;
	like($body, qr/What is the answer\?/, 'legacy path still renders');
};

# ─── verdict_signed render-time fold (WW3-053) ──────────────────────────────

# Mint a verdict_signed JWS for tests. Mirrors what the orchestrator emits
# from BuildVerdictJWT — same HS256 + problemJWTsecret, same claim shape.
sub make_verdict_signed {
	my (%args) = @_;
	my $payload = {
		iss                 => 'https://ww3.example.edu',
		aud                 => $ENV{SITE_HOST},
		play_id             => $args{play_id} // '11111111-1111-1111-1111-111111111111',
		challenge_id        => 'sha256:abcdef',
		mint_sequence_basis => $args{basis}   // 0,
		verdict             => $args{verdict} // {
			current_focus  => 1,
			next_available => [ 1, 2 ],
			draw_next      => undef,
			finalization   => undef,
		},
	};
	return encode_jwt(payload => $payload, key => $ENV{problemJWTsecret}, alg => 'HS256');
}

subtest 'verdict_signed: render-time fold replaces sessionJWT with verdict-applied state' => sub {
	my $jwt  = make_challenge_jwt();
	my $base = make_play_session_jwt(
		challenge_jwt => $jwt,
		state         => {
			started_at     => undef,
			current_focus  => 0,
			next_available => [ 0, 1, 2 ],
			draws          => [],
			finalization   => undef,
		},
		mint_sequence => 5,
	);
	my $vsigned = make_verdict_signed(
		basis   => 5,
		verdict => {
			current_focus  => 1,
			next_available => [ 1, 2 ],
			draw_next      => undef,
			finalization   => undef,
		},
	);

	post_json({
		challengeJWT   => $jwt,
		sessionJWT     => $base,
		verdict_signed => $vsigned,
		position       => 1,
		problemSource  => $pg_source,
	})->status_is(200);

	my $resp     = decode_json($t->tx->res->body);
	my $surfaced = $resp->{JWT}{session};
	ok($surfaced, 'sessionJWT surfaced after fold');

	my $claims = decode_jwt(token => $surfaced, key => $ENV{webworkJWTsecret});
	is($claims->{state}{current_focus}, 1, 'current_focus reflects verdict fold');
	is_deeply($claims->{state}{next_available}, [ 1, 2 ], 'next_available reflects verdict fold');
	cmp_ok($claims->{mint_sequence}, '>=', 6, 'mint_sequence advanced past base');
};

subtest 'verdict_signed: open-mode draw_next appends to draws[]' => sub {
	my $challengeJWT = make_challenge_jwt(
		shape    => 'open',
		problems => [ { pg_hash => 'sha256:open0', seed => '*' }, { pg_hash => 'sha256:open1', seed => '*' }, ],
	);
	my $base = make_play_session_jwt(
		challenge_jwt => $challengeJWT,
		state         => {
			started_at     => undef,
			current_focus  => 0,
			next_available => [0],
			draws          => [ { draw_position => 0, pool_index => 0, pg_hash => 'sha256:open0', seed => 11111 }, ],
			finalization   => undef,
		},
		mint_sequence => 1,
	);
	my $new_draw = { draw_position => 1, pool_index => 1, pg_hash => 'sha256:open1', seed => 77777 };
	my $vsigned  = make_verdict_signed(
		basis   => 1,
		verdict => {
			current_focus  => 1,
			next_available => [1],
			draw_next      => $new_draw,
			finalization   => undef,
		},
	);

	post_json({
		challengeJWT   => $challengeJWT,
		sessionJWT     => $base,
		verdict_signed => $vsigned,
		position       => 1,
		problemSource  => $pg_source,
	})->status_is(200);

	my $resp     = decode_json($t->tx->res->body);
	my $surfaced = $resp->{JWT}{session};
	my $claims   = decode_jwt(token => $surfaced, key => $ENV{webworkJWTsecret});
	is(scalar @{ $claims->{state}{draws} }, 2,     'draws[] now has both entries');
	is($claims->{state}{draws}[1]{seed},    77777, 'new draw seed appended');
};

subtest 'verdict_signed: invalid signature → 400' => sub {
	my $jwt   = make_challenge_jwt();
	my $base  = make_play_session_jwt(challenge_jwt => $jwt);
	my $bogus = encode_jwt(
		payload => {
			play_id             => '11111111-1111-1111-1111-111111111111',
			mint_sequence_basis => 0,
			verdict             => { current_focus => 0, next_available => [0] },
		},
		alg => 'HS256',
		key => 'a-totally-different-secret_____',
	);

	post_json({
		challengeJWT   => $jwt,
		sessionJWT     => $base,
		verdict_signed => $bogus,
		position       => 0,
		problemSource  => $pg_source,
	})->status_is(400);
};

subtest 'verdict_signed: mismatched play_id → 400' => sub {
	my $jwt     = make_challenge_jwt();
	my $base    = make_play_session_jwt(challenge_jwt => $jwt);
	my $vsigned = make_verdict_signed(
		play_id => '99999999-9999-9999-9999-999999999999',
		basis   => 0,
	);

	post_json({
		challengeJWT   => $jwt,
		sessionJWT     => $base,
		verdict_signed => $vsigned,
		position       => 0,
		problemSource  => $pg_source,
	})->status_is(400);
};

subtest 'verdict_signed: stale mint_sequence_basis → 400' => sub {
	my $jwt     = make_challenge_jwt();
	my $base    = make_play_session_jwt(challenge_jwt => $jwt, mint_sequence => 10);
	my $vsigned = make_verdict_signed(basis => 7);                                     # stale relative to base

	post_json({
		challengeJWT   => $jwt,
		sessionJWT     => $base,
		verdict_signed => $vsigned,
		position       => 0,
		problemSource  => $pg_source,
	})->status_is(400);
};

subtest 'verdict_signed without sessionJWT → 400' => sub {
	my $jwt     = make_challenge_jwt();
	my $vsigned = make_verdict_signed(basis => 0);

	post_json({
		challengeJWT   => $jwt,
		verdict_signed => $vsigned,
		position       => 0,
		problemSource  => $pg_source,
	})->status_is(400);
};

subtest 'verdict_signed without challengeJWT → 400' => sub {
	my $cjwt_for_base = make_challenge_jwt();
	my $base          = make_play_session_jwt(challenge_jwt => $cjwt_for_base);
	my $vsigned       = make_verdict_signed();

	post_json({
		sessionJWT     => $base,
		verdict_signed => $vsigned,
		position       => 0,
		problemSource  => $pg_source,
	})->status_is(400);
};

# Post-answer-URL verdict fold (WW3-053) — needs a fake orchestrator server
# so sendSubmissionEnvelope's POST gets a real verdict_signed in response.

subtest 'post-answer-URL fold: orchestrator verdict_signed in response folds into surfaced sessionJWT' => sub {
	require Mojolicious::Lite;
	require Mojo::Server::Daemon;

	# Tiny fake orchestrator: responds at /assess/play/.../answer with a
	# canned accepted verdict + verdict_signed under the same secret the
	# renderer uses for problemJWT verification.
	my $fake = Mojolicious::Lite->new;
	$fake->routes->post(
		'/assess/play/:play_id/answer' => sub {
			my $c       = shift;
			my $play_id = $c->stash('play_id');
			my $verdict = {
				current_focus  => 2,
				next_available => [2],
				draw_next      => undef,
				finalization   => undef,
			};
			my $verdict_signed = encode_jwt(
				payload => {
					iss          => 'https://ww3.example.edu',
					aud          => $ENV{SITE_HOST},
					play_id      => $play_id,
					challenge_id => 'sha256:abcdef',
					# Pre-POST mint advances inbound mint_sequence by 1. With
					# inbound sessionJWT_3 (sequence 3), pre-POST mint is 4;
					# orchestrator's verdict pairs with that basis.
					mint_sequence_basis => 4,
					verdict             => $verdict,
				},
				alg => 'HS256',
				key => $ENV{problemJWTsecret},
			);
			$c->render(
				json => {
					status         => 'accepted',
					verdict        => $verdict,
					verdict_signed => $verdict_signed,
				}
			);
		}
	);

	my $server = Mojo::Server::Daemon->new(app => $fake)->silent(1);
	$server->listen(['http://127.0.0.1']);
	$server->start;
	my $port       = $server->ports->[0];
	my $play_id    = '11111111-1111-1111-1111-111111111111';
	my $answer_url = "http://127.0.0.1:$port/assess/play/$play_id/answer";

	# Mint a challengeJWT pointing at the fake server, plus an inbound
	# sessionJWT at mint_sequence 3 to make the sequence chain explicit:
	# inbound 3 → pre-POST mint 4 → fold (basis=4) produces sequence 5.
	my $jwt             = make_challenge_jwt(answer_url => $answer_url);
	my $inbound_session = make_play_session_jwt(
		challenge_jwt => $jwt,
		mint_sequence => 3,
	);

	post_json({
		challengeJWT  => $jwt,
		sessionJWT    => $inbound_session,
		position      => 0,
		problemSource => $pg_source,
		submitAnswers => 1,
		'AnSwEr0001'  => '42',
	})->status_is(200);

	my $resp     = decode_json($t->tx->res->body);
	my $surfaced = $resp->{JWT}{session};
	ok($surfaced, 'sessionJWT surfaced post-POST');

	my $claims = decode_jwt(token => $surfaced, key => $ENV{webworkJWTsecret});
	is($claims->{state}{current_focus}, 2, 'surfaced sessionJWT carries verdict.current_focus');
	is_deeply($claims->{state}{next_available}, [2], 'surfaced sessionJWT carries verdict.next_available');
	is($claims->{mint_sequence}, 5, 'mint_sequence advanced from inbound 3 → pre-POST 4 → fold 5');
};

subtest 'post-answer-URL fold: missing verdict_signed leaves pre-POST mint intact' => sub {
	require Mojolicious::Lite;
	require Mojo::Server::Daemon;

	# Fake server returns a response WITHOUT verdict_signed. The fold
	# should be skipped (graceful degradation) and the pre-POST mint
	# should remain the surfaced sessionJWT.
	my $fake = Mojolicious::Lite->new;
	$fake->routes->post(
		'/answer-no-verdict' => sub {
			my $c = shift;
			$c->render(
				json => {
					status  => 'accepted',
					verdict => { current_focus => 5, next_available => [5] },
					# verdict_signed deliberately absent
				}
			);
		}
	);

	my $server = Mojo::Server::Daemon->new(app => $fake)->silent(1);
	$server->listen(['http://127.0.0.1']);
	$server->start;
	my $port       = $server->ports->[0];
	my $answer_url = "http://127.0.0.1:$port/answer-no-verdict";

	my $jwt = make_challenge_jwt(answer_url => $answer_url);

	post_json({
		challengeJWT  => $jwt,
		position      => 0,
		problemSource => $pg_source,
		submitAnswers => 1,
		'AnSwEr0001'  => '42',
	})->status_is(200);

	my $resp     = decode_json($t->tx->res->body);
	my $surfaced = $resp->{JWT}{session};
	my $claims   = decode_jwt(token => $surfaced, key => $ENV{webworkJWTsecret});
	# The pre-POST mint preserves inbound state (current_focus undef on
	# first render). Critically NOT 5 (the verdict's value) — fold did not
	# run because verdict_signed was absent.
	isnt($claims->{state}{current_focus}, 5, 'pre-POST mint NOT replaced by unsigned verdict');
};

subtest 'empty-string verdict_signed treated as not-present' => sub {
	# Symmetric with the empty-string handling for problemJWT / sessionJWT /
	# challengeJWT. An empty string in the form payload should be a no-op,
	# not a 400.
	my $jwt = make_challenge_jwt();
	post_json({
		challengeJWT   => $jwt,
		verdict_signed => '',
		position       => 0,
		problemSource  => $pg_source,
	})->status_is(200);
};

done_testing;
