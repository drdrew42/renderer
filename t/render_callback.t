use Mojo::Base -strict;
use Test::More;
use Test::Mojo;

# Subtest names contain Unicode (→, ──) — encode TAP output as UTF-8 so
# Test2::Formatter::TAP doesn't emit "Wide character in print" warnings.
binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
binmode Test::More->builder->todo_output,    ':encoding(UTF-8)';

use lib 't/lib';
use TestHelper qw(temp_render_root);

use Crypt::Ed25519;
use Digest::SHA qw(sha256_hex);
use MIME::Base64 qw(encode_base64 decode_base64);
use Mojo::JSON qw(encode_json);

# Set up a temp RENDER_ROOT so Renderer can boot
my $root = temp_render_root();
$ENV{RENDER_ROOT} = $root;
$ENV{SITE_HOST}   = 'https://renderer.test.edu';
$ENV{baseURL}     = '';

# Don't try to contact a real OPL during tests
delete $ENV{OPL_API_URL};

my $t = TestHelper::test_app();

# ── Callback without OPL registration → 503 ─────────────────────────

subtest 'Callback before registration → 503' => sub {
	my ($pub, $sec) = Crypt::Ed25519::generate_keypair();
	my $body = encode_json({ pg_source => 'DOCUMENT(); ENDDOCUMENT();', seed => 42 });
	my $sig  = Crypt::Ed25519::sign($body, $pub, $sec);

	$t->post_ok('/render-api/callback'
		=> {
			'Content-Type'          => 'application/json',
			'X-Telemetry-Signature' => encode_base64($sig, ''),
		}
		=> $body)
		->status_is(503)
		->json_like('/error' => qr/registration not completed/);
};

# ── Callback without signature → 401 ─────────────────────────────────

subtest 'Callback without signature → 503 (no OPL registration)' => sub {
	# Without a registered OPL public key, the registration guard fires before
	# the signature check — both unsigned and signed requests get 503.
	$t->post_ok('/render-api/callback'
		=> { 'Content-Type' => 'application/json' }
		=> encode_json({ pg_source => 'DOCUMENT(); ENDDOCUMENT();', seed => 42 }))
		->status_is(503)
		->json_like('/error' => qr/registration not completed/);
};

# ── normalize_for_hash: src stripping ─────────────────────────────────

subtest 'normalize_for_hash: strips src from img/script/iframe' => sub {
	local $ENV{SITE_HOST} = '';
	local $ENV{baseURL}   = '';

	my $html = '<img src="https://opl.example.edu/api/resources/42.png" alt="graph" width="400">'
		. '<script src="https://cdn.example.com/mathjax.js"></script>'
		. '<iframe src="https://embed.example.com/widget"></iframe>';

	my $normalized = Renderer::Telemetry::normalize_for_hash($html);

	unlike $normalized, qr/opl\.example\.edu/, 'OPL host stripped from img src';
	unlike $normalized, qr/cdn\.example\.com/, 'CDN host stripped from script src';
	unlike $normalized, qr/embed\.example\.com/, 'host stripped from iframe src';
	like $normalized, qr/alt="graph"/, 'alt attribute preserved';
	like $normalized, qr/width="400"/, 'width attribute preserved';
	like $normalized, qr/<img\b/, 'img tag still present';
	like $normalized, qr/<script\b/, 'script tag still present';
};

subtest 'normalize_for_hash: strips action from form' => sub {
	local $ENV{SITE_HOST} = '';
	local $ENV{baseURL}   = '';

	my $html = '<form action="https://renderer.test.edu/render-api" method="post" class="problem">';
	my $normalized = Renderer::Telemetry::normalize_for_hash($html);

	unlike $normalized, qr/action=/, 'action attribute stripped';
	like $normalized, qr/method="post"/, 'method attribute preserved';
	like $normalized, qr/class="problem"/, 'class attribute preserved';
};

# ── normalize_for_hash: SITE_HOST + baseURL ───────────────────────────

subtest 'normalize_for_hash: SITE_HOST and baseURL in non-src contexts' => sub {
	local $ENV{SITE_HOST} = 'https://renderer.test.edu';
	local $ENV{baseURL}   = '/ww3';

	# A remaining href or inline reference that isn't an img/script/iframe src
	my $html = '<a href="https://renderer.test.edu/ww3/help">Help</a>';
	my $normalized = Renderer::Telemetry::normalize_for_hash($html);

	unlike $normalized, qr/renderer\.test\.edu/, 'SITE_HOST replaced';
	like $normalized, qr/__SITE_HOST__/, 'placeholder present';
};

