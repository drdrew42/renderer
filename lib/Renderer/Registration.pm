package Renderer::Registration;

use strict;
use warnings;

use Mojo::IOLoop;
use Mojo::JSON qw(encode_json decode_json);
use MIME::Base64 qw(encode_base64 decode_base64);
use Renderer::Identity;

# Stored OPL public key (raw 32 bytes) — set after successful registration.
my $OPL_PUBLIC_KEY;

# Known OPL origins (public-facing URLs) — used for dynamic CORS.
my %OPL_ORIGINS;

my $RETRY_INTERVAL = 30;  # seconds between registration retries

# Register this renderer with the OPL.
# Fires a POST to $OPL_API_URL/api/renderers/register with a signed payload
# containing our fingerprint, public key, and callback URL.
# On success, stores the OPL's public key for verifying future callback requests.
# On failure, retries every $RETRY_INTERVAL seconds until success.
sub init {
	my ($app) = @_;
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
				$OPL_PUBLIC_KEY = decode_base64($body->{public_key});
				$app->log->info("Registration: success — OPL pubkey stored ("
					. length($OPL_PUBLIC_KEY) . " bytes)");
				if (my $origin = $body->{origin}) {
					$origin =~ s{/+$}{};  # strip trailing slash
					$OPL_ORIGINS{$origin} = 1;
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
		_attempt_register($app, $callback_url) unless $OPL_PUBLIC_KEY;
	});
}

sub _build_callback_url {
	my $host = $ENV{SITE_HOST} // return undef;
	my $base = $ENV{baseURL}   // '';
	return "${host}${base}/render-api/callback";
}

# Accessors for the stored OPL public key.
sub opl_public_key     { return $OPL_PUBLIC_KEY }
sub has_opl_public_key { return defined $OPL_PUBLIC_KEY && length($OPL_PUBLIC_KEY) == 32 }

# Check if an origin belongs to a known OPL.
sub is_known_origin { return $OPL_ORIGINS{ $_[0] // '' } ? 1 : 0 }

1;
