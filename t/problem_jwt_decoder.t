use strict;
use warnings;

use Test::More;
use Crypt::JWT   qw(encode_jwt);
use MIME::Base64 qw(encode_base64url);
use Mojo::JSON   qw(encode_json);

use lib 'lib';
use Renderer::Util::JWT qw(verify_problem_jwt PROBLEM_JWT_ALGS);

# Pure-function unit tests for Renderer::Util::JWT::verify_problem_jwt — the
# single problemJWT verify entry point every problemJWT-keyed lane calls
# (Lane::Problem / Challenge / Review / ContentFetch + RevealSidecar). No Mojo,
# no PG, no app boot.
#
# The alg allow-list is the security-load-bearing assertion: HS256 (the
# LMS/orchestrator mint) AND PBES2-HS512+A256KW (the self-mint/peer JWE
# continuation) decode, while `none`, alg-confusion, a wrong key, and a wrong
# audience all reject. A single-value pin would break the self-mint round-trip;
# no pin at all would honour a token's declared alg — the drift this locks.

$ENV{problemJWTsecret} = 'test-problem-secret';
$ENV{SITE_HOST}        = 'https://render.test';

sub hs256 {
	my (%claims) = @_;
	return encode_jwt(
		payload  => { aud => $ENV{SITE_HOST}, %claims },
		key      => $ENV{problemJWTsecret},
		alg      => 'HS256',
		auto_iat => 1,
	);
}

sub jwe_selfmint {
	my (%claims) = @_;
	return encode_jwt(
		payload  => { aud => $ENV{SITE_HOST}, %claims },
		key      => $ENV{problemJWTsecret},
		alg      => 'PBES2-HS512+A256KW',
		enc      => 'A256GCM',
		auto_iat => 1,
	);
}

# ─── The allow-list ────────────────────────────────────────────────────────

subtest 'allow-list is exactly [HS256, PBES2-HS512+A256KW]' => sub {
	is_deeply(PROBLEM_JWT_ALGS, [qw(HS256 PBES2-HS512+A256KW)], 'the two accepted algs and no more');
};

subtest 'HS256 (LMS/orchestrator mint) decodes' => sub {
	my ($claims, $err) = verify_problem_jwt(hs256(foo => 'bar'));
	ok(!$err, 'no error') or diag($err);
	is($claims->{foo}, 'bar', 'claims extracted');
};

subtest 'PBES2-HS512+A256KW JWE (self-mint/peer continuation) decodes' => sub {
	# This is the round-trip Lane/{Ungrounded,Peer} → Lane::Problem depends on.
	# A single-value HS256 pin would break it; the allow-list keeps it working.
	my ($claims, $err) = verify_problem_jwt(jwe_selfmint(foo => 'jwe'));
	ok(!$err, 'no error on the self-mint JWE') or diag($err);
	is($claims->{foo}, 'jwe', 'JWE claims extracted');
};

subtest 'a hand-forged alg:none token is rejected' => sub {
	# Crypt::JWT refuses to even MINT a `none` token, so forge one by hand:
	# header.payload with an empty signature.
	my $h = encode_base64url(encode_json({ alg => 'none', typ => 'JWT' }));
	my $p = encode_base64url(encode_json({ aud => $ENV{SITE_HOST}, foo => 'x' }));
	my ($claims, $err) = verify_problem_jwt("$h.$p.");
	ok($err,             'alg:none rejected') or diag('none was accepted');
	ok(!defined $claims, 'no claims returned');
};

subtest 'alg-confusion (a valid HMAC under an alg NOT on the list) is rejected' => sub {
	# HS384 validates against the shared secret but is not on the allow-list.
	# Without accepted_alg, decode_jwt would honour it — that is the hole.
	my $hs384 = encode_jwt(
		payload => { aud => $ENV{SITE_HOST}, foo => 'x' },
		key     => $ENV{problemJWTsecret},
		alg     => 'HS384',
	);
	my ($claims, $err) = verify_problem_jwt($hs384);
	ok($err,             'HS384 rejected — off the allow-list') or diag('HS384 was accepted');
	ok(!defined $claims, 'no claims returned');
};

# ─── Signature / audience ──────────────────────────────────────────────────

subtest 'a wrong-key signature is rejected' => sub {
	my $bad = encode_jwt(
		payload => { aud => $ENV{SITE_HOST}, foo => 'x' },
		key     => 'not-the-secret',
		alg     => 'HS256',
	);
	my ($claims, $err) = verify_problem_jwt($bad);
	ok($err,             'bad signature rejected');
	ok(!defined $claims, 'no claims returned');
};

subtest 'a wrong-audience token is rejected' => sub {
	my ($claims, $err) = verify_problem_jwt(hs256(aud => 'https://evil.example'));
	ok($err,             'wrong aud rejected');
	ok(!defined $claims, 'no claims returned');
};

# ─── verify_exp option ─────────────────────────────────────────────────────

subtest 'exp is enforced by default (RevealSidecar / Challenge / Review / ContentFetch)' => sub {
	my ($claims, $err) = verify_problem_jwt(hs256(exp => time() - 3600));
	ok($err,             'expired token rejected under the default verify_exp');
	ok(!defined $claims, 'no claims returned');
};

subtest 'verify_exp => 0 accepts an expired token (Lane::Problem matryoshka)' => sub {
	my ($claims, $err) = verify_problem_jwt(hs256(foo => 'y', exp => time() - 3600), verify_exp => 0);
	ok(!$err, 'expired token accepted with verify_exp => 0') or diag($err);
	is($claims->{foo}, 'y', 'claims extracted from the expired token');
};

# ─── hoist_provider option ─────────────────────────────────────────────────

subtest 'hoist_provider unwraps the LibreTexts `webwork` envelope' => sub {
	my ($claims, $err) =
		verify_problem_jwt(hs256(webwork => { problemSource => 'S', pg_hash => 'sha256:p' }), hoist_provider => 1);
	ok(!$err, 'no error') or diag($err);
	is($claims->{problemSource}, 'S',        'inner claims hoisted');
	is($claims->{pg_hash},       'sha256:p', 'inner pg_hash hoisted');
};

subtest 'without hoist_provider the envelope is left intact (ContentFetch reads outer typ first)' => sub {
	my ($claims, $err) = verify_problem_jwt(hs256(typ => 'solution', webwork => { problemSource => 'S' }));
	ok(!$err, 'no error') or diag($err);
	is($claims->{typ},         'solution', 'outer typ visible before any unwrap');
	is(ref $claims->{webwork}, 'HASH',     'provider envelope still nested');
};

done_testing;
