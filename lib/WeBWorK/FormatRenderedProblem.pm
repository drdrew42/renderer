################################################################################
# WeBWorK Online Homework Delivery System
# Copyright &copy; 2000-2022 The WeBWorK Project, https://github.com/openwebwork
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of either: (a) the GNU General Public License as published by the
# Free Software Foundation; either version 2, or (at your option) any later
# version, or (b) the "Artistic License" which comes with this package.
#
# This program is distributed in the hope that it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
# FOR A PARTICULAR PURPOSE.  See either the GNU General Public License or the
# Artistic License for more details.
################################################################################

=head1 NAME

FormatRenderedProblem.pm

=cut

package WeBWorK::FormatRenderedProblem;

use strict;
use warnings;

use JSON;
use Digest::SHA qw(sha1_base64);
use Mojo::Util qw(xml_escape);
use Mojo::DOM;

use WeBWorK::Localize;
use WeBWorK::AttemptsTable;
use WeBWorK::Utils qw(getAssetURL);
use WeBWorK::Utils::LanguageAndDirection;

sub formatRenderedProblem {
	my $c = shift;
	my $rh_result = shift;
	my $inputs_ref = $rh_result->{inputs_ref};

	my $renderErrorOccurred = 0;

	my $problemText = $rh_result->{text} // '';
	$problemText   .= $rh_result->{flags}{comment} if ( $rh_result->{flags}{comment} && $inputs_ref->{showComments} );

	if ($rh_result->{flags}{error_flag}) {
		$rh_result->{problem_result}{score} = 0;    # force score to 0 for such errors.
		$renderErrorOccurred                = 1;
	}

	my $SITE_URL        = $inputs_ref->{baseURL};
	my $FORM_ACTION_URL = $inputs_ref->{formURL}; 

	my $displayMode = $inputs_ref->{displayMode} // 'MathJax';

	# HTML document language setting
	my $formLanguage = $inputs_ref->{language} // 'en';

	# Third party CSS
	# The second element of each array in the following is whether or not the file is a theme file.
	# customize source for bootstrap.css
	my @third_party_css = map { getAssetURL($formLanguage, $_->[0]) } (
		[ 'css/bootstrap.css',                                         ],
		[ 'node_modules/jquery-ui-dist/jquery-ui.min.css',             ],
		[ 'node_modules/@fortawesome/fontawesome-free/css/all.min.css' ],
	);

	# Add CSS files requested by problems via ADD_CSS_FILE() in the PG file
	# or via a setting of $ce->{pg}{specialPGEnvironmentVars}{extra_css_files}
	# which can be set in course.conf (the value should be an anonomous array).
	my @cssFiles;
	# if (ref($ce->{pg}{specialPGEnvironmentVars}{extra_css_files}) eq 'ARRAY') {
	# 	push(@cssFiles, { file => $_, external => 0 }) for @{ $ce->{pg}{specialPGEnvironmentVars}{extra_css_files} };
	# }
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

	# Third party JavaScript
	# The second element of each array in the following is whether or not the file is a theme file.
	# The third element is a hash containing the necessary attributes for the script tag.
	my @third_party_js = map { [ getAssetURL($formLanguage, $_->[0]), $_->[1] ] } (
		[ 'node_modules/jquery/dist/jquery.min.js',                            {} ],
		[ 'node_modules/jquery-ui-dist/jquery-ui.min.js',                      {} ],
		[ 'node_modules/iframe-resizer/js/iframeResizer.contentWindow.min.js', {} ],
		[ "js/apps/MathJaxConfig/mathjax-config.js",                           { defer => undef } ],
		[ 'node_modules/mathjax/es5/tex-svg.js',                               { defer => undef, id => 'MathJax-script' } ],
		[ 'node_modules/bootstrap/dist/js/bootstrap.bundle.min.js',            { defer => undef } ],
		[ "js/apps/Problem/problem.js",                                                { defer => undef } ],
		[ "js/apps/Problem/submithelper.js",                                           { defer => undef } ],
		[ "js/apps/CSSMessage/css-message.js",                                 { defer => undef } ],
	);

	# Get the requested format. (outputFormat or outputformat)
	# override to static mode if showCorrectAnswers has been set
	my $formatName = $inputs_ref->{showCorrectAnswers} && !$inputs_ref->{isInstructor}
		? 'static' : $inputs_ref->{outputFormat};

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
				push(@extra_js_files,
					{ file => getAssetURL($formLanguage, $_->{file}), external => 0, attributes => $_->{attributes} });
			}
		}
	}

	# Set up the problem language and direction
	# PG files can request their language and text direction be set.  If we do not have access to a default course
	# language, fall back to the $formLanguage instead.
	# TODO: support for right-to-left languages
	my %PROBLEM_LANG_AND_DIR =
		get_problem_lang_and_dir($rh_result->{flags}, 'auto:en:ltr', $formLanguage);
	my $PROBLEM_LANG_AND_DIR = join(' ', map {qq{$_="$PROBLEM_LANG_AND_DIR{$_}"}} keys %PROBLEM_LANG_AND_DIR);

	# is there a reason this doesn't use the same button IDs?
	my $previewMode     = defined($inputs_ref->{previewAnswers})     || 0;
	my $submitMode      = defined($inputs_ref->{submitAnswers})      || $inputs_ref->{answersSubmitted} || 0;
	my $showCorrectMode = defined($inputs_ref->{showCorrectAnswers}) || 0;
	# A problemUUID should be added to the request as a parameter.  It is used by PG to create a proper UUID for use in
	# aliases for resources.  It should be unique for a course, user, set, problem, and version.
	my $problemUUID       = $inputs_ref->{problemUUID}       // '';
	my $problemResult     = $rh_result->{problem_result}     // {};
	my $showSummary       = $inputs_ref->{showSummary}       // 1;
	my $showAnswerNumbers = $inputs_ref->{showAnswerNumbers} // 0; # default no
	# allow the request to hide the results table or messages
	my $showTable    = $inputs_ref->{hideAttemptsTable} ? 0 : 1;
	my $showMessages = $inputs_ref->{hideMessages}      ? 0 : 1;
	# allow the request to override the display of partial correct answers
	my $showPartialCorrectAnswers = $inputs_ref->{showPartialCorrectAnswers}
		// $rh_result->{flags}{showPartialCorrectAnswers};

	# Attempts table
	my $answerTemplate = '';

	# Do not produce an AttemptsTable when we had a rendering error.
	if (!$renderErrorOccurred && $submitMode && $showTable) {
		my $tbl = WeBWorK::AttemptsTable->new(
			$rh_result->{answers} // {}, $c,
			answersSubmitted    => 1,
			answerOrder         => $rh_result->{flags}{ANSWER_ENTRY_ORDER} // [],
			displayMode         => $displayMode,
			showAnswerNumbers   => $showAnswerNumbers,
			showAttemptAnswers  => 0,
			showAttemptPreviews => 1,
			showAttemptResults  => $showPartialCorrectAnswers && !$previewMode,
			showCorrectAnswers  => $showCorrectMode,
			showMessages        => $showMessages,
			showSummary         => $showSummary && !$previewMode,
			mtRef               => WeBWorK::Localize::getLoc($formLanguage),
			summary             => $problemResult->{summary} // '',    # can be set by problem grader
		);
		$answerTemplate = $tbl->answerTemplate;
		# $tbl->imgGen->render(refresh => 1) if $tbl->displayMode eq 'images';
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

	# Raw format
	# This format returns javascript object notation corresponding to the perl hash
	# with everything that a client-side application could use to work with the problem.
	# There is no wrapping HTML "_format" template.
	if ($formatName eq 'raw') {
		my $output = {};

		# Everything that ships out with other formats can be constructed from these
		$output->{rh_result}  = $rh_result;
		$output->{inputs_ref} = $inputs_ref;
		# $output->{input}      = $ws->{input};

		# The following could be constructed from the above, but this is a convenience
		$output->{answerTemplate}  = $answerTemplate if ($answerTemplate);
		$output->{lang}            = $PROBLEM_LANG_AND_DIR{lang};
		$output->{dir}             = $PROBLEM_LANG_AND_DIR{dir};
		$output->{extra_css_files} = \@extra_css_files;
		$output->{extra_js_files}  = \@extra_js_files;

		# Include third party css and javascript files.  Only jquery, jquery-ui, mathjax, and bootstrap are needed for
		# PG.  See the comments before the subroutine definitions for load_css and load_js in pg/macros/PG.pl.
		# The other files included are only needed to make themes work in the webwork2 formats.
		$output->{third_party_css} = \@third_party_css;
		$output->{third_party_js}  = \@third_party_js;

		# Say what version of WeBWorK this is
		# $output->{ww_version} = $ce->{WW_VERSION};
		# $output->{pg_version} = $ce->{PG_VERSION};

		# Convert to JSON and render.
		return $c->render(data => JSON->new->utf8(1)->encode($output));
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
		COURSE_LANG_AND_DIR      => get_lang_and_dir($formLanguage),
		PROBLEM_LANG_AND_DIR     => $PROBLEM_LANG_AND_DIR,
		third_party_css          => \@third_party_css,
		extra_css_files          => \@extra_css_files,
		third_party_js           => \@third_party_js,
		extra_js_files           => \@extra_js_files,
		problemText              => $problemText,
		extra_header_text        => $inputs_ref->{extra_header_text} // '',
		answerTemplate           => $answerTemplate,
		showScoreSummary         => $submitMode && !$renderErrorOccurred && !$previewMode && $problemResult,
		answerhashXML            => $answerhashXML,
		showPreviewButton        => $inputs_ref->{hidePreviewButton}        ? '' : 0,
		showCheckAnswersButton   => $inputs_ref->{hideCheckAnswersButton}   ? '' : 0,
		showCorrectAnswersButton => $inputs_ref->{showCorrectAnswersButton} // $inputs_ref->{isInstructor} ? '' : '0',
		showFooter               => $inputs_ref->{showFooter}               // '0',
		pretty_print             => \&pretty_print,
	);

	return $c->render(%template_params) if $formatName eq 'json' && !$inputs_ref->{send_pg_flags};
	$rh_result->{renderedHTML} = $c->render_to_string(%template_params)->to_string;
	return $c->respond_to(
		html => { text => $rh_result->{renderedHTML} },
		json => { json => $rh_result });
}

