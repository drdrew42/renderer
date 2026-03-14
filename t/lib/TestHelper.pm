package TestHelper;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(test_app temp_render_root);

use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use Test::Mojo;

# Create a temporary RENDER_ROOT with required directory structure.
# Returns the path. Caller should keep $dir in scope (auto-cleans on destroy).
sub temp_render_root {
	my $dir = tempdir(CLEANUP => 1);
	make_path(File::Spec->catdir($dir, 'private'));
	make_path(File::Spec->catdir($dir, 'logs'));
	make_path(File::Spec->catdir($dir, 'tmp'));

	# RenderProblem.pm expects this file to exist
	my $log_file = File::Spec->catfile($dir, 'logs', 'resource_usage.log');
	open my $fh, '>', $log_file or die "Cannot create resource_usage.log: $!";
	close $fh;

	return $dir;
}

# Build a Test::Mojo instance for the Renderer app.
# RENDER_ROOT must already be set in %ENV before calling this.
sub test_app {
	# Ensure pg_config.yml exists — PG needs it at startup
	my $pg_conf = File::Spec->catfile(
		$ENV{RENDER_ROOT}, 'lib', 'PG', 'conf', 'pg_config.yml'
	);
	unless (-f $pg_conf) {
		# If we're running from the repo root, the real file is under lib/
		my $real_conf = File::Spec->catfile($ENV{RENDER_ROOT}, 'lib', 'PG', 'conf', 'pg_config.yml.dist');
		if (-f $real_conf && !-f $pg_conf) {
			require File::Copy;
			File::Copy::copy($real_conf, $pg_conf);
		}
	}

	return Test::Mojo->new('Renderer');
}

1;
