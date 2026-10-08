use strict;
use warnings;

use Test::More;
use FindBin;
use File::Temp qw(tempdir);
use File::Path qw(make_path);
use Crypt::JWT qw(encode_jwt decode_jwt);

# Session-claim precedence (WW3-205, contract C4): every claim in a verified
# sessionJWT beats a raw param of the same name, except the student's answer
# fields — the answer labels a problem-lane session keeps from PG's
# KEPT_EXTRA_ANSWERS — where the current render's raw answer wins.
#
# Lane::Session tells the two apart by SESSION_STATE_CLAIMS: the claims the
# minters write as session state. Part 1 pins that list to the minters in both
# directions; Part 2 drives Lane::Session::apply_prefix host-side through a
# MockController. No app boot, no PG render.

BEGIN {
	$ENV{PG_ROOT} //= "$FindBin::Bin/../lib/PG";
	my $root = tempdir(CLEANUP => 1);
	make_path("$root/logs");
	$ENV{RENDER_ROOT} //= $root;
}

use lib 'lib';
require WeBWorK::RenderProblem;
use WeBWorK::VerdictJWT     qw(verifyAndFoldVerdict verifyAndFoldLaunchVerdict);
use Renderer::Constants     qw(SESSION_STATE_CLAIMS);
use Renderer::Lane::Session ();

$ENV{problemJWTsecret} = 'test-problem-secret';
$ENV{webworkJWTsecret} = 'test-session-secret';
$ENV{SITE_HOST}        = 'https://render.test';