# Nice output for debugging
sub pretty_print {
	my ($r_input, $level) = @_;
	$level //= 4;
	$level--;
	return '' unless $level > 0;    # Only print three levels of hashes (safety feature)
	my $out = '';
	if (!ref $r_input) {
		$out = $r_input if defined $r_input;
		$out =~ s/</&lt;/g;         # protect for HTML output
	} elsif (eval { %$r_input && 1 }) {
		# eval { %$r_input && 1 } will pick up all objectes that can be accessed like a hash and so works better than
		# "ref $r_input".  Do not use "$r_input" =~ /hash/i" because that will pick up strings containing the word hash,
		# and that will cause an error below.
		local $^W = 0;
		$out .= qq{$r_input <table border="2" cellpadding="3" bgcolor="#FFFFFF">};

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
			$out .= "<tr><td>$key</td><td>=&gt;</td><td>&nbsp;" . pretty_print($r_input->{$key}, $level) . "</td></tr>";
		}
		$out .= '</table>';
	} elsif (ref $r_input eq 'ARRAY') {
		my @array = @$r_input;
		$out .= '( ';
		while (@array) {
			$out .= pretty_print(shift @array, $level) . ' , ';
		}
		$out .= ' )';
	} elsif (ref $r_input eq 'CODE') {
		$out = "$r_input";
	} else {
		$out = $r_input;
		$out =~ s/</&lt;/g;    # Protect for HTML output
	}

	return $out . ' ';
}

1;
