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

subtest 'instructor: explicit suppression wins' => sub {
	my $p = resolve_permissions({
		isInstructor       => 1,
		showCorrectAnswers => 0,
		showSolutions      => 0,
		showHints          => 0,
	});
	is($p->{showCorrectAnswers}, 0, 'explicit 0 suppresses correct answers');
	is($p->{showSolutions},      0, 'explicit 0 suppresses solutions');
	is($p->{showHints},          0, 'explicit 0 suppresses hints');
};

# ─── Student mode (assessed): nothing revealed by default ─────────────────

subtest 'student: everything off by default' => sub {
	my $p = resolve_permissions({ isInstructor => 0 });
	is($p->{showCorrectAnswers}, 0, 'showCorrectAnswers off');
	is($p->{showSolutions},      0, 'showSolutions off (no correct answers to ride with)');
	is($p->{showHints},          1, 'showHints defaults on (PG render gate, not security-sensitive)');
};

subtest 'student: showCorrectAnswers triggers solutions to ride along' => sub {
	my $p = resolve_permissions({
		isInstructor       => 0,
		showCorrectAnswers => 1,
	});
	is($p->{showCorrectAnswers}, 1, 'correct answers shown');
	is($p->{showSolutions},      1, 'solutions ride along by default');
};

subtest 'student: explicit showSolutions=0 suppresses ride-along' => sub {
	my $p = resolve_permissions({
		isInstructor       => 0,
		showCorrectAnswers => 1,
		showSolutions      => 0,
	});
	is($p->{showCorrectAnswers}, 1, 'correct answers shown');
	is($p->{showSolutions},      0, 'solutions explicitly suppressed');
};

subtest 'student: showSolutions alone (no correct answers) is ignored' => sub {
	my $p = resolve_permissions({
		isInstructor  => 0,
		showSolutions => 1,
	});
	is($p->{showCorrectAnswers}, 0, 'no correct answers');
	is($p->{showSolutions},      0, 'solutions without correct answers makes no sense');
};

subtest 'student: showHints respects explicit value' => sub {
	my $p = resolve_permissions({
		isInstructor => 0,
		showHints    => 0,
	});
	is($p->{showHints}, 0, 'explicit 0 suppresses hints');
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
