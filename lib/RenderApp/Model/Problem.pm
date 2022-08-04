package RenderApp::Model::Problem;

use strict;
use warnings;

use Mojo::File;
use Mojo::IOLoop;
use Mojo::JSON qw( encode_json );
use Mojo::Base -async_await;
use Time::HiRes qw( time );
use RenderApp::Controller::RenderProblem;

##### Problem params: #####
# = random_seed      (set randomization for rendering)
# = read_path        (path to existing problem for edit/render)
# = write_path       (path for updating existing problem/saving new problem)
# = problem_contents (source code for problem)

##### Problem methods: #####
## GET/SET
# - source (read/update problem_contents)
# - seed   (read/update random_seed)
# - path   (read/update read_path)
# - target (read/update write_path)
## IO methods
# - render (generate rendered html + pg info)
# - save   (write problem_contents to file at write_path)
# - load   (overwrite problem_contents with contents of file at read_path)
## Error handling
# - success (checks for internal errors and sets error code and message)
# - exception (renders JSON/HTML message w/ status & logs)

our $codes = {
    400 => 'Bad Request',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    412 => 'Precondition Failed',
    500 => 'Internal Server Error',
};

sub new {
    my $class       = shift;
    my $problem_ref = {
        _error      => '',
        action      => '',
        code_origin => '',
    };
    bless $problem_ref, $class;
    $problem_ref->{start} = time;
    $problem_ref->_init(@_);
    return $problem_ref;
}

sub _init {
    my ( $self, $args ) = @_;
    $self->{log} = $args->{log} if $args->{log};

    my $read_path        = $args->{read_path}        || '';
    my $write_path       = $args->{write_path}       || '';
    my $problem_contents = $args->{problem_contents} || '';
    my $random_seed      = $args->{random_seed}      || '';
    $self->{_error} =
      "400 Cannot create problem without either path or contents!\n"
      unless ( $problem_contents =~ /\S/ || $read_path =~ /\S/ );

    # sourcecode takes precedence over reading from file path
    if ( $problem_contents =~ /\S/ ) {
        $self->source($problem_contents);
        $self->{code_origin} = 'pg source (' . $self->path( $read_path, 'force' ) .')';
        # set read_path without failing for !-e
        # this supports images in problems via editor
    } else {
        $self->{code_origin} = $self->path($read_path);
        $self->load;
    }

    $self->target( $write_path ) if $write_path =~ /\S/;
    $self->seed( $random_seed )  if $random_seed =~ /\S/;

    my $path_info = $self->{code_origin};
    my $seed_info = $args->{random_seed} ? "random seed #" . $args->{random_seed} : "no random seed.";
    $self->{log}->info("CREATED: Problem created from $path_info with $seed_info");
}

sub source {
    my $self = shift;
    if ( scalar(@_) == 1 ) {
        my $contents = shift;

        # UNIX style line-endings are required
        $contents =~ s/\r\n/\n/g;
        $contents =~ s/\r/\n/g;
        $self->{problem_contents} = $contents;
    }
    return $self->{problem_contents};
}

sub seed {
    my $self = shift;
    if ( scalar(@_) == 1 ) {
        my $random_seed = shift;
        $self->{_error} =
          "400 You must provide a positive integer for the random seed.\n"
          unless $random_seed =~ m!^\d+$!;
        $self->{random_seed} = $random_seed;
    }
    return $self->{random_seed};
}

sub path {
    my $self = shift;
    if ( scalar(@_) >= 1 ) {
        my $read_path = shift;
        my $force = shift if @_;
        $read_path =~ s!\s+|\.\./!!g;    # prevent backtracking and whitespace
        my $opl_root = $ENV{OPL_DIRECTORY};
        if ( $read_path =~ m!^Library/! ) {
            $read_path =~ s!^Library/!$opl_root/OpenProblemLibrary/!;
            $self->{write_allowed} = 0;
        }
        elsif ( $read_path =~ m!^Contrib! ) {
            $read_path =~ s!^Contrib/!$opl_root/Contrib/!;
            $self->{write_allowed} = 0;    # eventually reconsider this?
        }
        else {
            # TODO: consider steps in pipeline towards OPL
            # these problems are not in OPL or Contrib yet
            # are we placing them in a folder relative to their user?
            $self->{write_allowed} = $read_path =~ m!^private\/!;
        }
        $self->{_error} = "404 I cannot find a problem with that file path."
          unless ( -e $read_path || $force );
        $self->{read_path} = Mojo::File->new($read_path);
    }
    return $self->{read_path};
}

