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
#   * Lock outputFormat to 'simple' (challengeJWT path is iframe-only).
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

	my $entry = $problems->[$position];
	my $pg_hash = $entry->{pg_hash}
		or return $c->exception('challengeJWT problem entry missing pg_hash.', 400);

	# Seed resolution. Closed challenges carry the seed in the JWT entry;
	# open challenges carry "*" and the resolved seed lives in the inbound
	# sessionJWT's state.draws[] (where draw_position == position). In
	# open mode the active pg_hash also lives on the draw record.
	my $seed = $entry->{seed};
	if (!defined $seed || $seed eq '*') {
		my $draws = $params->{state} && ref $params->{state} eq 'HASH'
			? ($params->{state}{draws} // [])
			: [];
		my ($draw) = grep { defined $_->{draw_position} && $_->{draw_position} == $position } @$draws;
		return $c->exception("Open challenge: no draw recorded for position $position.", 400)
			unless $draw && defined $draw->{seed};
		$seed = $draw->{seed};
		$pg_hash = $draw->{pg_hash} if defined $draw->{pg_hash};
	}

	$params->{pg_hash}     = $pg_hash;
	$params->{problemSeed} = $seed;

	# Synthesize problemSourceURL from pg_hash unless caller supplied raw
	# source (editor preview / test bypass — "use this verbatim").
	unless (defined $params->{problemSource}) {
		$params->{problemSourceURL} = $c->opl_client->problem_url_by_hash($pg_hash);
	}

	# Render permissions are attempt-wide. Apply renderer-visible fields;
	# orchestrator-only fields (e.g. duration_anchor) ignored.
	if (my $rp = $claims->{render_permissions}) {
		for my $k (qw(isInstructor showCorrectAnswers showHints showSolutions)) {
			$params->{$k} = $rp->{$k} if defined $rp->{$k};
		}
	}
	$params->{isInstructor} //= 0;

	# Identity claims propagate into the submissionJWT.
	for my $k (qw(play_id challenge_id chain_student_id assignment_id)) {
		$params->{$k} = $claims->{$k} if defined $claims->{$k};
	}

	# Declarative UI hide-list (WW3-R01). No bulk merge happens on this
	# lane, so propagate explicitly.
	$params->{hideElements} = $claims->{hideElements}
		if ref $claims->{hideElements} eq 'ARRAY';

	# Stamp the answer endpoint so submissionJWTs land at the orchestrator,
	# not at any legacy answerURL the client tried to inject.
	return $c->exception('challengeJWT missing answer_url.', 400)
		unless defined $claims->{answer_url};
	$params->{JWTanswerURL} = $claims->{answer_url};

	# outputFormat lock: WW3-028 ships challengeJWT WITHOUT an outputFormat
	# claim (preserves the 99bc18f leak fix). Iframe-render-only; "simple"
	# is the only safe value. Override any URL-injected value.
	$params->{outputFormat} = 'simple';

	$c->stash(_can_emit_answer_jwt => 1);
	return 1;
}

1;
