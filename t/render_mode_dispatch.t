use strict;
use warnings;

use File::Path qw(make_path);
use Test::More;

# Integration tests for Renderer::RenderMode hooked into
# Renderer::Render::ParseRequest::dispatch. Exercises the full dispatch path
# and verifies that the mode resolver runs in the parent process (so the
# format-layer primitives are visible) AND that the override list lands on
# $c->stash('_mode_overrides'). The debug outputFormat surfaces both values
# so we can assert on them without controller introspection.
#
# Render.pm uses -async_await which requires Future::AsyncAwait (Docker-only).
BEGIN {
	eval { require Future::AsyncAwait; 1; }
		or plan skip_all => 'Future::AsyncAwait not available (Docker-only) — skipping render_mode_dispatch tests';
}

use Test::Mojo;
use Crypt::JWT qw(encode_jwt);

# outputFormat=debug is a deployment affordance gated on this env var
# (WW3-R45). The test suite is its intended consumer.
$ENV{RENDERER_DEBUG_FORMAT} //= 1;
$ENV{problemJWTsecret}      //= 'test-problem-secret';
$ENV{webworkJWTsecret}      //= 'test-session-secret';
$ENV{SITE_HOST}             //= 'https://test.example.com';

delete $ENV{STRICT_JWT};
delete $ENV{OPL_API_URL};

my $t           = Test::Mojo->new('Renderer');
my $render_root = $ENV{RENDER_ROOT};
make_path("$render_root/private") unless -d "$render_root/private";
make_path("$render_root/logs")    unless -d "$render_root/logs";
unless (-f "$render_root/logs/resource_usage.log") {
	open my $fh, '>>', "$render_root/logs/resource_usage.log" or die $!;
	close $fh;
}

sub make_problem_jwt {
	my (%claims) = @_;
	return encode_jwt(
		payload => {
			aud => $ENV{SITE_HOST},
			iss => $ENV{SITE_HOST},
			%claims,
		},
		key => $ENV{problemJWTsecret},
		alg => 'HS256',
	);
}

my $pg_source = <<'PG';
DOCUMENT();
loadMacros("PGstandard.pl", "MathObjects.pl", "PGML.pl");
$ans = Real(2);
BEGIN_PGML
What is 1 + 1?  [_]{$ans}
END_PGML
ENDDOCUMENT();
PG

# ─── ungrounded lane (raw form) ────────────────────────────────────────────

subtest 'ungrounded: renderMode echoed back in debug; empty overrides when caller agrees' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			problemSeed   => 1234,
			outputFormat  => 'debug',
			renderMode    => 'default',
		}
	)->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode}, 'default', 'renderMode surfaced in debug');
	is_deeply($debug->{mode_overrides}, [], 'no overrides — caller supplied nothing conflicting');
};

subtest 'ungrounded: no-feedback overrides conflicting caller primitives' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource      => $pg_source,
			problemSeed        => 1234,
			outputFormat       => 'debug',
			renderMode         => 'no-feedback',
			hideFeedback       => 0,               # mode forces to 1
			showCorrectAnswers => 1,               # mode forces to 0
		}
	)->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode}, 'no-feedback', 'mode preserved');
	is_deeply(
		[ sort @{ $debug->{mode_overrides} } ],
		[ sort qw(hideFeedback showCorrectAnswers) ],
		'both conflicting caller primitives recorded as overrides',
	);
	# Permission resolver downstream of mode: showCorrectAnswers should be 0.
	is($debug->{permissions}{showCorrectAnswers},
		0, 'mode-forced showCorrectAnswers=0 visible to permission resolver');
};

subtest 'ungrounded: custom mode is pure passthrough' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			problemSeed   => 1234,
			outputFormat  => 'debug',
			renderMode    => 'custom',
			hideFeedback  => 1,            # caller value should survive
		}
	)->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode}, 'custom', 'mode preserved');
	is_deeply($debug->{mode_overrides}, [], 'custom mode never overrides');
};

subtest 'ungrounded: absent renderMode → custom (no overrides)' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			problemSeed   => 1234,
			outputFormat  => 'debug',
		}
	)->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode}, undef, 'no renderMode in inputs_ref');
	is_deeply($debug->{mode_overrides}, [], 'absent mode → no overrides');
};

subtest 'ungrounded: unknown mode treated as custom (forward-compat)' => sub {
	$t->post_ok(
		'/render-api' => form => {
			problemSource => $pg_source,
			problemSeed   => 1234,
			outputFormat  => 'debug',
			renderMode    => 'totally-fake-mode-name',
			hideFeedback  => 1,
		}
	)->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode}, 'totally-fake-mode-name', 'unknown mode echoed back unchanged');
	is_deeply($debug->{mode_overrides}, [], 'unknown mode acts as custom — no overrides');
};

# ─── problemJWT lane (claim-wins via bulk merge) ───────────────────────────

