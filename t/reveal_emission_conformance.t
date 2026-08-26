use strict;
use warnings;

use Test::More;
use Crypt::JWT qw(encode_jwt);

use lib 'lib';
use Renderer::Lane::Problem        ();
use Renderer::Lane::Challenge      ();
use Renderer::Lane::Review         ();
use Renderer::Lane::Ungrounded     ();
use Renderer::Lane::Peer           ();
use Renderer::Render::ParseRequest ();
use Renderer::Permissions          qw(resolve_permissions);

# ─── Cross-lane reveal + emission conformance ────────────────────────────────
#
# The two whole-taxonomy invariants the renderer must hold, driven through the
# REAL lane code host-side (MockController, no app boot — the async render
# pipeline is not exercised here; the lane/strip/resolver decisions are pure).
#
#   1. A student cannot self-grant a reveal. The defence lives at four sites:
#        (a) ParseRequest strips isInstructor + renderMode from raw input,
#        (b) the RenderMode bundle zeros showCorrectAnswers on non-offering
#            modes (via Lane::Problem's mode-gate),
#        (c) Lane::Challenge / Lane::Review hard-zero showCorrectAnswers,
#        (d) resolve_permissions is the final student/instructor switch.
#      Fed raw `showCorrectAnswers=1` / `isInstructor=1` / `renderMode=preview`,
#      every grounded lane resolves to the student view.
#
#   2. No answerJWT is emitted on a lane that is not upstream-grounded. The
#      emission site (Render.pm) gates on the `_can_emit_answer_jwt` stash;
#      only Lane::Problem and Lane::Challenge set it. Review, self-mint
#      (Ungrounded) and peer never do, so a submit on those lanes cannot POST a
#      signed answerJWT to any JWTanswerURL.
#
# Before this test the reveal invariant was pinned only via the Docker-gated
# reveal_invariant.t (full HTTP boot), and the "no answerJWT" assertion existed
# for a single lane (challenge_jwt.t:226). This is the host-runnable,
# every-lane guard — it fails if any one lane's defence is removed.

$ENV{problemJWTsecret} = 'test-problem-secret';
$ENV{webworkJWTsecret} = 'test-session-secret';
$ENV{SITE_HOST}        = 'https://render.test';
delete $ENV{STRICT_JWT};
delete $ENV{OPL_API_URL};

