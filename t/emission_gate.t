use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping emission_gate tests';
}

use Test::Mojo;
use Crypt::Ed25519;
use Crypt::JWT   qw(encode_jwt);
use MIME::Base64 qw(encode_base64);
use Mojo::JSON   qw(encode_json);
use Mojo::Parameters;

# Generate a peer keypair before the Renderer boots — Registration.pm reads
# RENDERER_PEERS at startup.
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

sub peer_headers {
	my ($method, $path, $body) = @_;
	my $ts = time;
	my $canonical = "$method\n$path\n$ts\n$body";
	utf8::encode($canonical);
	my $sig = Crypt::Ed25519::sign($canonical, $peer_pub, $peer_sec);
	return {
		'Content-Type'     => 'application/x-www-form-urlencoded',
		'X-Peer-Name'      => 'test-editor',
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
Emission gate test problem
END_PGML
ENDDOCUMENT();
PG

# The emission gate (_can_emit_answer_jwt) is enforced at the emission site
# in Render.pm — only when the request would actually emit an answerJWT (i.e.
# JWTanswerURL is plumbed and submitAnswers is set). Validated requests render
# regardless of grounding; emission is what's gated, not rendering. These
# subtests are smoke checks that ungrounded validated requests render cleanly.

# ─── Self-mint lane ────────────────────────────────────────────────────────

subtest 'self-mint: render proceeds without grounding' => sub {
	local $ENV{STRICT_JWT} = 0;
	$t->post_ok('/render-api' => form => {
		problemSource => $pg_source,
		outputFormat  => 'default',
		problemSeed   => 1234,
	})->status_is(200);
};

# ─── Peer-signed lane ──────────────────────────────────────────────────────

subtest 'peer-signed: render proceeds' => sub {
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'simple',
		problemSeed   => 1234,
	);
	my $headers = peer_headers('POST', '/render-api', $body);

	$t->post_ok('/render-api', $headers, $body)
		->status_is(200);
};

# ─── problemJWT lane (control) ─────────────────────────────────────────────

subtest 'problemJWT: submitAnswers proceeds (sets _can_emit_answer_jwt)' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
	);

	$t->post_ok('/render-api' => form => {
		problemJWT    => $jwt,
		outputFormat  => 'default',
		submitAnswers => 1,
		AnSwEr0001    => '42',
	})->status_is(200);
};

done_testing();
