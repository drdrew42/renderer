use strict;
use warnings;

use File::Path qw(make_path);
use File::Spec;
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping peer_signed tests';
}

use Test::Mojo;
use Crypt::Ed25519;
use Crypt::JWT   qw(encode_jwt);
use MIME::Base64 qw(encode_base64);
use Mojo::JSON   qw(encode_json);
use Mojo::Parameters;

# Generate a test peer keypair BEFORE the Renderer boots — Registration.pm
# reads RENDERER_PEERS at startup.
my ($peer_pub, $peer_sec) = Crypt::Ed25519::generate_keypair();

# Renderer startup refuses placeholder secrets; supply test values.
# The debug/JSON introspection shapes are deployment-gated (WW3-R45);
# the test suite is their intended consumer.
$ENV{RENDERER_DEBUG_FORMAT} //= 1;
$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';

# Pin the test peer at startup.
$ENV{RENDERER_PEERS} = encode_json([ { name => 'test-editor', public_key => encode_base64($peer_pub, '') }, ]);

# Make sure STRICT_JWT starts off — we'll flip per subtest using local $ENV{}.
delete $ENV{STRICT_JWT};

# Don't contact a real OPL during tests.
delete $ENV{OPL_API_URL};

my $t           = Test::Mojo->new('Renderer');
my $render_root = $ENV{RENDER_ROOT};
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

# Helper: produce peer-signature headers for a given method/path/body.
# Body is the URL-encoded form body as sent on the wire.
sub peer_headers {
	my ($method, $path, $body, %opts) = @_;
	my $ts        = $opts{timestamp} // time;
	my $name      = $opts{peer_name} // 'test-editor';
	my $secret    = $opts{secret}    // $peer_sec;
	my $public    = $opts{public}    // $peer_pub;
	my $canonical = "$method\n$path\n$ts\n$body";
	utf8::encode($canonical);    # match the renderer's verify side
	my $sig = Crypt::Ed25519::sign($canonical, $public, $secret);
	return {
		'Content-Type'     => 'application/x-www-form-urlencoded',
		'X-Peer-Name'      => $name,
		'X-Peer-Timestamp' => $ts,
		'X-Peer-Signature' => $opts{bad_sig} ? encode_base64('X' x 64, '') : encode_base64($sig, ''),
	};
}

sub form_body {
	my (%fields) = @_;
	return Mojo::Parameters->new(%fields)->to_string;
}

my $pg_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl");
BEGIN_PGML
Peer-signed render test
END_PGML
ENDDOCUMENT();
PG

# ── Valid peer signature → 200 ───────────────────────────────────────

subtest 'valid peer signature renders raw problemSource' => sub {
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'simple',
		problemSeed   => 1234,
	);
	my $headers = peer_headers('POST', '/render-api', $body);

	$t->post_ok('/render-api', $headers, $body)->status_is(200)
		->content_like(qr/Peer-signed render test/i, 'rendered raw source');
};

# ── Invalid signature → 401 ──────────────────────────────────────────

subtest 'invalid peer signature → 401' => sub {
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'simple',
		problemSeed   => 1234,
	);
	my $headers = peer_headers('POST', '/render-api', $body, bad_sig => 1);

	$t->post_ok('/render-api', $headers, $body)->status_is(401)->content_like(qr/peer signature/i);
};

# ── Unknown peer name → 401 ──────────────────────────────────────────

subtest 'unknown peer name → 401' => sub {
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'simple',
		problemSeed   => 1234,
	);
	my $headers = peer_headers('POST', '/render-api', $body, peer_name => 'unknown-peer');

	$t->post_ok('/render-api', $headers, $body)->status_is(401)->content_like(qr/unknown peer/i);
};

# ── Expired timestamp → 401 ──────────────────────────────────────────

subtest 'expired timestamp → 401' => sub {
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'simple',
		problemSeed   => 1234,
	);
	my $stale_ts = time - 3600;    # 1 hour ago, well past 300s window
	my $headers  = peer_headers('POST', '/render-api', $body, timestamp => $stale_ts);

	$t->post_ok('/render-api', $headers, $body)->status_is(401)->content_like(qr/skew/i);
};

# ── formAction override propagates to response HTML ──────────────────

