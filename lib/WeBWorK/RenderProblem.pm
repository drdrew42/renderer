package WeBWorK::RenderProblem;

use strict;
use warnings;

# for logs
use Time::HiRes qw/time/;
use Proc::ProcessTable;
use Date::Format;

use Mojo::JSON  qw( encode_json );
use Digest::MD5 qw( md5_hex );

use lib "$ENV{PG_ROOT}/lib";

use WeBWorK::PG;
use WeBWorK::Utils::Tags;
use Renderer::Constants   qw( PLATFORM_NAME );
use Renderer::Util::JWT   qw( mint_jwt );
use Renderer::Permissions qw( resolve_permissions reveal_state );

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
	my ($r_source, $inputs_ref) = @_;

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

	my ($return_object, $error_flag, $error_string) = process_problem($r_source, $inputs_ref);

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

	$return_object->{tags} = WeBWorK::Utils::Tags->new($inputs_ref->{sourceFilePath}, $$r_source)
		if ($inputs_ref->{includeTags});

	my $json = encode_json($return_object);
	return $json;
}

#######################################################################
# Process Problem
#######################################################################

sub process_problem {
	my ($r_source, $inputs_ref) = @_;

	my $source    = $$r_source;
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

	# Mint continuation tokens. The discriminator is JWTanswerURL: its presence
	# is the caller's signal "I want this rendering's answers reported back to
	# me" — i.e., persistence is desired. isInstructor is a second-tier gate
	# applied later in the controller, where the actual answerJWT POST is
	# refused for instructors (Render.pm:639). The artifact is still produced
	# here so the HTML form has a sessionJWT to carry forward.
	if ($inputs_ref->{challengeJWT}) {
		# challengeJWT path (WW3-032). Mints the play-level sessionJWT (always)
		# and the per-submission submissionJWT (only on submit). These minters
		# live side-by-side with generateJWTs; they share no state and emit
		# different shapes (Artifact Shape doc, sibling envelopes).
		$return_object->{sessionJWT}    = generatePlaySessionJWT($return_object, $inputs_ref);
		$return_object->{submissionJWT} = generateSubmissionJWT($return_object, $inputs_ref)
			if $inputs_ref->{submitAnswers};
	} elsif ($inputs_ref->{problemJWT} && $inputs_ref->{JWTanswerURL}) {
		# Caller asked for persistence (provided JWTanswerURL). Mint full
		# session+answer pair. Works for instructors and students alike;
		# the controller-side POST gate handles the instructor-as-second-tier
		# distinction.
		my ($sessionJWT, $answerJWT) = generateJWTs($return_object, $inputs_ref);
		$return_object->{sessionJWT} = $sessionJWT;
		$return_object->{answerJWT}  = $answerJWT;
	}
	# Else: problemJWT without JWTanswerURL = exploratory self-mint render.
	# No persistence signal from the caller, so no sessionJWT is minted. The
	# problemJWT-in-HTML hidden field carries config (incl. isInstructor)
	# forward across submits.

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

	my $isSubmit = defined($inputs_ref->{submitAnswers}) ? 1 : 0;

	# answersSubmitted is the cumulative "the student has submitted at some
	# point in this play/session" flag — distinct from submitAnswers (this
	# specific click). The displayResults gate (line below) reads this flag,
	# so without setting it on submit-the-current-render the first submit
	# response shows no green-feedback styling. Three carriers bring it in:
	#   - sessionJWT claim (parseRequest hoists it into $inputs_ref)
	#   - HTML hidden field (form-submit re-render carries it forward)
	#   - this in-render derivation (handles the very first submit, where
	#     neither prior carrier has it)
	# OR them together so any signal triggers it.
	$inputs_ref->{answersSubmitted} ||= $isSubmit;

	# Render-mode resolution happened upstream in
	# Renderer::Render::ParseRequest::dispatch — pre-fork, parent process.
	# By the time we get here, $inputs_ref already carries the resolved
	# primitive flags (hideFeedback, hideCheckAnswersButton,
	# showCorrectAnswersButton, isInstructor, etc.). Mode-aware logic ends
	# at the dispatch layer; everything from this point on reads primitives.

	# Permission model — see Renderer::Permissions for the full rule set.
	# Single decision point; no defaulting logic in this function. PG's 0/2
	# magic value for showCorrectAnswers is the only translation that stays
	# here, at the WeBWorK::PG->new() call boundary below.
	#
	# Session lifecycle (non-instructor only):
	# - answerJWTs flow on every submit. The LMS owns due-date / scoring.
	# - Session locks when: student scores 100% OR showCorrectAnswers
	#   (config-gated, see WW3-R02 / generateJWTs in Render.pm).
	# - After lock: no answerJWT, no session updates.
	my $perms              = resolve_permissions($inputs_ref);
	my $isInstructor       = $perms->{isInstructor};
	my $showCorrectAnswers = $perms->{showCorrectAnswers};
	my $showSolutions      = $perms->{showSolutions};
	my $showHints          = $perms->{showHints};

	# Feedback suppression: hideFeedback (set via mode bundle or claim) kills
	# the PG content post-processor entirely — no verdict CSS, no popovers,
	# no button, no summary text built. Layer 1 (answer eval) and Layer 4
	# (answerJWT to JWTanswerURL) are untouched. See
	# vault://WeBWorK/PG/Render Flag Inventory.
	my $hideFeedback   = $inputs_ref->{hideFeedback} ? 1 : 0;
	my $displayResults = !$hideFeedback && $inputs_ref->{answersSubmitted} ? 1 : 0;
	my $forceResults   = !$hideFeedback && $displayResults && $inputs_ref->{showPartialCorrectAnswers};

	my $pg = WeBWorK::PG->new(
		inputs_ref     => {%$inputs_ref},                        # preserve original values
		sourceFilePath => $inputs_ref->{sourceFilePath} // '',
		r_source       => $problemFile,
		problemSeed    => $inputs_ref->{problemSeed},
		# Content-addressed custom macros: inject source via envir so PG's
		# loadMacros() finds them without filesystem search (PGloadfiles.pm).
		($inputs_ref->{injectedMacros} ? (injectedMacros => $inputs_ref->{injectedMacros}) : ()),
		processAnswers          => $processAnswers,
		showFeedback            => $hideFeedback ? 0 : 1,    # exam-mode kill-switch (outer gate)
		showAttemptResults      => $displayResults,          # respects showPartialCorrectAnswers
		forceShowAttemptResults => $forceResults,            # overrides showPartialCorrectAnswers
		showAttemptAnswers      => 0,                # MathQuill renders inline as student types; no separate echo path
		showAttemptPreviews     => 1,                # display LaTeX version of submitted answer
		showHints               => $showHints,
		showSolutions           => $showSolutions,
		showCorrectAnswers      => $showCorrectAnswers ? 2 : 0,
		num_of_correct_ans      => $inputs_ref->{numCorrect}   || 0,
		num_of_incorrect_ans    => $inputs_ref->{numIncorrect} || 0,
		displayMode             => $inputs_ref->{displayMode},
		useMathQuill            => !defined $inputs_ref->{entryAssist} || $inputs_ref->{entryAssist} eq 'MathQuill',
		answerPrefix            => $inputs_ref->{answerPrefix},
		isInstructor            => $isInstructor,
		forceScaffoldsOpen      => $inputs_ref->{forceScaffoldsOpen},
		psvn                    => $inputs_ref->{psvn},
		problemUUID             => $inputs_ref->{problemUUID},
		language                => $inputs_ref->{language} // 'en',
		templateDirectory       => "$ENV{RENDER_ROOT}/",
		htmlURL                 => 'pg_files/',
		tempURL                 => 'pg_files/tmp/',
		debuggingOptions        => {
			show_resource_info          => $inputs_ref->{show_resource_info},
			view_problem_debugging_info => $inputs_ref->{view_problem_debugging_info} // $isInstructor,
			show_pg_info                => $inputs_ref->{show_pg_info},
			show_answer_hash_info       => $inputs_ref->{show_answer_hash_info},
			show_answer_group_info      => $inputs_ref->{show_answer_group_info}
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
		$ret->{warning_messages} = $pg->{pgcore}->get_warning_messages();
		$ret->{debug_messages}   = $pg->{pgcore}->get_debug_messages();
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
		$ret->{warning_messages} = ['Problem failed during render - no PGcore received.'];
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
# The answerJWT is sent to the LMS answer URL on every student submission. It
# carries: score, sessionJWT (opaque), per-render *Requested facts, cumulative
# *Revealed history (inbound at submission time), and platform.
#
# The renderer is dumb. It reports per-render facts and (for the legacy lane)
# carries cumulative reveal history forward across renders. It does NOT
# terminate sessions, lock submissions, or enforce scoring policy. The LMS
# owns all decisions.
#
# Security contract for LMS integrators:
#   The renderer is stateless. It cannot prevent session replay attacks.
#   LMS implementations MUST:
#   - Verify that (numCorrect + numIncorrect) is strictly increasing on each
#     answerJWT received. A stale or equal sum indicates a replayed session.
#   - Treat answersRevealed=1 / solutionsRevealed=1 as a signal that this
#     submission was made post-reveal — apply scoring policy accordingly.
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
	# Reveal reporting: a plain per-render fact — did this render show correct
	# answers / solutions. The former sticky one-way ratchet (and the answer-URL
	# peek-trigger it drove) is gone; WW3 records reveals to the chain at mint
	# and gates them on the frontend, and ADAPT hides the reveal button, so
	# nothing consumed the cumulative state. See Renderer::Permissions.
	my $reveal = reveal_state($inputs_ref);

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
	my $sessionJWT = mint_jwt($ENV{webworkJWTsecret}, $sessionHash);

	# Form answerJWT — the LMS-readable score report. Legacy answerJWT carries
	# problemJWT and sessionJWT as siblings. The sessionJWT is signed with
	# webworkJWTsecret (renderer-internal) so the recipient can't reach into
	# it to recover the original problemJWT — we surface it directly here.
	# The sessionJWT also retains problemJWT as an embedded claim so it
	# remains self-contained as a restart token; the duplication is
	# intentional for the legacy path.
	#
	# answerJWT carries the per-render reveal fact — whether this render showed
	# answers / solutions. No cumulative state: WW3 owns reveal history in the
	# chain, and ADAPT reads none of these fields.
	my $responseHash = {
		iss             => $ENV{SITE_HOST},
		aud             => $inputs_ref->{JWTanswerURL},
		score           => $scoreHash,
		problemJWT      => $inputs_ref->{problemJWT},
		sessionJWT      => $sessionJWT,
		answers_shown   => $reveal->{answers_shown},
		solutions_shown => $reveal->{solutions_shown},
		platform        => PLATFORM_NAME,
	};

	my $answerJWT = mint_jwt($ENV{problemJWTsecret}, $responseHash);
	return ($sessionJWT, $answerJWT);
}

# ─── challengeJWT path minters (WW3-032) ─────────────────────────────────
#
# These mint the play-level sessionJWT and the per-submission submissionJWT
# defined by [[WeBWorK3/Challenge/Artifact Shape]]. They live alongside the
# problem-lane generateJWTs above and share no state with it; the dispatch at
# process_problem picks one path or the other based on which envelope the
# request arrived with. The key architectural difference: attempt counting
# (numCorrect/numIncorrect) is NOT carried here — atom evaluation is
# orchestrator-only (Architecture B). Chain history (reveal events, attempt
# counts) lives in chain entries, not in the renderer's sessionJWT.

# Mint the play-level sessionJWT. Embeds the inbound challengeJWT verbatim
# and propagates the navigation state forward by one mint_sequence. The
# orchestrator updates state via answer-URL verdicts; the renderer never
# evaluates atoms or modifies state itself.
sub generatePlaySessionJWT {
	my ($pg, $inputs_ref) = @_;

	# Extract prior state + sequence from the inbound sessionJWT (already
	# decoded by parseRequest into $inputs_ref via the generic claim merge).
	# First render of a play has no inbound state — sequence starts at 0.
	my $prev_seq    = $inputs_ref->{mint_sequence};
	my $next_seq    = defined $prev_seq                    ? $prev_seq + 1        : 0;
	my $prior_state = (ref $inputs_ref->{state} eq 'HASH') ? $inputs_ref->{state} : {};

	# answersSubmitted: cumulative-once-submitted flag. Carry forward via the
	# minted sessionJWT so subsequent renders' displayResults gate fires.
	# Mirrors the legacy generateJWTs which always sets this to 1 — once any
	# render of this session has happened (which on the legacy lane means a
	# JWTanswerURL was provided), the next round-trip displays results.
	# Inputs_ref->answersSubmitted is already OR'd with $isSubmit above in
	# standaloneRenderer, so on the first submit the flag becomes truthy and
	# rides forward.
	my $answers_submitted = $inputs_ref->{answersSubmitted} ? 1 : 0;

	my $payload = {
		iss => $ENV{SITE_HOST},
		aud => $ENV{SITE_HOST},

		# Embed the static play definition. The orchestrator validates it on
		# every answer-URL POST without needing a separate lookup.
		challenge_jwt => $inputs_ref->{challengeJWT},

		# Navigation state — copied through unchanged from prior. The renderer
		# is not the atom evaluator; the orchestrator's verdicts (post-POST
		# fold via WW3-053) update this on the next round trip. Position
		# (the rendered problem) lives in render-context (form/URL), not
		# in state.current_focus — student_picks mode keeps focus null.
		state => {
			started_at     => $prior_state->{started_at},
			current_focus  => $prior_state->{current_focus},
			next_available => $prior_state->{next_available} // [],
			draws          => $prior_state->{draws}          // [],
			finalization   => $prior_state->{finalization},
		},

		# Cumulative "has submitted at some point" — see comment in
		# standaloneRenderer. Top-level so parseRequest's claim merge
		# treats it as a security-sensitive claim (line ~206).
		answersSubmitted => $answers_submitted,

		mint_sequence => $next_seq,
	};

	return mint_jwt($ENV{webworkJWTsecret}, $payload);
}

# Mint the per-submission submissionJWT. Self-audienced (renderer reads it
# back on reView), problemJWTsecret-signed (same key as today's answerJWT).
# Carries enough render context (pg_hash + seed) to reproduce the rendered
# state exactly, plus the student's answers and the renderer's grading.
sub generateSubmissionJWT {
	my ($pg, $inputs_ref) = @_;

	# Per-answer scores in stable order. Atoms see only the aggregated score;
	# part_scores are kept for chain audit and instructor review.
	#
	# submitted_answers carries BOTH the plain answer field (AnSwEr0001) AND
	# its MathQuill-paired field (MaThQuIlL_AnSwEr0001) when present. The
	# plain field is what PG grades against; the MathQuill field is the
	# LaTeX representation the visual editor renders from. Capturing both
	# lets the portal prefill the rendered form completely on warm reload —
	# without the LaTeX side, mqeditor.js's 100ms-delayed mathField.latex()
	# init has nothing to render the visual from, and complex expressions
	# (e.g., \frac{1}{2}) can't be reconstructed from mq.text() alone.
	my @answer_keys = sort keys %{ $pg->{answers} // {} };
	my %submitted_answers;
	my @part_scores;
	for my $k (@answer_keys) {
		$submitted_answers{$k} = $inputs_ref->{$k} // '';
		push @part_scores, $pg->{answers}{$k}{score} // 0;

		# Capture the MathQuill-paired LaTeX field if the form carried one.
		# Per mqeditor.js, the convention is `MaThQuIlL_<answer-label>`.
		my $mq_key = "MaThQuIlL_$k";
		if (defined $inputs_ref->{$mq_key}) {
			$submitted_answers{$mq_key} = $inputs_ref->{$mq_key};
		}
	}

	# ISO8601 UTC timestamp — matches the chain entry format the orchestrator
	# expects (per Artifact Shape §submissionJWT).
	my @t            = gmtime();
	my $submitted_at = sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ', $t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);

	# Per-render reveal fact: was each of answers/solutions shown this render.
	# Cumulative reveal history lives in the orchestrator's chain entries (the
	# reveal is minted and recorded by WW3, per WW3-117), not inferred from the
	# wire. play_sessionJWT carries nothing reveal-related — navigation only.
	my $reveal = reveal_state($inputs_ref);

	my $payload = {
		iss => $ENV{SITE_HOST},
		aud => $ENV{SITE_HOST},

		play_id          => $inputs_ref->{play_id},
		challenge_id     => $inputs_ref->{challenge_id},
		chain_student_id => $inputs_ref->{chain_student_id},
		position         => $inputs_ref->{position} + 0,       # numeric

		pg_hash => $inputs_ref->{pg_hash},
		seed    => $inputs_ref->{problemSeed},

		submitted_answers => \%submitted_answers,
		part_scores       => \@part_scores,
		score             => ($pg->{problem_result}{score} // 0) + 0,

		# Per-render reveal fact (snake_case per submissionJWT convention). The
		# orchestrator records reveals to chain entries at mint; this is a
		# record of what the render disclosed, not a signal it acts on.
		answers_shown   => $reveal->{answers_shown},
		solutions_shown => $reveal->{solutions_shown},

		submitted_at => $submitted_at,
	};

	return mint_jwt($ENV{problemJWTsecret}, $payload);
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
