use strict;
use warnings;

use Test::More;
use Renderer::RenderMode qw(resolve_render_mode mode_bundle RENDER_MODES);

# Pure-function unit tests for Renderer::RenderMode. No Mojo, no PG, no DB.
# Locks the per-mode primitive bundles + override posture so the contract
# doesn't drift.

# ─── Module surface ───────────────────────────────────────────────────────

subtest 'RENDER_MODES enumerates the documented modes' => sub {
	my @expected = qw(default no-feedback review no-stakes preview custom);
	is_deeply([ sort @{ RENDER_MODES() } ], [ sort @expected ], 'modes match design doc');
};

# ─── Per-mode bundles ─────────────────────────────────────────────────────

subtest 'default: verdict per attempt, no reveal button' => sub {
	my $i = { renderMode => 'default' };
	resolve_render_mode($i);
	is($i->{hideFeedback},             0, 'hideFeedback=0');
	is($i->{hideCheckAnswersButton},   0, 'hideCheckAnswersButton=0');
	is($i->{showCorrectAnswersButton}, 0, 'showCorrectAnswersButton=0 (coordinator-mediated)');
	ok(!exists $i->{isInstructor}, 'isInstructor untouched');
};

subtest 'no-feedback: exam mode kill-switch' => sub {
	my $i = { renderMode => 'no-feedback' };
	resolve_render_mode($i);
	is($i->{hideFeedback},             1, 'hideFeedback=1 (kill switch)');
	is($i->{hideCheckAnswersButton},   0, 'submit still allowed');
	is($i->{showCorrectAnswersButton}, 0, 'no reveal button');
	is($i->{showCorrectAnswers},       0, 'defense in depth: no reveal');
};

subtest 'review: no resubmits, reveal coordinator-mediated' => sub {
	my $i = { renderMode => 'review' };
	resolve_render_mode($i);
	is($i->{hideFeedback},             0, 'feedback shown');
	is($i->{hideCheckAnswersButton},   1, 'no new submits');
	is($i->{showCorrectAnswersButton}, 0, 'no reveal button');
};

subtest 'no-stakes: free-for-all sandbox' => sub {
	my $i = { renderMode => 'no-stakes' };
	resolve_render_mode($i);
	is($i->{hideFeedback},             0, 'feedback shown');
	is($i->{hideCheckAnswersButton},   0, 'submit allowed');
	is($i->{showCorrectAnswersButton}, 1, 'reveal button shown');
};

subtest 'preview: instructor revealAll' => sub {
	my $i = { renderMode => 'preview' };
	resolve_render_mode($i);
	is($i->{hideFeedback},             0, 'feedback shown');
	is($i->{hideCheckAnswersButton},   0, 'submit allowed');
	is($i->{showCorrectAnswersButton}, 1, 'reveal button shown');
	is($i->{isInstructor},             1, 'isInstructor=1 (perms resolver expands to revealAll)');
};

subtest 'custom: pure passthrough' => sub {
	my $i = {
		renderMode               => 'custom',
		hideFeedback             => 1,
		hideCheckAnswersButton   => 1,
		showCorrectAnswersButton => 1,
		isInstructor             => 1,
	};
	resolve_render_mode($i);
	is($i->{hideFeedback},             1, 'caller value preserved');
	is($i->{hideCheckAnswersButton},   1, 'caller value preserved');
	is($i->{showCorrectAnswersButton}, 1, 'caller value preserved');
	is($i->{isInstructor},             1, 'caller value preserved');
};

# ─── Forward-compat: absent / unknown mode = custom ────────────────────

subtest 'absent renderMode treated as custom' => sub {
	my $i = { hideFeedback => 1 };
	resolve_render_mode($i);
	is($i->{hideFeedback}, 1, 'no mode → caller value preserved');
};

subtest 'unknown mode treated as custom' => sub {
	my $i = { renderMode => 'garbage-string', hideFeedback => 1 };
	resolve_render_mode($i);
	is($i->{hideFeedback}, 1, 'unknown mode → passthrough (forward-compat)');
};

