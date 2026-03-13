package Renderer::Telemetry;

use strict;
use warnings;

use Time::HiRes qw(time);
use Mojo::IOLoop;
use Mojo::JSON qw(encode_json);
use MIME::Base64 qw(encode_base64);
use Renderer::Identity;

# Process-global event buffer. Hypnotoad workers rotate every ~100-200 requests,
# so this never grows unbounded. Events are lost on worker death — that's fine,
# telemetry is statistical.
my @BUFFER;

# Batch reporter state (set by init).
my $APP;
my $OPL_URL;
my $FLUSH_INTERVAL  = 60;   # seconds between timer flushes
my $FLUSH_THRESHOLD = 100;  # event count trigger

# Call from app startup() to enable batch reporting.
# Sets up a recurring timer to flush events to the OPL telemetry endpoint.
# No-op if OPL_API_URL is not set.
sub init {
	my ($app) = @_;
	return unless $ENV{OPL_API_URL};

	$APP     = $app;
	$OPL_URL = "$ENV{OPL_API_URL}/api/telemetry";

	Mojo::IOLoop->recurring($FLUSH_INTERVAL => sub { flush() if pending() > 0 });
	$app->log->info("Telemetry reporter: flushing to $OPL_URL every ${FLUSH_INTERVAL}s (threshold $FLUSH_THRESHOLD)");
}

# Drain buffer and POST to OPL. Fire-and-forget.
# Signs payload with Ed25519 identity if available.
sub flush {
	return unless $APP && $OPL_URL;
	my $events = drain();
	return unless @$events;

	my $body = encode_json({ events => $events });
	my %headers = ('Content-Type' => 'application/json');

	if (Renderer::Identity::has_identity()) {
		my $sig = Renderer::Identity::sign($body);
		if ($sig) {
			$headers{'X-Telemetry-PublicKey'}  = Renderer::Identity::public_key_b64();
			$headers{'X-Telemetry-Signature'}  = encode_base64($sig, '');
		}
	}

	$APP->ua->post_p($OPL_URL => \%headers => $body)->then(sub {
		my $tx = shift;
		my $code = $tx->res->code // 0;
		if ($code == 200) {
			my $accepted = $tx->res->json->{accepted} // 0;
			$APP->log->debug("Telemetry flush: $accepted/" . scalar(@$events) . " events accepted");
		} else {
			$APP->log->warn("Telemetry flush: HTTP $code");
		}
	})->catch(sub {
		my $err = shift;
		$APP->log->warn("Telemetry flush failed: $err");
	});
}

# Record a render event (every non-instructor request).
sub record_render {
	my (%args) = @_;
	return if $args{is_instructor};
	return unless $args{pg_hash};

	push @BUFFER, {
		type         => 'render',
		pg_hash      => $args{pg_hash},
		outcome      => $args{outcome}      // 'success',
		warnings     => $args{warnings}     // 0,
		render_ms    => $args{render_ms}    // 0,
		pg_version   => $ENV{PG_VERSION}    // 'unknown',
		cache_status => $args{cache_status} // 'unknown',
		timestamp    => _iso8601(),
	};
	_maybe_flush();
}

# Record an interaction event (answer submission, preview, show answers).
sub record_interaction {
	my (%args) = @_;
	return if $args{is_instructor};
	return unless $args{pg_hash};

	push @BUFFER, {
		type       => 'interaction',
		pg_hash    => $args{pg_hash},
		action     => $args{action}     // 'submit',
		score      => $args{score},
		attempt    => $args{attempt}    // 1,
		pg_version => $ENV{PG_VERSION}  // 'unknown',
		timestamp  => _iso8601(),
	};
	_maybe_flush();
}

# Drain the buffer — returns arrayref of events and clears it.
# Called by the batch reporter (LT-004).
sub drain {
	my @events = @BUFFER;
	@BUFFER = ();
	return \@events;
}

# Current buffer size (for threshold-based flushing).
sub pending { return scalar @BUFFER }

sub _maybe_flush {
	flush() if $APP && pending() >= $FLUSH_THRESHOLD;
}

sub _iso8601 {
	my @t = gmtime(time);
	return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
		$t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

1;
