package RenderApp::Controller::RenderProblem;

use strict;
use warnings;

use Time::HiRes qw/time/;
use Date::Format;
use MIME::Base64 qw(encode_base64 decode_base64);
use File::Find;
use FileHandle;
use File::Path;
use File::Basename;

#use File::Temp qw/tempdir/;
use String::ShellQuote;
use Cwd 'abs_path';
use JSON::XS;
use Crypt::JWT qw( encode_jwt );
use Digest::MD5 qw( md5_hex );

use lib "$ENV{PG_ROOT}/lib";

use Proc::ProcessTable;    # use for log memory use
use WeBWorK::PG;
use WeBWorK::Utils::Tags;
use WeBWorK::Localize;
use RenderApp::Controller::FormatRenderedProblem;

use 5.10.0;
$Carp::Verbose = 1;

### verbose output when UNIT_TESTS_ON =1;
our $UNIT_TESTS_ON = 0;

#our @path_list;

##################################################
# create log files :: expendable
##################################################

my $path_to_log_file = 'logs/standalone_results.log';

eval {    # attempt to create log file
    local (*FH);
    open( FH, '>>:encoding(UTF-8)', $path_to_log_file )
      or die "Can't open file $path_to_log_file for writing";
    close(FH);
};

die
"You must first create an output file at $path_to_log_file with permissions 777 "
  unless -w $path_to_log_file;

##################################################
# define universal TO_JSON for JSON::XS unbless
##################################################

sub UNIVERSAL::TO_JSON {
    my ($self) = shift;

    use Storable qw(dclone);
    use Data::Structure::Util qw(unbless);

    my $clone = unbless( dclone($self) );

    $clone;
}

##########################################################
#  END MAIN :: BEGIN SUBROUTINES
##########################################################

#######################################################################
# Process the pg file
#######################################################################

sub process_pg_file {
    my $problem   = shift;
    my $inputHash = shift;

    my $file_path    = $problem->path;
    my $problem_seed = $problem->seed || '666';

    # just make sure we have the fundamentals covered...
    $inputHash->{displayMode} //= 'MathJax';
    $inputHash->{sourceFilePath} ||= $file_path;
    $inputHash->{outputFormat}   ||= 'static';
    $inputHash->{language}       ||= 'en';

    # HACK: required for problemRandomize.pl
    $inputHash->{effectiveUser} = 'red.ted';
    $inputHash->{user}          = 'red.ted';

    # OTHER fundamentals - urls have been handled already...
    #	form_action_url => $inputHash->{form_action_url}||'http://failure.org',
    #	base_url        => $inputHash->{base_url}||'http://failure.org'
    #	#psvn            => $psvn//'23456', # DEPRECATED
    #	#forcePortNumber => $credentials{forcePortNumber}//'',

    my $pg_start =
      time;    # this is Time::HiRes's time, which gives floating point values

    my ( $error_flag, $formatter, $error_string ) =
      process_problem( $file_path, $inputHash );

    my $pg_stop     = time;
    my $pg_duration = $pg_stop - $pg_start;

    # format result
    my $html    = $formatter->formatRenderedProblem;
    my $pg_obj  = $formatter->{return_object};
    my $json_rh = {
        renderedHTML      => $html,
        answers           => $pg_obj->{answers},
        debug             => {
            perl_warn     => $pg_obj->{WARNINGS},
            pg_warn       => $pg_obj->{warning_messages},
            debug         => $pg_obj->{debug_messages},
            internal      => $pg_obj->{internal_debug_messages}
        },
        problem_result    => $pg_obj->{problem_result},
        problem_state     => $pg_obj->{problem_state},
        flags             => $pg_obj->{flags},
        resources         => {
            regex         => $pg_obj->{resources},
            tags          => $pg_obj->{pgResources},
            js            => $pg_obj->{js},
            css           => $pg_obj->{css},
        },
        form_data         => $inputHash,
        raw_metadata_text => $pg_obj->{raw_metadata_text},
        JWT               => {
            problem       => $inputHash->{problemJWT},
            session       => $pg_obj->{sessionJWT},
            answer        => $pg_obj->{answerJWT}
        },
    };

	# havoc caused by problemRandomize.pl inserting CODE ref into pg->{flags}
	# HACK: remove flags->{problemRandomize} if it exists -- cannot include CODE refs
    delete $json_rh->{flags}{problemRandomize}
      if $json_rh->{flags}{problemRandomize};
    # similar things happen with compoundProblem -- delete CODE refs
    delete $json_rh->{flags}{compoundProblem}{grader}
      if $json_rh->{flags}{compoundProblem}{grader};


    $json_rh->{tags} = WeBWorK::Utils::Tags->new($file_path, $inputHash->{problemSource}) if ( $inputHash->{includeTags} );
    my $coder = JSON::XS->new->ascii->pretty->allow_unknown->convert_blessed;
    my $json  = $coder->encode($json_rh);
    return $json;
}

