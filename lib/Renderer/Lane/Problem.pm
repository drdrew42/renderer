package Renderer::Lane::Problem;

# Legacy problemJWT body lane (LMS-minted, LibreTexts/ADAPT origin).
#
#   * Decode + verify_aud against $SITE_HOST under problemJWTsecret.
#   * LibreTexts wraps claims under a `webwork` provider key; hoist if present.
#   * Bulk merge: claims override raw params (claims-always-win).
#   * Sets _can_emit_answer_jwt — this lane is upstream-grounded and may
#     produce answerJWTs.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Crypt::JWT qw(decode_jwt);

use Exporter qw(import);
our @EXPORT_OK = qw(apply);

sub apply ($c, $params) {
	$c->log->info("Received JWT: using problemJWT");

	my $claims;
	eval {
		$claims = decode_jwt(
			token      => $params->{problemJWT},
			key        => $ENV{problemJWTsecret},
			verify_aud => $ENV{SITE_HOST},
		);
		1;
	} or do {
		return $c->croak($@, 3);
	};

	# LibreTexts wraps claims under a provider key.
	$claims = $claims->{webwork} if defined $claims->{webwork};

	# Override raw params with claims (claims-always-win precedence — the
	# whole point of carrying an upstream JWT is the upstream's view of
	# the problem context wins).
	@{$params}{ keys %$claims } = values %$claims;

	$c->stash(_can_emit_answer_jwt => 1);
	return 1;
}

1;
