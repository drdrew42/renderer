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
#   default      — staked attempts, verdict per attempt.
#   no-feedback  — score it, ship it, say nothing about correctness.
#                  hideFeedback kill-switch.
#   review       — past-attempt display; no resubmits. An instructor still
#                  sees answers via isInstructor → revealAll, which the
#                  permissions resolver applies after this bundle.
#   no-stakes    — sandbox / drill / public widget.
#   preview      — author / library browse; isInstructor=1 → revealAll
#                  bundle via the permissions resolver.
#   custom       — passthrough. No primitives locked.
#
# No mode reveals answers to a student: the reveal reaches a render only
# through isInstructor or a verified reveal sidecar (Renderer::Permissions),
# and reaches a student through the content-fetch endpoints.
#
# Unknown / absent renderMode → treated as 'custom' (forward-compat).
#
# The ratchet (WW3-R70). The RATCHET primitives resolve in three layers:
#   1. the bundle supplies the default;
#   2. a claim — any value in $inputs_ref after the lanes — replaces it, in
#      either direction;
#   3. a raw value — set aside in $raw_ref before the lanes — applies only
#      when it moves the value toward the stricter setting.
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
	isInstructor           => 0,
};

# Mode → primitive bundle. Only the keys the mode owns are present; anything
# not listed flows through from $inputs_ref unchanged. 'custom' has an empty
# bundle (full passthrough).
my %BUNDLES = (
	'default' => {
		hideFeedback           => 0,
		hideCheckAnswersButton => 0,
	},
	'no-feedback' => {
		hideFeedback           => 1,
		hideCheckAnswersButton => 0,
	},
	'review' => {
		hideFeedback           => 0,
		hideCheckAnswersButton => 1,
	},
	'no-stakes' => {
		hideFeedback           => 0,
		hideCheckAnswersButton => 0,
	},
	'preview' => {
		hideFeedback           => 0,
		hideCheckAnswersButton => 0,
		isInstructor           => 1,
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
		$inputs_ref->{$k} //= $bundle->{$k};
	}

	my @ignored;
	for my $k (sort grep { exists $ratchet->{$_} && defined $raw_ref->{$_} } keys %$raw_ref) {
		my $raw    = $raw_ref->{$k} ? 1 : 0;
		my $strict = $ratchet->{$k};
		if ($raw == $strict) {
			$inputs_ref->{$k} = $raw;
		} elsif (($inputs_ref->{$k} ? 1 : 0) != $raw) {
			push @ignored, $k;
		}
	}
	return \@ignored;
}

1;
