package Renderer::Telemetry;

use strict;
use warnings;

use Time::HiRes qw(time);
use Mojo::IOLoop;
use Mojo::JSON   qw(encode_json);
use MIME::Base64 qw(encode_base64);
use Digest::SHA  qw(sha256_hex);
use Encode       qw(encode);
use Renderer::Identity;
use Renderer::Log     qw(iso8601_now);
use Renderer::Version qw(pg_version);

# Process-global event buffer. Hypnotoad workers rotate every ~100-200 requests,
# so this never grows unbounded. Events are lost on worker death — that's fine,
# telemetry is statistical.
my @BUFFER;

# Batch reporter state (set by init).
my $APP;
my $OPL_URL;
my $FLUSH_INTERVAL  = 60;     # seconds between timer flushes
my $FLUSH_THRESHOLD = 100;    # event count trigger

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

	my $body    = encode_json({ events => $events });
	my %headers = ('Content-Type' => 'application/json');

	if (Renderer::Identity::has_identity()) {
		my $sig = Renderer::Identity::sign($body);
		if ($sig) {
			$headers{'X-Telemetry-PublicKey'} = Renderer::Identity::public_key_b64();
			$headers{'X-Telemetry-Signature'} = encode_base64($sig, '');
		}
	}

	$APP->ua->post_p($OPL_URL => \%headers => $body)->then(sub {
		my $tx   = shift;
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

# Record a render event. Universal — emitted on every render regardless of
# role. Render outcomes describe code-path health (PG warnings, errors,
# render time), which is the same signal whether a student or an instructor
# triggered the render. See vault: WeBWorK/Render Telemetry.md.
#
# `errors` is currently 0 or 1 (PG exposes the error blob as a string + a
# flag, not a structured list). Typed as int so LT-050 structured-warning
# capture can bump it to real counts without an API break.
sub record_render {
	my (%args) = @_;
	return unless $args{pg_hash};

	push @BUFFER,
		{
			type       => 'render',
			pg_hash    => $args{pg_hash},
			pg_version => pg_version(),
			warnings   => $args{warnings}  // 0,
			errors     => $args{errors}    // 0,
			render_ms  => $args{render_ms} // 0,
			timestamp  => iso8601_now(),
		};
	_maybe_flush();
}

# Record an interaction event (answer submission, preview, show answers).
# Non-instructor only — student-experience signal. Instructor submits/show-
# answers would poison completion-rate and give-up-rate aggregates.
sub record_interaction {
	my (%args) = @_;
	return if $args{is_instructor};
	return unless $args{pg_hash};

	push @BUFFER,
		{
			type       => 'interaction',
			pg_hash    => $args{pg_hash},
			pg_version => pg_version(),
			action     => $args{action} // 'submit',
			score      => $args{score},
			attempt    => $args{attempt} // 1,
			timestamp  => iso8601_now(),
		};
	_maybe_flush();
}

# Record a seed observation. Role-agnostic — the (seed -> html_hash) mapping
# is a deterministic content property; instructor previews, authoring renders,
# and review renders all contribute valid samples of the variant space.
# Called only on first renders (no sessionJWT = fresh seed).
sub record_seed_observation {
	my (%args) = @_;
	return unless $args{pg_hash};
	return unless defined $args{seed} && defined $args{html_hash};

	push @BUFFER,
		{
			type       => 'seed_observation',
			pg_hash    => $args{pg_hash},
			pg_version => pg_version(),
			seed       => $args{seed} + 0,
			html_hash  => $args{html_hash},
			timestamp  => iso8601_now(),
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

# Compute a content-addressable hash of a rendered problem.
# Combines normalized HTML text with sorted correct answers to produce
# a hash that is stable across renderer/OPL deployments but sensitive
# to seed-driven content differences.
#
# Args: $text (rendered HTML body), $answers (hashref of answer evaluators)
# Returns: "sha256:..." string, or undef if no hashable content.
sub content_hash {
	my ($text, $answers) = @_;

	my $normalized = normalize_for_hash($text);
	return undef unless length $normalized;

	# Append sorted correct answers — captures mathematical differences
	# that the visible text alone might miss (or vice versa for pool-selection
	# problems where answers are sparse but question text varies).
	my $answer_suffix = '';
	if ($answers && ref $answers eq 'HASH' && keys %$answers) {
		my @correct = map { $answers->{$_}{correct_ans} // '' } sort keys %$answers;
		$answer_suffix = "\x00" . join("\x00", @correct);
	}

	return 'sha256:' . sha256_hex(encode('UTF-8', $normalized . $answer_suffix));
}

# Normalize rendered HTML for content-addressable hashing.
# Strips deployment-specific values so that structurally identical renders
# from different renderer/OPL hosts produce the same normalized output.
#
# What gets stripped:
#   - src="..." on <img>, <script>, <iframe> (URLs are host-dependent;
#     image content isn't available to us, only the URL)
#   - action="..." on <form> (renderer-specific submit target)
#   - SITE_HOST hostname (renderer's own address)
#   - baseURL prefix (renderer path mounting)
#   - Whitespace runs outside <pre>/<code> blocks
#
# What's preserved:
#   - Tag structure (an <img> existing vs not is structural)
#   - alt, width, height, class, id and other non-URL attributes
#   - All text content, math markup, answer blank structure
#   - Content inside <pre>/<code> blocks (verbatim)
sub normalize_for_hash {
	my ($html) = @_;
	return '' unless defined $html && length $html;

	# 1. Strip src="..." from <img>, <script>, <iframe>
	#    Keeps the tag and all other attributes intact.
	$html =~ s/(<(?:img|script|iframe)\b[^>]*?)\s+src\s*=\s*(?:"[^"]*"|'[^']*')/$1/gi;

	# 2. Strip action="..." from <form>
	$html =~ s/(<form\b[^>]*?)\s+action\s*=\s*(?:"[^"]*"|'[^']*')/$1/gi;

	# 3. Replace SITE_HOST with placeholder (renderer-specific hostname)
	my $site_host = $ENV{SITE_HOST} // '';
	$html =~ s/\Q$site_host\E/__SITE_HOST__/g if length $site_host;

	# 4. Strip baseURL prefix from remaining paths
	my $base_url = $ENV{baseURL} // '';
	$html =~ s/\Q$base_url\E//g if length $base_url;

	# 5. Collapse whitespace runs outside <pre> and <code> blocks.
	my $result = '';
	my $in_pre = 0;
	for my $segment (split /(<\/?(?:pre|code)[^>]*>)/i, $html) {
		if ($segment =~ m{^<(pre|code)}i) {
			$in_pre++;
			$result .= $segment;
		} elsif ($segment =~ m{^</(pre|code)}i) {
			$in_pre-- if $in_pre > 0;
			$result .= $segment;
		} elsif ($in_pre) {
			$result .= $segment;
		} else {
			my $collapsed = $segment;
			$collapsed =~ s/\s+/ /g;
			$result .= $collapsed;
		}
	}

	return $result;
}

sub _maybe_flush {
	flush() if $APP && pending() >= $FLUSH_THRESHOLD;
}

1;
