use strict;
use warnings;

use Test::More;

# The audit handler itself needs the full app (Safe, Mojolicious).
# Future::AsyncAwait is a renderer-runtime dependency.
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping audit tests';
}

use Mojo::JSON   qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64);

# Renderer startup refuses placeholder secrets; supply test values.
$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';

use Test::Mojo;
use Renderer::Controller::Audit;

my $t = Test::Mojo->new('Renderer');

# ── Unit tests on _perform_audit (no HTTP, no auth) ──────────────────

subtest 'clean macro → no warnings, compiled ok' => sub {
	my $source = <<'PERL';
BEGIN { strict->import; }
sub add_one { return $_[0] + 1; }
1;
PERL
	my $result = Renderer::Controller::Audit::_perform_audit($source);
	ok $result->{compiled}, 'compiled';
	is scalar(@{ $result->{warnings_frontend} }), 0, 'no frontend warnings';
	is scalar(@{ $result->{warnings_backend} }),  0, 'no backend warnings';
	is scalar(@{ $result->{errors} }),            0, 'no errors';
};

subtest 'macro with s///r in void context → warning captured' => sub {
	my $source = <<'PERL';
BEGIN { strict->import; }
sub broken {
	my $x = "hello";
	$x =~ s/hello/world/r;   # void context — the modified copy is discarded
	return $x;
}
1;
PERL
	my $result = Renderer::Controller::Audit::_perform_audit($source);
	ok $result->{compiled}, 'still compiles';
	my @all_warns = (@{ $result->{warnings_frontend} }, @{ $result->{warnings_backend} });
	my @s_r       = grep { $_->{message} =~ /s\/\/\/r|non-destructive substitution/ } @all_warns;
	ok scalar(@s_r) >= 1,     's///r void warning surfaced';
	ok defined $s_r[0]{line}, 'line number captured' if @s_r;
};

subtest 'macro with syntax error → errors array, compiled false' => sub {
	my $source = <<'PERL';
sub broken { return 1;   # unclosed brace
PERL
	my $result = Renderer::Controller::Audit::_perform_audit($source);
	ok !$result->{compiled},                'did not compile';
	ok scalar(@{ $result->{errors} }) >= 1, 'error reported';
};

subtest 'empty source → compiles (trivially), no warnings' => sub {
	my $result = Renderer::Controller::Audit::_perform_audit("");
	ok $result->{compiled}, 'empty source is trivially valid';
	is scalar(@{ $result->{warnings_frontend} }), 0, 'no warnings';
};

# ── HTTP layer: auth gating (no Registration setup in this test fixture) ──

subtest 'POST /render-api/audit without registration → 503' => sub {
	$t->post_ok('/render-api/audit' => json => {})->status_is(503)
		->json_is('/error' => 'registration not completed');
};

done_testing();
