use Mojo::Base -strict, -signatures;
use Test::More;

# Subtest names contain Unicode (→) — encode TAP output as UTF-8.
binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
binmode Test::More->builder->todo_output,    ':encoding(UTF-8)';

use Mojolicious::Lite;
use Mojo::UserAgent;
use Mojo::Log;

use lib 'lib';
use Renderer::OPLClient;

# WW3-R39 Phase 2 — exercise OPLClient's conditional-GET (304 handling)
# and macro-fetch redirect canonicalization. Both are protocol-correctness
# concerns in OPLClient that previously had no test coverage.

# ─── Mock OPL ────────────────────────────────────────────────────────────
# Tiny inline app that pretends to be the OPL HTTP API. Mounted via
# $ua->server->app(...), so requests are dispatched in-process — no
# network, no port binding.

# Problem-by-hash with conditional GET. If If-None-Match matches the hash,
# return 304; else return the canonical 200 envelope.
get '/api/problems/hash/:pg_hash' => sub ($c) {
	my $pg_hash = $c->stash('pg_hash');
	my $etag    = $c->req->headers->header('If-None-Match') // '';
	return $c->rendered(304) if $etag && $etag eq $pg_hash;
	return $c->render(
		json => {
			raw_source => "DOCUMENT(); # source for $pg_hash\nENDDOCUMENT();",
			pg_hash    => $pg_hash,
			macros     => [],
		}
	);
};

# Macro fetch: name-form 302→hash-form. Hash-form returns the macro source.
# Canonical hashes are sha256:[0-9a-f]+ — the regex in OPLClient enforces
# that shape when extracting from the final URL. `*name` (wildcard) matches
# names containing dots (`.pl` etc.) which would otherwise be parsed as a
# format suffix by `:name`.
my $canonical_for_name = 'sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcd';
get '/api/macros/*name' => sub ($c) {
	my $name = $c->stash('name');
	return $c->redirect_to("/api/macros/$canonical_for_name")
		unless $name =~ /^sha256:/;
	return $c->render(text => "# macro source for $name\nsub mocked { 1 }");
};

my $ua = Mojo::UserAgent->new;
$ua->server->app(app);

my $client = Renderer::OPLClient->new(
	ua       => $ua,
	base_url => '',
	log      => Mojo::Log->new(level => 'fatal'),
);

# ─── Conditional GET: 304 path ────────────────────────────────────────────

subtest 'fetch_problem_p with matching etag → not_modified=1' => sub {
	my $hash = 'sha256:abc123';
	my $url  = "/api/problems/hash/$hash";

	my $result = $client->fetch_problem_p($url, etag => $hash)->wait;
	# Mojo::Promise->wait blocks until resolution; returns the resolved
	# value(s) as an array. Single-result promises return the value.
	# For consistency we re-resolve through ->wait() and capture via ->then.

	my $captured;
	$client->fetch_problem_p($url, etag => $hash)->then(sub { $captured = shift })->wait;
	is_deeply($captured, { not_modified => 1 }, '304 returns not_modified=1 only');
};

subtest 'fetch_problem_p without etag → full 200 response' => sub {
	my $hash = 'sha256:def456';
	my $url  = "/api/problems/hash/$hash";

	my $captured;
	$client->fetch_problem_p($url)->then(sub { $captured = shift })->wait;

	is($captured->{pg_hash}, $hash, 'pg_hash echoed');
	like($captured->{raw_source}, qr/source for $hash/, 'raw_source delivered');
	is_deeply($captured->{macros}, [], 'macros array present and empty');
	ok(!exists $captured->{not_modified}, 'no not_modified flag on 200');
};

subtest 'fetch_problem_p with non-matching etag → 200 (cache miss)' => sub {
	my $hash = 'sha256:fresh-hash';
	my $url  = "/api/problems/hash/$hash";

	my $captured;
	$client->fetch_problem_p($url, etag => 'sha256:stale-hash')->then(sub { $captured = shift })->wait;

	is($captured->{pg_hash}, $hash, 'fresh hash returned (mock honors If-None-Match)');
	ok(!$captured->{not_modified}, 'no not_modified when etag differs');
};

# ─── Macro redirect canonicalization ──────────────────────────────────────

subtest 'fetch_macro: name-form URL redirects to hash-form, canonical hash returned' => sub {
	my ($body, $canonical_hash) = $client->fetch_macro('/api/macros/contextSomething.pl');

	like($body, qr/macro source for $canonical_for_name/, 'body comes from final (hash-form) URL');
	is($canonical_hash, $canonical_for_name, 'canonical hash extracted from final URL after redirect');
};

subtest 'fetch_macro: hash-form URL stays as-is' => sub {
	my $direct_hash = 'sha256:fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210';
	my ($body, $canonical_hash) = $client->fetch_macro("/api/macros/$direct_hash");

	like($body, qr/macro source for $direct_hash/, 'body delivered');
	is($canonical_hash, $direct_hash, 'hash extracted directly when no redirect needed');
};

done_testing();
