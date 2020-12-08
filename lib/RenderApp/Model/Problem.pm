package RenderApp::Model::Problem;

use strict;
use warnings;

use Mojo::File;
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
# - errport (delivers a hash reference to be rendered as JSON)

our $codes = {
    400 => 'Bad Request',
    403 => 'Forbidden',
    404 => 'Not Found',
    405 => 'Method Not Allowed',
    412 => 'Precondition Failed'
};

sub new {
    my $class       = shift;
    my $problem_ref = {};
    bless $problem_ref, $class;
    $problem_ref->_init(@_);
    return $problem_ref;
}

sub _init {
    my ( $self, $args ) = @_;
    my $availability = 'private';

    $self->{log} = $args->{log} if $args->{log};

    my $read_path        = $args->{read_path}        || '';
    my $problem_contents = $args->{problem_contents} || '';
    $self->{_error} =
      "400 Cannot create problem without either path or contents!\n"
      unless ( $read_path =~ m/\S/ || $problem_contents =~ m/\S/ );

    if ( $read_path =~ m/\S/ ) {
        $self->path($read_path);
        $self->load;
    }

    # overwrite read_path file content if raw content is provided
    if ( $problem_contents =~ m/\S/ ) {
        $self->source($problem_contents);
    }

    $self->target( $args->{write_path} ) if $args->{write_path};
    $self->seed( $args->{random_seed} )  if $args->{random_seed};

    my $path_info = $read_path ? $read_path : "no read path provided";
    my $seed_info =
      $args->{random_seed} ? "#" . $args->{random_seed} : "no random seed.";
    $self->{log}
      ->info("CREATED: Problem created with $path_info and $seed_info");
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
    if ( scalar(@_) == 1 ) {
        my $read_path = shift;
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
          unless ( -e $read_path );
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

sub save {
    my $self    = shift;
    my $success = 0;
    my $write_path =
      ( $self->{write_path} =~ m/\S/ )
      ? $self->{write_path}
      : $self->{read_path};

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

    return 0 unless $self->success();

    $write_path->spurt( $self->{problem_contents} );
    $self->path($write_path);    # update the read_path to match
    return 1;
}

sub load {
    my $self      = shift;
    my $success   = 0;
    my $read_path = $self->{read_path};
    if ( -r $read_path ) {
        $self->{problem_contents} = $read_path->slurp;
        $success = 1;
    }
    else {
        $self->{_error} =
          "404 Problem set with un-read-able read_path: $read_path";
    }
    return $success;
}

sub render {
    my $self       = shift;
    my $inputs_ref = shift;
    return RenderApp::Controller::RenderProblem::process_pg_file( $self,
        $inputs_ref );
}

sub success {
    my $self = shift;
    return 1 unless $self->{_error};
    my ( $code, $mesg ) = split( / /, $self->{_error}, 2 );
    $self->{status}   = $code;
    $self->{_error}   = $codes->{$code};
    $self->{_message} = $mesg;
    return 0;
}

sub errport {
    my $self = shift;
    return unless $self->{_error};
    my $err_ref = {
        statusCode => $self->{status},
        error      => $self->{_error},
        message    => $self->{_message}
    };
    return $err_ref;
}

sub DESTROY {
    my $self = shift;
    my $end  = "TRASH: ";
	if ($self->{read_path}) $end .= $self->{read_path} . " ";
    $end .=
      ( $self->{_error} && $self->{_error} =~ /\S/ )
      ? $self->{_error}
      : "with no errors.";
    $self->{log}->info($end);
}

1;
