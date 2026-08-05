package Renderer::RenderMode;

# resolve_render_mode($inputs_ref) → mutates $inputs_ref in place + returns
#                                     the list of caller-supplied primitive
#                                     keys the mode bundle replaced.
#
# Translates the $inputs_ref->{renderMode} intent claim into the primitive
# flag bundle that mode owns. Downstream code (RenderProblem,
# FormatRenderedProblem, PG) reads primitives only — nothing past this
# resolver knows modes exist.
#
# Sequencing inside standaloneRenderer:
#   lane merge → resolve_render_mode → resolve_permissions → PG construction
#
# Modes pre-populate the primitives the orchestrator's intent owns. The
# permissions resolver still runs after — `renderMode: "preview"` sets
# isInstructor=1, which the resolver then expands to revealAll. The two
# layers compose; they don't conflict.
#
# Modes:
#   default      — staked attempts, verdict per attempt. Reveal button hidden
#                  AND the reveal itself refused (WW3-R46) — a coordinator
#                  that wants one mints it out of band rather than asking
#                  the render for it.
#   no-feedback  — score it, ship it, say nothing about correctness.
#                  hideFeedback kill-switch + reveal button hidden + reveal
#                  forced off for defense in depth.
#   review       — past-attempt display; no resubmits. Reveal button hidden
#                  and the reveal refused (WW3-R46). An instructor still
#                  sees answers via isInstructor → revealAll, which the
#                  permissions resolver applies after this bundle.
#   no-stakes    — sandbox / drill / public widget. Reveal button shown.
#   preview      — author / library browse; isInstructor=1 → revealAll
#                  bundle via the permissions resolver.
#   custom       — passthrough. No primitives locked.
#
# Unknown / absent renderMode → treated as 'custom' (forward-compat).
# Existing callers that don't send renderMode get no behavior change.
#
# Override posture: mode wins over caller-supplied primitives, silently.
# Picking a mode is opting into its bundle. The set of overridden keys is
# returned as an arrayref so the caller can surface it on the render
# return-object (mirrors the existing $pg->{_reveal_state} pattern — info
# that needs to bubble from inside standaloneRenderer back to the controller
# without plumbing $c through the call chain).
#
# Sensitivity: renderMode is policy. A student must not be able to override
# the orchestrator's mode from the rendered form. Lane::Problem's bulk
# merge gives claim-wins for free; Lane::Challenge propagates renderMode
# explicitly alongside hideElements / hideFeedback. Not in SENSITIVE_PARAMS
# — the claim-wins precedence is sufficient.
#
# See vault://WeBWorK/Renderer/Render Modes for the full design.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Exporter qw(import);
our @EXPORT_OK = qw(resolve_render_mode mode_bundle RENDER_MODES);

use constant RENDER_MODES => [qw(default no-feedback review no-stakes preview custom)];

# Mode → primitive bundle. Only the keys the mode owns are present; anything
# not listed flows through from $inputs_ref unchanged. 'custom' has an empty
# bundle (full passthrough).
my %BUNDLES = (
	# WW3-R46: `showCorrectAnswers => 0` alongside the hidden button.
	#
	# Hiding a button is not refusing an action. These bundles used to
	# suppress only `showCorrectAnswersButton`, so a caller who was never
	# offered the reveal could still POST `showCorrectAnswers=1` and get
	# the canonical answer — measured on the homelab 2026-08-05 against a
	# student's own live challengeJWT.
	#
	# `no-feedback` already did this ("reveal forced off for defense in
	# depth"); `default` and `review` did not. Same bundle table, same
	# author, one function apart — which is the WW3-098 shape again.
	'default' => {
		hideFeedback             => 0,
		hideCheckAnswersButton   => 0,
		showCorrectAnswersButton => 0,
		showCorrectAnswers       => 0,
	},
	'no-feedback' => {
		hideFeedback             => 1,
		hideCheckAnswersButton   => 0,
		showCorrectAnswersButton => 0,
		showCorrectAnswers       => 0,
	},
	# Instructor reView reaches the answers through isInstructor → revealAll
	# in resolve_permissions, which runs AFTER this bundle and is not
	# suppressed by it. What this closes is the student-supplied flag.
	# WW3-117 removes the flag from the portal entirely.
	'review' => {
		hideFeedback             => 0,
		hideCheckAnswersButton   => 1,
		showCorrectAnswersButton => 0,
		showCorrectAnswers       => 0,
	},
	'no-stakes' => {
		hideFeedback             => 0,
		hideCheckAnswersButton   => 0,
		showCorrectAnswersButton => 1,
	},
	'preview' => {
		hideFeedback             => 0,
		hideCheckAnswersButton   => 0,
		showCorrectAnswersButton => 1,
		isInstructor             => 1,
	},
	'custom' => {},
);

sub mode_bundle ($mode) {
	return $BUNDLES{$mode} // $BUNDLES{custom};
}

sub resolve_render_mode ($inputs_ref) {
	my $mode   = $inputs_ref->{renderMode} // 'custom';
	my $bundle = $BUNDLES{$mode} // {};    # unknown mode → passthrough
	return [] unless %$bundle;

	my @overrides;
	for my $k (sort keys %$bundle) {
		my $bundle_val = $bundle->{$k};
		# Caller supplied a value that the bundle is changing → record it.
		# Truthy compare — all bundle values are 0/1, caller-supplied values
		# already coerced to bool at the inputs_ref boundary upstream.
		if (defined $inputs_ref->{$k}
			&& (!!$inputs_ref->{$k}) != (!!$bundle_val))
		{
			push @overrides, $k;
		}
		$inputs_ref->{$k} = $bundle_val;
	}
	return \@overrides;
}

1;
