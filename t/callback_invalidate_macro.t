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
use Mojo::JSON   qw(encode_json);
use File::Path   qw(make_path);
use File::Spec;

# WW3-R39 Phase 4 — exercise the `invalidate_macro` action of the OPL
# callback endpoint. The cheap, no-PG-fork sibling of the render-probe
# action; previously untested.

my $root = temp_render_root();
$ENV{RENDER_ROOT} = $root;
$ENV{SITE_HOST}   = 'https://renderer.test.edu';
$ENV{baseURL}     = '';
delete $ENV{OPL_API_URL};

# Pin an OPL public key via RENDERER_PEERS (peer name 'opl' satisfies the
# Registration::has_opl_public_key check). Must be set BEFORE test_app()
# spins the app — startup reads RENDERER_PEERS once during init.
my ($opl_pub, $opl_sec) = Crypt::Ed25519::generate_keypair();
$ENV{RENDERER_PEERS} = encode_json([ { name => 'opl', public_key => encode_base64($opl_pub, '') }, ]);

my $t = TestHelper::test_app();

my $macros_dir = File::Spec->catdir($root, 'private', 'macros');
make_path($macros_dir);

# Helper: build a signed body and POST to /render-api/callback.
sub signed_post ($body_hash) {
	my $body = encode_json($body_hash);
	my $sig  = Crypt::Ed25519::sign($body, $opl_pub, $opl_sec);
	return $t->post_ok(
		'/render-api/callback' => {
			'Content-Type'          => 'application/json',
			'X-Telemetry-Signature' => encode_base64($sig, ''),
		} => $body
	);
}

subtest 'invalidate_macro: deletes the macro file by hash' => sub {
	my $hash = 'sha256:macro-to-invalidate';
	my $path = File::Spec->catfile($macros_dir, $hash);
	open my $fh, '>', $path or die "Cannot create macro fixture: $!";
	print $fh "sub fixture { 1 }";
	close $fh;
	ok(-f $path, 'sanity: macro file exists pre-invalidate');

	signed_post({ action => 'invalidate_macro', hash => $hash })->status_is(200)->json_is('/invalidated' => $hash)
		->json_is('/deleted' => Mojo::JSON::true);

	ok(!-f $path, 'macro file removed');
};

subtest 'invalidate_macro: missing-hash request → 400' => sub {
	signed_post({ action => 'invalidate_macro' })->status_is(400)->json_like('/error' => qr/missing hash/);
};

subtest 'invalidate_macro: hash for non-existent file → 200 deleted=false' => sub {
	# unlink on a missing file returns 0 (not an error). Endpoint reports
	# deleted=false; the OPL caller sees idempotent success.
	signed_post({ action => 'invalidate_macro', hash => 'sha256:nope-not-here' })->status_is(200)
		->json_is('/invalidated' => 'sha256:nope-not-here')->json_is('/deleted' => Mojo::JSON::false);
};

