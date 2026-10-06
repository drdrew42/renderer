package Renderer::RenderMode;

# resolve_render_mode($inputs_ref, $raw_ref) → mutates $inputs_ref in place
#                                              + returns the list of raw
#                                              keys the resolution ignored.
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
#
# The ratchet (WW3-R70). The RATCHET primitives resolve in three layers:
#   1. the bundle supplies the default;
#   2. a claim — any value in $inputs_ref after the lanes — replaces it, in
#      either direction;
#   3. a raw value — set aside in $raw_ref before the lanes — applies only
#      when it moves the value toward the stricter setting.
# One interim exception: under a mode that offers the reveal (no-stakes,
# preview), a raw showCorrectAnswers is the Show Correct Answers button's
# click, and applies when no claim or lane has set the flag (WW3-R67 retires
# the button and this exception with it).
#
# The remaining bundle primitive, showCorrectAnswersButton, is set by the
# bundle outright.
#
# renderMode itself is policy: claim-only on grounded lanes
# (RENDER_MODE_PARAMS, WW3-R51), so a student cannot pick the bundle.
#
# The raw keys the ratchet ignored are returned as an arrayref so the caller
# can surface them on the render return-object (`mode_overrides` in the debug
# envelope).
#
# See vault://WeBWorK/Renderer/Render Modes for the full design.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Exporter qw(import);
our @EXPORT_OK = qw(resolve_render_mode mode_bundle RENDER_MODES RATCHET);

use constant RENDER_MODES => [qw(default no-feedback review no-stakes preview custom)];

# Ratchet primitive → its stricter value.
use constant RATCHET => {
	hideFeedback           => 1,
	hideCheckAnswersButton => 1,
	showCorrectAnswers     => 0,
	isInstructor           => 0,
};

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

sub resolve_render_mode ($inputs_ref, $raw_ref = {}) {
	my $bundle  = mode_bundle($inputs_ref->{renderMode} // 'custom');
	my $ratchet = RATCHET;

	for my $k (sort keys %$bundle) {
		if (exists $ratchet->{$k}) { $inputs_ref->{$k} //= $bundle->{$k} }
		else                       { $inputs_ref->{$k} = $bundle->{$k} }
	}

	my @ignored;
	for my $k (sort grep { exists $ratchet->{$_} && defined $raw_ref->{$_} } keys %$raw_ref) {
		my $raw    = $raw_ref->{$k} ? 1 : 0;
		my $strict = $ratchet->{$k};
		if ($raw == $strict) {
			$inputs_ref->{$k} = $raw;
		} elsif ($k eq 'showCorrectAnswers' && $bundle->{showCorrectAnswersButton} && !defined $inputs_ref->{$k}) {
			$inputs_ref->{$k} = $raw;
		} elsif (($inputs_ref->{$k} ? 1 : 0) != $raw) {
			push @ignored, $k;
		}
	}
	return \@ignored;
}

1;
