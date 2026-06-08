use strict;
use warnings;

use Test::More;
use Crypt::JWT qw(encode_jwt decode_jwt);

use lib 'lib';
use WeBWorK::VerdictJWT qw(verifyAndFoldVerdict);

my $ORCH     = 'test-orchestrator-secret-32bytes';
my $RENDERER = 'test-renderer-secret-32bytes____';

$ENV{SITE_HOST} //= 'https://render.test';

# Helpers ---------------------------------------------------------------------

# Mint a fake challengeJWT carrying play_id. Real challengeJWTs carry more
# claims; for fold verification we only need play_id to land.
sub make_challenge_jwt {
	my (%overrides) = @_;
	my $payload = {
		iss                => 'https://ww3.test',
		aud                => $ENV{SITE_HOST},
		play_id            => '11111111-1111-1111-1111-111111111111',
		challenge_id       => 'sha256:abc',
		shape              => 'closed',
		problems           => [],
		mode               => {},
		constraints        => {},
		render_permissions => {},
		answer_url         => 'https://ww3.test/assess/play/x/answer',
		%overrides,
	};
	return encode_jwt(payload => $payload, alg => 'HS256', key => $ORCH, auto_iat => 1);
}

# Mint a base sessionJWT with the given embedded challengeJWT, sequence,
# and state.
sub make_session_jwt {
	my (%args) = @_;
	my $payload = {
		iss           => $ENV{SITE_HOST},
		aud           => $ENV{SITE_HOST},
		challenge_jwt => $args{challenge_jwt},
		state         => $args{state} // {
			started_at     => '2026-04-27T17:00:00Z',
			current_focus  => 0,
			next_available => [0],
			draws          => [],
			finalization   => undef,
		},
		mint_sequence => $args{mint_sequence} // 0,
	};
	return encode_jwt(payload => $payload, alg => 'HS256', key => $RENDERER, auto_iat => 1);
}

# Mint a fake verdict_signed with play_id, mint_sequence_basis, and verdict body.
sub make_verdict_signed {
	my (%args) = @_;
	my $payload = {
		iss                 => 'https://ww3.test',
		aud                 => $ENV{SITE_HOST},
		play_id             => $args{play_id} // '11111111-1111-1111-1111-111111111111',
		challenge_id        => 'sha256:abc',
		mint_sequence_basis => $args{basis}   // 0,
		verdict             => $args{verdict} // {
			current_focus  => 1,
			next_available => [ 1, 2 ],
			draw_next      => undef,
			finalization   => undef,
		},
	};
	return encode_jwt(payload => $payload, alg => 'HS256', key => $ORCH, auto_iat => 1);
}

# Round-trip happy path -------------------------------------------------------

