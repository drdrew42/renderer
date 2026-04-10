package WeBWorK::RenderProblem;

use strict;
use warnings;

# for logs
use Time::HiRes qw/time/;
use Proc::ProcessTable;
use Date::Format;

use Mojo::JSON  qw( encode_json );
use Crypt::JWT  qw( encode_jwt );
use Digest::MD5 qw( md5_hex );

use lib "$ENV{PG_ROOT}/lib";

use WeBWorK::PG;
use WeBWorK::Utils::Tags;

##################################################
# create log files :: expendable
##################################################

my $path_to_log_file = "$ENV{RENDER_ROOT}/logs/resource_usage.log";

eval {    # attempt to create log file
	local (*FH);
	open(FH, '>>:encoding(UTF-8)', $path_to_log_file)
		or die "Can't open file $path_to_log_file for writing";
	close(FH);
};

die "You must first create an output file at $path_to_log_file with permissions 777 "
	unless -w $path_to_log_file;

##################################################
# define universal TO_JSON for JSON::XS unbless
##################################################

sub UNIVERSAL::TO_JSON {
	my ($self) = shift;

	use Storable              qw(dclone);
	use Data::Structure::Util qw(unbless);

	my $clone = unbless(dclone($self));

	$clone;
}

##########################################################
#  END MAIN :: BEGIN SUBROUTINES
##########################################################

#######################################################################
# Process the pg file
#######################################################################

sub process_pg_file {
	my ($problem, $inputs_ref) = @_;

	# just make sure we have the fundamentals covered...
	$inputs_ref->{displayMode}  ||= 'MathJax';
	$inputs_ref->{outputFormat} ||= $inputs_ref->{outputformat} || 'default';
	$inputs_ref->{language}     ||= 'en';
	$inputs_ref->{isInstructor} //= ($inputs_ref->{permissionLevel} // 0) >= 10;
	# HACK: required for problemRandomize.pl
	$inputs_ref->{effectiveUser} = 'red.ted';
	$inputs_ref->{user}          = 'red.ted';

	my $pg_start         = time;
	my $memory_use_start = get_current_process_memory();

	my ($return_object, $error_flag, $error_string) = process_problem($problem, $inputs_ref);

	my $pg_stop        = time;
	my $pg_duration    = $pg_stop - $pg_start;
	my $log_file_path  = $inputs_ref->{sourceFilePath} || 'source provided without path';
	my $memory_use_end = get_current_process_memory();
	my $memory_use     = $memory_use_end - $memory_use_start;
	writeRenderLogEntry(
		sprintf("(duration: %.3f sec) ", $pg_duration)
			. sprintf("{memory: %6d bytes} ", $memory_use)
			. "file: $log_file_path"
			. $error_flag ? $error_string : '');

	# havoc caused by problemRandomize.pl inserting CODE ref into pg->{flags}
	# HACK: remove flags->{problemRandomize} if it exists -- cannot include CODE refs
	delete $return_object->{flags}{problemRandomize}
		if $return_object->{flags}{problemRandomize};
	# similar things happen with compoundProblem -- delete CODE refs
	delete $return_object->{flags}{compoundProblem}{grader}
		if $return_object->{flags}{compoundProblem}{grader};

	$return_object->{tags} = WeBWorK::Utils::Tags->new($inputs_ref->{sourceFilePath}, $problem->source)
		if ($inputs_ref->{includeTags});

	my $json = encode_json($return_object);
	return $json;
}

#######################################################################
# Process Problem
#######################################################################

