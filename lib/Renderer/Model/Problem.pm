package Renderer::Model::Problem;

use strict;
use warnings;

use Mojo::IOLoop;
use Mojo::JSON qw( encode_json );
use Mojo::Base -async_await, -signatures;
use Time::HiRes  qw( time );
use WeBWorK::RenderProblem;

##### Problem params: #####
# = random_seed      (set randomization for rendering)
# = read_path        (path identity for rendered problem)
# = problem_contents (source code for problem)

##### Problem methods: #####
## GET/SET
# - source (read/update problem_contents)
# - seed   (read/update random_seed)
# - path   (read/update read_path)
## IO methods
# - render (generate rendered html + pg info)
## Error handling
# - success (checks for internal errors, populates status and _message fields)

sub new ($class, @args) {
	my $problem_ref = {
		_error      => undef,
		action      => '',
		code_origin => '',
	};
	bless $problem_ref, $class;
	$problem_ref->{start} = time;
	$problem_ref->_init(@args);
	return $problem_ref;
}

sub _init ($self, $args) {
	$self->{log} = $args->{log} if $args->{log};

	my $read_path        = $args->{read_path}        || '';
	my $problem_contents = $args->{problem_contents} || '';
	my $random_seed      = $args->{random_seed}      || '';
	$self->{_error} = { status => 400, message => 'Cannot create problem without problem source!' }
		unless ($problem_contents =~ /\S/);

	$self->source($problem_contents) if $problem_contents =~ /\S/;
	$self->{code_origin} = 'pg source (' . ($self->path($read_path) || 'no path provided') . ')';

	$self->seed($random_seed) if $random_seed =~ /\S/;

	my $path_info = $self->{code_origin};
	my $seed_info = $args->{random_seed} ? "random seed #" . $args->{random_seed} : "no random seed.";
	$self->{log}->info("CREATED: Problem created from $path_info with $seed_info");
}

sub source ($self, @rest) {
	if (@rest == 1) {
		my $contents = $rest[0];

		# UNIX style line-endings are required
		$contents =~ s!\r\n?!\n!g;
		$self->{problem_contents} = $contents;
	}
	return $self->{problem_contents};
}

sub seed ($self, @rest) {
	if (@rest == 1) {
		my $random_seed = $rest[0];
		$self->{_error} = { status => 400, message => 'You must provide a positive integer for the random seed.' }
			unless $random_seed =~ m!^\d+$!;
		$self->{random_seed} = $random_seed;
	}
	return $self->{random_seed};
}

sub path ($self, @rest) {
	$self->{read_path} = $rest[0] if @rest >= 1 && defined $rest[0] && length $rest[0];
	return $self->{read_path};
}

# RETURNS PROMISE
sub render ($self, $inputs_ref) {

	$self->{action} = 'render';
	my $renderPromise = Mojo::IOLoop->subprocess->run_p(sub {
		return WeBWorK::RenderProblem::process_pg_file($self, $inputs_ref);
	})->catch(sub {
		$self->{exception} = Mojo::Exception->new(shift)->trace;
		$self->{_error}    = { status => 500, message => 'Render failed: ' . $self->{exception}->message };
	});
	return $renderPromise;
}

sub success ($self) {
	return 1 unless $self->{_error};
	$self->{status}   = $self->{_error}{status};
	$self->{_message} = $self->{_error}{message};
	return 0;
}

sub DESTROY ($self) {
	my $duration = time - $self->{start};
	my $logmsg   = 'TRASH: [' . sprintf("%.1f", $duration * 1000) . 'ms] ';
	$logmsg .= $self->{action} . ' from ';
	$logmsg .= $self->{code_origin};
	if ($self->{_error}) {
		$self->{log}->error("$logmsg failed with error: " . $self->{_error}{message});
	} else {
		$self->{log}->info("$logmsg succeeded.");
	}
}

1;
