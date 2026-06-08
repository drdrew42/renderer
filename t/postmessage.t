use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping postmessage tests';
}

use Test::Mojo;
use Crypt::JWT qw(encode_jwt);
use Crypt::Ed25519;
use MIME::Base64 qw(encode_base64);
use Mojo::JSON   qw(encode_json);
use Mojo::Parameters;

# Generate a test peer keypair before the Renderer boots.
my ($peer_pub, $peer_sec) = Crypt::Ed25519::generate_keypair();

$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';
$ENV{SITE_HOST}        //= 'https://test.example.com';

$ENV{RENDERER_PEERS} = encode_json([ { name => 'test-editor', public_key => encode_base64($peer_pub, '') }, ]);

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

# ─── Helpers ────────────────────────────────────────────────────────────────

sub peer_headers {
	my ($method, $path, $body, %opts) = @_;
	my $ts        = $opts{timestamp} // time;
	my $name      = $opts{peer_name} // 'test-editor';
	my $canonical = "$method\n$path\n$ts\n$body";
	utf8::encode($canonical);
	my $sig = Crypt::Ed25519::sign($canonical, $peer_pub, $peer_sec);
	return {
		'Content-Type'     => 'application/x-www-form-urlencoded',
		'X-Peer-Name'      => $name,
		'X-Peer-Timestamp' => $ts,
		'X-Peer-Signature' => encode_base64($sig, ''),
	};
}

sub form_body {
	my (%fields) = @_;
	return Mojo::Parameters->new(%fields)->to_string;
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
trust-lane test
END_PGML
ENDDOCUMENT();
PG

# ─── data-trust-lane attribute ─────────────────────────────────────────────

subtest 'problemJWT lane → data-trust-lane="problem"' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
	);

	$t->post_ok(
		'/render-api' => form => {
			problemJWT   => $jwt,
			outputFormat => 'default',
		}
	)->status_is(200)->content_like(qr{<html[^>]*\bdata-trust-lane="problem"}, 'problem lane sets data-trust-lane');
};

subtest 'peer-signed lane → data-trust-lane="peer"' => sub {
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'default',
		problemSeed   => 1234,
	);
	my $headers = peer_headers('POST', '/render-api', $body);

	$t->post_ok('/render-api', $headers, $body)->status_is(200)
		->content_like(qr{<html[^>]*\bdata-trust-lane="peer"}, 'peer lane sets data-trust-lane');
};

subtest 'ungrounded (self-mint) → data-trust-lane="ungrounded"' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			outputFormat  => 'default',
			problemSeed   => 1234,
		}
	)->status_is(200)
		->content_like(qr{<html[^>]*\bdata-trust-lane="ungrounded"}, 'ungrounded lane sets data-trust-lane');
};

# ─── Body onLoad regression ────────────────────────────────────────────────

subtest 'body has no onLoad postMessage broadcast' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
	);

	$t->post_ok(
		'/render-api' => form => {
			problemJWT   => $jwt,
			outputFormat => 'default',
		}
	)->status_is(200)->content_unlike(
		qr{onLoad="window\.parent\.postMessage},
		'body element no longer carries onLoad bare-string broadcast (replaced by webwork.lifecycle.loaded in problem.js)'
	);
};

# ─── parent_origin coexists with trust_lane ────────────────────────────────

subtest 'iframe-resizer asset is no longer included' => sub {
	# WW3-R23: iframe-resizer dropped in favor of webwork.lifecycle.resize.
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
	);

	$t->post_ok(
		'/render-api' => form => {
			problemJWT   => $jwt,
			outputFormat => 'default',
		}
	)->status_is(200)->content_unlike(qr/iframeResizer\.contentWindow/,
			'iframe-resizer asset removed from third_party_js (replaced by webwork.lifecycle.resize)');
};

subtest 'parent_origin + trust_lane both render on grounded lane' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
		parent_origin => 'https://portal.example.com',
	);

	$t->post_ok(
		'/render-api' => form => {
			problemJWT   => $jwt,
			outputFormat => 'default',
		}
	)->status_is(200)->content_like(
		qr{<html[^>]*\bdata-parent-origin="https://portal\.example\.com"[^>]*\bdata-trust-lane="problem"},
		'both attributes present together when parent_origin claim set on grounded lane'
	);
};

done_testing();
