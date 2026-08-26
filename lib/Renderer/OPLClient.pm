package Renderer::OPLClient;

# Encapsulates the renderer's view of OPL's HTTP contract:
#
#   * URL templates (problem-by-hash, problem-by-path, macro-by-url).
#   * Conditional GET via If-None-Match for content-addressed problem fetches.
#   * Macro-fetch redirect canonicalization (OPL redirects macro-by-name to
#     macro-by-hash; the canonical hash lives in the final URL).
#   * JSON response shape parsing for problem fetches (raw_source, pg_hash,
#     macros — captured verbatim, no schema validation).
#
# What the client does NOT own:
#
#   * The renderer's filtering rule for which `source_type` macros to stage
#     and inject — that's a code-level renderer-side semantic that lives in
#     `Renderer::Controller::Render::_parse_and_stage_response`.
#   * Local cache staging (`Renderer::ContentCache::stage_problem` /
#     `stage_macro`) — the controller orchestrates fetch → stage.
#   * Promise composition / async control flow above the single-request
#     level — caller awaits the promise the client returns.
#
# Construction:
#   Renderer::OPLClient->new(
#       ua       => $self->ua,                 # Mojo::UserAgent
#       base_url => $ENV{OPL_API_URL} || Renderer::OPLClient::DEFAULT_BASE_URL,
#       log      => $self->log,
#   );

use strict;
use warnings;
use feature qw(signatures state);
no warnings qw(experimental::signatures);

use Mojo::JSON qw(decode_json);
use Mojo::Promise;

# Homelab default OPL host. The single source of truth for the fallback the
# renderer uses when OPL_API_URL is unset; the app callsite (Renderer.pm) reads
# it too rather than re-typing the literal.
use constant DEFAULT_BASE_URL => 'http://webwork-opl:3000';

sub new ($class, %args) {
	my $base_url = $args{base_url} // DEFAULT_BASE_URL;
	$base_url =~ s!/+$!!;    # strip trailing slash; URL templates re-add as needed
	return bless {
		ua       => $args{ua},
		base_url => $base_url,
		log      => $args{log},
	}, $class;
}

# ─── URL templates ─────────────────────────────────────────────────────────
#
# Exposed so callers that originate a URL (parseRequest's challengeJWT branch,
# resolveSourceFilePath_p) can build one without re-encoding the API contract
# inline. The fetch methods below take a fully-qualified URL — they don't care
# whether the caller built it via these helpers or got it from elsewhere
# (e.g. an upstream JWT-supplied problemSourceURL).

sub problem_url_by_hash ($self, $pg_hash) {
	return "$self->{base_url}/api/problems/hash/$pg_hash";
}

sub problem_url_by_path ($self, $path) {
	return "$self->{base_url}/api/problems/path/$path";
}

# ─── Problem fetch ─────────────────────────────────────────────────────────
#
# fetch_problem_p($url, etag => $pg_hash, request_meta => { origin, referrer })
#
# Returns a Mojo::Promise that resolves to a hashref with one of these shapes:
#
#   { not_modified => 1 }                                       # 304
#   { raw_source => $bytes, pg_hash => $hash, macros => $aref } # 200 OK
#   { error => $msg, status => $code }                          # 4xx/5xx/parse
#
# The 304 → "use your cache" path is the caller's responsibility — the client
# doesn't know what's on disk. If the caller's cache is also missing the
# bytes, the caller should re-call fetch_problem_p without `etag` to force an
# unconditional fetch.

sub fetch_problem_p ($self, $url, %opts) {
	my $headers = $self->_default_headers($opts{request_meta});
	$headers->{'If-None-Match'} = $opts{etag} if $opts{etag};

	return $self->{ua}->max_redirects(5)->request_timeout(10)->get_p($url => $headers)->then(sub {
		my $tx  = shift;
		my $res = $tx->result;

		return { not_modified => 1 } if $res->code == 304;

		unless ($res->is_success) {
			$self->_log->error("OPLClient: GET $url failed - " . $res->message);
			return { error => $res->message, status => $res->code };
		}

		my $obj;
		eval { $obj = decode_json($res->body); 1; } or do {
			$self->_log->error("OPLClient: failed to parse JSON from $url");
			return { error => "JSON parse failure: $@", status => 502 };
		};

		my $raw_source   = $obj->{raw_source};
		my $fetched_hash = $obj->{pg_hash} || $res->headers->header('ETag');

		unless ($raw_source && $fetched_hash) {
			$self->_log->warn("OPLClient: response from $url missing raw_source or pg_hash");
			return { error => 'malformed response', status => 502 };
		}

		return {
			raw_source => $raw_source,
			pg_hash    => $fetched_hash,
			macros     => $obj->{macros} // [],
		};
	})->catch(sub {
		my $err = shift;
		$self->_log->error("OPLClient: GET $url threw - $err");
		return { error => $err, status => 0 };
	});
}

# ─── Macro fetch ───────────────────────────────────────────────────────────
#
# fetch_macro($macro_url) → ($source_bytes, $canonical_hash) or () on failure
#
# Synchronous. The macro endpoint redirects from name-form URLs to
# hash-form URLs (e.g. /api/macros/<name> → /api/macros/sha256:<hash>);
# the canonical hash is extracted from the final URL after redirects.
#
# Relative URLs (paths starting with `/`) are resolved against the
# configured OPL base. Absolute URLs are used as-is.
#
# Kept synchronous to match the existing controller's serial macro-fetch
# loop — turning this into a promise-based fan-out would be a meaningful
# parallelism improvement but is out of scope for the extraction (R12).

sub fetch_macro ($self, $macro_url) {
	my $url = $self->_absolute_url($macro_url);
	# Explicitly enable redirects: this method's contract is to canonicalize
	# name-form URLs via OPL's 302→hash-form redirect. Without this, callers
	# that hit fetch_macro before any fetch_problem_p call would silently get
	# the 302 body (not the canonical macro). The shared UA's max_redirects
	# is sticky once set; previously this method worked by accident because
	# fetch_problem_p set it first in the typical request order.
	my $tx  = $self->{ua}->max_redirects(5)->get($url);
	my $res = eval { $tx->result };
	unless ($res) {
		# Transport failure — $tx->result croaks on a connection error. Match
		# fetch_problem_p's catch: log and return () so the caller's serial
		# macro loop degrades instead of dying.
		$self->_log->warn("OPLClient: transport failure fetching macro from $url - $@");
		return ();
	}

	unless ($res->is_success) {
		$self->_log->warn("OPLClient: failed to fetch macro from $url");
		return ();
	}

	my $final_url = $tx->req->url->to_string;
	my ($canonical_hash) = $final_url =~ m{/api/macros/(sha256:[0-9a-f]+)$};

	return ($res->body, $canonical_hash);
}

# ─── Internals ─────────────────────────────────────────────────────────────

sub _absolute_url ($self, $url) {
	return $url unless $url =~ m{^/};
	return "$self->{base_url}$url";
}

sub _default_headers ($self, $meta) {
	$meta //= {};
	return {
		Accept    => 'application/json;charset=utf-8',
		Requester => $meta->{origin}   // 'no origin',
		Referrer  => $meta->{referrer} // 'no referrer',
	};
}

sub _log ($self) {
	return $self->{log} // do {
		require Mojo::Log;
		state $fallback;
		$fallback //= Mojo::Log->new;
		$fallback;
	};
}

1;
