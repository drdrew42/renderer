package Renderer::ContentCache;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Path  qw(make_path remove_tree);
use File::Spec;
use Mojo::Log;
use Mojo::JSON qw(encode_json);
use Mojo::Date;

# Base directory for all content-addressed storage
my $PRIVATE = "$ENV{RENDER_ROOT}/private";

# Module-level logger — respects LOG_FORMAT for structured output
my $log = Mojo::Log->new;
if ($ENV{LOG_FORMAT} && $ENV{LOG_FORMAT} eq 'json') {
	$log->format(sub {
		my ($time, $level, @lines) = @_;
		encode_json({
			timestamp => Mojo::Date->new($time)->to_datetime,
			level     => $level,
			pid       => $$,
			service   => 'renderer',
			component => 'ContentCache',
			message   => join(' ', @lines),
		}) . "\n";
	});
}

# Return the pg_hash associated with a URL, or undef if unknown.
sub pg_hash_for_url {
	my ($url) = @_;
	my $index_file = _url_index_path($url);
	return unless -f $index_file;
	open my $fh, '<', $index_file or return;
	chomp(my $hash = <$fh>);
	close $fh;
	return $hash;
}

# Record the mapping from URL → pg_hash.
sub save_url_index {
	my ($url, $pg_hash) = @_;
	my $index_file = _url_index_path($url);
	make_path(File::Spec->catdir($PRIVATE, '.url_index'));
	open my $fh, '>', $index_file or do { $log->warn("Cannot write url_index: $!"); return };
	print $fh $pg_hash;
	close $fh;
	return 1;
}

# True if a cached problem directory exists for this hash.
sub has_problem {
	my ($pg_hash) = @_;
	return -d _problem_dir($pg_hash);
}

# Write problem source and symlink macros into the cache.
# $macros_aref is an arrayref of hashrefs: [{ name => '...', hash => '...' }, ...]
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

	# Symlink each custom macro into the problem directory
	for my $macro (@{ $macros_aref // [] }) {
		my $macro_file = File::Spec->catfile($PRIVATE, 'macros', $macro->{hash});
		next unless -f $macro_file;
		my $link = File::Spec->catfile($dir, $macro->{name});
		# Relative symlink: ../../macros/{hash}
		my $target = File::Spec->catfile('..', '..', 'macros', $macro->{hash});
		symlink($target, $link) unless -e $link;
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
	my $path = File::Spec->catfile($PRIVATE, 'problems', $pg_hash, 'problem.pg');
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
	my $index_file = _path_index_path($file_path);
	return unless -f $index_file;
	open my $fh, '<', $index_file or return;
	chomp(my $hash = <$fh>);
	close $fh;
	return $hash;
}

# Record the mapping from file path → pg_hash.
sub save_path_index {
	my ($file_path, $pg_hash) = @_;
	my $index_file = _path_index_path($file_path);
	make_path(File::Spec->catdir($PRIVATE, '.path_index'));
	open my $fh, '>', $index_file or do { $log->warn("Cannot write path_index: $!"); return };
	print $fh $pg_hash;
	close $fh;
	return 1;
}

# Build the injectedMacros hash for a cached problem.
# Scans the problem directory for .pl symlinks pointing into macros/,
# reads the macro source, and returns { macro_name => source_code }.
# Returns empty hashref if no macros or problem not cached.
sub get_injected_macros {
	my ($pg_hash) = @_;
	my $dir = _problem_dir($pg_hash);
	return {} unless -d $dir;

	my %injected;
	opendir my $dh, $dir or return {};
	while (my $entry = readdir $dh) {
		next unless $entry =~ /\.pl$/i;
		my $link_path = File::Spec->catfile($dir, $entry);
		next unless -l $link_path;    # only symlinks (not regular .pl files)

		# Resolve the symlink and read the macro source
		my $target = readlink($link_path);
		my $abs_target = File::Spec->rel2abs($target, $dir);
		next unless -f $abs_target;

		open my $fh, '<:encoding(UTF-8)', $abs_target or next;
		local $/;
		$injected{$entry} = <$fh>;
		close $fh;
	}
	closedir $dh;

	return \%injected;
}

# Evict problem directories older than $max_age_hours (by mtime).
# Also sweeps stale url_index and path_index entries pointing to evicted hashes.
# Returns the number of problem directories removed.
sub sweep {
	my (%opts) = @_;
	my $max_age_hours = $opts{max_age_hours} // ($ENV{CACHE_TTL_HOURS} || 168);  # default 1 week
	my $cutoff = time - ($max_age_hours * 3600);
	my $evicted = 0;

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
			remove_tree($dir);
			$evicted_hashes{$entry} = 1;
			$evicted++;
		}
	}

	# Sweep index entries pointing to evicted hashes
	if ($evicted) {
		for my $index_dir ('.url_index', '.path_index') {
			my $idx_path = File::Spec->catdir($PRIVATE, $index_dir);
			next unless -d $idx_path;
			opendir my $ih, $idx_path or next;
			while (my $f = readdir $ih) {
				next if $f eq '.' || $f eq '..';
				my $file = File::Spec->catfile($idx_path, $f);
				open my $fh, '<', $file or next;
				chomp(my $hash = <$fh>);
				close $fh;
				unlink $file if $evicted_hashes{$hash};
			}
			closedir $ih;
		}
	}

	return $evicted;
}

# Remove a single problem directory and its index entries.
sub invalidate {
	my ($pg_hash) = @_;
	my $dir = _problem_dir($pg_hash);
	return 0 unless -d $dir;

	remove_tree($dir);

	# Clean any index entries pointing to this hash
	for my $index_dir ('.url_index', '.path_index') {
		my $idx_path = File::Spec->catdir($PRIVATE, $index_dir);
		next unless -d $idx_path;
		opendir my $ih, $idx_path or next;
		while (my $f = readdir $ih) {
			next if $f eq '.' || $f eq '..';
			my $file = File::Spec->catfile($idx_path, $f);
			open my $fh, '<', $file or next;
			chomp(my $hash = <$fh>);
			close $fh;
			unlink $file if $hash eq $pg_hash;
		}
		closedir $ih;
	}

	return 1;
}

# --- private helpers ---

sub _url_index_path {
	my ($url) = @_;
	my $url_hash = sha256_hex($url);
	return File::Spec->catfile($PRIVATE, '.url_index', $url_hash);
}

sub _path_index_path {
	my ($file_path) = @_;
	my $path_hash = sha256_hex($file_path);
	return File::Spec->catfile($PRIVATE, '.path_index', $path_hash);
}

sub _problem_dir {
	my ($pg_hash) = @_;
	return File::Spec->catdir($PRIVATE, 'problems', $pg_hash);
}

1;
