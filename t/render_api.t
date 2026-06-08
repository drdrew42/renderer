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

# Renderer startup refuses placeholder secrets; supply test values.
$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';

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

done_testing();
