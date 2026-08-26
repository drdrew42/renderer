package Renderer::OPLAuthed;
use Mojo::Base -signatures;

# Shared verify-and-parse prelude for OPL→renderer signed requests.
#
# Both Renderer::Controller::Callback and Renderer::Controller::Audit
# accept Ed25519-signed POST bodies from a registered OPL instance. The
# signature-check prelude is identical: has-public-key, signature header
# presence, Ed25519 verify, JSON body parse. Only the downstream
# concurrency guards and action bodies differ.
#
# The signature header is X-OPL-Signature, with the historical
# X-Telemetry-Signature still accepted for an in-flight OPL (see
# Renderer::Constants — the "Telemetry" prefix is a misnomer here).
#
# Usage:
#
#   my $body = Renderer::OPLAuthed::verify_request($c) or return;
#
# On success: returns the parsed JSON body as a hashref. On failure:
# renders the appropriate error status (503 / 401 / 400) and returns
# undef so the caller's `or return` bails.
#
# Extracted from Controller::Callback and Controller::Audit in WW3-R34.

use Crypt::Ed25519;
use MIME::Base64 qw(decode_base64);

use Renderer::Registration;
use Renderer::Constants qw(OPL_SIGNATURE_HEADER OPL_SIGNATURE_HEADER_LEGACY);

use Exporter qw(import);
our @EXPORT_OK = qw(verify_request);

sub verify_request ($c) {
	unless (Renderer::Registration::has_opl_public_key()) {
		$c->render(json => { error => 'registration not completed' }, status => 503);
		return undef;
	}

	my $raw_body = $c->req->body;
	my $sig_b64  = $c->req->headers->header(OPL_SIGNATURE_HEADER)
		// $c->req->headers->header(OPL_SIGNATURE_HEADER_LEGACY);
	unless ($sig_b64 && length $sig_b64) {
		$c->render(json => { error => 'missing signature' }, status => 401);
		return undef;
	}

	my $sig     = decode_base64($sig_b64);
	my $opl_key = Renderer::Registration::opl_public_key();
	# Crypt::Ed25519::verify returns falsy on signature mismatch (doesn't die).
	# eval is defensive against malformed-bytes crashes in the underlying C call.
	my $valid = eval { Crypt::Ed25519::verify($raw_body, $opl_key, $sig) } // 0;
	unless ($valid) {
		$c->render(json => { error => 'invalid signature' }, status => 401);
		return undef;
	}

	my $body = $c->req->json;
	unless ($body) {
		$c->render(json => { error => 'missing JSON body' }, status => 400);
		return undef;
	}

	return $body;
}

1;