subtest 'invalidate_macro: cascades to dependent problem manifests (WW3-R42)' => sub {
	my $macro_hash = 'sha256:cascade_target';

	# Macro file present
	my $macro_path = File::Spec->catfile($macros_dir, $macro_hash);
	open my $mfh, '>', $macro_path or die $!;
	print $mfh "sub macro { 1 }";
	close $mfh;

	# Two problems reference this macro, one does not
	require Renderer::ContentCache;
	for my $pg (qw(pg_dep_alpha pg_dep_beta)) {
		Renderer::ContentCache::stage_problem(
			$pg,
			"DOCUMENT(); loadMacros('m.pl'); ENDDOCUMENT();",
			[ { name => 'm.pl', hash => $macro_hash, source_type => 'custom' } ],
		);
	}
	Renderer::ContentCache::stage_macro('sha256:other_macro', 'sub o { 1 }');
	Renderer::ContentCache::stage_problem(
		'pg_independent',
		"DOCUMENT(); loadMacros('o.pl'); ENDDOCUMENT();",
		[ { name => 'o.pl', hash => 'sha256:other_macro', source_type => 'custom' } ],
	);
	Renderer::ContentCache::save_path_index('Library/Alpha/p.pg', 'pg_dep_alpha');
	Renderer::ContentCache::save_path_index('Library/Beta/p.pg',  'pg_dep_beta');
	Renderer::ContentCache::save_path_index('Library/Other/o.pg', 'pg_independent');

	signed_post({ action => 'invalidate_macro', hash => $macro_hash })->status_is(200)
		->json_is('/invalidated' => $macro_hash)->json_is('/deleted' => Mojo::JSON::true)->json_is('/dependents' => 2);

	ok(!Renderer::ContentCache::has_problem('pg_dep_alpha'),  'dependent problem alpha evicted');
	ok(!Renderer::ContentCache::has_problem('pg_dep_beta'),   'dependent problem beta evicted');
	ok(Renderer::ContentCache::has_problem('pg_independent'), 'unrelated problem untouched');
	is(Renderer::ContentCache::pg_hash_for_path('Library/Alpha/p.pg'), undef, 'path index entry alpha pruned');
	is(Renderer::ContentCache::pg_hash_for_path('Library/Beta/p.pg'),  undef, 'path index entry beta pruned');
	is(Renderer::ContentCache::pg_hash_for_path('Library/Other/o.pg'),
		'pg_independent', 'unrelated path index untouched');
};

subtest 'invalidate_macro: bad signature → 401 (does not delete)' => sub {
	my $hash = 'sha256:protected-by-signature';
	my $path = File::Spec->catfile($macros_dir, $hash);
	open my $fh, '>', $path or die $!;
	print $fh "sub still_here { 1 }";
	close $fh;

	my $body    = encode_json({ action => 'invalidate_macro', hash => $hash });
	my $bad_sig = Crypt::Ed25519::sign('different bytes', $opl_pub, $opl_sec);

	$t->post_ok(
		'/render-api/callback' => {
			'Content-Type'          => 'application/json',
			'X-Telemetry-Signature' => encode_base64($bad_sig, ''),
		} => $body
	)->status_is(401)->json_like('/error' => qr/invalid signature/);

	ok(-f $path, 'macro file untouched when signature rejects');
};

# ── invalidate_problem (LT-080) ──────────────────────────────────────

subtest 'invalidate_problem: evicts one problem cache dir by pg_hash' => sub {
	require Renderer::ContentCache;
	Renderer::ContentCache::stage_problem('pg_invalidate_target', "DOCUMENT(); ENDDOCUMENT();",);
	Renderer::ContentCache::save_path_index('Library/Inv/p.pg', 'pg_invalidate_target');
	ok(Renderer::ContentCache::has_problem('pg_invalidate_target'), 'sanity: problem cached pre-invalidate');

	signed_post({ action => 'invalidate_problem', pg_hash => 'pg_invalidate_target' })->status_is(200)
		->json_is('/invalidated' => 'pg_invalidate_target')->json_is('/evicted' => Mojo::JSON::true);

	ok(!Renderer::ContentCache::has_problem('pg_invalidate_target'), 'problem cache dir evicted');
	is(Renderer::ContentCache::pg_hash_for_path('Library/Inv/p.pg'), undef, 'path index entry pruned');
};

subtest 'invalidate_problem: missing pg_hash → 400' => sub {
	signed_post({ action => 'invalidate_problem' })->status_is(400)->json_like('/error' => qr/missing pg_hash/);
};

subtest 'invalidate_problem: unknown pg_hash → 200 evicted=false' => sub {
	signed_post({ action => 'invalidate_problem', pg_hash => 'pg_never_cached' })->status_is(200)
		->json_is('/invalidated' => 'pg_never_cached')->json_is('/evicted' => Mojo::JSON::false);
};

done_testing();
