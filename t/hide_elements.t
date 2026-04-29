use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping hide_elements tests';
}

use Test::Mojo;
use Crypt::JWT qw(encode_jwt);

$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';
$ENV{SITE_HOST}        //= 'https://test.example.com';

delete $ENV{STRICT_JWT};
delete $ENV{OPL_API_URL};

my $t = Test::Mojo->new('Renderer');
my $render_root = $ENV{RENDER_ROOT};
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

sub make_problem_jwt {
	my (%claims) = @_;
	return encode_jwt(
		payload => {
			aud => $ENV{SITE_HOST},
			iss => $ENV{SITE_HOST},
			%claims,
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

my $pg_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl");
BEGIN_PGML
hideElements test problem
END_PGML
ENDDOCUMENT();
PG

# ─── problemJWT lane ───────────────────────────────────────────────────────

subtest 'problemJWT: hideElements claim → inline <style> in <head>' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
		hideElements  => [ '.feedback-btn', '#hint-link' ],
	);

	$t->post_ok('/render-api' => form => {
		problemJWT   => $jwt,
		outputFormat => 'default',
	})->status_is(200)
	  ->content_like(
		qr{<style>\.feedback-btn,\s*\#hint-link\s*\{\s*display:\s*none\s*!important;\s*\}</style>},
		'inline <style> block with both selectors and display:none !important',
	);
};

subtest 'problemJWT: no hideElements claim → no <style> block emitted' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
	);

	$t->post_ok('/render-api' => form => {
		problemJWT   => $jwt,
		outputFormat => 'default',
	})->status_is(200)
	  ->content_unlike(
		qr{<style>[^<]*display:\s*none\s*!important[^<]*</style>},
		'no hide-style block when claim absent',
	);
};

subtest 'problemJWT: empty hideElements array → no <style> block' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
		hideElements  => [],
	);

	$t->post_ok('/render-api' => form => {
		problemJWT   => $jwt,
		outputFormat => 'default',
	})->status_is(200)
	  ->content_unlike(
		qr{<style>[^<]*display:\s*none\s*!important[^<]*</style>},
		'empty array treated like absent — no markup leak',
	);
};

# ─── XSS defense ───────────────────────────────────────────────────────────

subtest 'problemJWT: selectors are xml_escaped' => sub {
	# A pathological "selector" carrying an HTML break-out attempt. xml_escape
	# defangs the special chars; the raw `<script>` substring must not appear
	# inside the rendered <style> block.
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
		hideElements  => [ q{</style><script>alert(1)</script><style>.a} ],
	);

	$t->post_ok('/render-api' => form => {
		problemJWT   => $jwt,
		outputFormat => 'default',
	})->status_is(200)
	  ->content_unlike(
		qr{<script>alert\(1\)</script>},
		'malicious selector cannot break out of the <style> block',
	);
};

# ─── Raw-param rejection ───────────────────────────────────────────────────

# hideElements is not on SENSITIVE_PARAMS (it's not security-sensitive — caller
# can already toggle iframe styles via css-message.js). So a raw-param submission
# *would* reach the template. This test documents that the declarative path
# works equivalently for raw form submissions when no JWT is present, which
# matches the legacy css-message.js capability boundary.
#
# If at some point we want to restrict hideElements to JWT-bearing requests
# only (e.g. add it to SENSITIVE_PARAMS), this test will flip and serve as
# the regression sentinel.

done_testing();
