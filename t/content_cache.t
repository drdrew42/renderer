use strict;
use warnings;

use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use Test::More;

# ContentCache reads $ENV{RENDER_ROOT} at compile time, so set it first.
my $RENDER_ROOT;
BEGIN {
	$RENDER_ROOT = tempdir(CLEANUP => 1);
	make_path(File::Spec->catdir($RENDER_ROOT, 'private'));
	$ENV{RENDER_ROOT} = $RENDER_ROOT;
}

use Renderer::ContentCache;

# --- save_url_index / pg_hash_for_url round-trip ---

subtest 'url index round-trip' => sub {
	my $url     = 'https://opl.example.com/api/problems/hash/abc123';
	my $pg_hash = 'deadbeef' x 4;

	is(Renderer::ContentCache::pg_hash_for_url($url), undef, 'url lookup returns undef before save');
	ok(Renderer::ContentCache::save_url_index($url, $pg_hash), 'save_url_index succeeds');
	is(Renderer::ContentCache::pg_hash_for_url($url), $pg_hash, 'pg_hash_for_url returns saved hash');
};

# --- save_path_index / pg_hash_for_path round-trip ---

subtest 'path index round-trip' => sub {
	my $path    = 'Library/Rochester/setDerivatives/prob1.pg';
	my $pg_hash = 'cafebabe' x 4;

	is(Renderer::ContentCache::pg_hash_for_path($path), undef, 'path lookup returns undef before save');
	ok(Renderer::ContentCache::save_path_index($path, $pg_hash), 'save_path_index succeeds');
	is(Renderer::ContentCache::pg_hash_for_path($path), $pg_hash, 'pg_hash_for_path returns saved hash');
};

# --- stage_problem + has_problem + read_problem ---

subtest 'stage and read problem' => sub {
	my $pg_hash = 'a1b2c3d4' x 4;
	my $source  = "DOCUMENT();\nloadMacros('PGstandard.pl');\nENDDOCUMENT();";

	ok(!Renderer::ContentCache::has_problem($pg_hash), 'has_problem false before staging');
	ok(Renderer::ContentCache::stage_problem($pg_hash, $source), 'stage_problem succeeds');
	ok(Renderer::ContentCache::has_problem($pg_hash), 'has_problem true after staging');

	# Verify the file was actually written
	my $expected_dir = File::Spec->catdir($RENDER_ROOT, 'private', 'problems', $pg_hash);
	ok(-d $expected_dir, 'problem directory created');
	ok(-f File::Spec->catfile($expected_dir, 'problem.pg'), 'problem.pg file exists');

	# read_problem
	my $read_back = Renderer::ContentCache::read_problem($pg_hash);
	is($read_back, $source, 'read_problem returns staged source');
};

# --- read_problem on unknown hash ---

subtest 'read_problem unknown hash' => sub {
	is(Renderer::ContentCache::read_problem('nonexistent_hash'), undef, 'read_problem returns undef for unknown hash');
};

# --- problem_path ---

subtest 'problem_path format' => sub {
	my $pg_hash = 'ff00ff00' x 4;
	is(
		Renderer::ContentCache::problem_path($pg_hash),
		"private/problems/$pg_hash/problem.pg",
		'problem_path returns expected relative path'
	);
};

# --- stage_macro (idempotent) ---

subtest 'stage_macro idempotent' => sub {
	my $hash   = 'macro_hash_001';
	my $source = 'sub myMacro { return 42; }';

	ok(Renderer::ContentCache::stage_macro($hash, $source), 'stage_macro succeeds first call');

	my $macro_path = File::Spec->catfile($RENDER_ROOT, 'private', 'macros', $hash);
	ok(-f $macro_path, 'macro file exists on disk');

	# Read back
	open my $fh, '<', $macro_path or die "Cannot read macro: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	is($content, $source, 'macro file contains expected source');

	# Second call is idempotent (returns 1 without rewriting)
	ok(Renderer::ContentCache::stage_macro($hash, 'DIFFERENT SOURCE'), 'stage_macro idempotent on second call');

	# Content unchanged
	open $fh, '<', $macro_path or die "Cannot read macro: $!";
	$content = do { local $/; <$fh> };
	close $fh;
	is($content, $source, 'macro content unchanged after idempotent call');
};

# --- stage_problem with macros creates symlinks ---

subtest 'stage_problem with macro symlinks' => sub {
	my $macro_hash = 'macro_for_symlink_test';
	my $macro_src  = 'sub linked { 1 }';
	Renderer::ContentCache::stage_macro($macro_hash, $macro_src);

	my $pg_hash = 'problem_with_macros_test';
	my $source  = "DOCUMENT();\nloadMacros('custom.pl');\nENDDOCUMENT();";
	my @macros  = ({ name => 'custom.pl', hash => $macro_hash });

	ok(Renderer::ContentCache::stage_problem($pg_hash, $source, \@macros), 'stage_problem with macros succeeds');

	my $link_path = File::Spec->catfile($RENDER_ROOT, 'private', 'problems', $pg_hash, 'custom.pl');
	ok(-l $link_path, 'symlink created for custom macro');
	ok(-f $link_path, 'symlink resolves to existing file');

	# Read through the symlink
	open my $fh, '<', $link_path or die "Cannot read through symlink: $!";
	local $/;
	my $content = <$fh>;
	close $fh;
	is($content, $macro_src, 'symlink resolves to correct macro source');
};

done_testing();
