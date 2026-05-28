package Renderer::RenderMode;

# resolve_render_mode($inputs_ref, $c=undef) → mutates $inputs_ref in place
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
#   default      — staked attempts, verdict per attempt, coordinator-mediated
#                  reveal (Show Correct Answers button hidden by default).
#   no-feedback  — score it, ship it, say nothing about correctness.
#                  hideFeedback kill-switch + reveal button hidden + reveal
#                  forced off for defense in depth.
#   review       — past-attempt display; no resubmits. Reveal-button hidden
#                  by default (coordinator unlocks per-render).
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
# stashed on the Mojo controller under _mode_overrides for debug
# introspection (mirrors the existing _trust_lane / _is_first_render
# stash pattern).
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
	'default' => {
		hideFeedback             => 0,
		hideCheckAnswersButton   => 0,
		showCorrectAnswersButton => 0,
	},
	'no-feedback' => {
		hideFeedback             => 1,
		hideCheckAnswersButton   => 0,
		showCorrectAnswersButton => 0,
		showCorrectAnswers       => 0,
	},
	'review' => {
		hideFeedback             => 0,
		hideCheckAnswersButton   => 1,
		showCorrectAnswersButton => 0,
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

sub resolve_render_mode ($inputs_ref, $c = undef) {
	my $mode   = $inputs_ref->{renderMode} // 'custom';
	my $bundle = $BUNDLES{$mode} // {};    # unknown mode → passthrough
	return unless %$bundle;

	my @overrides;
	for my $k (sort keys %$bundle) {
		my $bundle_val = $bundle->{$k};
		# Caller supplied a value that the bundle is changing → record it.
		# Stringy-equal compare (all bundle values are 0/1; caller may send
		# either, or stringy truthy/falsy that we coerce on read elsewhere).
		if (defined $inputs_ref->{$k}
			&& (!!$inputs_ref->{$k}) != (!!$bundle_val))
		{
			push @overrides, $k;
		}
		$inputs_ref->{$k} = $bundle_val;
	}
	$c->stash(_mode_overrides => \@overrides) if $c && @overrides;
	return;
}

1;
