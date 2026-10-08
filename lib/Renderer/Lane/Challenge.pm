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
#   * Synthesize problemSourceURL from pg_hash via OPLClient. Raw source,
#     address and seed are stripped before the lane (WW3-R68); only a
#     verified peer body can carry its own problemSource here.
#   * Apply render_permissions and identity claims.
#   * Apply a verified permission sidecar's grants (reveal, debug).
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

use Renderer::RevealSidecar ();
use Renderer::Util::JWT     qw(verify_problem_jwt);

use Exporter qw(import);
our @EXPORT_OK = qw(apply);

sub apply ($c, $params) {
	$c->log->info("Received JWT: using challengeJWT");

	my ($claims, $err) = verify_problem_jwt($params->{challengeJWT});
	return $c->credential_error($err) if $err;

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

	# Synthesize problemSourceURL from pg_hash. A raw problemSource never
	# reaches this lane (TOKEN_CONTENT_PARAMS, WW3-R68); a verified peer body's
	# signed source renders as sent.
	unless (defined $params->{problemSource}) {
		$params->{problemSourceURL} = $c->opl_client->problem_url_by_hash($pg_hash);
	}

	# Render permissions are attempt-wide. Apply renderer-visible fields;
	# orchestrator-only fields (e.g. duration_anchor) ignored.
	#
	# WW3 omits render_permissions entirely (WW3-065), so in practice
	# isInstructor lands on its default. The claim path stays for
	# orchestrators that do send it; the reveal sidecar below is the only
	# route to answers for a student.
	if (my $rp = $claims->{render_permissions}) {
		for my $k (qw(isInstructor showHints showSolutions)) {
			$params->{$k} = $rp->{$k} if defined $rp->{$k};
		}
	}

	# Elevation (WW3-R46): the raw isInstructor is stripped in ParseRequest,
	# so this lane is claim-or-default. The default — the render mode's, then
	# 0 — lands in ParseRequest::dispatch after the mode resolves (WW3-R70).

	# Identity claims propagate into the submissionJWT.
	for my $k (qw(play_id challenge_id chain_student_id assignment_id)) {
		$params->{$k} = $claims->{$k} if defined $claims->{$k};
	}

	# The permission sidecar (Renderer::RevealSidecar), bound to this play.
	# `reveal` sets _reveal_grant, which resolve_permissions expands to answers
	# + solutions; `debug` turns on PG's debugging view (WW3-R58), whose raw
	# value ParseRequest strips. Absent or invalid ⇒ no grant.
	my $grants = Renderer::RevealSidecar::verify($c, $params, $claims->{play_id});
	$params->{_reveal_grant}               = 1 if $grants->{reveal};
	$params->{view_problem_debugging_info} = 1 if $grants->{debug};

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
	$params->{hideFeedback} = $claims->{hideFeedback}
		if $claims->{hideFeedback};

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
