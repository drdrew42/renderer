use strict;
use warnings;

use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use Test::More;

# WW3-R42: verify_consistent + find_problems_using_macro.
# ContentCache reads $ENV{RENDER_ROOT} at compile time — set before use.
my $RENDER_ROOT;
BEGIN {
	$RENDER_ROOT = tempdir(CLEANUP => 1);
	make_path(File::Spec->catdir($RENDER_ROOT, 'private'));
	$ENV{RENDER_ROOT} = $RENDER_ROOT;
}

use Renderer::ContentCache;

sub _stage_problem_with_macros {
	my ($pg_hash, $source, $macros) = @_;
	for my $m (@$macros) {
		Renderer::ContentCache::stage_macro($m->{hash}, $m->{source} // "sub x { 1 }");
	}
	my @link = map { { name => $_->{name}, hash => $_->{hash}, source_type => 'custom' } } @$macros;
	Renderer::ContentCache::stage_problem($pg_hash, $source, \@link);
}

subtest 'verify_consistent: happy path → ok=1' => sub {
	my $pg = 'consistent_happy_path';
	my $src = "loadMacros('a.pl','b.pl');";
	_stage_problem_with_macros($pg, $src, [
		{ name => 'a.pl', hash => 'sha256:aaa1' },
		{ name => 'b.pl', hash => 'sha256:bbb1' },
	]);
	my ($ok, $report) = Renderer::ContentCache::verify_consistent($pg);
	ok($ok, 'consistent cache reports ok=1');
	is(scalar @{ $report->{macros_missing_from_disk} },    0, 'no missing files');
	is(scalar @{ $report->{load_macros_not_in_manifest} }, 0, 'no source/manifest gap');
	is_deeply($report->{source_load_macros}, ['a.pl','b.pl'], 'source loadMacros parsed');
};

subtest 'verify_consistent: macro file missing → ok=0' => sub {
	my $pg = 'consistent_missing_macro_file';
	my $src = "loadMacros('a.pl','b.pl');";
	_stage_problem_with_macros($pg, $src, [
		{ name => 'a.pl', hash => 'sha256:aaa2' },
		{ name => 'b.pl', hash => 'sha256:bbb2' },
	]);
	# Simulate invalidate_macro deleting one of the files.
	unlink File::Spec->catfile($RENDER_ROOT, 'private', 'macros', 'sha256:bbb2');

	my ($ok, $report) = Renderer::ContentCache::verify_consistent($pg);
	ok(!$ok, 'cache with missing macro file reports ok=0');
	is_deeply($report->{macros_missing_from_disk}, ['sha256:bbb2'], 'missing hash flagged');
	is_deeply($report->{macros_on_disk},           ['sha256:aaa2'], 'remaining hash on disk');
};

subtest 'verify_consistent: source loadMacros mentions name not in manifest → informational, not fatal' => sub {
	# Standard macros (PGstandard.pl, PGML.pl, ...) are normally absent from
	# the manifest (only custom/override get linked). load_macros_not_in_manifest
	# is therefore informational: surfaced for the admin inspect endpoint and
	# operator review, but cannot drive eviction without false-positiving on
	# every problem that loads a standard macro.
	my $pg = 'consistent_source_drift';
	my $src = "loadMacros('a.pl','b.pl','PGstandard.pl');";
	_stage_problem_with_macros($pg, $src, [
		{ name => 'a.pl', hash => 'sha256:aaa3' },
		{ name => 'b.pl', hash => 'sha256:bbb3' },
	]);
	my ($ok, $report) = Renderer::ContentCache::verify_consistent($pg);
	ok($ok, 'name-in-source-but-not-manifest is not fatal (could be a standard macro)');
	is_deeply($report->{load_macros_not_in_manifest}, ['PGstandard.pl'],
		'drift surfaces in informational field for human review');
};

subtest 'verify_consistent: nonexistent pg_hash → reason no_problem_dir' => sub {
	my ($ok, $report) = Renderer::ContentCache::verify_consistent('does_not_exist');
	ok(!$ok, 'nonexistent → ok=0');
	is($report->{reason}, 'no_problem_dir', 'reason surfaced');
};

subtest 'verify_consistent: missing manifest.json → reason no_manifest' => sub {
	my $pg = 'consistent_no_manifest';
	my $dir = File::Spec->catdir($RENDER_ROOT, 'private', 'problems', $pg);
	make_path($dir);
	# create problem.pg but no manifest.json
	open my $fh, '>', File::Spec->catfile($dir, 'problem.pg') or die $!;
	print $fh "DOCUMENT();";
	close $fh;

	my ($ok, $report) = Renderer::ContentCache::verify_consistent($pg);
	ok(!$ok, 'no manifest → ok=0');
	is($report->{reason}, 'no_manifest', 'reason surfaced');
};

subtest 'find_problems_using_macro: returns pg_hashes referencing the macro' => sub {
	# Two problems share macro X; one references only Y.
	_stage_problem_with_macros('fpum_p1', "loadMacros('x.pl');", [
		{ name => 'x.pl', hash => 'sha256:fpum_x' },
	]);
	_stage_problem_with_macros('fpum_p2', "loadMacros('x.pl');", [
		{ name => 'x.pl', hash => 'sha256:fpum_x' },
	]);
	_stage_problem_with_macros('fpum_p3', "loadMacros('y.pl');", [
		{ name => 'y.pl', hash => 'sha256:fpum_y' },
	]);

	my $hits = Renderer::ContentCache::find_problems_using_macro('sha256:fpum_x');
	my %h = map { $_ => 1 } @$hits;
	ok($h{fpum_p1}, 'p1 found');
	ok($h{fpum_p2}, 'p2 found');
	ok(!$h{fpum_p3}, 'p3 not found (uses different macro)');
};

subtest 'find_problems_using_macro: unknown hash → empty' => sub {
	my $hits = Renderer::ContentCache::find_problems_using_macro('sha256:never_seen');
	is_deeply($hits, [], 'no hits');
};

subtest 'get_injected_macros: drops missing-file entries (loud, not fatal)' => sub {
	my $pg = 'inj_drop_missing';
	_stage_problem_with_macros($pg, "loadMacros('a.pl','b.pl');", [
		{ name => 'a.pl', hash => 'sha256:inj_a', source => 'aaa' },
		{ name => 'b.pl', hash => 'sha256:inj_b', source => 'bbb' },
	]);
	unlink File::Spec->catfile($RENDER_ROOT, 'private', 'macros', 'sha256:inj_b');

	my $injected = Renderer::ContentCache::get_injected_macros($pg);
	is($injected->{'a.pl'}, 'aaa', 'present macro injected');
	ok(!exists $injected->{'b.pl'}, 'missing-file macro dropped from injection (error logged separately)');
};

done_testing();
