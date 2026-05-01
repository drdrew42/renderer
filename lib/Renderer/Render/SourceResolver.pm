package Renderer::Render::SourceResolver;
use Mojo::Base -async_await, -signatures;

# Source resolution for the render pipeline.
#
# Three entry shapes the `problem` action must handle:
#
#   1. problemSourceURL — fetch raw source over HTTP (legacy mode) or
#      content-addressed (CONTENT_ADDRESSED + cache flow).
#   2. sourceFilePath (CONTENT_ADDRESSED) — resolve via OPL path index;
#      sub-cases: editor preview (keep editor's source, just resolve macro
#      pg_hash) vs. normal render (fetch source + macros from OPL).
#   3. problemSource bytes already in hand — nothing to resolve.
#
# `resolve_source` is the single entry point. The five fetch helpers below
# are the cache flow primitives used by both URL and path resolution paths.
# Moved out of Renderer::Controller::Render in WW3-R33.

use Mojo::Promise;
use Mojo::JSON qw(encode_json);

use Renderer::ContentCache;

use Exporter qw(import);
our @EXPORT_OK = qw(
	resolve_source
	fetch_remote_source_p
	resolve_source_file_path_p
);

# Mutates $inputs_ref to populate problemSource / sourceFilePath / pg_hash
# from whichever entry shape was supplied. Returns 1 on success or undef on
# failure (after $c->exception has rendered the error). Caller bails with
# `return unless $resolved`.
async sub resolve_source ($c, $inputs_ref) {

	if ($inputs_ref->{problemSourceURL}) {
		my ($source, $pg_hash)
			= await fetch_remote_source_p($c, $inputs_ref->{problemSourceURL}, $inputs_ref->{pg_hash});
		return $c->exception('Failed to retrieve problem source.', 500) unless $source;

		$inputs_ref->{problemSource} = $source;
		if ($pg_hash) {
			$inputs_ref->{pg_hash}        = $pg_hash;
			$inputs_ref->{sourceFilePath} = Renderer::ContentCache::problem_path($pg_hash);
		} else {
			$c->log->info("Problem source fetched from $inputs_ref->{problemSourceURL}");
		}
		return 1;
	}

	if ($ENV{CONTENT_ADDRESSED} && $inputs_ref->{sourceFilePath}) {
		if ($inputs_ref->{problemSource}) {
			# Editor preview: use the editor's source but resolve the path
			# for macro dependencies (pg_hash → injectedMacros at render time).
			my (undef, $pg_hash)
				= await resolve_source_file_path_p($c, $inputs_ref->{sourceFilePath}, $inputs_ref->{pg_hash});
			if ($pg_hash) {
				$inputs_ref->{pg_hash}        = $pg_hash;
				$inputs_ref->{sourceFilePath} = Renderer::ContentCache::problem_path($pg_hash);
			}
			return 1;
		}

		my ($source, $pg_hash)
			= await resolve_source_file_path_p($c, $inputs_ref->{sourceFilePath}, $inputs_ref->{pg_hash});
		return $c->exception("Cannot resolve sourceFilePath: $inputs_ref->{sourceFilePath}", 404)
			unless $source && $pg_hash;

		$inputs_ref->{problemSource}  = $source;
		$inputs_ref->{sourceFilePath} = Renderer::ContentCache::problem_path($pg_hash);
		$inputs_ref->{pg_hash}        = $pg_hash;
		return 1;
	}

	# problemSource bytes already in hand (peer-signed body, JWT claim, etc.).
	return 1;
}

sub fetch_remote_source_p ($c, $url, $pg_hash_hint = undef) {

	# Content-addressed mode: check disk cache first (unless noCache)
	if ($ENV{CONTENT_ADDRESSED}) {
		my $no_cache = $c->stash('_no_cache');

		# Try to resolve pg_hash from hint or url_index
		my $pg_hash = $pg_hash_hint || Renderer::ContentCache::pg_hash_for_url($url);

		if (!$no_cache && $pg_hash && Renderer::ContentCache::has_problem($pg_hash)) {
			my $cached_source = Renderer::ContentCache::read_problem($pg_hash);
			if ($cached_source) {
				$c->log->info("ContentCache HIT: $pg_hash (zero network)");
				$c->stash(_cache_status => 'hit');
				return Mojo::Promise->resolve($cached_source, $pg_hash);
			}
		}

		# Cache miss (or noCache forced) — fetch with conditional GET
		$c->log->info("ContentCache BYPASS (noCache)") if $no_cache;
		return _fetch_content_addressed_p($c, $url, $no_cache ? undef : $pg_hash);
	}

	# Legacy mode: unchanged behavior
	return _fetch_legacy_p($c, $url)->then(sub { return (shift, undef) });
}

