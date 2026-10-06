package TestHelper;

use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(test_app temp_render_root launch_verdict);

use File::Temp qw(tempdir);
use File::Path qw(make_path);
use File::Spec;
use Test::Mojo;
use Crypt::JWT qw(encode_jwt);

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

	# Renderer.pm requires renderer.conf.dist to boot
	my $conf_file = File::Spec->catfile($dir, 'renderer.conf.dist');
	open my $cfh, '>', $conf_file or die "Cannot create renderer.conf.dist: $!";
	print $cfh
		"{\n  secrets => ['test'],\n  problemJWTsecret => 'test-problem-secret',\n  webworkJWTsecret => 'test-session-secret',\n};\n";
	close $cfh;

	return $dir;
}

# Build a Test::Mojo instance for the Renderer app.
# RENDER_ROOT must already be set in %ENV before calling this.
sub test_app {
	# Ensure pg_config.yml exists — PG needs it at startup
	my $pg_conf = File::Spec->catfile($ENV{RENDER_ROOT}, 'lib', 'PG', 'conf', 'pg_config.yml');
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

# Mint a launch verdict — what the orchestrator returns from /play/launch and
# the portal threads through a play's first render (WW3-205). HS256 under
# problemJWTsecret, mint_sequence_basis 0. Defaults bind to the play_id the
# challengeJWT fixtures carry; `verdict` replaces the Verdict body wholesale.
sub launch_verdict {
	my (%args) = @_;
	return encode_jwt(
		payload => {
			iss                 => 'https://ww3.example.edu',
			aud                 => $ENV{SITE_HOST},
			play_id             => $args{play_id}      // '11111111-1111-1111-1111-111111111111',
			challenge_id        => $args{challenge_id} // 'sha256:abcdef',
			mint_sequence_basis => 0,
			verdict             => $args{verdict} // {
				current_focus   => undef,
				next_available  => [ 0, 1, 2 ],
				draw_next       => undef,
				finalization    => undef,
				spent_on_record => [],
			},
		},
		key      => $ENV{problemJWTsecret},
		alg      => 'HS256',
		auto_iat => 1,
	);
}

1;
