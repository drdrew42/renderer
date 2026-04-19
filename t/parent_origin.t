use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping parent_origin tests';
}

use Test::Mojo;
use Crypt::JWT   qw(encode_jwt);
use Crypt::Ed25519;
use MIME::Base64 qw(encode_base64);
use Mojo::JSON   qw(encode_json);
use Mojo::Parameters;

# Generate a test peer keypair before the Renderer boots — Registration.pm
# reads RENDERER_PEERS at startup.
my ($peer_pub, $peer_sec) = Crypt::Ed25519::generate_keypair();

$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';
$ENV{SITE_HOST}        //= 'https://test.example.com';

$ENV{RENDERER_PEERS} = encode_json([
	{ name => 'test-editor', public_key => encode_base64($peer_pub, '') },
]);

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

# ─── Helpers ────────────────────────────────────────────────────────────────

sub peer_headers {
	my ($method, $path, $body, %opts) = @_;
	my $ts   = $opts{timestamp} // time;
	my $name = $opts{peer_name} // 'test-editor';
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
Origin test problem
END_PGML
ENDDOCUMENT();
PG

my $portal_origin = 'https://portal.example.com';

# ─── Peer-signed lane ───────────────────────────────────────────────────────

subtest 'peer-signed: parent_origin in signed body → data-parent-origin in HTML' => sub {
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'default',
		problemSeed   => 1234,
		parent_origin => $portal_origin,
	);
	my $headers = peer_headers('POST', '/render-api', $body);

	$t->post_ok('/render-api', $headers, $body)
		->status_is(200)
		->content_like(qr{<html[^>]*\bdata-parent-origin="\Q$portal_origin\E"},
			'data-parent-origin attribute present on <html> tag');
};

subtest 'peer-signed: no parent_origin → data-parent-origin absent' => sub {
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'default',
		problemSeed   => 1234,
	);
	my $headers = peer_headers('POST', '/render-api', $body);

	$t->post_ok('/render-api', $headers, $body)
		->status_is(200)
		->content_unlike(qr/data-parent-origin/, 'attribute omitted entirely when unset');
};

# ─── Raw-param rejection (no trust signal) ─────────────────────────────────

subtest 'unauthenticated parent_origin URL param → stripped, attribute absent' => sub {
	# Self-mint path (STRICT_JWT off): raw param should not reach the template.
	local $ENV{STRICT_JWT} = 0;
	$t->post_ok('/render-api' => form => {
		problemSource => $pg_source,
		outputFormat  => 'default',
		problemSeed   => 1234,
		parent_origin => 'https://attacker.example.com',
	})->status_is(200)
	  ->content_unlike(qr/data-parent-origin/,
		'raw parent_origin URL param does not render without JWT/peer-sig');
};

# ─── JWT lane ──────────────────────────────────────────────────────────────

subtest 'JWT lane: parent_origin claim → data-parent-origin in HTML' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
		parent_origin => $portal_origin,
	);

	$t->post_ok('/render-api' => form => {
		problemJWT   => $jwt,
		outputFormat => 'default',
	})->status_is(200)
	  ->content_like(qr{<html[^>]*\bdata-parent-origin="\Q$portal_origin\E"},
		'JWT claim propagates to HTML attribute');
};

subtest 'JWT lane: no parent_origin claim → attribute absent' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
	);

	$t->post_ok('/render-api' => form => {
		problemJWT   => $jwt,
		outputFormat => 'default',
	})->status_is(200)
	  ->content_unlike(qr/data-parent-origin/,
		'attribute omitted when claim is absent');
};

# ─── Raw-param override resistance with JWT present ────────────────────────

subtest 'JWT lane: raw parent_origin URL param cannot override JWT-absent claim' => sub {
	# JWT present but without parent_origin claim; URL param attempts injection.
	# Attacker: "I have a legitimate JWT, I'll redirect its events to my origin."
	# The strip happens before JWT merge; JWT has no claim; attribute stays absent.
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
	);

	$t->post_ok('/render-api' => form => {
		problemJWT    => $jwt,
		outputFormat  => 'default',
		parent_origin => 'https://attacker.example.com',
	})->status_is(200)
	  ->content_unlike(qr/data-parent-origin/,
		'unauthenticated URL param cannot smuggle parent_origin past the strip');
};

done_testing();
