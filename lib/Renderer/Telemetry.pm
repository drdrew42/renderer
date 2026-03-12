package Renderer::Telemetry;

use strict;
use warnings;

use Time::HiRes qw(time);

# Process-global event buffer. Hypnotoad workers rotate every ~100-200 requests,
# so this never grows unbounded. Events are lost on worker death — that's fine,
# telemetry is statistical.
my @BUFFER;

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

sub _iso8601 {
	my @t = gmtime(time);
	return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
		$t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

1;
