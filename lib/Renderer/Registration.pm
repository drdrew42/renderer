package Renderer::Registration;

use strict;
use warnings;

use Mojo::IOLoop;
use Mojo::JSON qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64 decode_base64);
use Digest::SHA qw(sha256_hex);
use Renderer::Identity;

# Unified peer registry: name → raw 32-byte Ed25519 public key.
# Populated from two sources:
#   - Config/env var RENDERER_PEERS at startup (static peers — editor-providers, etc.)
#   - Successful TOFU registration with OPL (entry named 'opl')
my %PEERS;

# Known peer origins (public-facing URLs) — used for dynamic CORS.
# Populated during OPL registration; may be extended with static peer origins later.
my %PEER_ORIGINS;

my $RETRY_INTERVAL = 30;  # seconds between registration retries

# Register this renderer with the OPL.
# Fires a POST to $OPL_API_URL/api/renderers/register with a signed payload
# containing our fingerprint, public key, and callback URL.
# On success, stores the OPL's public key for verifying future callback requests.
# On failure, retries every $RETRY_INTERVAL seconds until success.
sub init {
	my ($app) = @_;

	# Load static peers from RENDERER_PEERS (env var or config), populating %PEERS.
	# Editor-providers, portals, and other trusted callers live here.
	_load_static_peers($app);

	return unless $ENV{OPL_API_URL};
	return unless Renderer::Identity::has_identity();

	my $callback_url = _build_callback_url();
	unless ($callback_url) {
		$app->log->warn("Registration: cannot determine callback URL (SITE_HOST not set)");
		return;
	}

	$app->log->info("Registration: will register with $ENV{OPL_API_URL} (callback: $callback_url)");

	# Fire first attempt immediately via next tick, then retry on timer if needed.
	Mojo::IOLoop->next_tick(sub { _attempt_register($app, $callback_url) });
}

# Parse RENDERER_PEERS — JSON array of {name, public_key} objects — and pin
# each entry into %PEERS. Called once at startup, before OPL registration.
# Shape (env var):
#   RENDERER_PEERS='[{"name":"adapt-editor","public_key":"jEA8...=="}]'
# Or config (list of hashrefs under 'peers' key in renderer.conf).
sub _load_static_peers {
	my ($app) = @_;

	my $raw = $ENV{RENDERER_PEERS};
	my $list;
	if ($raw && $raw =~ /\S/) {
		eval { $list = decode_json($raw); 1 } or do {
			$app->log->warn("Registration: RENDERER_PEERS is not valid JSON — ignoring ($@)");
			return;
		};
	} elsif (my $conf_peers = $app->config('peers')) {
		$list = $conf_peers;
	}

	return unless ref($list) eq 'ARRAY';

	my $count = 0;
	for my $entry (@$list) {
		next unless ref($entry) eq 'HASH';
		my $name   = $entry->{name};
		my $pubkey = $entry->{public_key};
		unless ($name && $pubkey) {
			$app->log->warn("Registration: peer entry missing name or public_key — skipping");
			next;
		}
		my $raw_key = decode_base64($pubkey);
		unless (length($raw_key) == 32) {
			$app->log->warn("Registration: peer '$name' public_key is not a 32-byte Ed25519 key — skipping");
			next;
		}
		if (exists $PEERS{$name}) {
			$app->log->warn("Registration: duplicate peer name '$name' — keeping first entry");
			next;
		}
		$PEERS{$name} = $raw_key;
		$count++;
		$app->log->info("Registration: pinned peer '$name' ("
			. substr(sha256_hex($raw_key), 0, 16) . "...)");
	}

	$app->log->info("Registration: loaded $count static peer(s)") if $count;
}

