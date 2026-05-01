package Renderer::Permissions;

# resolve_permissions($inputs_ref) → hashref of booleans:
#   { isInstructor, showCorrectAnswers, showSolutions, showHints }
#
# Single decision point for the renderer's "what gets shown" rules.
# Previously these defaults lived in an inline if/else inside
# WeBWorK::RenderProblem::standaloneRenderer, with the same selection
# logic spread across two branches. Hoisting them keeps the logic in
# one testable place and makes the WeBWorK::PG->new() call boundary
# the only site that knows about PG's 0/2 magic value for
# showCorrectAnswers.
#
# Permission model:
#
#   Instructor (preview): everything visible by default. Callers can
#     suppress individual flags to see the student view.
#
#   Student (assessed): nothing revealed by default. showCorrectAnswers
#     is the primary reveal trigger (the "Show Correct Answers" button).
#     Solutions ride with correct answers unless explicitly suppressed
#     (showSolutions=0). showSolutions alone is ignored — solutions
#     don't make sense without the answers they explain. Hints are
#     always available (PG's showHints is a render gate, not
#     security-sensitive).
#
# The `isInstructor` field is the mode switch and is normalized to a
# strict 0/1 boolean here. Callers that previously read
# `$inputs_ref->{isInstructor}` directly should switch to the resolver
# output to get the same normalization in one place.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Exporter qw(import);
our @EXPORT_OK = qw(resolve_permissions reveal_state);

sub resolve_permissions ($inputs_ref) {
	my $isInstructor = $inputs_ref->{isInstructor} ? 1 : 0;

	my ($showCorrectAnswers, $showSolutions, $showHints);

	if ($isInstructor) {
		# Defaults to "show" for each flag; explicit 0 from caller wins.
		$showCorrectAnswers = defined $inputs_ref->{showCorrectAnswers}
			? ($inputs_ref->{showCorrectAnswers} ? 1 : 0) : 1;
		$showSolutions = defined $inputs_ref->{showSolutions}
			? ($inputs_ref->{showSolutions} ? 1 : 0) : 1;
		$showHints = defined $inputs_ref->{showHints}
			? ($inputs_ref->{showHints} ? 1 : 0) : 1;
	} else {
		$showCorrectAnswers = $inputs_ref->{showCorrectAnswers} ? 1 : 0;

		# Solutions ride with correct answers unless explicitly suppressed
		# (showSolutions=0 wins; absence or truthy lets correct-answers
		# decide).
		$showSolutions = ($showCorrectAnswers
			&& !(defined $inputs_ref->{showSolutions} && !$inputs_ref->{showSolutions})) ? 1 : 0;

		$showHints = defined $inputs_ref->{showHints}
			? ($inputs_ref->{showHints} ? 1 : 0) : 1;
	}

	return {
		isInstructor       => $isInstructor,
		showCorrectAnswers => $showCorrectAnswers,
		showSolutions      => $showSolutions,
		showHints          => $showHints,
	};
}

# Compute the reveal-reporting facts for the current render. Returns the six
# fields the answerJWT and submissionJWT carry per WW3-R29:
#   answers_requested      — per-render, effective showCorrectAnswers
#   solutions_requested    — per-render, effective showSolutions
#   answers_revealed_in    — inbound cumulative (state-at-submission-time)
#   solutions_revealed_in  — inbound cumulative
#   answers_revealed_out   — outbound cumulative (sticky one-way: prior OR newly ratcheted)
#   solutions_revealed_out — outbound cumulative
#
# The ratchet only flips 0→1 when *_requested fires AND post-render is still
# incomplete (recorded_score < 1). Earned-then-peek doesn't ratchet.
#
# Decoupled from PG: caller passes the recorded_score scalar so this module
# stays in pure-permission territory and doesn't reach into $pg internals.
# Moved from WeBWorK::RenderProblem in WW3-R36.
sub reveal_state ($inputs_ref, $recorded_score = 0) {
	my $perms = resolve_permissions($inputs_ref);
	my $answers_requested   = $perms->{showCorrectAnswers};
	my $solutions_requested = $perms->{showSolutions};

	my $answers_revealed_in   = $inputs_ref->{answersRevealed}   ? 1 : 0;
	my $solutions_revealed_in = $inputs_ref->{solutionsRevealed} ? 1 : 0;

	my $earned = ($recorded_score // 0) >= 1;

	my $answers_revealed_out =
		($answers_revealed_in   || ($answers_requested   && !$earned)) ? 1 : 0;
	my $solutions_revealed_out =
		($solutions_revealed_in || ($solutions_requested && !$earned)) ? 1 : 0;

	return {
		answers_requested      => $answers_requested,
		solutions_requested    => $solutions_requested,
		answers_revealed_in    => $answers_revealed_in,
		solutions_revealed_in  => $solutions_revealed_in,
		answers_revealed_out   => $answers_revealed_out,
		solutions_revealed_out => $solutions_revealed_out,
	};
}

1;
