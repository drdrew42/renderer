use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping has_solution tests';
}

use Test::Mojo;
use Crypt::JWT qw(encode_jwt);

# WW3-142: the simple render format emits a `solutionExists` hidden field
# carrying the PG-parse fact of whether the problem has a written SOLUTION
# block. problem.js reads it off that field and forwards it as `has_solution`
# on the webwork.session.minted postMessage, so the portal can gate its
# forfeit-reveal Solution affordance before rendering it. Always emitted (1/0)
# so the value is a stable bool, never absent-vs-false.

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

# A problem WITH a written SOLUTION block.
my $pg_with_solution = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$answer = Compute("42");
BEGIN_PGML
What is the answer? [___]{$answer}
END_PGML
BEGIN_PGML_SOLUTION
The answer is 42 by definition.
END_PGML_SOLUTION
ENDDOCUMENT();
PG

# The same problem WITHOUT any SOLUTION block.
my $pg_without_solution = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "PGML.pl", "MathObjects.pl");
Context("Numeric");
$answer = Compute("42");
BEGIN_PGML
What is the answer? [___]{$answer}
END_PGML
ENDDOCUMENT();
PG

# Order-independent match of a hidden input carrying both id and value.
sub solution_field_re {
	my ($value) = @_;
	return qr{<input(?=[^>]*\bid="solutionExists")(?=[^>]*\bvalue="$value")[^>]*>};
}

subtest 'solutionExists = 1 when the problem has a SOLUTION block' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_with_solution,
		problemSeed   => 1234,
	);

	$t->post_ok(
		'/render-api' => form => {
			problemJWT   => $jwt,
			outputFormat => 'default',
		}
	)->status_is(200)->content_like(solution_field_re(1), 'simple format emits solutionExists=1');
};

subtest 'solutionExists = 0 when the problem has no SOLUTION block' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_without_solution,
		problemSeed   => 1234,
	);

	$t->post_ok(
		'/render-api' => form => {
			problemJWT   => $jwt,
			outputFormat => 'default',
		}
	)->status_is(200)->content_like(solution_field_re(0), 'simple format emits solutionExists=0')
		->content_unlike(solution_field_re(1), 'and not solutionExists=1');
};

done_testing();
