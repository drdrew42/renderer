package WeBWorK::HintSolution;

# Pure dumb content fetches: render a problem with showHints=1 (or showSolutions=1)
# and return only the hint/solution body content extracted from the rendered HTML.
#
# These are the implementation behind POST /render-api/hint and
# POST /render-api/solution (WW3-R28). Bypasses parseRequest entirely
# (PTX precedent — see WeBWorK::PreTeXt::render_ptx). Mints nothing,
# POSTs nothing, emits no events. The LMS/orchestrator gates user
# access at its own UI layer; the renderer is dumb about who's allowed
# to read what.
#
# See WeBWorK/Renderer/Render-Only Hint and Solution Modes.md for the
# investigation deliverable that informed this implementation
# (full render + DOM filter pattern using PG's existing showHints /
# showSolutions flags).

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Mojo::DOM;
use Mojo::IOLoop;
use lib "$ENV{PG_ROOT}/lib";
use WeBWorK::PG;

use Exporter qw(import);
our @EXPORT_OK = qw(render_hint render_solution);

# render_hint($p) → Mojo::Promise resolving to:
#   { hints => [ "<html>", ... ] }            # zero or more hints found
#   { error => "...", status => 5xx }         # render failure
sub render_hint ($p) {
	return _render_and_filter($p, mode => 'hint');
}

# render_solution($p) → Mojo::Promise resolving to:
#   { solution => "<html>" }                  # solution body found
#   { solution => undef }                     # no solution blocks in problem
#   { error => "...", status => 5xx }         # render failure
sub render_solution ($p) {
	return _render_and_filter($p, mode => 'solution');
}

sub _render_and_filter ($p, %opts) {
	my $mode   = $opts{mode};
	my $source = $p->{problemSource} // '';

	return Mojo::IOLoop->subprocess->run_p(sub {
		my $pg = WeBWorK::PG->new(
			# The two flags are mutually exclusive here — the endpoint isolates
			# one type of content. Setting only the one that matches the mode
			# keeps PG from emitting the other type's divs (smaller DOM to
			# parse, less work to do).
			showSolutions  => $mode eq 'solution' ? 1 : 0,
			showHints      => $mode eq 'hint'     ? 1 : 0,
			# No answer scoring — these endpoints don't grade anything.
			processAnswers => 0,
			# Force HTML output. PG's SOLUTION/HINT macros emit different
			# wrappers for TeX/PTX modes; we always want the .hint/.solution
			# accordion divs that DOM filtering targets.
			displayMode    => 'MathJax',
			problemSeed    => $p->{problemSeed} // 1234,
			r_source       => \$source,
			# Content-addressed custom macros: source bytes for custom/override
			# macros live only in the content cache, not on disk. Without this
			# wiring, loadMacros() for chemQuillMath / contextInexactValue /
			# etc. fails silently — PG returns no body, solutionExists stays 0,
			# and the endpoint returns solution: null. See RenderProblem.pm:256
			# for the same wiring on the main /render-api lane.
			($p->{injectedMacros} ? (injectedMacros => $p->{injectedMacros}) : ()),
			# State-conditional content (a hint reading $inputs{...}) flows
			# through PG's normal inputs_ref plumbing. Empty hashref for the
			# stateless case (the typical case).
			inputs_ref     => $p->{inputs_ref} // {},
		);

		# Render failure: PG sets error_flag and accumulates messages in
		# $pg->{errors} on Translator-level failures (uncompilable problem,
		# loadMacros failure, etc.). Surface as 5xx so the caller can tell
		# this apart from "this problem has no hint/solution block."
		if ($pg->{flags}{error_flag}) {
			my $err = $pg->{errors} // 'PG render failed';
			$pg->free;
			return { error => $err, status => 500 };
		}

		# Existence flag short-circuit. PG sets these to 1 only if at least
		# one HINT/SOLUTION macro fired during document evaluation. If a
		# problem has no hint/solution blocks at all, skip the DOM walk and
		# return the empty shape immediately.
		my $exists_flag = $mode eq 'solution'
			? $pg->{flags}{solutionExists}
			: $pg->{flags}{hintExists};

		unless ($exists_flag) {
			$pg->free;
			return $mode eq 'hint'
				? { hints    => [] }
				: { solution => undef };
		}

		# DOM filter — extract the .accordion-body content from each
		# .hint or .solution div. PGbasicmacros.pl emits a stable structure
		# (HINT and SOLUTION subs in lib/PG/macros/core/PGbasicmacros.pl).
		my $dom      = Mojo::DOM->new($pg->{body_text} // '');
		my $selector = ".$mode .accordion-body";
		my @bodies   = map { $_->content } $dom->find($selector)->each;

		$pg->free;

		return $mode eq 'hint'
			? { hints    => \@bodies }
			: { solution => $bodies[0] };
	})->catch(sub {
		my $err = shift;
		return { error => "$err", status => 500 };
	});
}

1;