subtest 'formAction override honored in rendered HTML' => sub {
	my $editor_url = 'https://editor.example.com/preview-submit';
	my $body       = form_body(
		problemSource => $pg_source,
		outputFormat  => 'default',     # full HTML page so we can inspect form
		problemSeed   => 1234,
		formAction    => $editor_url,
	);
	my $headers = peer_headers('POST', '/render-api', $body);

	$t->post_ok('/render-api', $headers, $body)->status_is(200)
		->content_like(qr/\Q$editor_url\E/, 'peer-provided formAction appears in output');
};

# ── STRICT_JWT=1 + no auth → 401 (entry gate) ────────────────────────

subtest 'STRICT_JWT=1 rejects ungrounded request' => sub {
	local $ENV{STRICT_JWT} = 1;
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'simple',
		problemSeed   => 1234,
	);
	$t->post_ok('/render-api', { 'Content-Type' => 'application/x-www-form-urlencoded' }, $body,)->status_is(401);
};

# ── STRICT_JWT=1 + valid peer sig → 200 (peer bypass) ────────────────

subtest 'STRICT_JWT=1 admits peer-signed request' => sub {
	local $ENV{STRICT_JWT} = 1;
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'simple',
		problemSeed   => 1234,
	);
	my $headers = peer_headers('POST', '/render-api', $body);

	$t->post_ok('/render-api', $headers, $body)->status_is(200)->content_like(qr/Peer-signed render test/i);
};

# ── STRICT_JWT=0 + no auth → self-mint renders ──────────────────────

subtest 'STRICT_JWT=0 self-mint still works (backward compat)' => sub {
	local $ENV{STRICT_JWT} = 0;
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'simple',
		problemSeed   => 1234,
	);
	$t->post_ok('/render-api', { 'Content-Type' => 'application/x-www-form-urlencoded' }, $body,)->status_is(200);
};

# ── Self-mint UX is independent of STRICT_JWT ────────────────────────
# Default-on: an admitted ungrounded request is wrapped in a self-minted
# problemJWT, which produces a sessionJWT in the response so the consumer
# can round-trip without re-mailing every input.

subtest 'STRICT_JWT=0 default: self-mint produces a problemJWT (no JWTanswerURL → no sessionJWT)' => sub {
	local $ENV{STRICT_JWT} = 0;
	local $ENV{SELF_MINT_DISABLED};
	delete $ENV{SELF_MINT_DISABLED};
	$t->post_ok(
		'/render-api',
		{ Accept => 'application/json' },
		form => {
			problemSource => $pg_source,
			problemSeed   => 1234,
		},
	)->status_is(200);
	my $resp = Mojo::JSON::decode_json($t->tx->res->body);
	ok($resp->{JWT}{problem},  'self-minted request returns a problemJWT');
	ok(!$resp->{JWT}{session}, 'no sessionJWT for self-mint without JWTanswerURL (persistence not requested)');
};

subtest 'SELF_MINT_DISABLED=1: ungrounded render emits no problemJWT' => sub {
	local $ENV{STRICT_JWT}         = 0;
	local $ENV{SELF_MINT_DISABLED} = 1;
	$t->post_ok(
		'/render-api',
		{ Accept => 'application/json' },
		form => {
			problemSource => $pg_source,
			problemSeed   => 1234,
		},
	)->status_is(200);
	my $resp = Mojo::JSON::decode_json($t->tx->res->body);
	ok(!$resp->{JWT}{problem}, 'no problemJWT minted when self-mint disabled');
	ok(!$resp->{JWT}{session}, 'no sessionJWT either (nothing to ground it)');
};

subtest 'SELF_MINT_DISABLED has no effect when STRICT_JWT=1' => sub {
	local $ENV{STRICT_JWT}         = 1;
	local $ENV{SELF_MINT_DISABLED} = 1;
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'simple',
		problemSeed   => 1234,
	);
	$t->post_ok('/render-api', { 'Content-Type' => 'application/x-www-form-urlencoded' }, $body,)->status_is(401);
};

# ── HTML continuation surface: problemJWT round-trip ─────────────────
# Self-minted problemJWT must end up in the rendered HTML as a hidden field
# so subsequent submits carry it back. Truthy guard means we never emit
# `value=""` for an undef JWT (which would crash Crypt::JWT::decode_jwt on
# the next request with "missing token").