sub target {
    my $self = shift;
    if ( scalar(@_) == 1 ) {
        my $write_path = shift;
        $write_path =~ s!\s+|\.\./!!g;    # prevent backtracking and whitespace
        my $opl_root = $ENV{OPL_DIRECTORY};
        if ( $write_path =~ m!^Library/! ) {
            $write_path =~ s!^Library/!$opl_root/OpenProblemLibrary/!;
        }
        elsif ( $write_path =~ m!^Contrib! ) {
            $write_path =~ s!^Contrib/!$opl_root/Contrib/!;
        }

        # TODO: include permission check to write to this path...
        $self->{write_allowed} =
          ( $write_path =~ m/^private\/(?:[^\s])*\.pg$/ ) ? 1 : 0;
        $self->{write_path} = Mojo::File->new($write_path);
    }
    return $self->{write_path};
}

# RETURNS PROMISE
sub save {
    my $self    = shift;
    my $success = 0;
    my $write_path =
      ( $self->{write_path} =~ /\S/ ) ?
        $self->{write_path} :
        $self->{read_path};

    $self->{action} = 'save to ' . $self->{write_path};

    $self->{_error} = "400 Nothing to write!"
      unless ( $self->{problem_contents} =~ m/\S/ );
    $self->{_error} = "412 No file paths specified."
      unless ( $write_path =~ m/\S/ );
    $self->{_error} = "403 You are not allowed to write to that path."
      unless $self->{write_allowed};

    my $errs;
    Mojo::File::make_path( $self->{write_path}->dirname, { error => $errs } )
      if !( -e $write_path );
    if ($errs) {
        $self->log->warn( join( "\n", @$errs ) )        if $errs;
        $self->{_error} = "405 " . join( "\n", @$errs ) if $errs;
    }

    my $savePromise = Mojo::IOLoop->subprocess->run_p( sub {
        $write_path->spurt( Encode::encode( 'UTF-8', $self->{problem_contents} ) );
        $self->path($write_path); # update the read_path to match
        return $self->success();
    })->catch( sub {
        $self->{exception} = Mojo::Exception->new(shift)->trace;
        $self->{_error} = "500 Write failed: " . $self->{exception}->message;
        return $self->success();
    });

    return $savePromise;
}

sub load {
    my $self      = shift;
    my $success   = 0;
    my $read_path = $self->{read_path};
    if ( -r $read_path ) {
        $self->{problem_contents} = Encode::decode( "UTF-8", $read_path->slurp );
        $success = 1;
    }
    else {
        $self->{_error} =
          "404 Problem set with un-read-able read_path: $read_path";
    }
    return $success;
}

# RETURNS PROMISE
sub render {
    my $self    = shift;
    my $inputs_ref = shift;
    $self->{action} = 'render';
    my $renderPromise = Mojo::IOLoop->subprocess->run_p( sub {
        return RenderApp::Controller::RenderProblem::process_pg_file( $self, $inputs_ref );
    })->catch(sub {
        $self->{exception} = Mojo::Exception->new(shift)->trace;
        $self->{_error} = "500 Render failed: " . $self->{exception}->message;
    });
    return $renderPromise;
}

sub success {
    my $self = shift;
    my $report = ( $self->{_error} =~ /\S/ ) ? $self->{_error} : 'NO ERRORS';
    return 1 unless $self->{_error} =~ /\S/;
    my ( $code, $mesg ) = split( / /, $self->{_error}, 2 );
    $self->{status}   = $code;
    $self->{_error}   = $codes->{$code};
    $self->{_message} = $mesg;
    return 0;
}

sub DESTROY {
    my $self     = shift;
    my $duration = time - $self->{start};
    my $logmsg   = 'TRASH: [' . sprintf("%.1f",$duration*1000) . 'ms] ';
    $logmsg     .= $self->{action} . ' from ';
	$logmsg     .= $self->{code_origin};
    if ( $self->{_error} && $self->{_error} =~ /\S/ ) {
        $self->{log}->error("$logmsg failed with error: " . $self->{_error});
    } else {
        $self->{log}->info("$logmsg succeeded.");
    }
}

1;