{

	package MockLog;
	sub new   { bless {}, shift }
	sub info  { }
	sub warn  { }
	sub error { }

	package MockController;
	sub new { bless { stash => {}, rejected => undef }, shift }
	sub log { $_[0]{log} //= MockLog->new }

	sub stash {
		my $self = shift;
		return $self->{stash}{ $_[0] } if @_ == 1;
		my %kv = @_;
		@{ $self->{stash} }{ keys %kv } = values %kv;
		return $self;
	}
	sub credential_error { $_[0]{rejected} = { err => $_[1] };                  return undef }
	sub exception        { $_[0]{rejected} = { msg => $_[1], status => $_[2] }; return undef }
}

my %LIST = map { $_ => 1 } SESSION_STATE_CLAIMS;

# Answer labels as PG names them: plain, MathQuill twin, a matrix cell, and a
# NAMED_ANS label with no prefix at all.
my @KEPT = qw(AnSwEr0001 MaThQuIlL_AnSwEr0001 MaTrIx_AnSwEr0002_0_1 named_ans);

sub problem_jwt {
	return encode_jwt(
		payload => { aud => $ENV{SITE_HOST}, iss => $ENV{SITE_HOST}, problemSeed => 7 },
		key     => $ENV{problemJWTsecret},
		alg     => 'HS256',
	);
}

sub challenge_jwt {
	return encode_jwt(
		payload => { aud => $ENV{SITE_HOST}, play_id => 'p-1', problems => [], answer_url => 'https://o.test/a' },
		key     => $ENV{problemJWTsecret},
		alg     => 'HS256',
	);
}

sub verdict_jwt {
	my (%args) = @_;
	return encode_jwt(
		payload => {
			play_id             => 'p-1',
			mint_sequence_basis => $args{basis} // 0,
			verdict => { current_focus => 0, next_available => [0], draw_next => undef, finalization => undef },
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

sub claims_of { decode_jwt(token => $_[0], key => $ENV{webworkJWTsecret}) }

# Every session shape the renderer mints.
my %minted;
{
	my $pg = {
		flags          => { KEPT_EXTRA_ANSWERS => [@KEPT] },
		problem_result => { score              => 1 },
		problem_state  => { num_of_correct_ans => 1, num_of_incorrect_ans => 0 },
		answers        => {},
	};
	my %inputs = (
		problemJWT   => problem_jwt(),
		pg_hash      => 'sha256:p',
		problemUUID  => 'uuid-1',
		sessionID    => 's-1',
		JWTanswerURL => 'https://lms.test/answer',
		map { $_ => "v-$_" } @KEPT
	);
	my ($session) = WeBWorK::RenderProblem::generateJWTs($pg, \%inputs);
	$minted{problem} = claims_of($session);

	$minted{play} = claims_of(WeBWorK::RenderProblem::generatePlaySessionJWT(
		{}, { challengeJWT => challenge_jwt(), state => {}, mint_sequence => 0 }
	));

	my ($launch, $err) =
		verifyAndFoldLaunchVerdict(challenge_jwt(), verdict_jwt(), $ENV{problemJWTsecret}, $ENV{webworkJWTsecret});
	die $err if $err;
	$minted{launch} = claims_of($launch);

	my ($folded, $ferr) =
		verifyAndFoldVerdict($launch, verdict_jwt(basis => 1), $ENV{problemJWTsecret}, $ENV{webworkJWTsecret});
	die $ferr if $ferr;
	$minted{fold} = claims_of($folded);
}

# ─── Part 1: SESSION_STATE_CLAIMS ↔ the minters ──────────────────────────────

subtest 'every non-answer claim a minter writes is a session-state claim' => sub {
	my %kept = map { $_ => 1 } @KEPT;
	for my $shape (sort keys %minted) {
		my @unlisted = grep { !$LIST{$_} && !$kept{$_} } sort keys %{ $minted{$shape} };
		is_deeply(\@unlisted, [], "$shape session: no unlisted state claim");
	}
	ok(!$LIST{$_}, "$_ is an answer field, not a state claim") for @KEPT;
};

subtest 'every session-state claim is one a minter writes (or a held-over trust claim)' => sub {
	my %written = map {%$_} values %minted;
	my @unwritten =
		grep { !exists $written{$_} } grep { $_ ne 'isInstructor' } SESSION_STATE_CLAIMS;
	is_deeply(\@unwritten, [], 'no stale entries in SESSION_STATE_CLAIMS');
};

# ─── Part 2: apply_prefix precedence ─────────────────────────────────────────

sub problem_session {
	my (%claims) = @_;
	return encode_jwt(
		payload => {
			iss              => $ENV{SITE_HOST},
			answersSubmitted => 1,
			problemJWT       => problem_jwt(),
			pg_hash          => 'sha256:session',
			problemUUID      => 'uuid-session',
			AnSwEr0001       => 'prior',
			named_ans        => 'prior-named',
			%claims,
		},
		key => $ENV{webworkJWTsecret},
		alg => 'HS256',
	);
}

subtest 'raw answers beat the session\'s kept answers' => sub {
	my $c      = MockController->new;
	my %params = (sessionJWT => problem_session(), AnSwEr0001 => 'current', named_ans => 'current-named');
	ok(Renderer::Lane::Session::apply_prefix($c, \%params), 'apply_prefix ok');
	is($params{AnSwEr0001}, 'current',       'raw AnSwEr0001 wins');
	is($params{named_ans},  'current-named', 'raw named answer label wins');
};

subtest 'a kept answer fills in when the render sends none' => sub {
	my $c      = MockController->new;
	my %params = (sessionJWT => problem_session());
	ok(Renderer::Lane::Session::apply_prefix($c, \%params), 'apply_prefix ok');
	is($params{AnSwEr0001}, 'prior', 'session answer restored');
};

subtest 'session-state claims beat raw params of the same name' => sub {
	my $c      = MockController->new;
	my %params = (
		sessionJWT       => problem_session(),
		pg_hash          => 'sha256:raw',
		problemUUID      => 'uuid-raw',
		answersSubmitted => 0,
	);
	ok(Renderer::Lane::Session::apply_prefix($c, \%params), 'apply_prefix ok');
	is($params{pg_hash},          'sha256:session', 'session pg_hash wins');
	is($params{problemUUID},      'uuid-session',   'session problemUUID wins');
	is($params{answersSubmitted}, 1,                'session answersSubmitted wins');
};

subtest 'a play session\'s state and mint_sequence beat raw' => sub {
	my $session = encode_jwt(
		payload => {
			challenge_jwt => challenge_jwt(),
			state         => { draws => [ { draw_position => 0, seed => 1 } ] },
			mint_sequence => 3,
		},
		key => $ENV{webworkJWTsecret},
		alg => 'HS256',
	);
	my $c      = MockController->new;
	my %params = (sessionJWT => $session, state => 'raw', mint_sequence => 99);
	ok(Renderer::Lane::Session::apply_prefix($c, \%params), 'apply_prefix ok');
	is(ref $params{state},     'HASH',          'session state wins');
	is($params{mint_sequence}, 3,               'session mint_sequence wins');
	is($params{challengeJWT},  challenge_jwt(), 'embedded challenge_jwt hoisted');
};

subtest 'the LTW-088 source sidecar still overrides the nested problemJWT' => sub {
	my $c       = MockController->new;
	my $sidecar = encode_jwt(
		payload => { aud => $ENV{SITE_HOST}, problemSourceURL => 'https://opl.test/new.pg' },
		key     => $ENV{problemJWTsecret},
		alg     => 'HS256',
	);
	my %params = (sessionJWT => problem_session(), problemJWT => $sidecar);
	ok(Renderer::Lane::Session::apply_prefix($c, \%params), 'apply_prefix ok');
	is($params{problemJWT},              problem_jwt(), 'nested problemJWT is the body token');
	is($c->stash('_sidecar_problemJWT'), $sidecar,      'differing sidecar stashed for the source override');
};

done_testing();
