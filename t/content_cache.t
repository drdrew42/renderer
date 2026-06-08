use strict;
use warnings;

use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use Mojo::JSON;
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

	ok(!Renderer::ContentCache::has_problem($pg_hash),           'has_problem false before staging');
	ok(Renderer::ContentCache::stage_problem($pg_hash, $source), 'stage_problem succeeds');
	ok(Renderer::ContentCache::has_problem($pg_hash),            'has_problem true after staging');

	# Verify the file was actually written
	my $expected_dir = File::Spec->catdir($RENDER_ROOT, 'private', 'problems', $pg_hash);
	ok(-d $expected_dir,                                    'problem directory created');
	ok(-f File::Spec->catfile($expected_dir, 'problem.pg'), 'problem.pg file exists');

	# read_problem
	my $read_back = Renderer::ContentCache::read_problem($pg_hash);
	is($read_back, $source, 'read_problem returns staged source');
};

# --- read_problem on unknown hash ---

subtest 'read_problem unknown hash' => sub {
	is(Renderer::ContentCache::read_problem('nonexistent_hash'),
		undef, 'read_problem returns undef for unknown hash');
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

# --- stage_problem writes a manifest.json (WW3-R11) ---

subtest 'stage_problem writes manifest.json with macro entries' => sub {
	my $macro1_hash = 'macro_manifest_test_1';
	my $macro1_src  = 'sub one { 1 }';
	my $macro2_hash = 'macro_manifest_test_2';
	my $macro2_src  = 'sub two { 2 }';
	Renderer::ContentCache::stage_macro($macro1_hash, $macro1_src);
	Renderer::ContentCache::stage_macro($macro2_hash, $macro2_src);

	my $pg_hash = 'problem_manifest_test';
	my $source  = "DOCUMENT();\nloadMacros('custom.pl', 'override.pl');\nENDDOCUMENT();";
	my @macros  = (
		{ name => 'custom.pl',   hash => $macro1_hash, source_type => 'custom' },
		{ name => 'override.pl', hash => $macro2_hash, source_type => 'override' },
	);

	ok(Renderer::ContentCache::stage_problem($pg_hash, $source, \@macros), 'stage_problem succeeds');

	# Manifest written, JSON parse, expected shape
	my $manifest_path = File::Spec->catfile($RENDER_ROOT, 'private', 'problems', $pg_hash, 'manifest.json');
	ok(-f $manifest_path,        'manifest.json exists');
	ok(!-f "$manifest_path.tmp", 'tmp file was renamed away (atomic install)');

	open my $fh, '<', $manifest_path or die "Cannot read manifest: $!";
	local $/;
	my $body = <$fh>;
	close $fh;
	my $parsed = Mojo::JSON::decode_json($body);
	is(ref $parsed,               'ARRAY',       'manifest is a JSON array');
	is(scalar @$parsed,           2,             'two entries');
	is($parsed->[0]{name},        'custom.pl',   'order preserved (entry 0)');
	is($parsed->[1]{name},        'override.pl', 'order preserved (entry 1)');
	is($parsed->[0]{source_type}, 'custom',      'source_type captured verbatim (entry 0)');
	is($parsed->[1]{source_type}, 'override',    'source_type captured verbatim (entry 1)');

	# Reader returns macros injected by name
	my $injected = Renderer::ContentCache::get_injected_macros($pg_hash);
	is($injected->{'custom.pl'},   $macro1_src, 'manifest reader resolves entry 0');
	is($injected->{'override.pl'}, $macro2_src, 'manifest reader resolves entry 1');
};

# Capturing source_type verbatim — even values the renderer's filter doesn't
# currently act on land in the manifest. (See `_parse_and_stage_response` for
# the filter that decides which source_types get fetched + staged in the
# first place; entries that arrive here have already passed that filter.)
subtest 'stage_problem omits source_type field when not provided' => sub {
	my $macro_hash = 'macro_no_source_type';
	my $macro_src  = 'sub plain { 1 }';
	Renderer::ContentCache::stage_macro($macro_hash, $macro_src);

	my $pg_hash = 'problem_no_source_type';
	my $source  = 'DOCUMENT(); ENDDOCUMENT();';
	my @macros  = ({ name => 'plain.pl', hash => $macro_hash });

	ok(Renderer::ContentCache::stage_problem($pg_hash, $source, \@macros), 'stage_problem succeeds');

	my $manifest_path = File::Spec->catfile($RENDER_ROOT, 'private', 'problems', $pg_hash, 'manifest.json');
	open my $fh, '<', $manifest_path or die "Cannot read manifest: $!";
	local $/;
	my $body = <$fh>;
	close $fh;
	my $parsed = Mojo::JSON::decode_json($body);
	ok(!exists $parsed->[0]{source_type}, 'source_type absent when caller did not supply it');
};

# --- sweep: TTL-based eviction (WW3-R39 Phase 1) ---

subtest 'sweep evicts stale problem dirs and their index entries' => sub {
	my $stale_hash = 'stale_problem_for_sweep';
	my $fresh_hash = 'fresh_problem_for_sweep';
	my $stale_url  = 'https://opl.example.com/api/problems/hash/stale';
	my $fresh_url  = 'https://opl.example.com/api/problems/hash/fresh';
	my $stale_path = 'Library/Sweep/stale.pg';
	my $fresh_path = 'Library/Sweep/fresh.pg';

	# Stage two problems + index entries pointing to each
	Renderer::ContentCache::stage_problem($stale_hash, 'DOCUMENT(); ENDDOCUMENT();');
	Renderer::ContentCache::stage_problem($fresh_hash, 'DOCUMENT(); ENDDOCUMENT();');
	Renderer::ContentCache::save_url_index($stale_url, $stale_hash);
	Renderer::ContentCache::save_url_index($fresh_url, $fresh_hash);
	Renderer::ContentCache::save_path_index($stale_path, $stale_hash);
	Renderer::ContentCache::save_path_index($fresh_path, $fresh_hash);

	# Backdate the stale problem dir to 200h ago (past the 168h default TTL)
	my $stale_dir = File::Spec->catdir($RENDER_ROOT, 'private', 'problems', $stale_hash);
	my $past      = time - (200 * 3600);
	utime($past, $past, $stale_dir) or die "utime failed: $!";

	my $evicted = Renderer::ContentCache::sweep();

	ok($evicted >= 1,                                                           'sweep reports >=1 evicted dir');
	ok(!-d $stale_dir,                                                          'stale problem dir removed');
	ok(-d File::Spec->catdir($RENDER_ROOT, 'private', 'problems', $fresh_hash), 'fresh problem dir untouched');

	# Index entries pointing to the evicted hash also gone
	is(Renderer::ContentCache::pg_hash_for_url($stale_url),   undef, 'stale url_index entry swept');
	is(Renderer::ContentCache::pg_hash_for_path($stale_path), undef, 'stale path_index entry swept');

	# Index entries for the fresh hash preserved
	is(Renderer::ContentCache::pg_hash_for_url($fresh_url),   $fresh_hash, 'fresh url_index preserved');
	is(Renderer::ContentCache::pg_hash_for_path($fresh_path), $fresh_hash, 'fresh path_index preserved');
};

subtest 'sweep on empty cache is a no-op' => sub {
	# Idempotent and safe even if nothing to evict
	my $evicted = Renderer::ContentCache::sweep(max_age_hours => 9_999_999);
	is($evicted, 0, 'sweep returns 0 when nothing is stale');
};

# --- invalidate: targeted single-hash removal (WW3-R39 Phase 1) ---

subtest 'invalidate removes problem dir and both index entries' => sub {
	my $hash = 'problem_to_invalidate';
	my $url  = 'https://opl.example.com/api/problems/hash/invalidate-me';
	my $path = 'Library/Invalidate/target.pg';

	Renderer::ContentCache::stage_problem($hash, 'DOCUMENT(); ENDDOCUMENT();');
	Renderer::ContentCache::save_url_index($url, $hash);
	Renderer::ContentCache::save_path_index($path, $hash);

	my $dir = File::Spec->catdir($RENDER_ROOT, 'private', 'problems', $hash);
	ok(-d $dir, 'sanity: problem dir exists pre-invalidate');

	ok(Renderer::ContentCache::invalidate($hash), 'invalidate returns truthy');
	ok(!-d $dir,                                  'problem dir removed');
	is(Renderer::ContentCache::pg_hash_for_url($url),   undef, 'url_index entry removed');
	is(Renderer::ContentCache::pg_hash_for_path($path), undef, 'path_index entry removed');
};

subtest 'invalidate leaves unrelated entries alone' => sub {
	my $target_hash    = 'target_for_partial_invalidate';
	my $bystander_hash = 'bystander_for_partial_invalidate';
	my $bystander_url  = 'https://opl.example.com/api/problems/hash/bystander';

	Renderer::ContentCache::stage_problem($target_hash,    'DOCUMENT(); ENDDOCUMENT();');
	Renderer::ContentCache::stage_problem($bystander_hash, 'DOCUMENT(); ENDDOCUMENT();');
	Renderer::ContentCache::save_url_index($bystander_url, $bystander_hash);

	Renderer::ContentCache::invalidate($target_hash);

	ok(-d File::Spec->catdir($RENDER_ROOT, 'private', 'problems', $bystander_hash),
		'bystander problem dir untouched');
	is(Renderer::ContentCache::pg_hash_for_url($bystander_url),
		$bystander_hash, 'bystander url_index entry preserved');
};

subtest 'invalidate on unknown hash returns 0' => sub {
	is(Renderer::ContentCache::invalidate('does_not_exist'), 0, 'invalidate returns 0 for absent dir');
};

done_testing();