subtest 'problemJWT: renderMode claim wins over raw form renderMode' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
		renderMode    => 'no-feedback',
	);

	$t->post_ok(
		'/render-api' => form => {
			problemJWT   => $jwt,
			outputFormat => 'debug',
			renderMode   => 'default',    # raw form tries 'default'; claim should win
		}
	)->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode}, 'no-feedback', 'JWT claim wins over raw form param (Lane::Problem bulk merge)');
};

subtest 'problemJWT: raw form renderMode is stripped on a grounded lane — no self-elevation (WW3-R51)' => sub {
	# The confirmed R46 sibling. A grounded student POSTs renderMode=preview in
	# the raw form; with NO renderMode claim to legitimize it, the grounded
	# strip removes it before mode resolution, so it resolves to 'custom'
	# (student view) instead of promoting to instructor revealAll. Measured on
	# the homelab as the same 8452-vs-6584-byte reveal R46 left open here.
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
		# deliberately no renderMode claim
	);

	$t->post_ok(
		'/render-api' => form => {
			problemJWT   => $jwt,
			outputFormat => 'debug',
			renderMode   => 'preview',    # raw injection attempt
		}
	)->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode},                      undef, 'raw renderMode stripped on a grounded request');
	is($debug->{permissions}{isInstructor},       0,     'no elevation to instructor');
	is($debug->{permissions}{showCorrectAnswers}, 0,     'no answer reveal');
	is($debug->{permissions}{showSolutions},      0,     'no solution reveal');
	is($debug->{permissions}{showHints},          0,     'no hint reveal');
};

subtest 'problemJWT: preview claim overrides caller isInstructor=0 in form' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
		renderMode    => 'preview',
	);

	$t->post_ok(
		'/render-api' => form => {
			problemJWT   => $jwt,
			outputFormat => 'debug',
		}
	)->status_is(200);

	my $debug = $t->tx->res->json;
	is($debug->{renderMode},                      'preview', 'preview mode applied');
	is($debug->{permissions}{isInstructor},       1,         'preview mode promoted to instructor → revealAll');
	is($debug->{permissions}{showCorrectAnswers}, 1,         'showCorrectAnswers revealed');
	is($debug->{permissions}{showHints},          1,         'showHints revealed');
	is($debug->{permissions}{showSolutions},      1,         'showSolutions revealed');
};

# ─── Format-layer primitives must survive the subprocess fork ──────────────

# Pre-WW3-R43-hoist, resolve_render_mode lived inside the rendering
# subprocess. Mutations to $inputs_ref made in the child were lost across
# the fork boundary, so FormatRenderedProblem (which runs in the parent
# post-subprocess) saw the un-mutated values. Symptom: preview rendered
# without the Show Correct Answers button. This subtest pins the fix —
# format-layer button-visibility flags must reflect the mode bundle.

subtest 'preview mode: Show Correct Answers button reaches the format layer' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
		renderMode    => 'preview',
	);

	$t->post_ok(
		'/render-api' => form => {
			problemJWT   => $jwt,
			outputFormat => 'default',
		}
	)->status_is(200)->content_like(
		qr/Show Correct Answers/,
		'preview-mode showCorrectAnswersButton=1 visible to template after fork',
	);
};

subtest 'review mode: Check Answers button hidden in the format layer' => sub {
	my $jwt = make_problem_jwt(
		problemSource => $pg_source,
		problemSeed   => 1234,
		renderMode    => 'review',
	);

	$t->post_ok(
		'/render-api' => form => {
			problemJWT   => $jwt,
			outputFormat => 'default',
		}
	)->status_is(200)
		->content_unlike(qr/Check Answers/, 'review-mode hideCheckAnswersButton=1 visible to template after fork',);
};

# ─── The ratchet (WW3-R70): bundle defaults, then claims, then raw tightens ──
#
# The interact button's default label reads the resolved hideFeedback —
# "Check Answers" when feedback shows, "Save Answers" when it is hidden — so
# the label is a direct readout of the resolution. Submitting a correct answer
# adds the feedback markup (ww-feedback-*) only when feedback is shown.

my $FEEDBACK_MARK = qr/ww-feedback-btn/;
my $INTERACT      = qr/<input[^>]*name="submitAnswers"[^>]*>/;

sub interact_button {
	my ($html)   = @_;
	my ($button) = $html =~ /($INTERACT)/;
	return $button;
}

