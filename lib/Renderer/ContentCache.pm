package Renderer::ContentCache;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Path  qw(make_path remove_tree);
use File::Spec;
use Mojo::JSON qw(encode_json decode_json);

use Renderer::Log;

# Base directory for all content-addressed storage
my $PRIVATE = "$ENV{RENDER_ROOT}/private";

# Module-level logger — respects LOG_FORMAT for structured output
my $log = Renderer::Log::structured('ContentCache');

# Return the pg_hash associated with a URL, or undef if unknown.
sub pg_hash_for_url {
	my ($url) = @_;
	return _read_index('.url_index', $url);
}

# Record the mapping from URL → pg_hash.
sub save_url_index {
	my ($url, $pg_hash) = @_;
	return _write_index('.url_index', $url, $pg_hash);
}

# True if a cached problem directory exists for this hash.
sub has_problem {
	my ($pg_hash) = @_;
	return -d _problem_dir($pg_hash);
}

# Write problem source and a manifest of its macro dependencies (WW3-R11).
# $macros_aref is an arrayref of hashrefs: each entry carries `name`, `hash`,
# and (optionally) `source_type` — captured verbatim from OPL's response so
# the renderer doesn't own the source-type vocabulary. The current renderer
# filtering rule (which source_types get fetched + cached + injected) lives
# in Render.pm:_parse_and_stage_response and is a code-level concern, not a
# format-level one.
#
# Manifest format at $dir/manifest.json:
#   [ { "name": "...", "hash": "sha256:...", "source_type": "..." }, ... ]
# Array preserves the order OPL sent. Future per-problem metadata (timestamps,
# fetch URL, etc.) would wrap as { macros: [...], metadata: {...} } — not
# done now (YAGNI).
#
# Atomic write: tmp + rename. Concurrency note: two concurrent renders of the
# same uncached pg_hash race to write the manifest. Contents are deterministic
# from the OPL response, so last-rename-wins is harmless. If a future failure
# mode surfaces as "manifest references a hash whose macro file is mid-write,"
# the right fix is atomic-rename in `stage_macro` (currently a plain open-write).
# Pre-emptive note for the maintainer; not blocking R11.
sub stage_problem {
	my ($pg_hash, $raw_source, $macros_aref) = @_;
	my $dir = _problem_dir($pg_hash);
	make_path($dir);

	# Write the problem source
	my $pg_file = File::Spec->catfile($dir, 'problem.pg');
	open my $fh, '>:encoding(UTF-8)', $pg_file
		or do { $log->warn("Cannot write problem.pg: $!"); return };
	print $fh $raw_source;
	close $fh;

	# Build manifest entries. Capture source_type verbatim if provided.
	my @entries;
	for my $macro (@{ $macros_aref // [] }) {
		next unless $macro->{name} && $macro->{hash};
		push @entries,
			{
				name => $macro->{name},
				hash => $macro->{hash},
				(defined $macro->{source_type} ? (source_type => $macro->{source_type}) : ()),
			};
	}

	my $manifest_path = File::Spec->catfile($dir, 'manifest.json');
	my $tmp_path      = "$manifest_path.tmp";
	open my $mfh, '>:encoding(UTF-8)', $tmp_path
		or do { $log->warn("Cannot write manifest tmp for $pg_hash: $!"); return };
	print $mfh encode_json(\@entries);
	close $mfh;
	unless (rename $tmp_path, $manifest_path) {
		$log->warn("Cannot install manifest for $pg_hash: $!");
		unlink $tmp_path;
		return;
	}

	return 1;
}

# Write a macro file by content hash (idempotent).
sub stage_macro {
	my ($hash, $source) = @_;
	my $macro_dir = File::Spec->catdir($PRIVATE, 'macros');
	make_path($macro_dir);
	my $path = File::Spec->catfile($macro_dir, $hash);
	return 1 if -f $path;    # already cached
	open my $fh, '>:encoding(UTF-8)', $path
		or do { $log->warn("Cannot write macro $hash: $!"); return };
	print $fh $source;
	close $fh;
	return 1;
}

# Return the relative path (from RENDER_ROOT) to a cached problem's .pg file.
# This must start with "private/" so Problem.pm::path() recognises it correctly.
sub problem_path {
	my ($pg_hash) = @_;
	return "private/problems/$pg_hash/problem.pg";
}

# Read the cached raw source for a problem, or undef.
sub read_problem {
	my ($pg_hash) = @_;
	my $path = File::Spec->catfile(_problem_dir($pg_hash), 'problem.pg');
	return unless -f $path;
	open my $fh, '<:encoding(UTF-8)', $path or return;
	local $/;
	my $source = <$fh>;
	close $fh;
	return $source;
}

# Return the pg_hash associated with a file path, or undef if unknown.
sub pg_hash_for_path {
	my ($file_path) = @_;
	return _read_index('.path_index', $file_path);
}

# Record the mapping from file path → pg_hash.
sub save_path_index {
	my ($file_path, $pg_hash) = @_;
	return _write_index('.path_index', $file_path, $pg_hash);
}

# Build the injectedMacros hash for a cached problem.
# Returns { macro_name => source_code } or empty hashref if no macros/cache.
#
# Reads manifest.json (R11 storage shape). Pre-R11 symlink fallback was
# dropped in R38 — the entrypoint cache-wipe at deploy is the safety net.
sub get_injected_macros {
	my ($pg_hash) = @_;
	my $dir = _problem_dir($pg_hash);
	return {} unless -d $dir;

	my $manifest_path = File::Spec->catfile($dir, 'manifest.json');
	return -f $manifest_path ? _read_manifest_macros($dir, $manifest_path) : {};
}

sub _read_manifest_macros {
	my ($dir, $manifest_path) = @_;

	my $entries = _read_manifest_entries($manifest_path);
	return {} unless $entries;

	my %injected;
	for my $entry (@$entries) {
		next unless ref $entry eq 'HASH' && $entry->{name} && $entry->{hash};
		my $macro_path = File::Spec->catfile($PRIVATE, 'macros', $entry->{hash});
		unless (-f $macro_path) {
			# WW3-R42: manifest references a macro hash whose source file is not
			# on disk. Two known triggers: (a) stage-time fetch_macro failure
			# left a half-written manifest, (b) invalidate_macro callback deleted
			# the file but didn't invalidate dependent problem manifests. Both
			# silently degraded the render. Now: loud log + skip. PATH HIT
			# consistency check in SourceResolver should catch this earlier and
			# force a re-stage.
			(my $pg_hash = $dir) =~ s{.*/}{};
			$log->error(
				"Manifest references missing macro file",
				pg_hash    => $pg_hash,
				macro_name => $entry->{name},
				macro_hash => $entry->{hash}
			);
			next;
		}
		open my $mfh, '<:encoding(UTF-8)', $macro_path or next;
		local $/;
		$injected{ $entry->{name} } = <$mfh>;
		close $mfh;
	}
	return \%injected;
}

# Read manifest.json and return its entries (arrayref) or undef on parse error.
# Shared by _read_manifest_macros, verify_consistent, inspect.
sub _read_manifest_entries {
	my ($manifest_path) = @_;
	open my $fh, '<:encoding(UTF-8)', $manifest_path or return undef;
	local $/;
	my $body = <$fh>;
	close $fh;

	my $entries = eval { decode_json($body) };
	if ($@ || ref $entries ne 'ARRAY') {
		$log->warn("Manifest at $manifest_path is not a JSON array; ignoring");
		return undef;
	}
	return $entries;
}

# Manifest-consistency check for a cached problem.
# Returns ($ok, $report). $ok is true iff:
#   * a manifest exists, AND
#   * every manifest entry's macro file is present on disk.
#
# The `load_macros_not_in_manifest` field is informational only — standard
# macros (PGstandard.pl, PGML.pl, MathObjects.pl, …) are intentionally absent
# from the manifest (the stage-time filter only captures source_type custom
# or override). So the source-vs-manifest delta is expected non-empty under
# normal operation and can't be a consistency signal on its own. The admin
# inspect endpoint still surfaces it for human review.
#
# $report is a hashref:
#   {
#     manifest                    => [ {name,hash,source_type}, ... ],
#     macros_on_disk              => [ "sha256:...", ... ],
#     macros_missing_from_disk    => [ "sha256:...", ... ],
#     source_load_macros          => [ "name.pl", ... ],
#     load_macros_not_in_manifest => [ "name.pl", ... ],  # informational
#   }
sub verify_consistent {
	my ($pg_hash) = @_;
	my $dir = _problem_dir($pg_hash);
	return (0, { reason => 'no_problem_dir' }) unless -d $dir;

	my $manifest_path = File::Spec->catfile($dir, 'manifest.json');
	my $entries       = -f $manifest_path ? _read_manifest_entries($manifest_path) : undef;
	return (0, { reason => 'no_manifest' }) unless defined $entries;

	my @on_disk;
	my @missing;
	my %manifest_names;
	for my $entry (@$entries) {
		next unless ref $entry eq 'HASH' && $entry->{name} && $entry->{hash};
		$manifest_names{ $entry->{name} } = 1;
		my $macro_path = File::Spec->catfile($PRIVATE, 'macros', $entry->{hash});
		if (-f $macro_path) {
			push @on_disk, $entry->{hash};
		} else {
			push @missing, $entry->{hash};
		}
	}

	# Parse the cached problem.pg's loadMacros() for the informational delta.
	my $source          = read_problem($pg_hash);
	my @source_macros   = $source ? @{ _parse_load_macros($source) } : ();
	my @not_in_manifest = grep { !$manifest_names{$_} } @source_macros;

	my $report = {
		manifest                    => $entries,
		macros_on_disk              => \@on_disk,
		macros_missing_from_disk    => \@missing,
		source_load_macros          => \@source_macros,
		load_macros_not_in_manifest => \@not_in_manifest,
	};

	my $ok = !@missing;
	return ($ok, $report);
}

# Find every cached problem whose manifest references the given macro hash.
# Returns arrayref of pg_hash strings. Used by the invalidate_macro cascade
# in Callback.pm — when OPL invalidates a macro hash, every problem manifest
# that pinned to it is now stale and must be evicted.
#
# Naive scan: walks private/problems/*/manifest.json. O(N) in problem count.
# Acceptable at current scale; if invalidate_macro batches grow, swap for an
# indexed reverse map at .macro_to_problems/<hash>.
sub find_problems_using_macro {
	my ($macro_hash) = @_;
	my $problems_dir = File::Spec->catdir($PRIVATE, 'problems');
	return [] unless -d $problems_dir;

	opendir my $dh, $problems_dir or return [];
	my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
	closedir $dh;

	my @hits;
	for my $pg_hash (@entries) {
		my $manifest_path = File::Spec->catfile($problems_dir, $pg_hash, 'manifest.json');
		next unless -f $manifest_path;
		my $manifest_entries = _read_manifest_entries($manifest_path);
		next unless $manifest_entries;
		for my $e (@$manifest_entries) {
			next unless ref $e eq 'HASH' && $e->{hash};
			if ($e->{hash} eq $macro_hash) {
				push @hits, $pg_hash;
				last;
			}
		}
	}
	return \@hits;
}

# Minimal loadMacros() parser — mirrors OPL::Macro::Parser::parse_load_macros
# in OPLv3. Renderer-side copy because the renderer doesn't depend on OPL
# code. Kept private; only verify_consistent calls it.
sub _parse_load_macros {
	my ($source) = @_;
	return [] unless defined $source && length $source;

	my @macros;
	while ($source =~ /loadMacros\s*\((.*?)\)/sg) {
		my $args = $1;
		while ($args =~ /["']([^"']+\.pl)["']/g) {
			push @macros, $1;
		}
	}

	my %seen;
	@macros = grep { !$seen{$_}++ } @macros;
	return \@macros;
}

# Evict problem directories older than $max_age_hours (by mtime).
# Also sweeps stale url_index and path_index entries pointing to evicted hashes.
# Returns the number of problem directories removed.
sub sweep {
	my (%opts)        = @_;
	my $max_age_hours = $opts{max_age_hours} // ($ENV{CACHE_TTL_HOURS} || 168);    # default 1 week
	my $cutoff        = time - ($max_age_hours * 3600);
	my $evicted       = 0;

	my $problems_dir = File::Spec->catdir($PRIVATE, 'problems');
	return 0 unless -d $problems_dir;

	opendir my $dh, $problems_dir or return 0;
	my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
	closedir $dh;

	my %evicted_hashes;
	for my $entry (@entries) {
		my $dir = File::Spec->catdir($problems_dir, $entry);
		next unless -d $dir;
		my $mtime = (stat($dir))[9];
		if ($mtime < $cutoff) {
			_remove_tree($dir);
			$evicted_hashes{$entry} = 1;
			$evicted++;
		}
	}

	# Sweep index entries pointing to evicted hashes
	_delete_index_entries_where(sub { $evicted_hashes{ $_[0] } }) if $evicted;

	return $evicted;
}

# remove_tree wrapper. File::Path's per-file carp ("cannot unlink file …
# No such file or directory", etc.) is raw, non-JSON STDERR noise and is
# common under concurrent invalidation, where a directory vanishes
# mid-removal. Suppress the carp via `error =>`, treat a vanished path as
# the benign race it is, and route any genuine failure through the
# structured logger instead.
sub _remove_tree {
	my ($dir) = @_;
	remove_tree($dir, { error => \my $err });
	for my $e (@{ $err // [] }) {
		my ($file, $message) = %$e;
		next if $message =~ /No such file or directory/;
		$log->warn("remove_tree failed for " . ($file || $dir) . ": $message");
	}
}

# Remove a single problem directory and its index entries.
sub invalidate {
	my ($pg_hash) = @_;
	my $dir = _problem_dir($pg_hash);
	return 0 unless -d $dir;

	_remove_tree($dir);
	_delete_index_entries_where(sub { $_[0] eq $pg_hash });

	return 1;
}

# Drop the path→hash binding plus any url_index entries pointing at the
# same hash. Leaves the content cache and the hash itself untouched, so
# direct-by-hash requests (signed render tokens locked to a historical
# version) keep working. Use when the bytes at a path change but the old
# hash is still legitimately addressable.
#
# The url_index sweep covers the URL-flow caller path: when OPL serves a
# problem by path, the renderer indexes the fetch URL (e.g.
# `/api/problems/path/<file>`) → pg_hash. If we only dropped the path
# binding, a URL-flow caller hitting the same path-form URL would still
# resolve to the old hash via url_index. Sweeping by bound hash catches
# this. Hash-form URLs (`/api/problems/<hash>`) that happen to be indexed
# at the same hash get swept too — harmless: they re-fetch from OPL,
# OPL returns the same hash content, the renderer re-indexes.
sub invalidate_path {
	my ($file_path) = @_;
	my $idx = _index_path('.path_index', $file_path);
	return 0 unless -f $idx;

	# Capture the bound hash before we unlink so we know what url_index
	# entries to sweep.
	my $bound_hash;
	if (open my $fh, '<', $idx) {
		chomp($bound_hash = <$fh>);
		close $fh;
	}
	unlink $idx;

	_delete_url_index_entries_where(sub { $_[0] eq $bound_hash })
		if defined $bound_hash && length $bound_hash;

	return 1;
}

# Walk both .url_index and .path_index, deleting any entry whose stored
# pg_hash satisfies the predicate. Each index file holds a single hash
# (chomp'd) that maps a URL or path to a problem directory.
sub _delete_index_entries_where {
	my ($predicate) = @_;
	_sweep_index_dir('.path_index', $predicate);
	_sweep_index_dir('.url_index',  $predicate);
}

# url_index-only sweep — used by invalidate_path so it doesn't clobber
# path_index entries for other paths that happen to hash to the same value.
sub _delete_url_index_entries_where {
	my ($predicate) = @_;
	_sweep_index_dir('.url_index', $predicate);
}

sub _sweep_index_dir {
	my ($index_dir, $predicate) = @_;
	my $idx_path = File::Spec->catdir($PRIVATE, $index_dir);
	return unless -d $idx_path;
	opendir my $ih, $idx_path or return;
	while (my $f = readdir $ih) {
		next if $f eq '.' || $f eq '..';
		my $file = File::Spec->catfile($idx_path, $f);
		open my $fh, '<', $file or next;
		chomp(my $hash = <$fh>);
		close $fh;
		unlink $file if $predicate->($hash);
	}
	closedir $ih;
}

# --- private helpers ---

# Index entry path for a key ($url or $file_path) under $index_dir
# (.url_index / .path_index). The filename is the sha256 of the key.
sub _index_path {
	my ($index_dir, $key) = @_;
	return File::Spec->catfile($PRIVATE, $index_dir, sha256_hex($key));
}

# Read a single-hash index entry, or undef if the entry is absent/unreadable.
sub _read_index {
	my ($index_dir, $key) = @_;
	my $index_file = _index_path($index_dir, $key);
	return unless -f $index_file;
	open my $fh, '<', $index_file or return;
	chomp(my $hash = <$fh>);
	close $fh;
	return $hash;
}

# Write a single-hash index entry, creating $index_dir as needed.
sub _write_index {
	my ($index_dir, $key, $pg_hash) = @_;
	make_path(File::Spec->catdir($PRIVATE, $index_dir));
	my $index_file = _index_path($index_dir, $key);
	open my $fh, '>', $index_file or do { $log->warn("Cannot write $index_dir: $!"); return };
	print $fh $pg_hash;
	close $fh;
	return 1;
}

sub _problem_dir {
	my ($pg_hash) = @_;
	return File::Spec->catdir($PRIVATE, 'problems', $pg_hash);
}

1;
