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
	is_deeply([ sort @{ RENDER_MODES() } ], [ sort @expected ],
		'modes match design doc');
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

# ─── Override posture: mode wins over caller-supplied primitives ──────

subtest 'mode wins over caller-supplied conflicting primitive' => sub {
	my $i = { renderMode => 'no-feedback', hideFeedback => 0 };
	resolve_render_mode($i);
	is($i->{hideFeedback}, 1, 'no-feedback bundle wins over caller hideFeedback=0');
};

subtest 'mode passes through caller value when bundle does not lock that primitive' => sub {
	my $i = { renderMode => 'default', showCorrectAnswers => 1 };
	resolve_render_mode($i);
	is($i->{showCorrectAnswers}, 1, 'default mode does not lock showCorrectAnswers');
	is($i->{hideFeedback},       0, 'default bundle still applies hideFeedback');
};

# ─── Override tracking via return value ────────────────────────────────

subtest 'return value records replaced caller values' => sub {
	my $i = {
		renderMode             => 'no-feedback',
		hideFeedback           => 0,        # mode overrides to 1
		hideCheckAnswersButton => 0,        # matches bundle, no override
		showCorrectAnswers     => 1,        # mode overrides to 0
	};
	my $overrides = resolve_render_mode($i);
	is(ref($overrides), 'ARRAY', 'returns an arrayref');
	is_deeply([ sort @$overrides ],
		[ sort qw(hideFeedback showCorrectAnswers) ],
		'only conflicting keys recorded');
};

subtest 'empty override list when bundle and caller agree' => sub {
	my $i = { renderMode => 'no-feedback' };
	my $overrides = resolve_render_mode($i);
	is(ref($overrides), 'ARRAY', 'returns an arrayref');
	is(scalar @$overrides, 0, 'no overrides recorded');
};

subtest 'custom and unknown modes return empty arrayref' => sub {
	my $overrides;
	$overrides = resolve_render_mode({ renderMode => 'custom', hideFeedback => 1 });
	is(scalar @$overrides, 0, 'custom: no overrides (passthrough)');
	$overrides = resolve_render_mode({ renderMode => 'garbage', hideFeedback => 1 });
	is(scalar @$overrides, 0, 'unknown: no overrides (forward-compat)');
	$overrides = resolve_render_mode({});
	is(scalar @$overrides, 0, 'absent: no overrides');
};

# ─── Side effects: only touches keys the bundle owns ──────────────────

subtest 'mode resolution preserves unrelated keys' => sub {
	my $i = {
		renderMode     => 'no-feedback',
		pg_hash        => 'sha256:abc',
		problemSeed    => 42,
		JWTanswerURL   => 'https://example.test/answers',
		displayMode    => 'MathJax',
		language       => 'en',
		hideElements   => ['.foo'],
	};
	resolve_render_mode($i);
	is($i->{pg_hash},      'sha256:abc',                'pg_hash untouched');
	is($i->{problemSeed},  42,                          'problemSeed untouched');
	is($i->{JWTanswerURL}, 'https://example.test/answers', 'JWTanswerURL untouched');
	is($i->{displayMode},  'MathJax',                   'displayMode untouched');
	is($i->{language},     'en',                        'language untouched');
	is_deeply($i->{hideElements}, ['.foo'],             'hideElements untouched');
};

done_testing();
