package Renderer::Log;

# Shared structured-log formatter. Three places previously hand-rolled the
# same JSON shape: Identity.pm, ContentCache.pm, and the app-level log set
# up in Renderer::_configure_logging. Centralized in WW3-R38.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Mojo::Log;
use Mojo::JSON qw(encode_json);
use Mojo::Date;

use Exporter qw(import);
our @EXPORT_OK = qw(structured apply_json_format iso8601_now);

# UTC ISO-8601 timestamp ("YYYY-MM-DDTHH:MM:SSZ"). Used for the `audited_at`
# field on Audit responses and the `timestamp` on telemetry batches; both
# sites previously hand-rolled the same gmtime+sprintf clone.
sub iso8601_now {
	my @t = gmtime;
	return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
		$t[5] + 1900, $t[4] + 1, $t[3], $t[2], $t[1], $t[0]);
}

# Build a Mojo::Log with the structured-JSON formatter attached when
# LOG_FORMAT=json is set; otherwise return a plain Mojo::Log (default text
# format). $component, when given, populates the `component` field on each
# emitted JSON entry — module-level loggers should pass their module name.
sub structured ($component = undef) {
	my $log = Mojo::Log->new;
	apply_json_format($log, $component);
	return $log;
}

# Attach the JSON formatter to an existing Mojo::Log if LOG_FORMAT=json.
# No-op otherwise. Returns the log for chaining.
sub apply_json_format ($log, $component = undef) {
	return $log unless $ENV{LOG_FORMAT} && $ENV{LOG_FORMAT} eq 'json';

	$log->format(sub {
		my ($time, $level, @lines) = @_;
		my %entry = (
			timestamp => Mojo::Date->new($time)->to_datetime,
			level     => $level,
			pid       => $$,
			service   => 'renderer',
			message   => join(' ', @lines),
		);
		$entry{component} = $component if defined $component;
		return encode_json(\%entry) . "\n";
	});

	return $log;
}

1;
