package Renderer::Permissions;

# resolve_permissions($inputs_ref) → hashref of booleans:
#   { isInstructor, showCorrectAnswers, showSolutions, showHints,
#     show_pg_info, show_answer_hash_info, show_answer_group_info,
#     show_resource_info }
# The four show_* flags are the permission half of PG's debug gate (WW3-R56).
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
#   Instructor (preview / revealAll): everything visible — showHints,
#     showSolutions, and showCorrectAnswers all forced to 1. The mode is
#     intended for authoring previews and library browsing; if a caller
#     wants the "what would a student see" view, mint a JWT with
#     isInstructor=0 instead of trying to suppress per-flag.
#
#   Student (assessed): nothing revealed by default. showCorrectAnswers
#     is the only in-render reveal trigger (the "Show Correct Answers"
#     button). Hints and solutions are NEVER rendered in the main
#     response — `showHints` and `showSolutions` are hardwired to 0
#     regardless of inbound. Callers wanting hint or solution content
#     must use the dedicated `/render-api/hint` and `/render-api/solution`
#     endpoints, which are gated by typed-JWT and minted policy-side by
#     the LMS / orchestrator. This minimizes the cheat surface: the
#     student-facing render carries only the problem, never the canonical
#     answer derivation.
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
		# revealAll: everything on. No per-flag suppression; if a caller
		# wants the student view, mint with isInstructor=0.
		$showCorrectAnswers = 1;
		$showSolutions      = 1;
		$showHints          = 1;
	} else {
		# Student: showCorrectAnswers is the only in-render reveal.
		# Hints and solutions are hardwired off — fetch via /render-api/hint
		# and /render-api/solution endpoints instead.
		$showCorrectAnswers = $inputs_ref->{showCorrectAnswers} ? 1 : 0;
		$showSolutions      = 0;
		$showHints          = 0;
	}

	# WW3-117: a verified reveal sidecar is a trusted grant and wins here — it
	# lights answers AND solutions (one grant; every problem has an answer, only
	# some a written solution, and that is a property of content, not a policy
	# to gate twice). `_reveal_grant` is set only by a lane that verified a
	# play-bound revealJWT (Renderer::RevealSidecar), and it is a SENSITIVE_PARAM
	# stripped from raw input, so it cannot be self-declared. Hints are left
	# untouched — reveal is answers + solutions, never the mode's mid-play
	# scaffolding.
	if ($inputs_ref->{_reveal_grant}) {
		$showCorrectAnswers = 1;
		$showSolutions      = 1;
	}

	# WW3-R56: the debug-info envir flags PG reads — show_pg_info,
	# show_answer_hash_info, show_answer_group_info, show_resource_info — are the
	# PERMISSION half of PG's two-factor debug gate. PG shows each surface only
	# when both this envir flag AND its camelCase request twin (showPGInfo etc.)
	# are set. The front end owns the permission half; the request half stays
	# caller-controlled in RenderProblem. Gate the permission half on
	# isInstructor so a student cannot self-grant the answer hash or the internals
	# dump by declaring both halves themselves.
	#
	# view_problem_debugging_info is deliberately NOT here: it is error verbosity
	# (caught error text, backend warnings — never the answer), an ADAPT request
	# contract, and stays caller-controlled in RenderProblem.
	my $debugPermission = $isInstructor;

	return {
		isInstructor           => $isInstructor,
		showCorrectAnswers     => $showCorrectAnswers,
		showSolutions          => $showSolutions,
		showHints              => $showHints,
		show_pg_info           => $debugPermission,
		show_answer_hash_info  => $debugPermission,
		show_answer_group_info => $debugPermission,
		show_resource_info     => $debugPermission,
	};
}

# Compute the reveal-reporting fact for the current render: was each of
# answers / solutions shown? A plain per-render pair, carried on the
# answerJWT and submissionJWT so the backend has a record of what a render
# disclosed — "just in case" (Drew, 2026-08-07).
#
#   answers_shown    — effective showCorrectAnswers this render
#   solutions_shown  — effective showSolutions this render
#
# This used to be a six-field dual-state ratchet (per-render *_requested plus
# a sticky one-way *_revealed_in/out) so the orchestrator could INFER reveal
# history from the wire. WW3-116/117 abandoned that: WW3 gates reveals on the
# frontend and records them to the chain at mint, so nothing consumed the
# sticky state — WW3 read none of it, and ADAPT hides the reveal button and
# reads none of it either. The ratchet and its answer-URL peek-trigger are
# gone; what remains is the honest per-render fact.
sub reveal_state ($inputs_ref) {
	my $perms = resolve_permissions($inputs_ref);
	return {
		answers_shown   => $perms->{showCorrectAnswers},
		solutions_shown => $perms->{showSolutions},
	};
}

1;