# ─── The ratchet (WW3-R70): bundle, then claims, then raw tightens ─────
#
# $inputs_ref carries the claims (whatever the lanes left); the second
# argument carries the raw values ParseRequest set aside before the lanes.

subtest 'order 1: the bundle supplies the default' => sub {
	my $i = { renderMode => 'no-feedback' };
	resolve_render_mode($i, {});
	is($i->{hideFeedback}, 1, 'no claim, no raw → the bundle value');
};

subtest 'order 2: a claim overrides the bundle in either direction' => sub {
	my $i = { renderMode => 'default', hideFeedback => 1 };
	resolve_render_mode($i, {});
	is($i->{hideFeedback}, 1, 'claim hideFeedback=1 tightens default');

	$i = { renderMode => 'no-feedback', hideFeedback => 0 };
	resolve_render_mode($i, {});
	is($i->{hideFeedback}, 0, 'claim hideFeedback=0 loosens no-feedback');

	$i = { renderMode => 'review', hideCheckAnswersButton => 0 };
	resolve_render_mode($i, {});
	is($i->{hideCheckAnswersButton}, 0, 'claim re-shows the button review hides');

	$i = { renderMode => 'preview', isInstructor => 0 };
	resolve_render_mode($i, {});
	is($i->{isInstructor}, 0, 'claim isInstructor=0 overrides the preview bundle');
};

subtest 'order 3: raw tightens, never loosens' => sub {
	my $i       = { renderMode => 'no-feedback' };
	my $ignored = resolve_render_mode($i, { hideFeedback => 0 });
	is($i->{hideFeedback}, 1, 'raw hideFeedback=0 cannot loosen the mode');
	is_deeply($ignored, ['hideFeedback'], 'the ignored raw key is reported');

	$i = { renderMode => 'default' };
	resolve_render_mode($i, { hideFeedback => 1 });
	is($i->{hideFeedback}, 1, 'raw hideFeedback=1 tightens the mode');

	$i = { renderMode => 'default', hideFeedback => 0 };
	resolve_render_mode($i, { hideFeedback => 1 });
	is($i->{hideFeedback}, 1, 'raw hideFeedback=1 tightens a claim');

	$i = { renderMode => 'default', hideFeedback => 1 };
	resolve_render_mode($i, { hideFeedback => 0 });
	is($i->{hideFeedback}, 1, 'raw hideFeedback=0 cannot loosen a claim');

	$i = { renderMode => 'review' };
	resolve_render_mode($i, { hideCheckAnswersButton => 0 });
	is($i->{hideCheckAnswersButton}, 1, 'raw cannot re-show the button review hides');

	$i = {};
	resolve_render_mode($i, { hideCheckAnswersButton => 1 });
	is($i->{hideCheckAnswersButton}, 1, 'raw may hide the button with no mode');

	$i = { renderMode => 'preview' };
	resolve_render_mode($i, { isInstructor => 0 });
	is($i->{isInstructor}, 0, 'raw isInstructor=0 tightens preview');

	$i = { renderMode => 'default' };
	resolve_render_mode($i, { isInstructor => 1 });
	ok(!$i->{isInstructor}, 'raw isInstructor=1 is ignored');

	$i = {};
	resolve_render_mode($i, { showCorrectAnswers => 1 });
	ok(!$i->{showCorrectAnswers}, 'raw showCorrectAnswers=1 is ignored with no mode');
};

subtest 'mode leaves primitives it does not own alone' => sub {
	my $i = { renderMode => 'default', showFooter => 1 };
	resolve_render_mode($i, {});
	is($i->{showFooter},   1, 'default mode does not lock showFooter');
	is($i->{hideFeedback}, 0, 'default bundle still applies hideFeedback');
};

subtest 'showCorrectAnswersButton is set by the bundle outright' => sub {
	my $i = { renderMode => 'default', showCorrectAnswersButton => 1 };
	resolve_render_mode($i, {});
	is($i->{showCorrectAnswersButton}, 0, 'the bundle value replaces a supplied one');
};

