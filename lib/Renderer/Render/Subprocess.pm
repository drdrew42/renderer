package Renderer::Render::Subprocess;

# Run PG rendering in a forked subprocess.
#
# Replaces the Renderer::Model::Problem object: that class was a render-request
# function with a duration timer wearing the costume of an object. Once R07/R08
# stripped the editor surface, what remained was new() → render() → DESTROY()
# log → garbage-collect; nothing about that needs OO. The function-style entry
# is shorter, drops the Storable serialization tax of shipping a $self into the
# subprocess (no $self->{log} captured by closure across the fork boundary),
# and gives the caller a clear error idiom (resolved hashref with _error vs
# resolved JSON string).
#
# Usage:
#
#   use Renderer::Render::Subprocess qw(render_in_subprocess);
#   my $result = await render_in_subprocess(\$source_bytes, $inputs_ref, $log_id, $c->log);
#   if (ref $result eq 'HASH' && $result->{_error}) {
#       return $c->exception($result->{_error}{message}, $result->{_error}{status});
#   }
#   # $result is the JSON string returned by WeBWorK::RenderProblem::process_pg_file.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Exporter qw(import);
use Mojo::IOLoop;
use Mojo::Exception;
use Time::HiRes qw(time);
use WeBWorK::RenderProblem;

our @EXPORT_OK = qw(render_in_subprocess);

# render_in_subprocess(\$source, $inputs_ref, $log_id, $log)
#
# Returns a Mojo::Promise that resolves to:
#   * the JSON string from WeBWorK::RenderProblem::process_pg_file on success
#   * a hashref { _error => { status, message } } on failure
#
# $log_id is a free-form identifier rendered into the duration log line —
# typically pg_hash if available, else sourceFilePath, else '(no-source-id)'.
# $log is the controller's Mojo::Log instance; we don't ship it into the
# subprocess (the prior $self->{log} closure incurred a Storable round-trip).
sub render_in_subprocess ($r_source, $inputs_ref, $log_id, $log) {
	my $start = time;

	return Mojo::IOLoop->subprocess->run_p(sub {
		return WeBWorK::RenderProblem::process_pg_file($r_source, $inputs_ref);
	})->then(sub ($json) {
		my $duration_ms = sprintf("%.1f", (time - $start) * 1000);
		$log->info("RENDER: [${duration_ms}ms] $log_id");
		return $json;
	})->catch(sub ($err) {
		my $exception = Mojo::Exception->new($err)->trace;
		$log->error("RENDER FAILED: $log_id: " . $exception->message);
		return { _error => { status => 500, message => 'Render failed: ' . $exception->message } };
	});
}

1;