#######################################################################
# Process Problem
#######################################################################

sub process_problem {
    my $file_path  = shift;
    my $inputs_ref = shift;
    my $adj_file_path;
    my $source;

    # obsolete if using JSON return format
    # These can FORCE display of AnsGroup AnsHash PGInfo and ResourceInfo
    #	$inputs_ref->{showAnsGroupInfo}	= 1; #$print_answer_group;
    #	$inputs_ref->{showAnsHashInfo}	= 1; #$print_answer_hash;
    #	$inputs_ref->{showPGInfo}				= 1; #$print_pg_hash;
    #	$inputs_ref->{showResourceInfo}	= 1; #$print_resource_hash;

    ### stash inputs that get wiped by PG
    my $problem_seed = $inputs_ref->{problemSeed};
    die "problem seed not defined in Controller::RenderProblem::process_problem"
      unless $problem_seed;

    # if base64 source is provided, use that over fetching problem path
    if ( $inputs_ref->{problemSource} && $inputs_ref->{problemSource} =~ m/\S/ )
    {
        # such hackery - but Mojo::Promises are so well-built that they are invisible
        # ... until you leave the Mojo space
        $inputs_ref->{problemSource} = $inputs_ref->{problemSource}{results}[0] if $inputs_ref->{problemSource} =~ /Mojo::Promise/;
        # sanitize the base64 encoded source
        $inputs_ref->{problemSource} =~ s/\s//gm;
        # while ($source =~ /([^A-Za-z0-9+])/gm) {
        #     warn "invalid character found: ".sprintf( "\\u%04x", ord($1) )."\n";
        # }
        $source = Encode::decode("UTF-8", decode_base64( $inputs_ref->{problemSource} ) );
    }
    else {
        ( $adj_file_path, $source ) = get_source($file_path);

        # WHY are there so many fields in which to stash the file path?
        #$inputs_ref->{fileName} = $adj_file_path;
        #$inputs_ref->{probFileName} = $adj_file_path;
        #$inputs_ref->{sourceFilePath} = $adj_file_path;
        #$inputs_ref->{pathToProblemFile} = $adj_file_path;
    }
    my $raw_metadata_text = $1 if ($source =~ /(.*?)DOCUMENT\(\s*\)\s*;/s);
    $inputs_ref->{problemUUID} = md5_hex(Encode::encode_utf8($source));

    # TODO verify line ending are LF instead of CRLF

    # included (external) pg content is not recorded by PGalias
    # record the dependency separately -- TODO: incorporate into PG.pl or PGcore?
    my $pgResources = [];
    while ($source =~ m/includePG(?:problem|file)\(["'](.*)["']\);/g )
    {
        warn "PG asset reference found: $1\n" if $UNIT_TESTS_ON;
        push @$pgResources, $1;
    }

    # # this does not capture _all_ image asset references, unfortunately...
    # # asset filenames may be stored as variables before image() is called
    # while ($source =~ m/image\(\s*("[^\$]+?"|'[^\$]+?')\s*[,\)]/g) {
    #     warn "Image asset reference found!\n" . $1 . "\n" if $UNIT_TESTS_ON;
    #     my $image = $1;
    #     $image =~ s/['"]//g;
    #     $image = dirname($file_path) . '/' . $image if ($image =~ /^[^\/]*\.(?:gif|jpg|jpeg|png)$/i);
    #     warn "Recording image asset as: $image\n" if $UNIT_TESTS_ON;
    #     push @$assets, $image;
    # }

    # $inputs_ref->{pathToProblemFile} = $adj_file_path
    #   if ( defined $adj_file_path );

    ##################################################
    # Process the pg file
    ##################################################
    ### store the time before we invoke the content generator
    my $cg_start =
      time;    # this is Time::HiRes's time, which gives floating point values

    ############################################
    # Call server via standaloneRenderer to render problem
    ############################################

    our ( $return_object, $error_flag, $error_string );
    $error_flag   = 0;
    $error_string = '';

    my $memory_use_start = get_current_process_memory();

    # can include @args as third input below
    $return_object = standaloneRenderer( \$source, $inputs_ref );

    # stash assets list in $return_object
    $return_object->{pgResources} = $pgResources;

    # stash raw metadata text in $return_object
    $return_object->{raw_metadata_text} = $raw_metadata_text;

    # generate sessionJWT to store session data and answerJWT to update grade store
    # only occurs if problemJWT exists!
    my ($sessionJWT, $answerJWT) = generateJWTs($return_object, $inputs_ref);
    $return_object->{sessionJWT} = $sessionJWT // '';
    $return_object->{answerJWT}  = $answerJWT // '';

    #######################################################################
    # Handle errors
    #######################################################################

    print "\n\n Result of renderProblem \n\n" if $UNIT_TESTS_ON;
    print pretty_print_rh($return_object)     if $UNIT_TESTS_ON;
    if ( not defined $return_object )
    {    #FIXME make sure this is the right error message if site is unavailable
        $error_string = "0\t Could not process $file_path problem file \n";
    }
    elsif ( defined( $return_object->{flags}->{error_flag} )
        and $return_object->{flags}->{error_flag} )
    {
        $error_string = "0\t $file_path has errors\n";
    }
    elsif ( defined( $return_object->{errors} ) and $return_object->{errors} ) {
        $error_string = "0\t $file_path has syntax errors\n";
    }
    $error_flag = 1 if $return_object->{errors};

    ##################################################
    # Create FormatRenderedProblems object
    ##################################################

 	# my $encoded_source = encode_base64($source); # create encoding of source_file;
    my $formatter = RenderApp::Controller::FormatRenderedProblem->new(
      return_object   => $return_object,
      encoded_source  => '', #encode_base64($source),
      sourceFilePath  => $file_path,
      url             => $inputs_ref->{baseURL},
      form_action_url => $inputs_ref->{formURL},
      maketext        => sub {return @_},
      courseID        => 'blackbox',
      userID          => 'Motoko_Kusanagi',
      course_password => 'daemon',
      inputs_ref      => $inputs_ref,
      problem_seed    => $problem_seed
    );

    ##################################################
    # log elapsed time
    ##################################################
    my $scriptName     = 'standalonePGproblemRenderer';
    my $log_file_path  = $file_path // 'source provided without path';
    my $cg_end         = time;
    my $cg_duration    = $cg_end - $cg_start;
    my $memory_use_end = get_current_process_memory();
    my $memory_use     = $memory_use_end - $memory_use_start;
    writeRenderLogEntry(
        "",
        "{script:$scriptName; file:$log_file_path; "
          . sprintf( "duration: %.3f sec;", $cg_duration )
          . sprintf( " memory: %6d bytes;", $memory_use ) . "}",
        ''
    );

    #######################################################################
    # End processing of the pg file
    #######################################################################

    return $error_flag, $formatter, $error_string;
}

###########################################
# standalonePGproblemRenderer
###########################################

sub standaloneRenderer {
    my $problemFile = shift // '';
    my $inputs_ref  = shift // {};
    my %args        = @_;

    # default to 1, explicitly avoid generating answer components
    my $processAnswers = $inputs_ref->{processAnswers} // 1;
    print "NOT PROCESSING ANSWERS" unless $processAnswers == 1;

    unless (ref $problemFile) {
        # In this case the source file name is passed
        print "standaloneProblemRenderer: setting source_file = $problemFile";
    }

    # Attempt to match old parameters.
    my $isInstructor = $inputs_ref->{isInstructor} // ($inputs_ref->{permissionLevel} // 0) >= 10;

	my $pg = WeBWorK::PG->new(
		ref $problemFile
		? (
			sourceFilePath => $inputs_ref->{sourceFilePath} // '',
			r_source       => $problemFile,
			)
		: (sourceFilePath => $problemFile),
		problemSeed          => $inputs_ref->{problemSeed},
		processAnswers       => $processAnswers,
		showHints            => $inputs_ref->{showHints},              # default is to showHint (set in PG.pm)
		showSolutions        => $inputs_ref->{showSolutions},
		problemNumber        => $inputs_ref->{problemNumber},          # ever even relevant?
		num_of_correct_ans   => $inputs_ref->{numCorrect} || 0,
		num_of_incorrect_ans => $inputs_ref->{numIncorrect} // 1000,
		displayMode          => $inputs_ref->{displayMode},
		useMathQuill         => !defined $inputs_ref->{entryAssist} || $inputs_ref->{entryAssist} eq 'MathQuill',
		answerPrefix         => $inputs_ref->{answerPrefix},
		isInstructor         => $isInstructor,
		forceScaffoldsOpen   => $inputs_ref->{forceScaffoldsOpen},
		psvn                 => $inputs_ref->{psvn},
		problemUUID          => $inputs_ref->{problemUUID},
		language             => $inputs_ref->{language} // 'en',
		language_subroutine  => WeBWorK::Localize::getLoc($inputs_ref->{language} // 'en'),
		inputs_ref           => {%$inputs_ref},  # Copy the inputs ref so the original can be relied on after rendering.
		templateDirectory    => "$ENV{RENDER_ROOT}/",
		debuggingOptions     => {
			show_resource_info          => $inputs_ref->{show_resource_info},
			view_problem_debugging_info => $inputs_ref->{view_problem_debugging_info} // $isInstructor,
			show_pg_info                => $inputs_ref->{show_pg_info},
			show_answer_hash_info       => $inputs_ref->{show_answer_hash_info},
			show_answer_group_info      => $inputs_ref->{show_answer_group_info}
		}
	);

    # new version of output:
    my ( $internal_debug_messages, $pgwarning_messages, $pgdebug_messages );
    if ( ref( $pg->{pgcore} ) ) {
        $internal_debug_messages = $pg->{pgcore}->get_internal_debug_messages;
        $pgwarning_messages      = $pg->{pgcore}->get_warning_messages();
        $pgdebug_messages        = $pg->{pgcore}->get_debug_messages();
    }
    else {
        $internal_debug_messages =
          ['Problem failed during render - no PGcore received.'];
    }

    my $out2 = {
        text                    => $pg->{body_text},
        header_text             => $pg->{head_text},
        post_header_text        => $pg->{post_header_text},
        answers                 => $pg->{answers},
        errors                  => $pg->{errors},
        WARNINGS                => $pg->{warnings},
        PG_ANSWERS_HASH         => $pg->{pgcore}->{PG_ANSWERS_HASH},
        problem_result          => $pg->{result},
        problem_state           => $pg->{state},
        flags                   => $pg->{flags},
        resources               => [ keys %{$pg->{pgcore}{PG_alias}{resource_list}} ],
        warning_messages        => $pgwarning_messages,
        debug_messages          => $pgdebug_messages,
        internal_debug_messages => $internal_debug_messages,
    };
    $pg->free;
    $out2;
}

sub display_html_output {    #display the problem in a browser
    my $file_path   = shift;
    my $formatter   = shift;
    my $output_text = $formatter->formatRenderedProblem;
    return $output_text;
}

##################################################
# utilities
##################################################

sub get_current_process_memory {
    state $pt = Proc::ProcessTable->new;
    my %info = map { $_->pid => $_ } @{ $pt->table };
    return $info{$$}->rss;
}

# expects a pg/result_object and a ref to submitted formdata
# generates a sessionJWT and an answerJWT
sub generateJWTs {
    my $pg = shift;
    my $inputs_ref = shift;
    my $sessionHash = {'answersSubmitted' => 1, 'iss' =>$ENV{SITE_HOST}};
    my $scoreHash = {};

    # if no problemJWT exists, then why bother?
    return unless $inputs_ref->{problemJWT};

    # store the current answer/response state for each entry
    foreach my $ans (keys %{$pg->{answers}}) {
        # TODO: Anything else we want to add to sessionHash?
        $sessionHash->{$ans}                  = $inputs_ref->{$ans};
        $sessionHash->{ 'previous_' . $ans }  = $inputs_ref->{$ans};
        $sessionHash->{ 'MaThQuIlL_' . $ans } = $inputs_ref->{ 'MaThQuIlL_' . $ans } if ($inputs_ref->{ 'MaThQuIlL_' . $ans});

        # $scoreHash->{ans_id} = $ans;
        # $scoreHash->{answer} = unbless($pg->{answers}{$ans}) // {},
        # $scoreHash->{score}  = $pg->{answers}{$ans}{score} // 0,

        # TODO see why this key is causing JWT corruption in PHP
        delete( $pg->{answers}{$ans}{student_ans});
    }
    $scoreHash->{answers}   = unbless($pg->{answers});

    # update the number of correct/incorrect submissions if answers were 'submitted'
    $sessionHash->{numCorrect} = (defined $inputs_ref->{submitAnswers}) ?
        $pg->{problem_state}{num_of_correct_ans} : ($inputs_ref->{numCorrect} // 0);
    $sessionHash->{numIncorrect} = (defined $inputs_ref->{submitAnswers}) ?
        $pg->{problem_state}{num_of_incorrect_ans} : ($inputs_ref->{numIncorrect} // 0);

    # include the final result of the combined scores
    $scoreHash->{result} = $pg->{problem_result}{score};

    # create and return the session JWT
    # TODO swap to   alg => 'PBES2-HS512+A256KW', enc => 'A256GCM'
    my $sessionJWT = encode_jwt(payload => $sessionHash, auto_iat => 1, alg => 'HS256', key => $ENV{webworkJWTsecret});

    # form answerJWT
    my $responseHash = {
      iss        => $ENV{SITE_HOST},
      aud        => $inputs_ref->{JWTanswerURL},
      score      => $scoreHash,
      problemJWT => $inputs_ref->{problemJWT},
      sessionJWT => $sessionJWT,
      platform   => 'standaloneRenderer'
    };

    # Can instead use alg => 'PBES2-HS512+A256KW', enc => 'A256GCM' for JWE
    my $answerJWT = encode_jwt(payload=>$responseHash, alg => 'HS256', key => $ENV{problemJWTsecret}, auto_iat => 1);

    return ($sessionJWT, $answerJWT);
}

# Get problem template source and adjust file_path name
sub get_source {
    my $file_path = shift;
    my $source;
    die "Unable to read file $file_path \n"
      unless $file_path eq '-' or -r $file_path;
    eval {    #File::Slurp would be faster (see perl monks)
        local $/ = undef;
        if ( $file_path eq '-' ) {
            $source = <STDIN>;
        } else {
            # To support proper behavior with UTF-8 files, we need to open them with "<:encoding(UTF-8)"
            # as otherwise, the first HTML file will render properly, but when "Preview" "Submit answer"
            # or "Show correct answer" is used it will make problems, as in process_problem() the
            # encodeSource() method is called on a data which is still UTF-8 encoded, and leads to double
            # encoding and gibberish.
            # NEW:
            open( FH, "<:encoding(UTF-8)", $file_path )
              or die "Couldn't open file $file_path: $!";

          # OLD:
          #open(FH, "<" ,$file_path) or die "Couldn't open file $file_path: $!";
            $source = <FH>;    #slurp  input
            close FH;
        }
    };
    die "Something is wrong with the contents of $file_path\n" if $@;
    return $file_path, $source;
}

sub pretty_print_rh {
    shift if UNIVERSAL::isa( $_[0] => __PACKAGE__ );
    my $rh     = shift;
    my $indent = shift || 0;
    my $out    = "";
    my $type   = ref($rh);

    if ( defined($type) and $type ) {
        $out .= " type = $type; ";
    }
    elsif ( !defined($rh) ) {
        $out .= " type = UNDEFINED; ";
    }
    return $out . " " unless defined($rh);

    if ( ref($rh) =~ /HASH/ ) {
        $out .= "{\n";
        $indent++;
        foreach my $key ( sort keys %{$rh} ) {
            $out .=
                "  " x $indent
              . "$key => "
              . pretty_print_rh( $rh->{$key}, $indent ) . "\n";
        }
        $indent--;
        $out .= "\n" . "  " x $indent . "}\n";

    }
    elsif ( ref($rh) =~ /ARRAY/ or "$rh" =~ /ARRAY/ ) {
        $out .= " ( ";
        foreach my $elem ( @{$rh} ) {
            $out .= pretty_print_rh( $elem, $indent );

        }
        $out .= " ) \n";
    }
    elsif ( ref($rh) =~ /SCALAR/ ) {
        $out .= "scalar reference " . ${$rh};
    }
    elsif ( ref($rh) =~ /Base64/ ) {
        $out .= "base64 reference " . $$rh;
    }
    else {
        $out .= $rh;
    }

    return $out . " ";
}

sub writeRenderLogEntry($$$) {
    my ( $function, $details, $beginEnd ) = @_;
    $beginEnd =
      ( $beginEnd eq "begin" ) ? ">" : ( $beginEnd eq "end" ) ? "<" : "-";

    local *LOG;
    if ( open LOG, ">>", $path_to_log_file ) {
        print LOG "[", time2str( "%a %b %d %H:%M:%S %Y", time ),
          "] $$ " . time . " $beginEnd $function [$details]\n";
        close LOG;
    }
    else {
        warn "failed to open $path_to_log_file for writing: $!";
    }
}

1;