subtest 'default and review refuse a raw showCorrectAnswers (WW3-R46)' => sub {
	# Offering is not the same as permitting. Both bundles hide the reveal
	# button; before R46 neither refused the flag, so a caller who was
	# never offered the reveal could ask for it directly and be given it.
	for my $mode (qw(default review)) {
		my $i       = { renderMode => $mode };
		my $ignored = resolve_render_mode($i, { showCorrectAnswers => 1 });
		is($i->{showCorrectAnswers},       0, "$mode refuses a raw showCorrectAnswers");
		is($i->{showCorrectAnswersButton}, 0, "$mode still hides the button");
		ok((grep { $_ eq 'showCorrectAnswers' } @$ignored), "$mode reports the raw value it ignored");
	}
};

subtest 'no-stakes and preview still offer the reveal' => sub {
	# The bundles where revealing costs nothing keep the button's click
	# working until WW3-R67 retires it.
	for my $mode (qw(no-stakes preview)) {
		my $i = { renderMode => $mode };
		resolve_render_mode($i, { showCorrectAnswers => 1 });
		is($i->{showCorrectAnswers},       1, "$mode honours the button's raw showCorrectAnswers");
		is($i->{showCorrectAnswersButton}, 1, "$mode offers the button");

		$i = { renderMode => $mode, showCorrectAnswers => 0 };
		resolve_render_mode($i, { showCorrectAnswers => 1 });
		is($i->{showCorrectAnswers}, 0, "$mode: a lane or claim that set the flag holds");
	}
};

# ─── Ignored-raw tracking via return value ─────────────────────────────

subtest 'return value records the raw values the ratchet ignored' => sub {
	my $i       = { renderMode => 'no-feedback' };
	my $ignored = resolve_render_mode(
		$i,
		{
			hideFeedback           => 0,    # loosens → ignored
			hideCheckAnswersButton => 0,    # matches the bundle → nothing to ignore
			showCorrectAnswers     => 1,    # loosens → ignored
		}
	);
	is(ref($ignored), 'ARRAY', 'returns an arrayref');
	is_deeply([ sort @$ignored ], [ sort qw(hideFeedback showCorrectAnswers) ], 'only loosening keys recorded');
};

subtest 'empty list when nothing is ignored' => sub {
	my $ignored = resolve_render_mode({ renderMode => 'no-feedback' });
	is(ref($ignored),    'ARRAY', 'returns an arrayref');
	is(scalar @$ignored, 0,       'nothing ignored');

	$ignored = resolve_render_mode({ renderMode => 'custom' }, { hideFeedback => 1 });
	is(scalar @$ignored, 0, 'custom: a tightening raw value applies');
	$ignored = resolve_render_mode({ renderMode => 'garbage' }, { hideFeedback => 1 });
	is(scalar @$ignored, 0, 'unknown: a tightening raw value applies');
	$ignored = resolve_render_mode({});
	is(scalar @$ignored, 0, 'absent: nothing ignored');
};

# ─── Side effects: only touches keys the bundle owns ──────────────────

subtest 'mode resolution preserves unrelated keys' => sub {
	my $i = {
		renderMode   => 'no-feedback',
		pg_hash      => 'sha256:abc',
		problemSeed  => 42,
		JWTanswerURL => 'https://example.test/answers',
		displayMode  => 'MathJax',
		language     => 'en',
		hideElements => ['.foo'],
	};
	resolve_render_mode($i);
	is($i->{pg_hash},      'sha256:abc',                   'pg_hash untouched');
	is($i->{problemSeed},  42,                             'problemSeed untouched');
	is($i->{JWTanswerURL}, 'https://example.test/answers', 'JWTanswerURL untouched');
	is($i->{displayMode},  'MathJax',                      'displayMode untouched');
	is($i->{language},     'en',                           'language untouched');
	is_deeply($i->{hideElements}, ['.foo'], 'hideElements untouched');
};

done_testing();
