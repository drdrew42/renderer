package Renderer::Controller::Callback;
use Mojo::Base 'Mojolicious::Controller', -async_await, -signatures;

# POST /render-api/callback
#
# Ed25519-signed by OPL. Actions, dispatched by the request body's
# `action` field:
#
#   * invalidate_macro — delete a macro by hash from the cache, and cascade
#     to dependent problem dirs (WW3-R42). Cheap; no PG fork.
#   * invalidate_problem — evict one problem's cache dir by pg_hash, fired
#     when its resource set changes (LT-080). Cheap; no PG fork.
#   * (default — render) — render a problem and return html_hash for
#     OPL-side verification. Originates from LT-016.
#
# Mirrors Renderer::Controller::Audit in shape: signature verify prelude,
# semaphore guard, eval render. The shared verify dance is a known
# duplicate — see WW3-R34 for the OPLAuthed extraction.
#
# Moved out of Renderer::Controller::Render in WW3-R33.

use Mojo::JSON qw(decode_json);
use File::Spec;

use Renderer::ContentCache;
use Renderer::OPLAuthed qw(verify_request);
use Renderer::Telemetry;
use Renderer::Render::Subprocess qw(render_in_subprocess);

# Concurrency guard. Independent of the audit pool so a burst of OPL
# probes doesn't starve live renders (and vice versa).
my $CALLBACK_SEMAPHORE = 0;
my $CALLBACK_MAX_CONCURRENT = $ENV{CALLBACK_MAX_CONCURRENT} // 4;

async sub callback ($c) {
	my $req = verify_request($c) or return;

	# Dispatch: invalidate_macro doesn't need the render pipeline
	if (($req->{action} // '') eq 'invalidate_macro') {
		my $hash = $req->{hash};
		unless ($hash) {
			return $c->render(json => { error => 'missing hash' }, status => 400);
		}
		my $deleted = eval { unlink File::Spec->catfile("$ENV{RENDER_ROOT}/private/macros", $hash) } // 0;

		# WW3-R42: cascade. Removing the macro file leaves every problem
		# manifest that pinned to this hash stranded — _read_manifest_macros
		# silently drops the entry, render fails on loadMacros. Walk the
		# problem cache (naive scan) and invalidate every dependent dir.
		my $dependents = Renderer::ContentCache::find_problems_using_macro($hash);
		for my $pg_hash (@$dependents) {
			Renderer::ContentCache::invalidate($pg_hash);
		}

		$c->log->info(
			"Macro invalidated",
			hash       => $hash,
			deleted    => $deleted ? \1 : \0,
			dependents => scalar @$dependents,
		);
		return $c->render(json => {
			invalidated => $hash,
			deleted     => $deleted ? \1 : \0,
			dependents  => scalar @$dependents,
		});
	}

	# Dispatch: invalidate_problem — evict one problem's cache dir. LT-080.
	# Fired by OPL when a problem's resource set changes (link / replace).
	# The macro-manifest consistency check (WW3-R42) doesn't cover resources,
	# so a resource change needs an explicit push-invalidation. Cheap; no fork.
	if (($req->{action} // '') eq 'invalidate_problem') {
		my $pg_hash = $req->{pg_hash};
		unless ($pg_hash) {
			return $c->render(json => { error => 'missing pg_hash' }, status => 400);
		}
		my $evicted = Renderer::ContentCache::invalidate($pg_hash);
		$c->log->info(
			"Problem cache invalidated",
			pg_hash => $pg_hash,
			evicted => $evicted ? \1 : \0,
		);
		return $c->render(json => {
			invalidated => $pg_hash,
			evicted     => $evicted ? \1 : \0,
		});
	}

	# Default action: render (original callback behavior)
	unless (defined $req->{pg_source} && defined $req->{seed}) {
		return $c->render(json => { error => 'missing pg_source or seed' }, status => 400);
	}

	# Concurrency guard
	if ($CALLBACK_SEMAPHORE >= $CALLBACK_MAX_CONCURRENT) {
		return $c->render(json => { error => 'callback queue full' }, status => 429);
	}
	$CALLBACK_SEMAPHORE++;

	# Build minimal inputs_ref and render via the full pipeline
	$c->render_later;

	my %inputs = (
		problemSource => $req->{pg_source},
		problemSeed   => $req->{seed} + 0,
		outputFormat  => 'json',
		isInstructor  => 0,
	);

	unless (defined $inputs{problemSource} && $inputs{problemSource} =~ /\S/) {
		$CALLBACK_SEMAPHORE--;
		return $c->render(json => { outcome => 'error', warnings => 0, error => 'missing pg_source' }, status => 200);
	}

	my $ww_return_json = eval {
		await render_in_subprocess(\$inputs{problemSource}, \%inputs, 'callback', $c->log);
	};
	my $eval_err = $@;
	$CALLBACK_SEMAPHORE--;

	if ($eval_err) {
		return $c->render(json => { outcome => 'error', warnings => 0, error => "$eval_err" }, status => 200);
	}
	if (ref $ww_return_json eq 'HASH' && $ww_return_json->{_error}) {
		return $c->render(json => { outcome => 'error', warnings => 0, error => $ww_return_json->{_error}{message} }, status => 200);
	}

	my $return_object;
	eval { $return_object = decode_json($ww_return_json); 1; } or do {
		return $c->render(json => { outcome => 'error', warnings => 0, error => 'JSON decode failed' }, status => 200);
	};

	my $warnings = scalar(@{ $return_object->{warning_messages} // [] });
	my $outcome  = $warnings ? 'warning' : 'success';

	# Compute html_hash using the same normalization as telemetry
	my $html_hash = Renderer::Telemetry::content_hash(
		$return_object->{text}, $return_object->{answers});

	return $c->render(json => {
		html_hash => $html_hash,
		outcome   => $outcome,
		warnings  => $warnings,
	});
}

1;
