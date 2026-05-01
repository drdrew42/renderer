package Renderer::Controller::Callback;
use Mojo::Base 'Mojolicious::Controller', -async_await, -signatures;

# POST /render-api/callback
#
# Ed25519-signed by OPL. Two actions, dispatched by the request body's
# `action` field:
#
#   * invalidate_macro — delete a macro by hash from the cache. Cheap;
#     no PG fork.
#   * (default — render) — render a problem and return html_hash for
#     OPL-side verification. Originates from LT-016.
#
# Mirrors Renderer::Controller::Audit in shape: signature verify prelude,
# semaphore guard, eval render. The shared verify dance is a known
# duplicate — see WW3-R34 for the OPLAuthed extraction.
#
# Moved out of Renderer::Controller::Render in WW3-R33.

use Mojo::JSON   qw(encode_json decode_json);
use Crypt::Ed25519;
use MIME::Base64 qw(decode_base64);
use File::Spec;

use Renderer::Registration;
use Renderer::Telemetry;
use Renderer::Render::Subprocess qw(render_in_subprocess);

# Concurrency guard. Independent of the audit pool so a burst of OPL
# probes doesn't starve live renders (and vice versa).
my $CALLBACK_SEMAPHORE = 0;
my $CALLBACK_MAX_CONCURRENT = $ENV{CALLBACK_MAX_CONCURRENT} // 4;

async sub callback ($c) {
	# Verify OPL signature
	unless (Renderer::Registration::has_opl_public_key()) {
		return $c->render(json => { error => 'registration not completed' }, status => 503);
	}

	my $raw_body = $c->req->body;
	my $sig_b64  = $c->req->headers->header('X-Telemetry-Signature');
	unless ($sig_b64 && length($sig_b64)) {
		return $c->render(json => { error => 'missing signature' }, status => 401);
	}

	my $sig = decode_base64($sig_b64);
	my $opl_key = Renderer::Registration::opl_public_key();
	my $valid = eval { Crypt::Ed25519::verify($raw_body, $opl_key, $sig); 1 } // 0;
	unless ($valid) {
		return $c->render(json => { error => 'invalid signature' }, status => 401);
	}

	# Parse request and dispatch by action
	my $req = $c->req->json;
	unless ($req) {
		return $c->render(json => { error => 'missing JSON body' }, status => 400);
	}

	# Dispatch: invalidate_macro doesn't need the render pipeline
	if (($req->{action} // '') eq 'invalidate_macro') {
		my $hash = $req->{hash};
		unless ($hash) {
			return $c->render(json => { error => 'missing hash' }, status => 400);
		}
		my $deleted = eval { unlink File::Spec->catfile("$ENV{RENDER_ROOT}/private/macros", $hash) } // 0;
		$c->log->info("Macro invalidated: $hash (deleted=$deleted)");
		return $c->render(json => { invalidated => $hash, deleted => $deleted ? \1 : \0 });
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
