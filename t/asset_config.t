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

my $t           = Test::Mojo->new('Renderer');
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
	ok(scalar @$js >= 6,  'third_party_js has the expected default entries');
};

# Asset-name matcher tolerant of static-assets.json fingerprinting.
# `getAssetURL` resolves a logical path like `js/apps/Problem/problem.js`
# through the build-time manifest into a hashed minified filename like
# `js/apps/Problem/problem.5585204b.min.js`. Tests assert that each logical
# basename appears, allowing for an optional `.<hex>` fingerprint and an
# optional `.min` infix before the extension. Matches both the unbuilt
# (literal-name) and built (hashed) cases.
sub asset_present {
	my ($body, $basename, $ext) = @_;
	# basename + optional .hash + optional .min + .ext, anchored at a non-word
	# boundary on the left so e.g. "submithelper" doesn't accidentally match
	# inside a longer name. Right side anchored on .ext to avoid matching
	# basename.<ext>.foo.
	my $re = qr{(?:^|[/\b])\Q$basename\E(?:\.[a-f0-9]+)?(?:\.min)?\.\Q$ext\E\b};
	return $body =~ $re;
}

subtest 'rendered HTML includes all bundled JS assets' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
	);

	my $tx = $t->post_ok(
		'/render-api' => form => {
			problemJWT   => $jwt,
			outputFormat => 'default',
		}
	)->status_is(200)->tx;

	my $body = $tx->res->body;
	# Each entry: [basename, extension]. The asset_present matcher tolerates
	# build-time fingerprinting (`.<hex>.min` infix). jquery / jquery-ui /
	# bootstrap.bundle / tex-svg ride from node_modules and aren't fingerprinted;
	# the others (js/apps/*) are fingerprinted in built deployments.
	for my $spec (
		[ 'jquery',           'js' ],
		[ 'jquery-ui',        'js' ],
		[ 'mathjax-config',   'js' ],
		[ 'tex-svg',          'js' ],
		[ 'bootstrap.bundle', 'js' ],
		[ 'problem',          'js' ],
		[ 'submithelper',     'js' ],
		[ 'css-message',      'js' ],
		[ 'draft-tracker',    'js' ],
		)
	{
		my ($basename, $ext) = @$spec;
		ok(asset_present($body, $basename, $ext), "rendered HTML includes $basename.$ext (with or without hash)");
	}
};

subtest 'rendered HTML includes all bundled CSS assets' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
	);

	my $tx = $t->post_ok(
		'/render-api' => form => {
			problemJWT   => $jwt,
			outputFormat => 'default',
		}
	)->status_is(200)->tx;

	my $body = $tx->res->body;
	for my $spec ([ 'bootstrap', 'css' ], [ 'jquery-ui', 'css' ],) {
		my ($basename, $ext) = @$spec;
		ok(asset_present($body, $basename, $ext), "rendered HTML includes $basename.$ext (with or without hash)");
	}
	# fontawesome-free rides from node_modules under that directory name —
	# the directory token is the stable signal regardless of fingerprinting.
	like($body, qr{fontawesome-free}, 'rendered HTML includes fontawesome-free');
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

	$t->post_ok(
		'/render-api' => form => {
			problemJWT   => $jwt,
			outputFormat => 'default',
		}
	)->status_is(200);
	my $body = $t->tx->res->body;
	ok(!asset_present($body, 'submithelper', 'js'), 'removed asset is absent from HTML');
	ok(asset_present($body,  'problem',      'js'), 'untouched assets still present');

	# Restore for downstream test files that share this app instance.
	$t->app->config(third_party_js => $orig);
};

done_testing();
