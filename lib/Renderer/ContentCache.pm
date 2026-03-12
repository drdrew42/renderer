package Renderer::ContentCache;

use strict;
use warnings;

use Digest::SHA qw(sha256_hex);
use File::Path  qw(make_path);
use File::Spec;

# Base directory for all content-addressed storage
my $PRIVATE = "$ENV{RENDER_ROOT}/private";

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
	open my $fh, '>', $index_file or warn "ContentCache: cannot write url_index: $!" && return;
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
		or warn "ContentCache: cannot write problem.pg: $!" && return;
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
		or warn "ContentCache: cannot write macro $hash: $!" && return;
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
	open my $fh, '>', $index_file or warn "ContentCache: cannot write path_index: $!" && return;
	print $fh $pg_hash;
	close $fh;
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