subtest 'happy path: closed mode fold advances state and sequence' => sub {
	my $cjwt = make_challenge_jwt();
	my $base = make_session_jwt(
		challenge_jwt => $cjwt,
		mint_sequence => 5,
		state         => {
			started_at     => '2026-04-27T17:00:00Z',
			current_focus  => 0,
			next_available => [ 0, 1, 2 ],
			draws          => [],
			finalization   => undef,
		},
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

	my ($new_jwt, $err) = verifyAndFoldVerdict($base, $vsigned, $ORCH, $RENDERER);
	is($err, undef, 'no error');
	ok($new_jwt, 'got a new sessionJWT');

	my $claims = decode_jwt(token => $new_jwt, key => $RENDERER, accepted_alg => 'HS256');
	is($claims->{mint_sequence},        6, 'mint_sequence advanced by 1');
	is($claims->{state}{current_focus}, 1, 'current_focus from verdict');
	is_deeply($claims->{state}{next_available}, [ 1, 2 ], 'next_available from verdict');
	is($claims->{state}{started_at}, '2026-04-27T17:00:00Z', 'started_at preserved');
	is_deeply($claims->{state}{draws}, [], 'draws[] empty (closed mode, no draw_next)');
	is($claims->{state}{finalization}, undef, 'finalization undef');
	is($claims->{challenge_jwt},       $cjwt, 'challenge_jwt re-embedded verbatim');
};

subtest 'open mode: draw_next appends to draws[]' => sub {
	my $cjwt = make_challenge_jwt();
	my $base = make_session_jwt(
		challenge_jwt => $cjwt,
		mint_sequence => 2,
		state         => {
			started_at     => '2026-04-27T17:00:00Z',
			current_focus  => 0,
			next_available => [0],
			draws          =>
				[ { draw_position => 0, pool_index => 5, pg_hash => 'sha256:x', seed => 11111, drawn_at => '...' }, ],
			finalization => undef,
		},
	);
	my $new_draw = { draw_position => 1, pool_index => 7, pg_hash => 'sha256:y', seed => 22222, drawn_at => '...' };
	my $vsigned  = make_verdict_signed(
		basis   => 2,
		verdict => {
			current_focus  => 1,
			next_available => [1],
			draw_next      => $new_draw,
			finalization   => undef,
		},
	);

	my ($new_jwt, $err) = verifyAndFoldVerdict($base, $vsigned, $ORCH, $RENDERER);
	is($err, undef, 'no error');
	my $claims = decode_jwt(token => $new_jwt, key => $RENDERER, accepted_alg => 'HS256');
	is(scalar @{ $claims->{state}{draws} },    2, 'draws[] now has 2 entries');
	is($claims->{state}{draws}[1]{pool_index}, 7, 'new draw is the second entry');
};

subtest 'finalization: terminal verdict folds finalization into state' => sub {
	my $cjwt    = make_challenge_jwt();
	my $base    = make_session_jwt(challenge_jwt => $cjwt, mint_sequence => 3);
	my $vsigned = make_verdict_signed(
		basis   => 3,
		verdict => {
			current_focus  => undef,
			next_available => [],
			draw_next      => undef,
			finalization   => { at => '2026-04-27T17:48:00Z', reason => 'student_finalized' },
		},
	);

	my ($new_jwt, $err) = verifyAndFoldVerdict($base, $vsigned, $ORCH, $RENDERER);
	is($err, undef, 'no error');
	my $claims = decode_jwt(token => $new_jwt, key => $RENDERER, accepted_alg => 'HS256');
	is($claims->{state}{finalization}{reason}, 'student_finalized', 'finalization reason set');
	is_deeply($claims->{state}{next_available}, [], 'next_available empty on terminal');
};

# Verification gates ----------------------------------------------------------

subtest 'reject: verdict signed under wrong secret' => sub {
	my $cjwt  = make_challenge_jwt();
	my $base  = make_session_jwt(challenge_jwt => $cjwt, mint_sequence => 0);
	my $bogus = encode_jwt(
		payload => { play_id => 'x', mint_sequence_basis => 0, verdict => {} },
		alg     => 'HS256',
		key     => 'a-different-secret-not-orch_____',
	);

	my ($new_jwt, $err) = verifyAndFoldVerdict($base, $bogus, $ORCH, $RENDERER);
	is($new_jwt, undef, 'no new sessionJWT');
	like($err, qr/verdict_signed.*invalid signature/, 'error names the gate');
};

subtest 'reject: base sessionJWT signed under wrong secret' => sub {
	my $cjwt       = make_challenge_jwt();
	my $bogus_base = encode_jwt(
		payload => { challenge_jwt => $cjwt, state => {}, mint_sequence => 0 },
		alg     => 'HS256',
		key     => 'a-different-secret-not-renderer_',
	);
	my $vsigned = make_verdict_signed();

	my ($new_jwt, $err) = verifyAndFoldVerdict($bogus_base, $vsigned, $ORCH, $RENDERER);
	is($new_jwt, undef, 'no new sessionJWT');
	like($err, qr/base_session_jwt.*invalid signature/, 'error names the gate');
};

subtest 'reject: play_id mismatch between verdict and embedded challengeJWT' => sub {
	my $cjwt    = make_challenge_jwt(play_id => '11111111-1111-1111-1111-111111111111');
	my $base    = make_session_jwt(challenge_jwt => $cjwt, mint_sequence => 0);
	my $vsigned = make_verdict_signed(play_id => '99999999-9999-9999-9999-999999999999');

	my ($new_jwt, $err) = verifyAndFoldVerdict($base, $vsigned, $ORCH, $RENDERER);
	is($new_jwt, undef, 'no new sessionJWT');
	like($err, qr/play_id mismatch/, 'error names the cross-check');
};

subtest 'reject: mint_sequence_basis older than base.mint_sequence' => sub {
	my $cjwt    = make_challenge_jwt();
	my $base    = make_session_jwt(challenge_jwt => $cjwt, mint_sequence => 10);
	my $vsigned = make_verdict_signed(basis => 7);                                 # stale

	my ($new_jwt, $err) = verifyAndFoldVerdict($base, $vsigned, $ORCH, $RENDERER);
	is($new_jwt, undef, 'no new sessionJWT');
	like($err, qr/mint_sequence_basis.*<.*base/, 'error names the basis check');
};

subtest 'accept: mint_sequence_basis equal to base.mint_sequence' => sub {
	# basis == base.mint_sequence is the normal case (RESUME path: verdict
	# was derived from session_k.state, basis == k).
	my $cjwt    = make_challenge_jwt();
	my $base    = make_session_jwt(challenge_jwt => $cjwt, mint_sequence => 4);
	my $vsigned = make_verdict_signed(basis => 4);

	my ($new_jwt, $err) = verifyAndFoldVerdict($base, $vsigned, $ORCH, $RENDERER);
	is($err, undef, 'no error');
	my $claims = decode_jwt(token => $new_jwt, key => $RENDERER, accepted_alg => 'HS256');
	is($claims->{mint_sequence}, 5, 'mint_sequence still advances by 1');
};

subtest 'reject: missing required claims' => sub {
	my $cjwt = make_challenge_jwt();
	my $base = make_session_jwt(challenge_jwt => $cjwt, mint_sequence => 0);

	# Missing play_id.
	my $no_play_id = encode_jwt(
		payload => { mint_sequence_basis => 0, verdict => {} },
		alg     => 'HS256',
		key     => $ORCH,
	);
	my ($_jwt, $err) = verifyAndFoldVerdict($base, $no_play_id, $ORCH, $RENDERER);
	like($err, qr/missing play_id/, 'rejects missing play_id');

	# Missing mint_sequence_basis.
	my $no_basis = encode_jwt(
		payload => { play_id => 'x', verdict => {} },
		alg     => 'HS256',
		key     => $ORCH,
	);
	($_jwt, $err) = verifyAndFoldVerdict($base, $no_basis, $ORCH, $RENDERER);
	like($err, qr/missing mint_sequence_basis/, 'rejects missing basis');

	# Missing verdict.
	my $no_verdict = encode_jwt(
		payload => { play_id => 'x', mint_sequence_basis => 0 },
		alg     => 'HS256',
		key     => $ORCH,
	);
	($_jwt, $err) = verifyAndFoldVerdict($base, $no_verdict, $ORCH, $RENDERER);
	like($err, qr/missing verdict/, 'rejects missing verdict');
};

subtest 'reject: empty inputs' => sub {
	my ($jwt, $err) = verifyAndFoldVerdict('', 'x', $ORCH, $RENDERER);
	like($err, qr/base_session_jwt is required/, 'rejects empty base');

	($jwt, $err) = verifyAndFoldVerdict('y', '', $ORCH, $RENDERER);
	like($err, qr/verdict_signed is required/, 'rejects empty verdict');

	($jwt, $err) = verifyAndFoldVerdict('y', 'x', '', $RENDERER);
	like($err, qr/orchestrator_secret/, 'rejects empty orch secret');

	($jwt, $err) = verifyAndFoldVerdict('y', 'x', $ORCH, '');
	like($err, qr/renderer_secret/, 'rejects empty renderer secret');
};

subtest 'reject: base_session_jwt missing embedded challenge_jwt' => sub {
	my $bogus_base = encode_jwt(
		payload => { state => {}, mint_sequence => 0 },    # no challenge_jwt
		alg     => 'HS256',
		key     => $RENDERER,
	);
	my $vsigned = make_verdict_signed();

	my ($jwt, $err) = verifyAndFoldVerdict($bogus_base, $vsigned, $ORCH, $RENDERER);
	is($jwt, undef, 'no new sessionJWT');
	like($err, qr/missing embedded challenge_jwt/, 'error names the gate');
};

# Idempotency / determinism ---------------------------------------------------

subtest 'fold preserves base challenge_jwt verbatim' => sub {
	my $cjwt    = make_challenge_jwt();
	my $base    = make_session_jwt(challenge_jwt => $cjwt, mint_sequence => 1);
	my $vsigned = make_verdict_signed(basis => 1);

	my ($new_jwt, $err) = verifyAndFoldVerdict($base, $vsigned, $ORCH, $RENDERER);
	is($err, undef, 'fold succeeds');
	my $claims = decode_jwt(token => $new_jwt, key => $RENDERER, accepted_alg => 'HS256');
	is($claims->{challenge_jwt}, $cjwt, 'embedded challenge_jwt is byte-identical to base');
};

done_testing();