# ─── Minimal mock controller ─────────────────────────────────────────────────
# The surface the lanes + _parse_envelope touch: log (no-op), stash (Mojo dual
# get/set), credential_error / exception (record + return undef so `or return`
# bails), opl_client (never reached — every lane below carries problemSource, so
# the pg_hash → URL synthesis is skipped — but stubbed so a miss doesn't die),
# and a fake req/tx for the ParseRequest envelope.
{

	package MockLog;
	sub new   { bless {}, shift }
	sub info  { }
	sub warn  { }
	sub error { }

	package MockHeaders;
	sub new    { bless {}, shift }
	sub header { return undef }      # no X-Forwarded-For, no X-Peer-* headers

	package MockUrl;
	sub new       { bless {}, shift }
	sub path      { return MockUrl->new }
	sub to_string { return '/render-api' }

	package MockReq;
	sub new     { bless {}, shift }
	sub headers { $_[0]{h} //= MockHeaders->new }
	sub method  {'POST'}
	sub url     { MockUrl->new }
	sub body    {''}

	package MockTx;
	sub new            { bless {}, shift }
	sub remote_address {'127.0.0.1'}

	package MockOplClient;
	sub new                 { bless {}, shift }
	sub problem_url_by_hash { return 'http://opl.test/by-hash' }

	package MockController;
	sub new        { bless { stash => {}, rejected => undef }, shift }
	sub log        { $_[0]{log} //= MockLog->new }
	sub req        { $_[0]{req} //= MockReq->new }
	sub tx         { $_[0]{tx}  //= MockTx->new }
	sub opl_client { $_[0]{opl} //= MockOplClient->new }

	sub stash {
		my $self = shift;
		return $self->{stash}{ $_[0] } if @_ == 1;    # getter
		my %kv = @_;                                  # setter
		@{ $self->{stash} }{ keys %kv } = values %kv;
		return $self;
	}
	sub credential_error { $_[0]{rejected} = { err => $_[1] };                  return undef }
	sub exception        { $_[0]{rejected} = { msg => $_[1], status => $_[2] }; return undef }
}

# ─── JWT mint helpers (orchestrator/LMS side — HS256 under problemJWTsecret) ──

sub problem_jwt {
	my (%claims) = @_;
	return encode_jwt(
		payload  => { aud => $ENV{SITE_HOST}, iss => $ENV{SITE_HOST}, %claims },
		key      => $ENV{problemJWTsecret},
		alg      => 'HS256',
		auto_iat => 1,
	);
}

sub challenge_jwt {
	my (%claims) = @_;
	return problem_jwt(
		problems   => [ { pg_hash => 'sha256:p0', seed => 111 } ],
		answer_url => 'https://orchestrator.test/answer',
		%claims,
	);
}

sub submission_jwt {
	my (%claims) = @_;
	return problem_jwt(
		pg_hash  => 'sha256:p0',
		seed     => 111,
		position => 0,
		%claims,
	);
}

# ═════════════════════════════════════════════════════════════════════════════
# Part 1 — ParseRequest strips the elevation + render-mode vectors (site a)
# ═════════════════════════════════════════════════════════════════════════════

subtest 'ParseRequest strips raw isInstructor + renderMode from a grounded request' => sub {
	my $c = MockController->new;
	# A student's own POST: a grounded body (challengeJWT) plus hand-added
	# elevation and render-mode params, and the reveal button's own flag.
	my %params = (
		challengeJWT       => challenge_jwt(),
		isInstructor       => 1,
		renderMode         => 'preview',
		showCorrectAnswers => 1,
	);
	my %ctx;
	ok(Renderer::Render::ParseRequest::_parse_envelope($c, \%params, \%ctx), '_parse_envelope ok');

	ok(!exists $params{isInstructor}, 'raw isInstructor stripped (ELEVATION_PARAMS)');
	ok(!exists $params{renderMode},   'raw renderMode stripped (RENDER_MODE_PARAMS)');
	is($c->stash('_stripped_elevation')->{isInstructor},
		1, 'stripped isInstructor stashed for a lane that legitimately restores it');
	# showCorrectAnswers is deliberately NOT stripped — it is the reveal
	# BUTTON's own mechanism (see Constants). Each lane defends it instead.
	is($params{showCorrectAnswers}, 1, 'showCorrectAnswers survives the strip (button mechanism)');
};

# ═════════════════════════════════════════════════════════════════════════════
# Part 2 — every grounded lane keeps a raw reveal student-side (sites b, c, d)
# ═════════════════════════════════════════════════════════════════════════════

subtest 'Lane::Problem: raw showCorrectAnswers is mode-gated off (custom → no reveal)' => sub {
	my $c = MockController->new;
	# Post-strip reality: showCorrectAnswers is NOT stripped, so it reaches the
	# lane. No renderMode claim ⇒ resolves to `custom`, whose bundle offers no
	# reveal button — so the mode-gate zeros the flag.
	my %params = (
		problemJWT         => problem_jwt(problemSource => 'S', pg_hash => 'sha256:p0'),
		showCorrectAnswers => 1,
	);
	ok(Renderer::Lane::Problem::apply($c, \%params), 'apply ok');
	my $perms = resolve_permissions(\%params);
	is($perms->{showCorrectAnswers}, 0, 'reveal denied — mode-gate zeroed the raw flag');
	is($perms->{isInstructor},       0, 'student');
	is($perms->{showSolutions},      0, 'no revealAll');
};

subtest 'Lane::Challenge: raw showCorrectAnswers is hard-zeroed' => sub {
	my $c      = MockController->new;
	my %params = (
		challengeJWT       => challenge_jwt(),
		position           => 0,
		problemSource      => 'S',
		showCorrectAnswers => 1,
	);
	ok(Renderer::Lane::Challenge::apply($c, \%params), 'apply ok');
	is($params{showCorrectAnswers}, 0, 'lane hard-zeroed the raw flag');
	my $perms = resolve_permissions(\%params);
	is($perms->{showCorrectAnswers}, 0, 'reveal denied');
	is($perms->{showSolutions},      0, 'no revealAll');
};

subtest 'Lane::Review: raw showCorrectAnswers AND isInstructor are hard-zeroed' => sub {
	my $c = MockController->new;
	# reView is the lane where the student is SUPPOSED to hold their own body
	# token, so its self-defence must be total: both vectors hard-zeroed.
	my %params = (
		submissionJWT      => submission_jwt(),
		problemSource      => 'S',
		showCorrectAnswers => 1,
		isInstructor       => 1,
	);
	ok(Renderer::Lane::Review::apply($c, \%params), 'apply ok');
	is($params{showCorrectAnswers}, 0, 'lane hard-zeroed showCorrectAnswers');
	is($params{isInstructor},       0, 'lane hard-zeroed isInstructor');
	my $perms = resolve_permissions(\%params);
	is($perms->{showCorrectAnswers}, 0, 'reveal denied');
	is($perms->{isInstructor},       0, 'student');
	is($perms->{showSolutions},      0, 'no revealAll');
};

# ═════════════════════════════════════════════════════════════════════════════
# Part 3 — the emission gate: only upstream-grounded lanes may emit an answerJWT
# ═════════════════════════════════════════════════════════════════════════════
#
# Render.pm emits an answerJWT only when JWTanswerURL && submitAnswers &&
# $c->stash('_can_emit_answer_jwt'). Asserting the stash per lane pins the exact
# gate input the emission site reads.

subtest 'Lane::Problem sets _can_emit_answer_jwt (upstream-grounded, may emit)' => sub {
	my $c      = MockController->new;
	my %params = (problemJWT => problem_jwt(problemSource => 'S', pg_hash => 'sha256:p0'));
	ok(Renderer::Lane::Problem::apply($c, \%params), 'apply ok');
	ok($c->stash('_can_emit_answer_jwt'),            'emission allowed');
};

subtest 'Lane::Challenge sets _can_emit_answer_jwt (upstream-grounded, may emit)' => sub {
	my $c      = MockController->new;
	my %params = (challengeJWT => challenge_jwt(), position => 0, problemSource => 'S');
	ok(Renderer::Lane::Challenge::apply($c, \%params), 'apply ok');
	ok($c->stash('_can_emit_answer_jwt'),              'emission allowed');
};

subtest 'Lane::Review does NOT set _can_emit_answer_jwt (read-only replay)' => sub {
	my $c      = MockController->new;
	my %params = (submissionJWT => submission_jwt(), problemSource => 'S');
	ok(Renderer::Lane::Review::apply($c, \%params), 'apply ok');
	ok(!$c->stash('_can_emit_answer_jwt'),          'no answerJWT emission on reView');
};

subtest 'Lane::Ungrounded (self-mint) does NOT set _can_emit_answer_jwt' => sub {
	my $c      = MockController->new;
	my %params = (problemSource => 'S', problemSeed => 1);
	ok(Renderer::Lane::Ungrounded::apply($c, \%params), 'apply ok');
	ok($params{problemJWT},                             'self-minted a continuation problemJWT (JWE)');
	ok(!$c->stash('_can_emit_answer_jwt'),              'no answerJWT emission on a self-minted lane');
};

subtest 'Lane::Peer (peer-signed body) does NOT set _can_emit_answer_jwt' => sub {
	my $c      = MockController->new;
	my %params = (problemSource => 'S', problemSeed => 1);
	ok(Renderer::Lane::Peer::apply_body($c, \%params), 'apply_body ok');
	ok($params{problemJWT},                            'self-minted a continuation problemJWT (JWE)');
	ok(!$c->stash('_can_emit_answer_jwt'),             'no answerJWT emission on the first peer render');
};

done_testing;
