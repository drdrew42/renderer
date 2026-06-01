
=head1 NAME

FormatRenderedProblem.pm

=cut

package WeBWorK::FormatRenderedProblem;

use strict;
use warnings;

use Mojo::JSON qw(encode_json);
use Mojo::Util qw(xml_escape);
use Mojo::DOM;
use Mojo::URL;

use WeBWorK::Localize;
use WeBWorK::Utils qw(getAssetURL);
use WeBWorK::Utils::LanguageAndDirection;
use Renderer::Permissions;

sub formatRenderedProblem {
	my $c          = shift;
	my $rh_result  = shift;
	my $inputs_ref = $rh_result->{inputs_ref};

	my $renderErrorOccurred = 0;

	my $problemText = $rh_result->{text} // '';
	$problemText .= $rh_result->{flags}{comment} if ($rh_result->{flags}{comment} && $inputs_ref->{showComments});

	if ($rh_result->{flags}{error_flag}) {
		$rh_result->{problem_result}{score} = 0;    # force score to 0 for such errors.
		$renderErrorOccurred = 1;
	}

	# TODO: add configuration to disable these overrides
	my $SITE_URL        = $inputs_ref->{baseURL} ? Mojo::URL->new($inputs_ref->{baseURL}) : $main::basehref;
	my $FORM_ACTION_URL = $inputs_ref->{formURL} ? Mojo::URL->new($inputs_ref->{formURL}) : $main::formURL;

	# parent_origin: where rendered iframe's postMessage broadcasts are allowed
	# to target. Only set if it arrived via a trusted lane (JWT claim or
	# peer-signed body field). Empty string → template omits data-parent-origin
	# attribute → problem.js falls back to wildcard '*' (preserves legacy behavior).
	my $parent_origin = $inputs_ref->{parent_origin} // '';

	# trust_lane: the lane the request entered through, set by Renderer::Lane::*
	# on entry. Read by css-message.js (via data-trust-lane on <html>) to decide
	# whether to warn when an inbound message arrives without parent_origin
	# declared. Defaults to 'ungrounded' (PTX builds, direct callback paths,
	# any code path that bypasses parseRequest's lane dispatcher).
	my $trust_lane = $c->stash('_trust_lane') // 'ungrounded';

	my $displayMode = $inputs_ref->{displayMode} // 'MathJax';

	# HTML document language setting
	my $formLanguage = $inputs_ref->{language} // 'en';

	# Third party CSS — config-driven (WW3-R24). Defaults baked into
	# Renderer.pm startup; per-language asset resolution still happens here.
	my $css_list = $c->config('third_party_css') // [];
	my @third_party_css = map { getAssetURL($formLanguage, $_) } @$css_list;

	# Add CSS files requested by problems via ADD_CSS_FILE() in the PG file
	# or via a setting of $ce->{pg}{specialPGEnvironmentVars}{extra_css_files}
	# which can be set in course.conf (the value should be an anonomous array).
	my @cssFiles;
	if (ref($rh_result->{flags}{extra_css_files}) eq 'ARRAY') {
		push @cssFiles, @{ $rh_result->{flags}{extra_css_files} };
	}
	my %cssFilesAdded;    # Used to avoid duplicates
	my @extra_css_files;
	for (@cssFiles) {
		next if $cssFilesAdded{ $_->{file} };
		$cssFilesAdded{ $_->{file} } = 1;
		if ($_->{external}) {
			push(@extra_css_files, $_);
		} else {
			push(@extra_css_files, { file => getAssetURL($formLanguage, $_->{file}), external => 0 });
		}
	}

	# Third party JavaScript — config-driven (WW3-R24). Each entry is
	# [path, attrs-hash]; attrs hash carries `defer`, `id`, etc. Defaults
	# baked into Renderer.pm startup.
	my $js_list = $c->config('third_party_js') // [];
	my @third_party_js = map { [ getAssetURL($formLanguage, $_->[0]), $_->[1] ] } @$js_list;

	# Get the requested format. (outputFormat or outputformat)
	my $formatName = $inputs_ref->{outputFormat} || 'default';

	# Collapse the default/simple/static alias cluster (WW3-R21). All three
	# render the same template; `static` hides the two remaining buttons.
	# `simple` is a pure alias for `default`. Caller's explicit per-button
	# flags always win — translate only when the flag isn't already set.
	if ($formatName eq 'static') {
		$inputs_ref->{hideCheckAnswersButton}   //= 1;
		$inputs_ref->{showCorrectAnswersButton} //= 0;
	}
	$formatName = 'default' if $formatName eq 'simple' || $formatName eq 'static';

	# Add JS files requested by problems via ADD_JS_FILE() in the PG file.
	my @extra_js_files;
	if (ref($rh_result->{flags}{extra_js_files}) eq 'ARRAY') {
		my %jsFiles;
		for (@{ $rh_result->{flags}{extra_js_files} }) {
			next if $jsFiles{ $_->{file} };
			$jsFiles{ $_->{file} } = 1;
			my %attributes = ref($_->{attributes}) eq 'HASH' ? %{ $_->{attributes} } : ();
			if ($_->{external}) {
				push(@extra_js_files, $_);
			} else {
				push(
					@extra_js_files,
					{
						file       => getAssetURL($formLanguage, $_->{file}),
						external   => 0,
						attributes => $_->{attributes}
					}
				);
			}
		}
	}

	# Set up the problem language and direction
	# PG files can request their language and text direction be set.  If we do not have access to a default course
	# language, fall back to the $formLanguage instead.
	# TODO: support for right-to-left languages
	my %PROBLEM_LANG_AND_DIR = get_problem_lang_and_dir($rh_result->{flags}, 'auto:en:ltr', $formLanguage);
	my $PROBLEM_LANG_AND_DIR = join(' ', map {qq{$_="$PROBLEM_LANG_AND_DIR{$_}"}} keys %PROBLEM_LANG_AND_DIR);

	my $submitMode      = defined($inputs_ref->{submitAnswers})      || $inputs_ref->{answersSubmitted} || 0;
	my $showCorrectMode = defined($inputs_ref->{showCorrectAnswers}) || 0;
	# A problemUUID should be added to the request as a parameter.  It is used by PG to create a proper UUID for use in
	# aliases for resources.  It should be unique for a course, user, set, problem, and version.
	my $problemUUID      = $inputs_ref->{problemUUID}      // '';
	my $problemResult    = $rh_result->{problem_result}    // {};
	my $showSummary      = $inputs_ref->{showSummary}      // 1;
	my $scoresExist      = $submitMode && !$renderErrorOccurred && $problemResult;
	my $showScoreSummary = ( $inputs_ref->{showScoreSummary} // 0 ) && $scoresExist;
	# allow the request to override the display of partial correct answers
	my $showPartialCorrectAnswers = $inputs_ref->{showPartialCorrectAnswers}
		// $rh_result->{flags}{showPartialCorrectAnswers};

	# Do not produce a result summary when we had a rendering error.
	my $resultSummary = '';
	if (!$renderErrorOccurred
		&& $showSummary
		&& ($submitMode || $showCorrectMode)
		&& $problemResult->{summary})
	{
		$resultSummary = $c->c(
			$c->tag(
				'h2',
				class => 'fs-3 mb-2',
				'Results for this submission'
				)
				. $c->tag('div', role => 'alert', $c->b($problemResult->{summary}))
		)->join('');
	}

	# Answer hash in XML format used by the PTX format.
	my $answerhashXML = '';
	if ($formatName eq 'ptx') {
		my $dom = Mojo::DOM->new->xml(1);
		for my $answer (sort keys %{ $rh_result->{answers} }) {
			$dom->append_content($dom->new_tag(
				$answer,
				map { $_ => ($rh_result->{answers}{$answer}{$_} // '') } keys %{ $rh_result->{answers}{$answer} }
			));
		}
		$dom->wrap_content('<answerhashes></answerhashes>');
		$answerhashXML = $dom->to_string;
	}

	# Make sure this is defined and is an array reference as saveGradeToLTI might add to it.
	$rh_result->{debug_messages} = [] unless defined $rh_result && ref $rh_result->{debug_messages} eq 'ARRAY';

	# Execute and return the interpolated problem template

	# Debug format: diagnostic view for troubleshooting + test introspection.
	# Returns JSON with permission decisions, macro injection, render state,
	# the minted-token payload, and the resolved inputs_ref (post-claim-merge).
	# This is the format the renderer's test suite uses to inspect rendered
	# state — see t/permissions.t, t/reveal_reporting.t for example uses.
	if ($formatName eq 'debug') {
		# Top-level `lane` field exposes which trust lane produced this
		# render (WW3-R27). The R31 retirement of isLocked left the
		# permissions block carrying only render-affecting flags;
		# reveal-history reporting lives on the answerJWT and is inspected
		# via the tokens block, not here.
		#
		# Permissions block is the resolver's view (renderer decision),
		# not raw inputs — instructor mode's default-on rules now show
		# correctly here. Was a latent bug pre-R36: instructors with no
		# explicit showCorrectAnswers would see 0 in this block while
		# the actual render resolved to 1.
		my $perms = Renderer::Permissions::resolve_permissions($inputs_ref);
		my $debug = {
			lane        => $trust_lane,
			permissions => $perms,
			problem => {
				pg_hash        => $inputs_ref->{pg_hash} // '',
				sourceFilePath => $inputs_ref->{sourceFilePath} // '',
				problemSeed    => $inputs_ref->{problemSeed},
				problemUUID    => $problemUUID,
			},
			macros => {
				injected => $inputs_ref->{injectedMacros} ? [
					map { { name => $_->{name}, hash => $_->{hash} } }
						@{ $inputs_ref->{injectedMacros} }
				] : [],
			},
			result => {
				score    => $rh_result->{problem_result}{score} // undef,
				errors   => $rh_result->{errors} // '',
				warnings => $rh_result->{warning_messages} // [],
				flags    => {
					map { $_ => $rh_result->{flags}{$_} }
						grep { defined $rh_result->{flags}{$_} }
						qw(showPartialCorrectAnswers PROBLEM_GRADING_ATTEMPTED comment)
				},
			},
			render_error => $renderErrorOccurred ? 1 : 0,

			# Continuation tokens the renderer minted for this request.
			# Undef when the lane / config did not produce one — tests can
			# assert presence/absence directly. Replaces the historical
			# $rh_result->{sessionJWT} / answerJWT extraction from the now-
			# retired `raw` outputFormat (WW3-R21).
			tokens => {
				sessionJWT    => $rh_result->{sessionJWT},
				answerJWT     => $rh_result->{answerJWT},
				submissionJWT => $rh_result->{submissionJWT},
			},

			# Echo of the resolved $inputs_ref after parseRequest's claim
			# merge. Useful for tests that need to verify the post-merge
			# shape (e.g. that a directive was or wasn't synthesized from
			# session state).
			inputs_ref => $inputs_ref,
		};
		return $c->render(data => encode_json($debug));
	}

	# Declarative element-hiding via JWT claim (WW3-R01). Caller's JWT envelope
	# may carry hideElements => [<selector>, ...]; we splice an inline <style>
	# block into <head> so target elements are never present in the initial
	# paint — closes the flash window between PG render and css-message.js
	# postMessage styling. Selectors arrive via JWT (trusted-but-not-trustworthy);
	# xml_escape defends the splice against caller-controlled markup.
	my $hideElementsCSS = '';
	if (ref $inputs_ref->{hideElements} eq 'ARRAY' && @{ $inputs_ref->{hideElements} }) {
		my $selectors = join(', ', map { xml_escape($_) } @{ $inputs_ref->{hideElements} });
		$hideElementsCSS = "<style>$selectors { display: none !important; }</style>";
	}

	# Setup and render the appropriate template in the templates/RPCRenderFormats folder depending on the outputformat.
	# "ptx" has a special template.  "json" uses the default json template.  All others use the default html template.
	my %template_params = (
		template => $formatName eq 'ptx' ? 'RPCRenderFormats/ptx' : 'RPCRenderFormats/default',
		$formatName eq 'json' ? (format => 'json') : (),
		formatName               => $formatName,
		lh                       => WeBWorK::Localize::getLangHandle($inputs_ref->{language} // 'en'),
		rh_result                => $rh_result,
		SITE_URL                 => $SITE_URL,
		FORM_ACTION_URL          => $FORM_ACTION_URL,
		parent_origin            => $parent_origin,
		trust_lane               => $trust_lane,
		COURSE_LANG_AND_DIR      => get_lang_and_dir($formLanguage),
		PROBLEM_LANG_AND_DIR     => $PROBLEM_LANG_AND_DIR,
		third_party_css          => \@third_party_css,
		extra_css_files          => \@extra_css_files,
		third_party_js           => \@third_party_js,
		extra_js_files           => \@extra_js_files,
		problemText              => $problemText,
		extra_header_text        => $inputs_ref->{extra_header_text} // '',
		hideElementsCSS          => $hideElementsCSS,
		resultSummary            => $resultSummary,
		showSummary              => $showSummary,
		showScoreSummary         => $showScoreSummary,
		answerhashXML            => $answerhashXML,
		showCheckAnswersButton   => $inputs_ref->{hideCheckAnswersButton} ? 0 : 1,
		showCorrectAnswersButton => $inputs_ref->{showCorrectAnswersButton}
			// ($inputs_ref->{isInstructor} ? 1 : 0),
		showFooter   => $inputs_ref->{showFooter} // 0,
		pretty_print => \&pretty_print,
	);

	return $c->render(%template_params) if $formatName eq 'json';
	$rh_result->{renderedHTML} = $c->render_to_string(%template_params)->to_string;
	return $c->respond_to(
		html => { text => $rh_result->{renderedHTML} },
		json => {
			json => jsonResponse(
				$rh_result, $inputs_ref, @extra_css_files, @third_party_css, @extra_js_files, @third_party_js
			)
		},
	);
}

sub jsonResponse {
	my ($rh_result, $inputs_ref, @extra_files) = @_;
	return {
		(
			$inputs_ref->{isInstructor}
			? (
				answers => $rh_result->{answers},
				inputs  => $inputs_ref,
				pgcore  => {
					persist    => $rh_result->{PERSISTENCE_HASH},
					persist_up => $rh_result->{PERSISTENCE_HASH_UPDATED},
					pgah       => $rh_result->{PG_ANSWERS_HASH}
				}
				)
			: ()
		),
		(
			$inputs_ref->{includeTags}
			? (tags => $rh_result->{tags}, raw_metadata_text => $rh_result->{raw_metadata_text})
			: ()
		),
		renderedHTML => $rh_result->{renderedHTML},
		debug        => {
			perl_warn => $rh_result->{WARNINGS},
			pg_warn   => $rh_result->{warning_messages},
			debug     => $rh_result->{debug_messages},
			internal  => $rh_result->{internal_debug_messages}
		},
		problem_result => $rh_result->{problem_result},
		problem_state  => $rh_result->{problem_state},
		flags          => $rh_result->{flags},
		resources      => {
			regex  => $rh_result->{pgResources},
			alias  => $rh_result->{resources},
			assets =>
				[ map { ref $_ eq 'HASH' ? "$_->{file}" : ref $_ eq 'ARRAY' ? "$_->[0]" : "$_" } @extra_files ],
		},
		JWT => {
			problem    => $inputs_ref->{problemJWT},
			session    => $rh_result->{sessionJWT},
			answer     => $rh_result->{answerJWT},
			challenge  => $inputs_ref->{challengeJWT},
			submission => $rh_result->{submissionJWT},
		},
	};
}

# Nice output for debugging
sub pretty_print {
	my ($r_input, $level) = @_;
	return 'undef' unless defined $r_input;

	$level //= 4;
	$level--;
	return 'too deep' unless $level > 0;    # Only print three levels of hashes (safety feature)

	my $ref = ref($r_input);

	if (!$ref) {
		return xml_escape($r_input);
	} elsif (eval { %$r_input && 1 }) {
		# `eval { %$r_input && 1 }` will pick up all objects that can be accessed like a hash and so works better than
		# `ref $r_input`.  Do not use `"$r_input" =~ /hash/i` because that will pick up strings containing the word
		# hash, and that will cause an error below.
		my $out =
			'<div style="display:table;border:1px solid black;background-color:#fff;">'
			. ($ref eq 'HASH'
				? ''
				: '<div style="'
				. 'display:table-caption;padding:3px;border:1px solid black;background-color:#fff;text-align:center;">'
				. "$ref</div>")
			. '<div style="display:table-row-group">';
		for my $key (sort keys %$r_input) {
			# Safety feature - we do not want to display the contents of %seed_ce which
			# contains the database password and lots of other things, and explicitly hide
			# certain internals of the CourseEnvironment in case one slips in.
			next
				if (($key =~ /database/)
					|| ($key =~ /dbLayout/)
					|| ($key eq "ConfigValues")
					|| ($key eq "ENV")
					|| ($key eq "externalPrograms")
					|| ($key eq "permissionLevels")
					|| ($key eq "seed_ce"));
			$out .=
				'<div style="display:table-row"><div style="display:table-cell;vertical-align:middle;padding:3px">'
				. xml_escape($key)
				. '</div>'
				. qq{<div style="display:table-cell;vertical-align:middle;padding:3px">=&gt;</div>}
				. qq{<div style="display:table-cell;vertical-align:middle;padding:3px">}
				. pretty_print($r_input->{$key}, $level)
				. '</div></div>';
		}
		$out .= '</div></div>';
		return $out;
	} elsif ($ref eq 'ARRAY') {
		return '[ ' . join(', ', map { pretty_print($_, $level) } @$r_input) . ' ]';
	} elsif ($ref eq 'CODE') {
		return 'CODE';
	} else {
		return xml_escape($r_input);
	}
}

1;
