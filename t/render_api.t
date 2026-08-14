use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
# Skip gracefully if the module isn't available.
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping render_api tests';
}

use Test::Mojo;
use Crypt::JWT qw(encode_jwt);

# Renderer startup refuses placeholder secrets; supply test values.
$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';
$ENV{SITE_HOST}        //= 'https://test.example.com';

# Boot the app — Renderer.pm's BEGIN block auto-derives RENDER_ROOT.
my $t           = Test::Mojo->new('Renderer');
my $render_root = $ENV{RENDER_ROOT};

# Ensure required directories exist
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

# --- Baseline: inline problemSource ---

subtest 'render inline problemSource' => sub {
	my $pg_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl");
BEGIN_PGML
Hello world
END_PGML
ENDDOCUMENT();
PG
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			outputFormat  => 'simple',
			problemSeed   => 1234,
		}
	)->status_is(200)->content_like(qr/Hello world/i, 'rendered output contains problem text');
};

# --- Content-addressed: pre-staged cache hit ---

subtest 'render from content-addressed cache' => sub {
	# Stage a problem in the cache
	require Renderer::ContentCache;
	my $pg_hash = 'test_render_api_cached_hash';
	my $source  = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl");
BEGIN_PGML
Cached problem
END_PGML
ENDDOCUMENT();
PG
	Renderer::ContentCache::stage_problem($pg_hash, $source);
	Renderer::ContentCache::save_path_index('test/cached_problem.pg', $pg_hash);

	local $ENV{CONTENT_ADDRESSED} = 1;

	$t->post_ok(
		'/render-api' => form => {
			sourceFilePath => 'test/cached_problem.pg',
			outputFormat   => 'simple',
			problemSeed    => 5678,
		}
	)->status_is(200)->content_like(qr/Cached problem/i, 'rendered output from cached problem');
};

# --- Content-addressed: unresolvable sourceFilePath → 404 ---

subtest 'content-addressed 404 on missing sourceFilePath' => sub {
	local $ENV{CONTENT_ADDRESSED} = 1;

	$t->post_ok(
		'/render-api' => form => {
			sourceFilePath => 'nonexistent/path/to/problem.pg',
			outputFormat   => 'simple',
			problemSeed    => 9999,
		}
	)->status_is(404);
};

# --- Editor preview: problemSource + sourceFilePath both set ---
# Per resolve_source: when CONTENT_ADDRESSED is on AND sourceFilePath is
# given AND problemSource is *also* present, the renderer uses the editor's
# live source (not the cached bytes) but still resolves the path to populate
# pg_hash so cached custom macros get injected by name.

subtest 'editor preview: problemSource overrides cached source, path still resolves pg_hash' => sub {
	require Renderer::ContentCache;
	my $cached_hash   = 'test_render_api_editor_preview_hash';
	my $cached_source = "DOCUMENT();\nBEGIN_PGML\nCACHED VERSION\nEND_PGML\nENDDOCUMENT();";
	my $editor_source =
		"DOCUMENT();\nloadMacros('PGstandard.pl', 'PGML.pl');\nBEGIN_PGML\nEDITOR VERSION\nEND_PGML\nENDDOCUMENT();";

	Renderer::ContentCache::stage_problem($cached_hash, $cached_source);
	Renderer::ContentCache::save_path_index('test/editor_preview.pg', $cached_hash);

	local $ENV{CONTENT_ADDRESSED} = 1;

	$t->post_ok(
		'/render-api' => form => {
			problemSource  => $editor_source,
			sourceFilePath => 'test/editor_preview.pg',
			outputFormat   => 'simple',
			problemSeed    => 4242,
		}
	)->status_is(200)->content_like(qr/EDITOR VERSION/i, 'editor source rendered (not the cached bytes)')
		->content_unlike(qr/CACHED VERSION/i, 'cached source not used when editor source supplied');
};

# ─── R50 guard: a bad-credential problemJWT is a 401, not a 500 ──────────────
#
# Lane::Problem verifies aud (and the signature) before any lane logic. A caller
# presenting a wrong-audience or wrong-signature token is a client error — 401,
# not 500 — and the response names which failure it is so an integrator can tell
# "fix your token" from "the renderer broke". Before WW3-R50 these routed through
# croak, which hardcoded 500. Guards the credential_error mapping directly.
subtest 'a bad-credential problemJWT is a 401, not a 500 (WW3-R50)' => sub {
	my %as_json = (Accept => 'application/json');

	# Wrong audience: signed correctly, but aud != SITE_HOST.
	my $wrong_aud = encode_jwt(
		payload  => { aud => 'https://someone-else.example', problemSourceURL => 'https://x/y' },
		key      => $ENV{problemJWTsecret},
		alg      => 'HS256',
		auto_iat => 1,
	);
	$t->post_ok('/render-api' => \%as_json => form => { problemJWT => $wrong_aud, outputFormat => 'simple' })
		->status_is(401)
		->json_like('/message', qr/audience/i, 'wrong aud → 401, naming the audience failure');

	# Wrong signature: right aud, signed with a key the renderer does not hold.
	my $bad_sig = encode_jwt(
		payload  => { aud => $ENV{SITE_HOST}, problemSourceURL => 'https://x/y' },
		key      => 'not-the-renderers-secret',
		alg      => 'HS256',
		auto_iat => 1,
	);
	$t->post_ok('/render-api' => \%as_json => form => { problemJWT => $bad_sig, outputFormat => 'simple' })
		->status_is(401, 'bad signature → 401, not 500');
};

done_testing();
