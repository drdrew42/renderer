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

my $render_root = $ENV{RENDER_ROOT};
die "RENDER_ROOT not set" unless $render_root;

# Ensure required directories exist
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

my $t = Test::Mojo->new('Renderer');

# --- Baseline: inline problemSource ---

subtest 'render inline problemSource' => sub {
	$t->post_ok('/render-api' => form => {
		problemSource => 'DOCUMENT(); loadMacros("PGstandard.pl","PGML.pl"); BEGIN_PGML Hello world END_PGML ENDDOCUMENT();',
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
	my $source  = 'DOCUMENT(); loadMacros("PGstandard.pl","PGML.pl"); BEGIN_PGML Cached problem END_PGML ENDDOCUMENT();';
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