sub render_problem_lane {
	my (%args) = @_;
	my $jwt = make_problem_jwt(problemSource => $pg_source, problemSeed => 1234, %{ $args{claims} // {} });
	$t->post_ok('/render-api' => form => { problemJWT => $jwt, %{ $args{raw} // {} } })->status_is(200);
	return $t->tx->res->body;
}

subtest 'claim renderMode default + claim hideFeedback 1 → feedback hidden' => sub {
	my $html = render_problem_lane(
		claims => { renderMode    => 'default', hideFeedback => 1 },
		raw    => { submitAnswers => 1,         AnSwEr0001   => '2' },
	);
	unlike($html, $FEEDBACK_MARK, 'the hideFeedback claim overrides the mode default');
	like(interact_button($html), qr/value="Save Answers"/, 'the interact button reads "Save Answers"');
};

subtest 'claim renderMode no-feedback + raw hideFeedback=0 → feedback hidden' => sub {
	my $html = render_problem_lane(
		claims => { renderMode    => 'no-feedback' },
		raw    => { submitAnswers => 1, AnSwEr0001 => '2', hideFeedback => 0 },
	);
	unlike($html, $FEEDBACK_MARK, 'a raw value cannot loosen the mode');
	like(interact_button($html), qr/value="Save Answers"/, 'the interact button reads "Save Answers"');
};

subtest 'claim renderMode default + raw hideFeedback=1 → feedback hidden (tightening honored)' => sub {
	my $html = render_problem_lane(
		claims => { renderMode    => 'default' },
		raw    => { submitAnswers => 1, AnSwEr0001 => '2', hideFeedback => 1 },
	);
	unlike($html, $FEEDBACK_MARK, 'a raw value may tighten the mode');
	like(interact_button($html), qr/value="Save Answers"/, 'the interact button reads "Save Answers"');
};

subtest 'claim renderMode default, no hideFeedback anywhere → feedback shown' => sub {
	my $html = render_problem_lane(
		claims => { renderMode    => 'default' },
		raw    => { submitAnswers => 1, AnSwEr0001 => '2' },
	);
	like($html,                  $FEEDBACK_MARK,            'the mode default shows feedback');
	like(interact_button($html), qr/value="Check Answers"/, 'the interact button reads "Check Answers"');
};

subtest 'claim renderMode review + raw hideCheckAnswersButton=0 → no interact button' => sub {
	my $html = render_problem_lane(
		claims => { renderMode             => 'review' },
		raw    => { hideCheckAnswersButton => 0 },
	);
	ok(!defined interact_button($html), 'raw input cannot re-show the button a mode hides');
};

subtest 'raw hideCheckAnswersButton=1 hides the interact button' => sub {
	my $html = render_problem_lane(raw => { hideCheckAnswersButton => 1 });
	ok(!defined interact_button($html), 'raw input may hide the button');
};

subtest 'claim hideCheckAnswersButton 0 overrides the review default' => sub {
	my $html = render_problem_lane(claims => { renderMode => 'review', hideCheckAnswersButton => 0 });
	ok(defined interact_button($html), 'a claim moves the mode default in either direction');
};

subtest 'interactLabel: a claim names the button; raw is stripped; markup is escaped' => sub {
	my $html = render_problem_lane(claims => { interactLabel => 'Submit' });
	like(interact_button($html), qr/value="Submit"/, 'the claim label is used');

	$html = render_problem_lane(claims => { hideFeedback => 1, interactLabel => 'Submit' });
	like(interact_button($html), qr/value="Submit"/, 'the claim label wins over the feedback default');

	$html = render_problem_lane(raw => { interactLabel => 'Hijacked' });
	like(interact_button($html), qr/value="Check Answers"/, 'a raw label is ignored');
	unlike($html, qr/Hijacked/, 'the raw label does not reach the page');

	$html = render_problem_lane(claims => { interactLabel => '"><b>bold</b>' });
	unlike($html, qr/<b>bold<\/b>/, 'markup in a label does not render');
	like(interact_button($html), qr/value="&quot;&gt;&lt;b&gt;bold&lt;\/b&gt;"/, 'the label is HTML-escaped');
};

subtest 'raw isInstructor=0 tightens a preview claim; raw isInstructor=1 is ignored' => sub {
	my $jwt = make_problem_jwt(problemSource => $pg_source, problemSeed => 1234, renderMode => 'preview');
	$t->post_ok('/render-api' => form => { problemJWT => $jwt, outputFormat => 'debug', isInstructor => 0 })
		->status_is(200);
	is($t->tx->res->json->{permissions}{isInstructor}, 0, 'the raw value lowers the mode default');

	$jwt = make_problem_jwt(problemSource => $pg_source, problemSeed => 1234, renderMode => 'default');
	$t->post_ok('/render-api' => form => { problemJWT => $jwt, outputFormat => 'debug', isInstructor => 1 })
		->status_is(200);
	is($t->tx->res->json->{permissions}{isInstructor}, 0, 'the raw value cannot raise it');
	is_deeply($t->tx->res->json->{mode_overrides}, ['isInstructor'], 'the ignored raw value is reported');
};

subtest 'session: a signed hideFeedback claim beats a raw hideFeedback=0' => sub {
	my $problemJWT = make_problem_jwt(problemSource => $pg_source, problemSeed => 1234);
	my $sessionJWT = encode_jwt(
		payload => { problemJWT => $problemJWT, hideFeedback => 1 },
		key     => $ENV{webworkJWTsecret},
		alg     => 'HS256',
	);
	$t->post_ok('/render-api' => form => { sessionJWT => $sessionJWT, hideFeedback => 0 })->status_is(200);
	like(interact_button($t->tx->res->body), qr/value="Save Answers"/, 'the session claim is in force');
};

done_testing();
