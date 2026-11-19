use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# LTW-105: image names resolve through the OPL resource map at alias time.

BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping resource map tests';
}

use Test::Mojo;

$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';
$ENV{SITE_HOST}        //= 'https://test.example.com';
delete $ENV{OPL_API_URL};

my $t           = Test::Mojo->new('Renderer');
my $render_root = $ENV{RENDER_ROOT};
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

require Renderer::ContentCache;

my $H   = 'sha256:' . ('c' x 64);
my $URL = "https://opl.example.edu/api/resources/$H.gif";

# The file name is built at runtime, so no text rewrite can reach it.
my $runtime_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl");
$n = 2;
$name = $n . ".gif";
BEGIN_PGML
[@ image($name, width => 100) @]*
[@ image("./" . $name, width => 100) @]*
END_PGML
ENDDOCUMENT();
PG

my %staged;
sub stage {
	my ($path, $pg_hash, $source, $resources) = @_;
	Renderer::ContentCache::stage_problem($pg_hash, $source, [], $resources) or die "stage $pg_hash";
	Renderer::ContentCache::save_path_index($path, $pg_hash);
	$staged{$pg_hash} = 1;
}

sub render {
	my ($path) = @_;
	local $ENV{CONTENT_ADDRESSED} = 1;
	$t->post_ok('/render-api' => form => { sourceFilePath => $path, outputFormat => 'simple', problemSeed => 1 })
		->status_is(200);
	return $t->tx->res->body;
}

subtest 'get_injected_resources maps link filename to URL' => sub {
	stage('test/ltw105/map.pg', 'ltw105_map', $runtime_source,
		[ { content_hash => $H, alt => undef, filename => '2.gif', url => $URL } ]);
	is_deeply Renderer::ContentCache::get_injected_resources('ltw105_map'), { '2.gif' => $URL };
};

subtest 'a runtime-built name resolves to the OPL URL, as written and with ./' => sub {
	stage('test/ltw105/runtime.pg', 'ltw105_runtime', $runtime_source,
		[ { content_hash => $H, alt => 'Stored alt for the graph', filename => '2.gif', url => $URL } ]);
	my $body = render('test/ltw105/runtime.pg');
	my @srcs = $body =~ m{<img[^>]*\bsrc="([^"]+)"}g;
	is_deeply \@srcs, [ $URL, $URL ], 'both images point at the OPL URL';
	unlike $body, qr/Unable to find file/, 'no missing-file warning';
	like $body, qr{<img[^>]*alt="Stored alt for the graph"}, 'the stored alt fills the resolved image';
};

subtest 'a cache staged without filenames renders as before' => sub {
	stage('test/ltw105/legacy.pg', 'ltw105_legacy', $runtime_source,
		[ { content_hash => $H, alt => 'Stored alt for the graph' } ]);
	is_deeply Renderer::ContentCache::get_injected_resources('ltw105_legacy'), {}, 'no map';
	my $body = render('test/ltw105/legacy.pg');
	unlike $body, qr{\Q$URL\E}, 'nothing resolves to the OPL URL';
};

subtest 'a literal URL in the source is unaffected' => sub {
	my $src = $runtime_source =~ s/\$name = \$n \. "\.gif";/\$name = "$URL";/r;
	$src =~ s/\[\@ image\("\.\/" \. \$name, width => 100\) \@\]\*\n//;
	stage('test/ltw105/literal.pg', 'ltw105_literal', $src,
		[ { content_hash => $H, alt => undef, filename => '2.gif', url => $URL } ]);
	my @srcs = render('test/ltw105/literal.pg') =~ m{<img[^>]*\bsrc="([^"]+)"}g;
	is_deeply \@srcs, [$URL];
};

END { Renderer::ContentCache::invalidate($_) for keys %staged }

done_testing;
