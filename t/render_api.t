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
my $t = Test::Mojo->new('Renderer');
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
	$t->post_ok('/render-api' => form => {
		problemSource => $pg_source,
		outputFormat  => 'simple',
		problemSeed   => 1234,
	})
		->status_is(200)
		->content_like(qr/Hello world/i, 'rendered output contains problem text');
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

	$t->post_ok('/render-api' => form => {
		sourceFilePath => 'test/cached_problem.pg',
		outputFormat   => 'simple',
		problemSeed    => 5678,
	})
		->status_is(200)
		->content_like(qr/Cached problem/i, 'rendered output from cached problem');
};

# --- Content-addressed: unresolvable sourceFilePath → 404 ---

subtest 'content-addressed 404 on missing sourceFilePath' => sub {
	local $ENV{CONTENT_ADDRESSED} = 1;

	$t->post_ok('/render-api' => form => {
		sourceFilePath => 'nonexistent/path/to/problem.pg',
		outputFormat   => 'simple',
		problemSeed    => 9999,
	})
		->status_is(404);
};

done_testing();
