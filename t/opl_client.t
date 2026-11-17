use strict;
use warnings;

use Test::More;
use Mojo::UserAgent;

use Renderer::OPLClient;

# Unit tests for the URL-template + base_url normalization layer of
# Renderer::OPLClient. The fetch_problem_p / fetch_macro integration paths
# are exercised end-to-end by the controller-level suites (render_api.t,
# content_cache.t, render_callback.t) — those go through the real
# controller and the real UA, which is the more realistic regression
# coverage. Direct integration tests against an in-process Mojo daemon are
# brittle in this codebase (loop-reentrancy interactions between
# Mojo::Server::Daemon and the sync $ua->get used by fetch_macro), and the
# duplicated coverage doesn't justify the test infrastructure.
#
# What's covered here: anything the OPL contract itself encodes that
# doesn't require live HTTP — URL templates, base_url normalization.

my $ua     = Mojo::UserAgent->new;
my $client = Renderer::OPLClient->new(
	ua       => $ua,
	base_url => 'http://opl.test:3000',
);

# ─── URL templates ─────────────────────────────────────────────────────────

subtest 'problem_url_by_hash builds the documented endpoint shape' => sub {
	is(
		$client->problem_url_by_hash('sha256:abc123'),
		'http://opl.test:3000/api/problems/hash/sha256:abc123',
		'expected URL',
	);
};

subtest 'problem_url_by_path builds the documented endpoint shape' => sub {
	is(
		$client->problem_url_by_path('Library/Foo/Bar.pg'),
		'http://opl.test:3000/api/problems/path/Library/Foo/Bar.pg',
		'expected URL',
	);
};

subtest 'base_url trailing slash is stripped at construction' => sub {
	my $client_with_slash = Renderer::OPLClient->new(
		ua       => $ua,
		base_url => 'http://opl.test:3000/',
	);
	is(
		$client_with_slash->problem_url_by_hash('sha256:abc'),
		'http://opl.test:3000/api/problems/hash/sha256:abc',
		'no double slash between base and template path',
	);
};

subtest 'base_url multiple trailing slashes stripped' => sub {
	my $messy = Renderer::OPLClient->new(
		ua       => $ua,
		base_url => 'http://opl.test:3000///',
	);
	is(
		$messy->problem_url_by_hash('sha256:abc'),
		'http://opl.test:3000/api/problems/hash/sha256:abc',
		'all trailing slashes normalized away',
	);
};

# ─── Default base_url ──────────────────────────────────────────────────────

subtest 'default base_url is the production OPL hostname' => sub {
	# Verifies the documented contract for the no-arg constructor.
	# Production renderer overrides this via OPL_API_URL env var; the
	# fallback should match the docker-compose service hostname expected
	# by deployments that don't set it.
	my $client_default = Renderer::OPLClient->new(ua => $ua);
	is(
		$client_default->problem_url_by_hash('x'),
		'http://webwork-opl:3000/api/problems/hash/x',
		'default base_url is webwork-opl:3000',
	);
};

# ─── fetch_problem_p resources passthrough (WW3-R78) ───────────────────────
#
# A stub UA answers get_p with a canned 200 body, so the parse path runs
# without HTTP.

{

	package StubTx;
	sub new    { my ($class, $body) = @_; bless { body => $body }, $class }
	sub result { $_[0] }
	sub code       {200}
	sub is_success {1}
	sub message    {'OK'}
	sub body       { $_[0]{body} }
	sub headers    { bless {}, 'StubHeaders' }

	package StubHeaders;
	sub header { undef }

	package StubUA;
	sub new { my ($class, $body) = @_; bless { body => $body }, $class }
	sub max_redirects  { $_[0] }
	sub request_timeout { $_[0] }
	sub get_p {
		my ($self) = @_;
		return Mojo::Promise->resolve(StubTx->new($self->{body}));
	}
}

sub fetch_with_body {
	my ($body) = @_;
	my $stub   = StubUA->new($body);
	my $c      = Renderer::OPLClient->new(ua => $stub, base_url => 'http://opl.test:3000');
	my $result;
	$c->fetch_problem_p('http://opl.test:3000/api/problems/hash/sha256:abc')->then(sub { $result = shift })->wait;
	return $result;
}

subtest 'fetch_problem_p passes resources through with content_hash and alt' => sub {
	my $hash = 'sha256:' . ('a' x 64);
	my $body = Mojo::JSON::encode_json({
		raw_source => 'DOCUMENT(); ENDDOCUMENT();',
		pg_hash    => 'sha256:abc',
		macros     => [],
		resources  => [
			{ content_hash => $hash, alt => 'A parabola', mime => 'image/png', filename => 'q1.png' },
			{ content_hash => 'sha256:' . ('b' x 64), alt => undef },
		],
	});
	my $r = fetch_with_body($body);
	ok(!$r->{error}, 'no error');
	is_deeply(
		$r->{resources},
		[
			{ content_hash => $hash, alt => 'A parabola', mime => 'image/png', filename => 'q1.png' },
			{ content_hash => 'sha256:' . ('b' x 64), alt => undef },
		],
		'resources array passed through unchanged',
	);
};

subtest 'fetch_problem_p yields [] resources when the response omits them' => sub {
	my $body = Mojo::JSON::encode_json({
		raw_source => 'DOCUMENT(); ENDDOCUMENT();',
		pg_hash    => 'sha256:abc',
	});
	my $r = fetch_with_body($body);
	ok(!$r->{error}, 'no error');
	is_deeply($r->{resources}, [], 'missing resources defaults to []');
};

done_testing();