subtest 'HTML emits problemJWT when self-minted, no sessionJWT (no JWTanswerURL)' => sub {
	local $ENV{STRICT_JWT} = 0;
	local $ENV{SELF_MINT_DISABLED};
	delete $ENV{SELF_MINT_DISABLED};
	# Exploratory render (instructor, no JWTanswerURL). Self-mint produces a
	# problemJWT for round-trip; sessionJWT is NOT minted because no caller
	# asked for persistence.
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'simple',
		problemSeed   => 1234,
		isInstructor  => 1,
	);
	$t->post_ok('/render-api', { 'Content-Type' => 'application/x-www-form-urlencoded' }, $body,)->status_is(200);
	my $html = $t->tx->res->body;
	like(
		$html,
		qr/<input[^>]*name="problemJWT"[^>]*value="[^"]+"/,
		'problemJWT hidden field present with non-empty value'
	);
	unlike(
		$html,
		qr/<input[^>]*name="sessionJWT"/,
		'sessionJWT hidden field NOT emitted when caller provided no JWTanswerURL'
	);
	unlike($html, qr/<input[^>]*name="problemJWT"[^>]*value=""/, 'problemJWT never emits empty value');
};

subtest 'HTML emits sessionJWT when caller provided JWTanswerURL (instructor)' => sub {
	local $ENV{STRICT_JWT} = 0;
	# Instructor + caller-provided JWTanswerURL = persistence requested.
	# sessionJWT is minted regardless of isInstructor. The controller's submit
	# dispatcher fires the answerURL POST whenever a JWT-borne answerURL is
	# present (renderer is dumb — it does as it's told); isInstructor is the
	# orchestrator's concern. We supply a problemJWT carrying both
	# isInstructor=1 and a JWTanswerURL, signed with problemJWTsecret.
	my $problemJWT = encode_jwt(
		payload => {
			aud          => $ENV{SITE_HOST},
			iss          => $ENV{SITE_HOST},
			isInstructor => 1,
			JWTanswerURL => 'https://upstream.example.test/answer',
			pg_hash      => 'sha256:probe',
			problemUUID  => 'probe-uuid',
		},
		key      => $ENV{problemJWTsecret},
		alg      => 'HS256',
		auto_iat => 1,
	);
	my $body = form_body(
		problemSource => $pg_source,
		problemJWT    => $problemJWT,
		outputFormat  => 'simple',
		problemSeed   => 1234,
	);
	$t->post_ok('/render-api', { 'Content-Type' => 'application/x-www-form-urlencoded' }, $body,)->status_is(200);
	my $html = $t->tx->res->body;
	like($html, qr/<input[^>]*name="problemJWT"[^>]*value="[^"]+"/, 'problemJWT hidden field present');
	like(
		$html,
		qr/<input[^>]*name="sessionJWT"[^>]*value="[^"]+"/,
		'sessionJWT minted + injected (instructor + JWTanswerURL)'
	);
	unlike($html, qr/value=""/, 'no empty hidden values anywhere');
};

subtest 'empty-string sessionJWT submit is treated as not-present' => sub {
	local $ENV{STRICT_JWT} = 0;
	# Simulates the form-resubmit path: client sends sessionJWT="" because the
	# template (pre-fix) emitted an empty hidden field. With the defensive
	# delete-up-front in parseRequest, this should render normally instead of
	# 500-ing with "JWT: missing token".
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'simple',
		problemSeed   => 1234,
		sessionJWT    => '',
	);
	$t->post_ok('/render-api', { 'Content-Type' => 'application/x-www-form-urlencoded' }, $body,)->status_is(200);
};

subtest 'empty-string problemJWT submit is treated as not-present' => sub {
	local $ENV{STRICT_JWT} = 0;
	my $body = form_body(
		problemSource => $pg_source,
		outputFormat  => 'simple',
		problemSeed   => 1234,
		problemJWT    => '',
	);
	$t->post_ok('/render-api', { 'Content-Type' => 'application/x-www-form-urlencoded' }, $body,)->status_is(200);
};

done_testing();
