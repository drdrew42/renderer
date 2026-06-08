package Renderer::Render::AnswerURL;
use Mojo::Base -async_await, -signatures;

# Answer-URL postback for the `problem` action.
#
# When a render carries JWTanswerURL + submitAnswers, the renderer POSTs the
# answer envelope back to the URL declared in the upstream JWT. Two envelope
# shapes share one HTTP path:
#
#   * legacy problemJWT: raw answerJWT body, text/plain.
#   * challengeJWT:      JSON envelope { type, session_jwt, submission_jwt },
#                        with a post-POST verdict fold (WW3-053) when the
#                        orchestrator returns verdict_signed.
#
# `process` is the single entry point used by the `problem` action; it
# dispatches by the presence of `submissionJWT` in the rendered envelope.
# Moved out of Renderer::Controller::Render in WW3-R33.

use Mojo::JSON qw(encode_json);

use WeBWorK::VerdictJWT qw(verifyAndFoldVerdict);
use Renderer::Constants qw(
	ANSWER_RESPONSE_SUBJECT
	ANSWER_RESPONSE_DEFAULT_MESSAGE
);

use Exporter qw(import);
our @EXPORT_OK = qw(process post_p encode_status);

# Dispatcher: pick the right envelope based on what the render produced,
# POST it, fold any returned verdict, and stash the encoded status onto
# $return_object->{JWTanswerURLstatus}.
#
# Caller (Controller::Render::problem) has already verified that
# JWTanswerURL is set, submitAnswers is set, and _can_emit_answer_jwt is
# stashed. This module is the dumb messenger.
async sub process ($c, $inputs_ref, $return_object) {
	if ($return_object->{submissionJWT}) {
		# challengeJWT path: POST {type, session_jwt, submission_jwt} envelope
		# to challengeJWT.answer_url (per Answer-URL Contract).
		my $envelope_body = encode_json({
			type           => 'submission',
			session_jwt    => $return_object->{sessionJWT},
			submission_jwt => $return_object->{submissionJWT},
		});
		my $resp = await post_p($c, $inputs_ref->{JWTanswerURL}, $envelope_body);

		# Post-answer-URL verdict fold (WW3-053). When the orchestrator
		# returns verdict_signed alongside the verdict, mint sessionJWT_{k+1}
		# folding it. Same primitive as the render-time fold in parseRequest
		# — different source of verdict_signed (HTTP response body vs form
		# param), identical fold semantics. The result replaces
		# $return_object->{sessionJWT} so the rendered JSON envelope's
		# JWT.session carries the verdict-folded mint.
		#
		# Skip the fold on:
		#   - rejected/error responses (no verdict to fold; keep the
		#     pre-POST mint as the surfaced session)
		#   - missing verdict_signed (orchestrator below WW3-053 cutover,
		#     or non-WW3 answer_url targets — graceful degradation: the
		#     pre-POST mint stays surfaced, system catches up on next
		#     interaction via stale-recovery)
		if ($resp->{verdict_signed}) {
			my ($folded, $err) = verifyAndFoldVerdict(
				$return_object->{sessionJWT}, $resp->{verdict_signed},
				$ENV{problemJWTsecret},       $ENV{webworkJWTsecret},
			);
			if ($err) {
				$c->log->error("post-answer-URL verdict fold rejected: $err");
				# Don't fail the whole render — the submission landed and
				# the pre-POST mint is still a valid sessionJWT (just one
				# verdict behind). Stale-recovery handles the catch-up.
			} else {
				$return_object->{sessionJWT} = $folded;
			}
		}

		$return_object->{JWTanswerURLstatus} = encode_status($resp);
		return 1;
	}

	# Legacy problemJWT path: POST raw answerJWT to JWTanswerURL as
	# text/plain. The body is the JWT string itself (not a JSON envelope).
	my $resp =
		await post_p($c, $inputs_ref->{JWTanswerURL}, $return_object->{answerJWT}, content_type => 'text/plain',);
	$return_object->{JWTanswerURLstatus} = encode_status($resp);
	return 1;
}

# Single helper for the renderer's answer-URL POSTs. Both lanes — legacy
# problemJWT (raw JWT body, text/plain) and challengeJWT (JSON envelope,
# application/json) — share the same UA setup, default-response shape, and
# success/failure handling. The only differences are the body format and
# content-type, both controlled by callers.
#
# Always resolves to a hashref. Caller decides what to do with it:
# legacy lane runs encode_status and stores the JS-safe string in
# JWTanswerURLstatus; challengeJWT lane consults $resp->{verdict_signed}
# for the post-POST fold before encoding.
async sub post_p ($c, $url, $body, %opts) {
	my $headers = {
		Origin         => $ENV{SITE_HOST},
		'Content-Type' => $opts{content_type} // 'application/json',
	};

	my $response = {
		subject => ANSWER_RESPONSE_SUBJECT,
		message => ANSWER_RESPONSE_DEFAULT_MESSAGE,
	};

	$c->log->info("POSTing to $url");
	await $c->ua->max_redirects(5)->request_timeout(7)->post_p($url, $headers, $body)->then(sub {
		my $tx = shift->result;
		$response->{status} = int($tx->code);
		# answerURL responses are expected to be JSON; fall back to body-as-message.
		if ($tx->json) {
			$response = { %$response, %{ $tx->json } };
		} else {
			$response->{message} = $tx->body;
		}
	})->catch(sub {
		my $err = shift;
		$c->log->error($err);
		$response->{status}  = 500;
		$response->{message} = '[' . $c->logID . '] ' . $err;
	});

	$c->log->info("answer-URL response " . encode_json($response));
	return $response;
}

# Encode a response hashref as the JSON string that goes into the
# JWTanswerURLstatus hidden form field. Mojo's `hidden_field` helper handles
# HTML-attribute escaping in default.html.ep — no JS-source-literal escape
# is needed: the client reads `.value` and JSON.parses, so single quotes in
# the payload round-trip unmolested.
sub encode_status ($response) {
	return encode_json($response);
}

1;
