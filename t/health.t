use strict;
use warnings;

use Test::More;

# The Renderer app requires Future::AsyncAwait (Docker-only) to boot.
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping health tests';
}

use File::Path qw(make_path remove_tree);
use File::Spec;
use Test::Mojo;

# health.t — Tests for GET /health endpoint
# Renderer.pm's BEGIN block auto-derives RENDER_ROOT from the lib/ directory.
# We boot the app first, then use RENDER_ROOT for setup.

# Renderer startup refuses placeholder secrets; supply test values.
$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';

my $t           = Test::Mojo->new('Renderer');
my $render_root = $ENV{RENDER_ROOT};

# Ensure required directories exist
make_path("$render_root/logs") unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

# Ensure private/ exists for the healthy test
my $private_dir     = File::Spec->catdir($render_root, 'private');
my $created_private = 0;
unless (-d $private_dir) {
	make_path($private_dir);
	$created_private = 1;
}

subtest 'health 200 when private/ exists' => sub {
	$t->get_ok('/health')->status_is(200)->json_is('/status' => 'ok')->json_is('/service' => 'Renderer')
		->json_has('/pg_version')->json_has('/renderer_version');
};

subtest 'health 503 when private/ missing' => sub {
	# Temporarily rename private/ away
	my $backup = "${private_dir}_backup_$$";
	rename $private_dir, $backup or do {
		plan skip_all => "Cannot rename private/ for test: $!";
		return;
	};

	$t->get_ok('/health')->status_is(503)->json_is('/status' => 'error')->json_is('/service' => 'Renderer');

	# Restore
	rename $backup, $private_dir or die "Cannot restore private/: $!";
};

# Cleanup: remove private/ only if we created it
if ($created_private && -d $private_dir) {
	remove_tree($private_dir);
}

done_testing();
