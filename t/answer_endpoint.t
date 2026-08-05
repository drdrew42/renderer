use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping answer endpoint tests';
}

use Test::Mojo;

$ENV{problemJWTsecret} //= 'test-problem-secret';
$ENV{webworkJWTsecret} //= 'test-session-secret';
$ENV{SITE_HOST}        //= 'test.local';
delete $ENV{STRICT_JWT};
delete $ENV{OPL_API_URL};

my $t = Test::Mojo->new('Renderer');

# JSON-only endpoint; real callers send Accept. $c->exception honours content
# negotiation, so without this the error assertions would get the HTML
# exception template. Mirrors t/hint_solution_endpoints.t.
$t->ua->on(
	start => sub {
		my ($ua, $tx) = @_;
		$tx->req->headers->accept('application/json') unless $tx->req->headers->accept;
	}
);

use Renderer::Util::JWT qw(mint_jwt);

sub mint_typed {
	my ($typ, %extra) = @_;
	return mint_jwt($ENV{problemJWTsecret}, { typ => $typ, aud => $ENV{SITE_HOST}, %extra });
}

my $render_root = $ENV{RENDER_ROOT};
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

# Two blanks with distinct answers, so a per-blank projection is
# distinguishable from "returned something".
my $pg_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "MathObjects.pl", "PGML.pl");
Context("Numeric");
$a = Compute("42");
$b = Compute("7/2");
BEGIN_PGML
First: [_]{$a}
Second: [_]{$b}
END_PGML
BEGIN_PGML_SOLUTION
Because it is.
END_PGML_SOLUTION
ENDDOCUMENT();
PG

subtest 'returns the canonical answer per blank' => sub {
	my $jwt = mint_typed('answer', problemSource => $pg_source, problemSeed => 1234);
	$t->post_ok('/render-api/answer' => form => { problemJWT => $jwt })->status_is(200)->json_is('/status' => 200)
		->json_has('/answers');

	my $answers = $t->tx->res->json->{answers};
	is(scalar keys %$answers, 2, 'one entry per answer blank');

	my @labels = sort keys %$answers;
	is($answers->{ $labels[0] }{correct_ans}, '42', 'first blank carries its correct answer');
	like($answers->{ $labels[1] }{correct_ans}, qr{7/2|3\.5}, 'second blank carries its own, not the first');

	ok(exists $answers->{ $labels[0] }{correct_ans_latex_string}, 'latex string present for rendering');
};

subtest 'the projection is narrow — no AnswerHash spill' => sub {
	# The whole point of R47: NOT unbless($pg->{answers}) behind a nicer
	# door. A caller gets the two fields it renders and nothing else —
	# no evaluator internals, no student answer, no score.
	my $jwt = mint_typed('answer', problemSource => $pg_source, problemSeed => 1234);
	$t->post_ok('/render-api/answer' => form => { problemJWT => $jwt })->status_is(200);

	my $answers = $t->tx->res->json->{answers};
	for my $label (keys %$answers) {
		is_deeply(
			[ sort keys %{ $answers->{$label} } ],
			[qw(correct_ans correct_ans_latex_string)],
			"$label exposes exactly the two projected fields"
		);
	}
};

subtest 'no HTML is produced or returned' => sub {
	my $jwt = mint_typed('answer', problemSource => $pg_source, problemSeed => 1234);
	$t->post_ok('/render-api/answer' => form => { problemJWT => $jwt })->status_is(200);

	my $body = $t->tx->res->body;
	unlike($body, qr/<div/,           'no markup in the response');
	unlike($body, qr/solution/i,      'the SOLUTION block is not along for the ride');
	unlike($body, qr/renderedHTML/,   'no render envelope');
};

subtest 'typ is enforced — a solution token cannot fetch answers' => sub {
	my $jwt = mint_typed('solution', problemSource => $pg_source, problemSeed => 1234);
	$t->post_ok('/render-api/answer' => form => { problemJWT => $jwt })->status_is(401);
};

subtest 'an untyped problemJWT is refused' => sub {
	my $jwt = mint_jwt($ENV{problemJWTsecret},
		{ aud => $ENV{SITE_HOST}, problemSource => $pg_source, problemSeed => 1234 });
	$t->post_ok('/render-api/answer' => form => { problemJWT => $jwt })->status_is(401);
};

subtest 'no token at all is refused' => sub {
	$t->post_ok('/render-api/answer' => form => { problemSource => $pg_source, problemSeed => 1234 })
		->status_is(401);
};

subtest 'the token binds the source — form data cannot redirect it' => sub {
	# claims-always-win: a typed token can only fetch what it was minted
	# for, so swapping problemSource in the form must not change the answer.
	my $other = $pg_source;
	$other =~ s/Compute\("42"\)/Compute("999")/;

	my $jwt = mint_typed('answer', problemSource => $pg_source, problemSeed => 1234);
	$t->post_ok('/render-api/answer' => form => { problemJWT => $jwt, problemSource => $other })->status_is(200);

	my $answers = $t->tx->res->json->{answers};
	my @labels  = sort keys %$answers;
	is($answers->{ $labels[0] }{correct_ans}, '42', 'the claim won, not the form');
};

subtest 'a broken problem surfaces as 500, not as an empty answer set' => sub {
	my $jwt = mint_typed('answer', problemSource => "DOCUMENT();\nthis is not perl(((\nENDDOCUMENT();",
		problemSeed => 1234);
	$t->post_ok('/render-api/answer' => form => { problemJWT => $jwt })->status_is(500);
};

done_testing();
