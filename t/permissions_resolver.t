use strict;
use warnings;

use Test::More;
use Renderer::Permissions qw(resolve_permissions);

# Pure-function unit tests for Renderer::Permissions::resolve_permissions.
# No Mojo, no PG, no DB. The integration-level coverage in t/permissions.t
# continues to verify the rendering pipeline as a whole; this file locks
# the resolver's contract directly so the rules don't drift.

# ─── isInstructor normalization ───────────────────────────────────────────

subtest 'isInstructor normalizes to strict 0/1' => sub {
	is(resolve_permissions({})->{isInstructor},                       0, 'undef → 0');
	is(resolve_permissions({ isInstructor => 0 })->{isInstructor},    0, '0 → 0');
	is(resolve_permissions({ isInstructor => '' })->{isInstructor},   0, "'' → 0");
	is(resolve_permissions({ isInstructor => 1 })->{isInstructor},    1, '1 → 1');
	is(resolve_permissions({ isInstructor => 'y' })->{isInstructor}, 1, "truthy string → 1");
};

# ─── Instructor mode (preview): everything visible by default ────────────

subtest 'instructor: everything on by default' => sub {
	my $p = resolve_permissions({ isInstructor => 1 });
	is($p->{showCorrectAnswers}, 1, 'showCorrectAnswers defaults to 1');
	is($p->{showSolutions},      1, 'showSolutions defaults to 1');
	is($p->{showHints},          1, 'showHints defaults to 1');
};

subtest 'instructor: per-flag inputs are ignored (revealAll means all-on)' => sub {
	my $p = resolve_permissions({
		isInstructor       => 1,
		showCorrectAnswers => 0,
		showSolutions      => 0,
		showHints          => 0,
	});
	is($p->{showCorrectAnswers}, 1, 'instructor: showCorrectAnswers stays on regardless of input');
	is($p->{showSolutions},      1, 'instructor: showSolutions stays on regardless of input');
	is($p->{showHints},          1, 'instructor: showHints stays on regardless of input');
};

# ─── Student mode (assessed): hints/solutions hardwired off ──────────────

subtest 'student: everything off by default' => sub {
	my $p = resolve_permissions({ isInstructor => 0 });
	is($p->{showCorrectAnswers}, 0, 'showCorrectAnswers off');
	is($p->{showSolutions},      0, 'showSolutions hardwired off (use /render-api/solution)');
	is($p->{showHints},          0, 'showHints hardwired off (use /render-api/hint)');
};

subtest 'student: showCorrectAnswers from input, solutions/hints stay off' => sub {
	my $p = resolve_permissions({
		isInstructor       => 0,
		showCorrectAnswers => 1,
	});
	is($p->{showCorrectAnswers}, 1, 'correct answers shown');
	is($p->{showSolutions},      0, 'solutions still hardwired off');
	is($p->{showHints},          0, 'hints still hardwired off');
};

subtest 'student: inbound showSolutions/showHints are ignored' => sub {
	my $p = resolve_permissions({
		isInstructor  => 0,
		showSolutions => 1,
		showHints     => 1,
	});
	is($p->{showSolutions}, 0, 'inbound showSolutions=1 ignored — fetch via /render-api/solution');
	is($p->{showHints},     0, 'inbound showHints=1 ignored — fetch via /render-api/hint');
};

# ─── Output shape ─────────────────────────────────────────────────────────

subtest 'returns hashref with exactly the documented keys' => sub {
	my $p = resolve_permissions({});
	is(ref($p), 'HASH', 'returns a hashref');
	my @keys = sort keys %$p;
	is_deeply(\@keys,
		[ sort qw(isInstructor showCorrectAnswers showSolutions showHints) ],
		'no extra keys, no missing keys');
	for my $k (@keys) {
		ok($p->{$k} == 0 || $p->{$k} == 1,
			"$k is strict 0/1 (no magic value, no undef)");
	}
};

done_testing();
