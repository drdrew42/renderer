package Renderer::Lane::Challenge;

# challengeJWT body lane (WW3 orchestrator-minted, WW3-032).
#
# The challengeJWT is the static play definition: a pool of problems with
# render permissions and an answer endpoint. Atom evaluation lives
# orchestrator-side (Architecture B). The renderer's job here is:
#
#   * Decode + verify_aud against $SITE_HOST under problemJWTsecret.
#   * Locate the requested problem by `position` (URL/form param).
#   * Resolve seed and pg_hash — closed-mode reads from the JWT entry,
#     open-mode reads from the inbound sessionJWT's state.draws[] (already
#     merged into $params by Lane::Session).
#   * Synthesize problemSourceURL from pg_hash via OPLClient (skip if
#     caller supplied raw problemSource).
#   * Apply render_permissions and identity claims.
#   * Lock outputFormat to 'default' (challengeJWT path is iframe-only).
#   * Set _can_emit_answer_jwt — upstream-grounded.
#
# Selectively merges (unlike Lane::Problem's bulk merge) — challengeJWT
# claims are structured (problems[], render_permissions, identity), each
# slot mapped explicitly. hideElements (WW3-R01) propagates explicitly
# since there's no bulk merge to carry it through.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Crypt::JWT qw(decode_jwt);

use Exporter qw(import);
our @EXPORT_OK = qw(apply);

sub apply ($c, $params) {
	$c->log->info("Received JWT: using challengeJWT");

	my $claims;
	eval {
		$claims = decode_jwt(
			token      => $params->{challengeJWT},
			key        => $ENV{problemJWTsecret},
			verify_aud => $ENV{SITE_HOST},
		);
		1;
	} or do {
		return $c->croak($@, 3);
	};

	# Position resolves the problem within the pool. Initial render gets
	# it from the portal's URL param; form-submit re-render carries it as
	# a hidden form field. Render-context belongs in the form, not in
	# sessionJWT state — student_picks mode deliberately keeps
	# state.current_focus null.
	my $position = $params->{position};
	return $c->exception('challengeJWT requires a position parameter.', 400)
		unless defined $position && $position =~ /^\d+$/;

	my $problems = $claims->{problems} // [];
	return $c->exception("position $position out of range (have @{[ scalar @$problems ]} problems).", 400)
		if $position >= scalar @$problems;

	my $entry   = $problems->[$position];
	my $pg_hash = $entry->{pg_hash}
		or return $c->exception('challengeJWT problem entry missing pg_hash.', 400);

	# Seed resolution. Closed challenges carry the seed in the JWT entry;
	# open challenges carry "*" and the resolved seed lives in the inbound
	# sessionJWT's state.draws[] (where draw_position == position). In
	# open mode the active pg_hash also lives on the draw record.
	my $seed = $entry->{seed};
	if (!defined $seed || $seed eq '*') {
		my $draws = $params->{state} && ref $params->{state} eq 'HASH' ? ($params->{state}{draws} // []) : [];
		my ($draw) = grep { defined $_->{draw_position} && $_->{draw_position} == $position } @$draws;
		return $c->exception("Open challenge: no draw recorded for position $position.", 400)
			unless $draw && defined $draw->{seed};
		$seed    = $draw->{seed};
		$pg_hash = $draw->{pg_hash} if defined $draw->{pg_hash};
	}

	$params->{pg_hash}     = $pg_hash;
	$params->{problemSeed} = $seed;

	# Synthesize problemSourceURL from pg_hash unless caller supplied raw
	# source (editor preview / test bypass — "use this verbatim").
	unless (defined $params->{problemSource}) {
		$params->{problemSourceURL} = $c->opl_client->problem_url_by_hash($pg_hash);
	}

	# No raw-form path to the reveal on this lane (WW3-R46). The mode
	# bundles hide the button but only bite when a caller opts into a mode,
	# and WW3 sends `renderMode` only for library preview — never on play —
	# so the challenge lane resolves to `custom` and the bundle never runs.
	# Hard-zero first; a claim below may re-enable it deliberately.
	#
	# Nothing legitimate is lost: PlayRendererFrame does not send
	# showCorrectAnswers at all. What this closes is a student adding it to
	# their own POST, measured mid-play on the homelab 2026-08-05.
	$params->{showCorrectAnswers} = 0;

	# Render permissions are attempt-wide. Apply renderer-visible fields;
	# orchestrator-only fields (e.g. duration_anchor) ignored.
	#
	# WW3 omits render_permissions entirely (WW3-065), so in practice both
	# elevation params land on their defaults. The claim path stays for
	# orchestrators that do send it.
	if (my $rp = $claims->{render_permissions}) {
		for my $k (qw(isInstructor showCorrectAnswers showHints showSolutions)) {
			$params->{$k} = $rp->{$k} if defined $rp->{$k};
		}
	}

	# Elevation defaults (WW3-R46). These were `//= 0`, which assigns only
	# when the key is UNDEF — so a form-supplied `isInstructor=1` sailed
	# through untouched and resolved to revealAll on a live scored attempt.
	# The raw values are stripped in ParseRequest now; this lane is
	# claim-or-default, with no raw-form path at all.
	$params->{isInstructor} //= 0;

	# Identity claims propagate into the submissionJWT.
	for my $k (qw(play_id challenge_id chain_student_id assignment_id)) {
		$params->{$k} = $claims->{$k} if defined $claims->{$k};
	}

	# Declarative UI hide-list (WW3-R01). No bulk merge happens on this
	# lane, so propagate explicitly.
	$params->{hideElements} = $claims->{hideElements}
		if ref $claims->{hideElements} eq 'ARRAY';

	# Render-mode intent claim (WW3-R43). Resolved into primitive flags by
	# Renderer::RenderMode at the RenderProblem boundary.
	$params->{renderMode} = $claims->{renderMode}
		if defined $claims->{renderMode};

	# Exam-mode feedback suppression: kills the PG post-processor (no
	# verdict CSS classes, popovers, buttons, or summary). Score still
	# flows to JWTanswerURL — only the student's visual signal is gone.
	# Must arrive via claim so students can't toggle it back from the form.
	# `hideAttemptsTable` is an accepted alias.
	# DEPRECATED: remove `hideAttemptsTable` propagation after Summer 2026 —
	# after ADAPT's live JWTs (which may bear the legacy claim) have expired.
	$params->{hideFeedback} = $claims->{hideFeedback}
		if $claims->{hideFeedback};
	$params->{hideAttemptsTable} = $claims->{hideAttemptsTable}
		if $claims->{hideAttemptsTable};

	# Stamp the answer endpoint so submissionJWTs land at the orchestrator,
	# not at any legacy answerURL the client tried to inject.
	return $c->exception('challengeJWT missing answer_url.', 400)
		unless defined $claims->{answer_url};
	$params->{JWTanswerURL} = $claims->{answer_url};

	# outputFormat lock: WW3-028 ships challengeJWT WITHOUT an outputFormat
	# claim (preserves the 99bc18f leak fix). Iframe-render-only — override
	# any URL-injected value to the canonical default. Pre-WW3-R21 this
	# locked to 'simple', which was an alias for 'default'; both still
	# work post-R21 but 'default' is the post-collapse canonical.
	$params->{outputFormat} = 'default';

	$c->stash(_can_emit_answer_jwt => 1);
	$c->stash(_trust_lane          => 'challenge');
	return 1;
}

1;
