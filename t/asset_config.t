use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping asset config tests';
}

use Test::Mojo;
use Crypt::JWT qw(encode_jwt);
use Mojo::JSON qw(encode_json);

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
asset config test
END_PGML
ENDDOCUMENT();
PG

# ─── Config defaults ───────────────────────────────────────────────────────

subtest 'startup populates third_party_css and third_party_js defaults' => sub {
	# WW3-R24: Renderer.pm bakes defaults into config at startup so deployments
	# whose renderer.conf predates this work keep rendering.
	my $css = $t->app->config('third_party_css');
	my $js  = $t->app->config('third_party_js');

	is(ref($css), 'ARRAY', 'third_party_css is an arrayref');
	is(ref($js),  'ARRAY', 'third_party_js is an arrayref');
	ok(scalar @$css >= 3, 'third_party_css has the expected default entries');
	ok(scalar @$js  >= 6, 'third_party_js has the expected default entries');
};

subtest 'rendered HTML includes all bundled JS assets' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
	);

	my $tx = $t->post_ok('/render-api' => form => {
		problemJWT   => $jwt,
		outputFormat => 'default',
	})->status_is(200)->tx;

	my $body = $tx->res->body;
	for my $expected (qw(
		jquery.min.js
		jquery-ui.min.js
		mathjax-config.js
		tex-svg.js
		bootstrap.bundle.min.js
		problem.js
		submithelper.js
		css-message.js
	)) {
		like($body, qr/\Q$expected\E/, "rendered HTML includes $expected");
	}
};

subtest 'rendered HTML includes all bundled CSS assets' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
	);

	my $tx = $t->post_ok('/render-api' => form => {
		problemJWT   => $jwt,
		outputFormat => 'default',
	})->status_is(200)->tx;

	my $body = $tx->res->body;
	for my $expected (qw(
		bootstrap.css
		jquery-ui.min.css
		fontawesome-free
	)) {
		like($body, qr/\Q$expected\E/, "rendered HTML includes $expected");
	}
};

subtest 'config override replaces baked defaults' => sub {
	# Drop one asset; render; assert it's gone but the others survive.
	# Demonstrates the config drives the asset list (not just used as initial
	# seed for some hardcoded fallback).
	my $orig = $t->app->config('third_party_js');
	my @kept = grep { $_->[0] !~ /submithelper/ } @$orig;
	$t->app->config(third_party_js => \@kept);

	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
	);

	$t->post_ok('/render-api' => form => {
		problemJWT   => $jwt,
		outputFormat => 'default',
	})->status_is(200)
	  ->content_unlike(qr/submithelper\.js/, 'removed asset is absent from HTML')
	  ->content_like(qr/problem\.js/,        'untouched assets still present');

	# Restore for downstream test files that share this app instance.
	$t->app->config(third_party_js => $orig);
};

done_testing();
