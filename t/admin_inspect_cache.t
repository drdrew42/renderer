use Mojo::Base -strict, -signatures;
use Test::More;
use Test::Mojo;

# Subtest names contain Unicode (→) — encode TAP output as UTF-8.
binmode Test::More->builder->output,         ':encoding(UTF-8)';
binmode Test::More->builder->failure_output, ':encoding(UTF-8)';
binmode Test::More->builder->todo_output,    ':encoding(UTF-8)';

use lib 't/lib';
use TestHelper qw(temp_render_root);

use Crypt::Ed25519;
use MIME::Base64 qw(encode_base64);
use Mojo::JSON qw(encode_json);
use File::Path qw(make_path);
use File::Spec;

# WW3-R42: signed /render-api/admin/inspect-cache endpoint.
# Auth mirrors the existing /render-api/callback prelude (Ed25519 from OPL).

my $root = temp_render_root();
$ENV{RENDER_ROOT} = $root;
$ENV{SITE_HOST}   = 'https://renderer.test.edu';
$ENV{baseURL}     = '';
delete $ENV{OPL_API_URL};

my ($opl_pub, $opl_sec) = Crypt::Ed25519::generate_keypair();
$ENV{RENDERER_PEERS} = encode_json([
	{ name => 'opl', public_key => encode_base64($opl_pub, '') },
]);

my $t = TestHelper::test_app();

make_path(File::Spec->catdir($root, 'private', 'macros'));

sub signed_post ($body_hash) {
	my $body = encode_json($body_hash);
	my $sig  = Crypt::Ed25519::sign($body, $opl_pub, $opl_sec);
	return $t->post_ok('/render-api/admin/inspect-cache' => {
		'Content-Type'          => 'application/json',
		'X-Telemetry-Signature' => encode_base64($sig, ''),
	} => $body);
}

require Renderer::ContentCache;

subtest 'inspect: consistent cache → consistent:true' => sub {
	Renderer::ContentCache::stage_macro('sha256:insp_a', 'aaa');
	Renderer::ContentCache::stage_macro('sha256:insp_b', 'bbb');
	Renderer::ContentCache::stage_problem(
		'pg_inspect_ok',
		"DOCUMENT(); loadMacros('a.pl','b.pl'); ENDDOCUMENT();",
		[
			{ name => 'a.pl', hash => 'sha256:insp_a', source_type => 'custom' },
			{ name => 'b.pl', hash => 'sha256:insp_b', source_type => 'custom' },
		],
	);

	signed_post({ pg_hash => 'pg_inspect_ok' })
		->status_is(200)
		->json_is('/pg_hash'    => 'pg_inspect_ok')
		->json_is('/exists'     => Mojo::JSON::true)
		->json_is('/consistent' => Mojo::JSON::true)
		->json_is('/report/macros_missing_from_disk' => [])
		->json_is('/report/load_macros_not_in_manifest' => []);
};

subtest 'inspect: missing-macro-file cache → consistent:false + report shows it' => sub {
	Renderer::ContentCache::stage_macro('sha256:insp_c', 'ccc');
	Renderer::ContentCache::stage_macro('sha256:insp_d', 'ddd');
	Renderer::ContentCache::stage_problem(
		'pg_inspect_bad',
		"DOCUMENT(); loadMacros('c.pl','d.pl'); ENDDOCUMENT();",
		[
			{ name => 'c.pl', hash => 'sha256:insp_c', source_type => 'custom' },
			{ name => 'd.pl', hash => 'sha256:insp_d', source_type => 'custom' },
		],
	);
	# Simulate invalidate_macro racing — unlink one macro file without cascading.
	unlink File::Spec->catfile($root, 'private', 'macros', 'sha256:insp_d');

	signed_post({ pg_hash => 'pg_inspect_bad' })
		->status_is(200)
		->json_is('/consistent' => Mojo::JSON::false)
		->json_is('/report/macros_missing_from_disk' => ['sha256:insp_d']);
};

subtest 'inspect: nonexistent pg_hash → consistent:false + reason no_problem_dir' => sub {
	signed_post({ pg_hash => 'pg_inspect_missing' })
		->status_is(200)
		->json_is('/exists'            => Mojo::JSON::false)
		->json_is('/consistent'        => Mojo::JSON::false)
		->json_is('/report/reason'     => 'no_problem_dir');
};

subtest 'inspect: missing pg_hash field → 400' => sub {
	signed_post({})
		->status_is(400)
		->json_like('/error' => qr/missing pg_hash/);
};

subtest 'inspect: bad signature → 401' => sub {
	my $body = encode_json({ pg_hash => 'whatever' });
	my $bad_sig = Crypt::Ed25519::sign('different bytes', $opl_pub, $opl_sec);
	$t->post_ok('/render-api/admin/inspect-cache' => {
		'Content-Type'          => 'application/json',
		'X-Telemetry-Signature' => encode_base64($bad_sig, ''),
	} => $body)
		->status_is(401)
		->json_like('/error' => qr/invalid signature/);
};

done_testing();
