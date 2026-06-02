use strict;
use warnings;

use Test::More;
use Crypt::JWT qw(encode_jwt);

use lib 'lib';
use Renderer::Lane::Session qw(apply_prefix apply_source_override);

# Pure-function unit tests for the LTW-088 sidecar source-override: a sidecar
# problemJWT submitted in tandem with a sessionJWT overrides the nested
# ("matryoshka") problemJWT's SOURCE fields only, atomically. No Mojo render
# path, no PG, no async — the override is synchronous param mutation, so it
# unit-tests directly here. End-to-end render coverage lives in the
# Docker-gated HTTP suite (Future::AsyncAwait), not this file.

$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';
$ENV{SITE_HOST}        //= 'https://render.test';

# ─── Minimal mock controller ─────────────────────────────────────────────
# Implements just the surface apply_prefix / apply_source_override touch:
# log->info (no-op), stash (Mojo dual get/set), croak (records + returns 0).
{
	package MockLog;
	sub new  { bless {}, shift }
	sub info { }
	sub warn { }

	package MockController;
	sub new { bless { stash => {}, croaked => undef }, shift }
	sub log { $_[0]{log} //= MockLog->new }
	sub stash {
		my $self = shift;
		return $self->{stash}{ $_[0] } if @_ == 1;   # getter
		my %kv = @_;                                  # setter
		@{ $self->{stash} }{ keys %kv } = values %kv;
		return $self;
	}
	sub croak { $_[0]{croaked} = { msg => $_[1], code => $_[2] }; return 0 }
}

sub problem_jwt {
	my (%claims) = @_;
	return encode_jwt(
		payload => { aud => $ENV{SITE_HOST}, %claims },
		key     => $ENV{problemJWTsecret},
		alg     => 'HS256',
	);
}

sub session_jwt {
	my (%claims) = @_;
	return encode_jwt(
		payload => { iss => $ENV{SITE_HOST}, aud => $ENV{SITE_HOST}, %claims },
		key     => $ENV{webworkJWTsecret},
		alg     => 'HS256',
	);
}

# ─── apply_prefix: sidecar capture ────────────────────────────────────────

subtest 'differing sidecar is stashed; nested stays the body token' => sub {
	my $nested  = problem_jwt(problemSourceURL => 'http://old', pg_hash => 'sha256:old');
	my $sidecar = problem_jwt(problemSourceURL => 'http://new');
	my $c = MockController->new;
	my %params = (sessionJWT => session_jwt(problemJWT => $nested), problemJWT => $sidecar);

	ok(apply_prefix($c, \%params), 'apply_prefix ok');
	is($params{problemJWT}, $nested, 'body token is the nested problemJWT');
	is($c->stash('_sidecar_problemJWT'), $sidecar, 'sidecar stashed for override');
};

subtest 'sidecar identical to nested → no stash (no-op override)' => sub {
	my $nested = problem_jwt(problemSourceURL => 'http://same');
	my $c = MockController->new;
	my %params = (sessionJWT => session_jwt(problemJWT => $nested), problemJWT => $nested);

	ok(apply_prefix($c, \%params), 'apply_prefix ok');
	is($params{problemJWT}, $nested, 'body token is the nested token');
	ok(!defined $c->stash('_sidecar_problemJWT'), 'no sidecar stashed');
};

subtest 'sidecar without a nested problemJWT → sidecar becomes the body' => sub {
	my $sidecar = problem_jwt(problemSourceURL => 'http://only');
	my $c = MockController->new;
	my %params = (sessionJWT => session_jwt(), problemJWT => $sidecar);  # session has no nested

	ok(apply_prefix($c, \%params), 'apply_prefix ok');
	is($params{problemJWT}, $sidecar, 'sidecar is the body token');
	ok(!defined $c->stash('_sidecar_problemJWT'), 'nothing stashed for override');
};

# ─── apply_source_override: atomic source replacement ─────────────────────

subtest 'atomic bundle: a URL-only sidecar drops the stale nested hash/path/bytes' => sub {
	# Simulate post-Lane::Problem state: nested source fields already merged in.
	my %params = (
		problemSourceURL => 'http://old',
		sourceFilePath   => '/cache/old.pg',
		pg_hash          => 'sha256:STALE',
		problemSource    => 'OLD BYTES',
		isInstructor     => 0,
	);
	my $c = MockController->new;
	$c->stash(_sidecar_problemJWT => problem_jwt(problemSourceURL => 'http://new'));

	ok(apply_source_override($c, \%params), 'apply_source_override ok');
	is($params{problemSourceURL}, 'http://new', 'URL taken from sidecar');
	ok(!exists $params{pg_hash},        'stale pg_hash dropped (no URL+stale-hash mix)');
	ok(!exists $params{sourceFilePath}, 'stale sourceFilePath dropped');
	ok(!exists $params{problemSource},  'stale problemSource bytes dropped');
};

subtest 'source-only boundary: trust/routing/state claims never cross' => sub {
	my %params = (
		problemSourceURL => 'http://old',
		isInstructor     => 0,
		JWTanswerURL     => 'https://good/answer',
	);
	my $c = MockController->new;
	# Hostile sidecar: tries to elevate + redirect alongside a real source swap.
	$c->stash(_sidecar_problemJWT => problem_jwt(
		problemSourceURL => 'http://new',
		isInstructor     => 1,
		JWTanswerURL     => 'https://evil/exfil',
	));

	ok(apply_source_override($c, \%params), 'apply_source_override ok');
	is($params{problemSourceURL}, 'http://new',         'source field crossed');
	is($params{isInstructor},     0,                    'isInstructor NOT elevated by sidecar');
	is($params{JWTanswerURL},     'https://good/answer','JWTanswerURL NOT redirected by sidecar');
};

subtest 'sidecar carrying no source fields → no-op' => sub {
	my %params = (problemSourceURL => 'http://keep', pg_hash => 'sha256:keep');
	my $c = MockController->new;
	$c->stash(_sidecar_problemJWT => problem_jwt(isInstructor => 1));  # non-source only

	ok(apply_source_override($c, \%params), 'apply_source_override ok');
	is($params{problemSourceURL}, 'http://keep', 'source untouched');
	is($params{pg_hash},          'sha256:keep', 'hash untouched');
};

subtest 'no sidecar stashed → no-op' => sub {
	my %params = (problemSourceURL => 'http://keep');
	my $c = MockController->new;

	ok(apply_source_override($c, \%params), 'returns 1 with nothing stashed');
	is($params{problemSourceURL}, 'http://keep', 'params untouched');
};

subtest 'malformed sidecar → croak (rejected as a bad request)' => sub {
	my %params = (problemSourceURL => 'http://old');
	my $c = MockController->new;
	$c->stash(_sidecar_problemJWT => 'not.a.valid.jwt');

	my $rv = apply_source_override($c, \%params);
	ok(!$rv, 'returns falsy (short-circuits the controller)');
	ok($c->stash('_sidecar_problemJWT'), 'sidecar was present');
	is(ref $c->{croaked}, 'HASH', 'croak was invoked on decode failure');
};

done_testing;