# ── normalize_for_hash: whitespace ────────────────────────────────────

subtest 'normalize_for_hash: whitespace collapse outside pre/code' => sub {
	local $ENV{SITE_HOST} = '';
	local $ENV{baseURL}   = '';

	my $html = "<div>  lots   of   space  </div><pre>  keep   me  </pre>";
	my $normalized = Renderer::Telemetry::normalize_for_hash($html);

	like $normalized, qr/<div> lots of space <\/div>/, 'whitespace collapsed in div';
	like $normalized, qr/<pre>  keep   me  <\/pre>/, 'whitespace preserved in pre';
};

subtest 'normalize_for_hash: empty input' => sub {
	is Renderer::Telemetry::normalize_for_hash(''), '', 'empty string returns empty';
	is Renderer::Telemetry::normalize_for_hash(undef), '', 'undef returns empty';
};

# ── content_hash: answers affect hash ─────────────────────────────────

subtest 'content_hash: same text, different answers → different hash' => sub {
	local $ENV{SITE_HOST} = '';
	local $ENV{baseURL}   = '';

	my $text = '<p>What is the derivative?</p>';

	my $hash_a = Renderer::Telemetry::content_hash($text, {
		AnSwEr0001 => { correct_ans => '2x' },
	});
	my $hash_b = Renderer::Telemetry::content_hash($text, {
		AnSwEr0001 => { correct_ans => '3x^2' },
	});

	ok $hash_a, 'hash_a defined';
	ok $hash_b, 'hash_b defined';
	isnt $hash_a, $hash_b, 'different correct_ans → different hash';
};

subtest 'content_hash: same text, same answers → same hash' => sub {
	local $ENV{SITE_HOST} = '';
	local $ENV{baseURL}   = '';

	my $text = '<p>Compute the integral.</p>';
	my $answers = { AnSwEr0001 => { correct_ans => 'x^2 + C' } };

	my $hash_a = Renderer::Telemetry::content_hash($text, $answers);
	my $hash_b = Renderer::Telemetry::content_hash($text, $answers);

	is $hash_a, $hash_b, 'identical inputs → identical hash';
};

subtest 'content_hash: same text, no answers vs with answers → different hash' => sub {
	local $ENV{SITE_HOST} = '';
	local $ENV{baseURL}   = '';

	my $text = '<p>True or False?</p>';

	my $hash_none = Renderer::Telemetry::content_hash($text, {});
	my $hash_with = Renderer::Telemetry::content_hash($text, {
		AnSwEr0001 => { correct_ans => 'True' },
	});

	isnt $hash_none, $hash_with, 'answers present vs absent → different hash';
};

subtest 'content_hash: different img src, same structure → same hash' => sub {
	local $ENV{SITE_HOST} = '';
	local $ENV{baseURL}   = '';

	my $text_a = '<p>Look: <img src="https://opl-a.edu/res/42.png" alt="graph"></p>';
	my $text_b = '<p>Look: <img src="https://opl-b.edu/res/42.png" alt="graph"></p>';

	my $hash_a = Renderer::Telemetry::content_hash($text_a, {});
	my $hash_b = Renderer::Telemetry::content_hash($text_b, {});

	is $hash_a, $hash_b, 'different OPL hosts in img src → same hash';
};

subtest 'content_hash: different form action → same hash' => sub {
	local $ENV{SITE_HOST} = '';
	local $ENV{baseURL}   = '';

	my $text_a = '<form action="https://renderer-a.edu/render-api" method="post"><input name="q"></form>';
	my $text_b = '<form action="https://renderer-b.edu/render-api" method="post"><input name="q"></form>';

	my $hash_a = Renderer::Telemetry::content_hash($text_a, {});
	my $hash_b = Renderer::Telemetry::content_hash($text_b, {});

	is $hash_a, $hash_b, 'different form actions → same hash';
};

subtest 'content_hash: undef text → undef' => sub {
	my $hash = Renderer::Telemetry::content_hash(undef, {});
	is $hash, undef, 'undef text returns undef';
};

done_testing();
