package Renderer::Controller::Audit;
use Mojo::Base 'Mojolicious::Controller', -signatures;

use Mojo::JSON qw(encode_json);
use Opcode;

# Self-bootstrap PG/lib so direct loads (e.g. `prove t/audit.t`, `perl -c`)
# resolve WWSafe without external -I. In production, RenderProblem.pm has
# already added it by the time Mojo lazy-loads this controller.
use File::Basename qw(dirname);
use File::Spec;
use lib File::Spec->catdir(dirname(__FILE__), '..', '..', 'PG', 'lib');

use WWSafe;

use Renderer::OPLAuthed qw(verify_request);
use Renderer::Log       qw(iso8601_now);
use Renderer::Version   qw(pg_version renderer_version);

# POST /render-api/audit
# Ed25519-signed by OPL. Safe-compiles a single macro and returns
# structured warnings (split frontend/backend per Translator.pm:699).
#
# Request body:
#   { macro_name: "contextInexactValue.pl",
#     macro_hash: "sha256:...",
#     macro_source: "..." }
#
# Response:
#   { macro_hash, warnings_frontend, warnings_backend, errors,
#     compiled, renderer_version, pg_version, audited_at }
#
# This is compile-time only.  `reval` parses the macro but does not
# exercise its subroutines, so runtime warnings (div-by-zero inside
# an answer checker, etc.) don't fire here.  Documented in LT-049.

# Concurrency guard independent of the render callback pool so a burst
# of audits doesn't starve live renders (and vice versa).
my $AUDIT_SEMAPHORE      = 0;
my $AUDIT_MAX_CONCURRENT = $ENV{AUDIT_MAX_CONCURRENT} // 4;

sub audit ($c) {
	my $req = verify_request($c) or return;

	my $macro_name   = $req->{macro_name};
	my $macro_hash   = $req->{macro_hash};
	my $macro_source = $req->{macro_source};
	unless ($macro_name && $macro_hash && defined $macro_source) {
		return $c->render(
			json => {
				error => 'missing macro_name, macro_hash, or macro_source',
			},
			status => 400
		);
	}

	if ($AUDIT_SEMAPHORE >= $AUDIT_MAX_CONCURRENT) {
		return $c->render(json => { error => 'audit queue full' }, status => 429);
	}
	$AUDIT_SEMAPHORE++;

	my $result;
	eval { $result = _perform_audit($macro_source); };
	my $err = $@;
	$AUDIT_SEMAPHORE--;

	if ($err || !$result) {
		$c->log->warn("Audit failed for $macro_name ($macro_hash): " . ($err // 'unknown'));
		return $c->render(
			json => {
				error      => 'audit internal error',
				macro_hash => $macro_hash,
			},
			status => 500
		);
	}

	$c->render(
		json => {
			macro_hash        => $macro_hash,
			warnings_frontend => $result->{warnings_frontend},
			warnings_backend  => $result->{warnings_backend},
			errors            => $result->{errors},
			compiled          => $result->{compiled} ? \1 : \0,
			renderer_version  => renderer_version(),
			pg_version        => pg_version(),
			audited_at        => iso8601_now(),
		}
	);
}

# Safe-compile the macro source and collect warnings.  No exceptions leak
# out — compile errors are reported via the errors array.  Pure data
# transformation otherwise.
sub _perform_audit ($source) {
	my $safe = WWSafe->new;
	# Mirror Translator.pm::set_mask so the audit runs under the same
	# opcode policy as live rendering.  Any drift between this and the
	# live mask would produce misleading audit results.
	$safe->mask(Opcode::full_opset());
	$safe->permit(qw(:default));
	$safe->permit(qw(time));
	$safe->permit(qw(atan2 sin cos exp log sqrt));
	$safe->deny(qw(entereval));
	$safe->deny(qw(unlink symlink system exec));
	$safe->deny(qw(print require));

	# Alias strict:: and warnings:: into the compartment so the canonical
	# `BEGIN { strict->import; }` PG idiom works when a macro uses it.
	# These pragmas are pure compile-time state mutators — no I/O, no danger.
	# Without this the BEGIN block would fail with "Can't locate object method
	# import via package strict" because Safe isolates %main::.
	#
	# Note: we do NOT pass strict=1 to reval itself.  Many production PG macros
	# reference globals that are `our`-declared in PG.pl or other bootstrap
	# macros loaded *before* them in the real runtime — auditing them in
	# isolation under strict produces false positives that abort the compile
	# before useful warnings fire.  Letting the macro's own BEGIN block decide
	# matches authorial intent and produces the richest warning output.
	my $root = $safe->root;
	{
		no strict 'refs';
		*{"${root}::strict::"}   = \%strict::;
		*{"${root}::warnings::"} = \%warnings::;
	}

	my (@frontend_raw, @backend_raw);
	my $compiled;
	my $eval_err;
	{
		# PG macros don't `use warnings` themselves (many rely on PG's
		# looser-than-modern conventions).  But the *point* of the audit
		# is to see what warnings they produce — so force Perl's global
		# warning flag on for the duration of the compile.
		local $^W = 1;
		local $SIG{__WARN__} = sub {
			my ($msg, $backend_flag) = @_;
			if   ($backend_flag) { push @backend_raw,  $msg }
			else                 { push @frontend_raw, $msg }
		};
		# Reset $SIG{__DIE__} to default so Mojolicious's global die
		# handler (which tries to construct a Mojo::Exception) doesn't
		# intercept dies that happen inside the Safe compartment.  Without
		# this, every Safe-reval failure shows up as a misleading
		# "Can't locate object method new via package Mojo::Exception"
		# because Safe blocks the `require Mojo::Exception` that the
		# handler tries to do.
		local $SIG{__DIE__} = 'DEFAULT';
		# Safe::reval returns the value of the last statement; that may
		# legitimately be undef (e.g. empty source).  $@ is the
		# discriminator: non-empty means compile error or die during
		# execution; empty means success.
		#
		# Pass strict=0 so we don't layer extra strict on top of whatever
		# the macro's own BEGIN block sets up.  See the "do NOT pass
		# strict=1" rationale above.
		$safe->reval($source, 0);
		if ($@ && length "$@") {
			$eval_err = "$@";
			$compiled = 0;
		} else {
			$compiled = 1;
		}
	}

	my @errors;
	if (!$compiled) {
		push @errors, { message => _clean_diagnostic("$eval_err") };
	}

	return {
		warnings_frontend => [ map { _structure_warning($_) } @frontend_raw ],
		warnings_backend  => [ map { _structure_warning($_) } @backend_raw ],
		errors            => \@errors,
		compiled          => $compiled,
	};
}

# Parse a Perl warning string into a structured record.  Perl warnings from
# Safe::reval carry "at (eval N) line M." suffixes — extract the line, keep
# the message.
sub _structure_warning ($raw) {
	my $msg  = $raw;
	my $line = undef;
	if ($msg =~ /\bat\s+\(eval\s+\d+\)\s+line\s+(\d+)/) {
		$line = $1 + 0;
	}
	$msg =~ s/\s+$//;    # trailing newline
	return {
		message  => $msg,
		line     => $line,
		severity => 'warning',
	};
}

sub _clean_diagnostic ($msg) {
	$msg =~ s/\s+$//;
	return $msg;
}

1;