# Content-addressed fetch: conditional GET, stage problem + macros on 200.
# Returns promise resolving to ($raw_source, $pg_hash).
sub _fetch_content_addressed_p ($c, $url, $pg_hash) {
	my %meta = (
		origin   => $c->req->headers->origin,
		referrer => $c->req->headers->referrer,
	);

	my $client = $c->opl_client;
	return $client->fetch_problem_p($url, etag => $pg_hash, request_meta => \%meta)->then(sub {
		my $result = shift;

		# 304 Not Modified — use cached source.
		if ($result->{not_modified} && $pg_hash) {
			my $cached_source = Renderer::ContentCache::read_problem($pg_hash);
			if ($cached_source) {
				$c->log->info("ContentCache 304: $pg_hash");
				$c->stash(_cache_status => 'miss_304');
				return ($cached_source, $pg_hash);
			}
			# Cache index thought we had it (we sent If-None-Match) but the
			# bytes are missing on disk. Force an unconditional re-fetch.
			$c->log->warn("ContentCache 304 but disk miss for $pg_hash — retrying unconditional");
			return $client->fetch_problem_p($url, request_meta => \%meta)->then(sub {
				my $retry = shift;
				return (undef, undef) if $retry->{error} || $retry->{not_modified};
				return _stage_problem_response($c, $retry, $url);
			});
		}

		if ($result->{error}) {
			return (undef, undef);
		}

		return _stage_problem_response($c, $result, $url);
	});
}

# Stage the OPL response into the disk cache and return (raw_source, hash).
# Filters macros by source_type before staging — current renderer-side semantic
# is "inject custom + override only." The filtering rule lives here, not in
# OPLClient (per R12 design: client captures verbatim, controller decides what
# to do with it).
sub _stage_problem_response ($c, $result, $url) {
	my $raw_source   = $result->{raw_source};
	my $fetched_hash = $result->{pg_hash};
	my $client       = $c->opl_client;

	my @macros_to_link;
	for my $macro (@{ $result->{macros} // [] }) {
		next unless $macro->{hash} && $macro->{source_type}
			&& ($macro->{source_type} eq 'custom' || $macro->{source_type} eq 'override');

		my $cache_hash = $macro->{hash};

		unless (-f "$ENV{RENDER_ROOT}/private/macros/$cache_hash") {
			if ($macro->{url}) {
				$c->log->info("Fetching macro $macro->{name}: $macro->{url}");
				my ($source_bytes, $canonical_hash) = $client->fetch_macro($macro->{url});
				if (defined $source_bytes) {
					if ($canonical_hash && $canonical_hash ne $macro->{hash}) {
						$c->log->info("Macro $macro->{name}: redirected $macro->{hash} → $canonical_hash");
						$cache_hash = $canonical_hash;
					}
					Renderer::ContentCache::stage_macro($cache_hash, $source_bytes);
				} else {
					$c->log->warn("ContentCache: failed to fetch macro $macro->{name}");
				}
			}
		}

		push @macros_to_link, {
			name        => $macro->{name},
			hash        => $cache_hash,
			source_type => $macro->{source_type},
		};
	}

	Renderer::ContentCache::stage_problem($fetched_hash, $raw_source, \@macros_to_link);
	Renderer::ContentCache::save_url_index($url, $fetched_hash);
	$c->log->info("ContentCache STAGED: $fetched_hash from $url");
	$c->stash(_cache_status => 'miss_200');

	return ($raw_source, $fetched_hash);
}

# Legacy fetch: no caching, no macro staging — just the raw_source field
# from a JSON response. Returns a promise resolving to source bytes or undef.
sub _fetch_legacy_p ($c, $url) {
	my %meta = (
		origin   => $c->req->headers->origin,
		referrer => $c->req->headers->referrer,
	);
	return $c->opl_client->fetch_problem_p($url, request_meta => \%meta)->then(sub {
		my $result = shift;
		return undef if $result->{error} || $result->{not_modified};
		return $result->{raw_source};
	});
}

sub resolve_source_file_path_p ($c, $file_path, $pg_hash_hint = undef) {

	# Normalize: strip leading private/ if present (Problem.pm adds it)
	my $normalized = $file_path;
	$normalized =~ s!^private/!!;

	# 1. Path index + cache — zero network (unless noCache)
	my $no_cache = $c->stash('_no_cache');
	my $pg_hash = $no_cache ? undef : ($pg_hash_hint || Renderer::ContentCache::pg_hash_for_path($normalized));
	if (!$no_cache && $pg_hash && Renderer::ContentCache::has_problem($pg_hash)) {
		my $cached_source = Renderer::ContentCache::read_problem($pg_hash);
		if ($cached_source) {
			$c->log->info("ContentCache PATH HIT: $pg_hash (zero network)");
			$c->stash(_cache_status => 'hit');
			return Mojo::Promise->resolve($cached_source, $pg_hash, undef);
		}
	}

	# 2. OPL lookup — delegate to existing fetch flow with client-built URL
	my $opl_url = $c->opl_client->problem_url_by_path($normalized);

	$c->log->info("sourceFilePath OPL lookup: $opl_url");

	return _fetch_content_addressed_p($c, $opl_url, $pg_hash)->then(sub {
		my ($source, $fetched_hash) = @_;
		if ($source && $fetched_hash) {
			Renderer::ContentCache::save_path_index($normalized, $fetched_hash);
		}
		return ($source, $fetched_hash, undef);
	});
}

1;