sub _attempt_register {
	my ($app, $callback_url) = @_;

	my $payload = encode_json({
		fingerprint  => Renderer::Identity::fingerprint(),
		public_key   => Renderer::Identity::public_key_b64(),
		callback_url => $callback_url,
	});

	my $sig = Renderer::Identity::sign($payload);
	my %headers = (
		'Content-Type'         => 'application/json',
		'X-Telemetry-PublicKey' => Renderer::Identity::public_key_b64(),
		'X-Telemetry-Signature' => encode_base64($sig, ''),
	);

	my $url = "$ENV{OPL_API_URL}/api/renderers/register";

	$app->ua->post_p($url => \%headers => $payload)->then(sub {
		my $tx   = shift;
		my $code = $tx->res->code // 0;
		if ($code == 200) {
			my $body = $tx->res->json // {};
			if ($body->{public_key}) {
				my $opl_key = decode_base64($body->{public_key});
				if (length($opl_key) == 32) {
					$PEERS{opl} = $opl_key;
					$app->log->info("Registration: success — OPL pubkey stored as peer 'opl' ("
						. substr(sha256_hex($opl_key), 0, 16) . "...)");
				} else {
					$app->log->warn("Registration: OPL public_key not a 32-byte Ed25519 key");
				}
				if (my $origin = $body->{origin}) {
					$origin =~ s{/+$}{};  # strip trailing slash
					$PEER_ORIGINS{$origin} = 1;
					$app->log->info("Registration: CORS origin learned — $origin");
				}
			} else {
				$app->log->warn("Registration: 200 but no OPL public_key in response");
				_schedule_retry($app, $callback_url);
			}
		} else {
			$app->log->warn("Registration: HTTP $code — will retry in ${RETRY_INTERVAL}s");
			_schedule_retry($app, $callback_url);
		}
	})->catch(sub {
		my $err = shift;
		$app->log->warn("Registration: failed ($err) — will retry in ${RETRY_INTERVAL}s");
		_schedule_retry($app, $callback_url);
	});
}

sub _schedule_retry {
	my ($app, $callback_url) = @_;
	Mojo::IOLoop->timer($RETRY_INTERVAL => sub {
		_attempt_register($app, $callback_url) unless $PEERS{opl};
	});
}

sub _build_callback_url {
	my $host = $ENV{SITE_HOST} // return undef;
	my $base = $ENV{baseURL}   // '';
	return "${host}${base}/render-api/callback";
}

# Canonical request signing: verify an inbound peer signature.
#
#   Canonical form: method + "\n" + path + "\n" + timestamp + "\n" + body_bytes
#   Signature: raw 64 bytes, Ed25519-signed by the peer, base64-encoded on the wire.
#   Timestamp tolerance: ±$PEER_TIMESTAMP_SKEW seconds (default 300).
#
# Returns (ok => 0|1, reason => string). Reason is short, log-safe, and describes
# the *failure* on ok=0; on ok=1 it is "ok".
my $PEER_TIMESTAMP_SKEW = 300;  # seconds

sub verify_peer_signature {
	my (%args) = @_;
	my $method    = $args{method}    // '';
	my $path      = $args{path}      // '';
	my $timestamp = $args{timestamp} // '';
	my $body      = $args{body}      // '';
	my $peer_name = $args{peer_name} // '';
	my $sig_b64   = $args{signature} // '';

	return (ok => 0, reason => 'missing peer name')      unless length $peer_name;
	return (ok => 0, reason => 'missing signature')      unless length $sig_b64;
	return (ok => 0, reason => 'missing timestamp')      unless length $timestamp;
	return (ok => 0, reason => 'malformed timestamp')    unless $timestamp =~ /^\d+$/;

	my $pubkey = $PEERS{$peer_name};
	return (ok => 0, reason => "unknown peer '$peer_name'") unless $pubkey;

	my $now  = time;
	my $skew = abs($now - $timestamp);
	return (ok => 0, reason => "timestamp skew ${skew}s exceeds ${PEER_TIMESTAMP_SKEW}s")
		if $skew > $PEER_TIMESTAMP_SKEW;

	my $sig = eval { decode_base64($sig_b64) };
	return (ok => 0, reason => 'signature not valid base64') unless defined $sig;
	return (ok => 0, reason => 'signature wrong length')     unless length($sig) == 64;

	my $canonical = $method . "\n" . $path . "\n" . $timestamp . "\n" . $body;
	# Force to bytes — Mojo's $req->body is raw bytes, but $req->url->path may be
	# UTF-8-flagged. Concatenation mixes states; Ed25519 operates on bytes.
	utf8::encode($canonical);
	my $valid = Renderer::Identity::verify($canonical, $sig, $pubkey);
	return (ok => 0, reason => 'signature verification failed') unless $valid;

	return (ok => 1, reason => 'ok');
}

# Generalized peer accessors.
sub peer_public_key     { my ($name) = @_; return $PEERS{ $name // '' } }
sub has_peer_public_key { my ($name) = @_; my $k = $PEERS{ $name // '' };
	return defined $k && length($k) == 32 }
sub peer_names          { return keys %PEERS }

# Backward-compat shims for callers that expect the OPL-singleton interface.
sub opl_public_key     { return $PEERS{opl} }
sub has_opl_public_key { return defined $PEERS{opl} && length($PEERS{opl}) == 32 }

# Check if an origin belongs to a known peer (currently OPL; may generalize later).
sub is_known_origin { return $PEER_ORIGINS{ $_[0] // '' } ? 1 : 0 }

1;