sub process_problem {
	my ($problem, $inputs_ref) = @_;

	my $source    = $problem->{problem_contents};
	my $file_path = $inputs_ref->{sourceFilePath} || $inputs_ref->{problemSourceURL};
	my ($raw_metadata_text, $problemUUID);

	# TODO: include problemUUID from problemSourceURL and skip this if present
	if ($source =~ m|^(.*?)(&?DOCUMENT\s*\(?.*?\)?\s*;.*?&?ENDDOCUMENT\s*\(?\s*\)?\s*;?)(.*)$|s) {
		$raw_metadata_text = $1;
		my $body = $2;
		$body =~ s|#.*$||g;    # strip commments before hashing
		$body =~ s|\s||gm;     # strip whitespace before hashing
		$problemUUID = md5_hex(Encode::encode_utf8($body));
	} else {
		$raw_metadata_text = 'no-document';
		$problemUUID       = 'no-document';
	}
	warn "Mismatched problemUUID (incoming: $inputs_ref->{problemUUID}) (computed: $problemUUID)"
		if (defined $inputs_ref->{problemUUID} && $inputs_ref->{problemUUID} ne $problemUUID);
	$inputs_ref->{problemUUID} //= $problemUUID;

	# external dependencies on pg content is not recorded by PGalias
	# record the dependency separately -- TODO: incorporate into PG.pl or PGcore?
	my @pgResources;
	while ($source =~ m/includePG(?:problem|file)\(\s*["'](.*)["']\s*\);/g) {
		push @pgResources, $1;
	}

	##################################################
	# Process the pg file
	##################################################
	our ($return_object, $error_flag, $error_string);
	$error_flag   = 0;
	$error_string = '';

	# can include @args as third input below
	$return_object = standaloneRenderer(\$source, $inputs_ref);

	# stash assets list in $return_object
	$return_object->{pgResources}       = \@pgResources;
	$return_object->{raw_metadata_text} = $raw_metadata_text if $inputs_ref->{includeTags};

	# Generate sessionJWT + answerJWT for student interactions only.
	# Instructors don't get session tracking or answer JWTs — their
	# interactions are exploratory and should not produce telemetry.
	if ($inputs_ref->{isInstructor}) {
		# no-op: no session, no answer JWT
	} elsif ($inputs_ref->{previewAnswers}) {
		# preview: leave session unmodified, no answerJWT
		$return_object->{sessionJWT} = $inputs_ref->{sessionJWT};
	} elsif ($inputs_ref->{problemJWT}) {
		my ($sessionJWT, $answerJWT) = generateJWTs($return_object, $inputs_ref);
		$return_object->{sessionJWT} = $sessionJWT;
		$return_object->{answerJWT}  = $answerJWT;
	}

	#######################################################################
	# Handle errors
	#######################################################################

	if (not defined $return_object) {
		$error_string = " could not be processed";
	} elsif (defined $return_object->{flags}{error_flag}
		&& $return_object->{flags}{error_flag})
	{
		$error_string = " has errors";
	} elsif (defined($return_object->{errors}) && $return_object->{errors}) {
		$error_string = " has syntax errors";
	}
	$error_flag = 1 if $return_object->{errors};

	#######################################################################
	# End processing of the pg file
	#######################################################################

	return $return_object, $error_flag, $error_string;
}

###########################################
# standalonePGproblemRenderer
###########################################

sub standaloneRenderer {
	my $problemFile = shift // '';
	my $inputs_ref  = shift // {};
	my %args        = @_;

	my $processAnswers = $inputs_ref->{processAnswers} // 1;

	my $isPreview    = defined($inputs_ref->{previewAnswers}) ? 1 : 0;
	my $isSubmit     = defined($inputs_ref->{submitAnswers})  ? 1 : 0;
	my $isInstructor = $inputs_ref->{isInstructor} ? 1 : 0;

	# Permission model — isInstructor is the mode switch.
	#
	# Instructor (preview): everything visible by default. Callers can
	#   suppress individual flags to see the student view.
	#
	# Student (assessed): nothing revealed by default. showCorrectAnswers
	#   is the primary reveal trigger (the "Show Correct Answers" button).
	#   Solutions ride along with correct answers unless explicitly
	#   suppressed (showSolutions=0). showSolutions alone without
	#   showCorrectAnswers is ignored — solutions don't make sense without
	#   the answers they explain. Hints are always available (PG's
	#   showHints is a render gate, not security-sensitive).
	#
	# Session lifecycle (non-instructor only):
	# - answerJWTs flow on every submit. The LMS owns due-date / scoring.
	# - Session locks when: student scores 100% OR showCorrectAnswers.
	# - After lock: no answerJWT, no session updates.
	my $showCorrectAnswers;
	my $showSolutions;
	my $showHints;

	if ($isInstructor) {
		$showCorrectAnswers = defined $inputs_ref->{showCorrectAnswers}
			? ($inputs_ref->{showCorrectAnswers} ? 1 : 0) : 1;
		$showSolutions = defined $inputs_ref->{showSolutions}
			? ($inputs_ref->{showSolutions} ? 1 : 0) : 1;
		$showHints = defined $inputs_ref->{showHints}
			? ($inputs_ref->{showHints} ? 1 : 0) : 1;
	} else {
		$showCorrectAnswers = $inputs_ref->{showCorrectAnswers} ? 1 : 0;
		# Solutions ride with correct answers unless explicitly suppressed.
		$showSolutions = $showCorrectAnswers
			&& !(defined $inputs_ref->{showSolutions} && !$inputs_ref->{showSolutions});
		$showHints = defined $inputs_ref->{showHints}
			? ($inputs_ref->{showHints} ? 1 : 0) : 1;
	}
	my $displayResults = $inputs_ref->{answersSubmitted} && !$isPreview;
	my $forceResults   = $displayResults                 && $inputs_ref->{showPartialCorrectAnswers};

	my $pg = WeBWorK::PG->new(
		inputs_ref              => {%$inputs_ref},                        # preserve original values
		sourceFilePath          => $inputs_ref->{sourceFilePath} // '',
		r_source                => $problemFile,
		problemSeed             => $inputs_ref->{problemSeed},
		# Content-addressed custom macros: inject source via envir so PG's
		# loadMacros() finds them without filesystem search (PGloadfiles.pm).
		($inputs_ref->{injectedMacros} ? (injectedMacros => $inputs_ref->{injectedMacros}) : ()),
		processAnswers          => $processAnswers,
		showFeedback            => 1,
		showAttemptResults      => $displayResults,                       # respects showPartialCorrectAnswers
		forceShowAttemptResults => $forceResults,                         # overrides showPartialCorrectAnswers
		showAttemptAnswers      => $isPreview,                            # display string version of submitted answer
		showAttemptPreviews     => 1,                                     # display LaTeX version of submitted answer
		showHints               => $showHints,
		showSolutions           => $showSolutions,
		showCorrectAnswers      => $showCorrectAnswers ? 2 : 0,
		num_of_correct_ans      => $inputs_ref->{numCorrect}   || 0,
		num_of_incorrect_ans    => $inputs_ref->{numIncorrect} || 0,
		displayMode             => $inputs_ref->{displayMode},
		useMathQuill            => !defined $inputs_ref->{entryAssist} || $inputs_ref->{entryAssist} eq 'MathQuill',
		answerPrefix            => $inputs_ref->{answerPrefix},
		isInstructor            => $inputs_ref->{isInstructor},
		forceScaffoldsOpen      => $inputs_ref->{forceScaffoldsOpen},
		psvn                    => $inputs_ref->{psvn},
		problemUUID             => $inputs_ref->{problemUUID},
		language                => $inputs_ref->{language} // 'en',
		templateDirectory       => "$ENV{RENDER_ROOT}/",
		htmlURL                 => 'pg_files/',
		tempURL                 => 'pg_files/tmp/',
		debuggingOptions        => {
			show_resource_info          => $inputs_ref->{show_resource_info},
			view_problem_debugging_info => $inputs_ref->{view_problem_debugging_info}
				// $inputs_ref->{isInstructor},
			show_pg_info           => $inputs_ref->{show_pg_info},
			show_answer_hash_info  => $inputs_ref->{show_answer_hash_info},
			show_answer_group_info => $inputs_ref->{show_answer_group_info}
		}
	);

	# new version of output:
	my $ret = {
		text             => $pg->{body_text},
		header_text      => $pg->{head_text},
		post_header_text => $pg->{post_header_text},
		answers          => $pg->{answers},            # unbless?
		errors           => $pg->{errors},
		pg_warnings      => $pg->{warnings},
		problem_result   => $pg->{result},
		problem_state    => $pg->{state},
		flags            => $pg->{flags},
	};
	if (ref($pg->{pgcore}) eq 'PGcore') {
		$ret->{internal_debug_messages} = $pg->{pgcore}->get_internal_debug_messages();
		$ret->{warning_messages}        = $pg->{pgcore}->get_warning_messages();
		$ret->{debug_messages}          = $pg->{pgcore}->get_debug_messages();
		# $ret->{resources}                = [ keys %{ $pg->{pgcore}{PG_alias}{resource_list} } ];
		$ret->{PERSISTENCE_HASH_UPDATED} = $pg->{pgcore}{PERSISTENCE_HASH_UPDATED};
		$ret->{PERSISTENCE_HASH}         = $pg->{pgcore}{PERSISTENCE_HASH};
		$ret->{PG_ANSWERS_HASH}          = {
			map {
				$_ => {
					response_obj => unbless($pg->{pgcore}{PG_ANSWERS_HASH}{$_}->response_obj),
					rh_ans       => $pg->{pgcore}{PG_ANSWERS_HASH}{$_}{ans_eval}{rh_ans}
				}
			}
				keys %{ $pg->{pgcore}{PG_ANSWERS_HASH} }
		};
		# TODO: replace resources after PG merges #1046
		$ret->{resources} = {
			map { $_ => $pg->{pgcore}{PG_alias}{resource_list}{$_}{uri} }
				keys %{ $pg->{pgcore}{PG_alias}{resource_list} }
		};
	} else {
		$ret->{internal_debug_messages} = ['Problem failed during render - no PGcore received.'];
	}
	$pg->free;
	return $ret;
}

##################################################
# utilities
##################################################

sub get_current_process_memory {
	CORE::state $pt = Proc::ProcessTable->new;
	my %info = map { $_->pid => $_ } @{ $pt->table };
	return $info{$$}->rss;
}

# Generate sessionJWT (updated interaction state) and answerJWT (score report for LMS).
#
# The answerJWT is sent to the LMS answer URL on every student submission.
# It contains: score, sessionJWT (opaque), isLocked, and platform.
#
# Three states:
#   1. Normal submit:  isLocked=0 on entry, not triggered. answerJWT sent, isLocked: 0.
#   2. Locking submit: isLocked=0 on entry, triggered this request (100% or
#      showCorrectAnswers). Final answerJWT sent with isLocked: 1.
#   3. Already locked:  isLocked=1 on entry. No answerJWT generated or sent.
#
# Security contract for LMS integrators:
#   The renderer is stateless. It cannot prevent session replay attacks.
#   LMS implementations MUST:
#   - Verify that (numCorrect + numIncorrect) is strictly increasing on each
#     answerJWT received. A stale or equal sum indicates a replayed session.
#   - Once an answerJWT arrives with isLocked=1, reject all further answerJWT
#     updates for that student+problem. isLocked is irreversible.
#   - The answerJWT is a report, not a command. The LMS owns scoring policy.
sub generateJWTs {
	my $pg          = shift;
	my $inputs_ref  = shift;
	my $sessionHash = {
		iss              => $ENV{SITE_HOST},
		answersSubmitted => 1,
		sessionID        => $inputs_ref->{sessionID},
		problemUUID      => $inputs_ref->{problemUUID},
		problemJWT       => $inputs_ref->{problemJWT},
	};
	# Content-addressed mode: carry pg_hash through session for cache hits on follow-ups
	$sessionHash->{pg_hash} = $inputs_ref->{pg_hash} if $inputs_ref->{pg_hash};
	my $scoreHash = {
		result  => $pg->{problem_result}{score},
		answers => unbless($pg->{answers}),
	};
	# Lock the session when the interaction is over (non-instructor only):
	# - Student requested correct answers (which implies solutions too), or
	# - Student scored 100% (nothing left to accomplish).
	# After lock: no further answerJWTs, no session updates.
	if (!$inputs_ref->{isInstructor}) {
		my $perfect = defined $pg->{problem_result}{score} && $pg->{problem_result}{score} >= 1;
		if ($inputs_ref->{showCorrectAnswers} || $perfect) {
			$sessionHash->{showCorrectAnswers} = 1 if $inputs_ref->{showCorrectAnswers};
			$sessionHash->{isLocked}           = 1;
		}
	}

	# store the current answer/response state for each entry
	foreach my $ans (@{ $pg->{flags}{KEPT_EXTRA_ANSWERS} }) {
		$sessionHash->{$ans} = $inputs_ref->{$ans};
	}

	# update the number of correct/incorrect submissions if answers were 'submitted'
	# but don't update either if the problem was already correct
	$sessionHash->{numCorrect} =
		(defined $inputs_ref->{submitAnswers} && ($inputs_ref->{numCorrect} // 0) == 0)
		? $pg->{problem_state}{num_of_correct_ans}
		: ($inputs_ref->{numCorrect} // 0);
	$sessionHash->{numIncorrect} =
		(defined $inputs_ref->{submitAnswers} && ($inputs_ref->{numCorrect} // 0) == 0)
		? $pg->{problem_state}{num_of_incorrect_ans}
		: ($inputs_ref->{numIncorrect} // 0);

	# create the session JWT
	my $sessionJWT = encode_jwt(payload => $sessionHash, auto_iat => 1, alg => 'HS256', key => $ENV{webworkJWTsecret});

	# Skip answerJWT when session was ALREADY locked on entry — this is a replay.
	# But if the lock was just triggered THIS request, send the final answerJWT
	# with isLocked=1 so the LMS knows to stop.
	return ($sessionJWT, undef) if $inputs_ref->{isLocked};

	# form answerJWT — this is the LMS-readable score report.
	# isLocked signals the LMS to stop sending new interactions for this student+problem.
	my $responseHash = {
		iss        => $ENV{SITE_HOST},
		aud        => $inputs_ref->{JWTanswerURL},
		score      => $scoreHash,
		sessionJWT => $sessionJWT,
		isLocked   => $sessionHash->{isLocked} ? 1 : 0,
		platform   => 'standaloneRenderer'
	};

	my $answerJWT = encode_jwt(payload => $responseHash, alg => 'HS256', key => $ENV{problemJWTsecret}, auto_iat => 1);
	return ($sessionJWT, $answerJWT);
}

sub writeRenderLogEntry($) {
	my $message = shift;

	local *LOG;
	if (open LOG, ">>", $path_to_log_file) {
		print LOG "[", time2str("%a %b %d %H:%M:%S %Y", time), "] $message\n";
		close LOG;
	} else {
		warn "failed to open $path_to_log_file for writing: $!";
	}
}

1;
