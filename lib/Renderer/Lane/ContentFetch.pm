package Renderer::Lane::ContentFetch;

# Typed-problemJWT lane for content-fetch endpoints (/hint, /solution).
#
# Parallels Lane::Problem (same secret, same aud, same claim-unwrap, same
# claims-always-win merge), but enforces a `typ` claim and does NOT set
# _can_emit_answer_jwt — content-fetch endpoints don't go through the render
# pipeline and never emit answerJWTs.
#
# `typ` may live at either nesting:
#   { iss, aud, typ: 'solution', webwork: { problemSource: ... } }  ← outer
#   { iss, aud, webwork: { typ: 'solution', problemSource: ... } }  ← inner
# The outer placement matches the natural JWT spot (sibling of iss/aud); the
# inner mirrors LibreTexts' provider-namespace convention. Both are accepted.
#
# Used by hint/solution controllers ahead of SourceResolver::resolve_source,
# which then turns problemSourceURL / sourceFilePath / problemSource into a
# concrete (problemSource, sourceFilePath, pg_hash) tuple.

use strict;
use warnings;
use feature 'signatures';
no warnings qw(experimental::signatures);

use Crypt::JWT qw(decode_jwt);

use Exporter qw(import);
our @EXPORT_OK = qw(apply);

sub apply ($c, $params, $expected_typ) {
	my $jwt = $params->{problemJWT};
	unless (defined $jwt && length $jwt) {
		$c->exception('Missing required parameter: problemJWT', 401);
		return;
	}

	my $claims = eval {
		decode_jwt(
			token      => $jwt,
			key        => $ENV{problemJWTsecret},
			verify_aud => $ENV{SITE_HOST},
		);
	};
	if (my $err = $@) {
		$c->log->info("Content-fetch JWT verify failed: $err");
		$c->exception('Invalid or expired problemJWT', 401);
		return;
	}

	# `typ` is an auth-shape claim and may live at either level. Check outer
	# first so a top-level mint isn't lost when we unwrap the provider envelope.
	my $outer_typ = $claims->{typ};

	# LibreTexts wraps problem-detail claims under a provider key.
	$claims = $claims->{webwork} if defined $claims->{webwork};

	my $actual_typ = $outer_typ // $claims->{typ} // '';
	if ($actual_typ ne $expected_typ) {
		$c->exception("Wrong typ: expected '$expected_typ', got '$actual_typ'", 401);
		return;
	}

	# Claims-always-win merge — same precedence as Lane::Problem. The token
	# binds the caller to a specific problem; a valid hint/solution token
	# cannot be redirected at a different source via form override.
	@{$params}{ keys %$claims } = values %$claims;

	$c->stash(_trust_lane => 'content_fetch');
	return 1;
}

1;
