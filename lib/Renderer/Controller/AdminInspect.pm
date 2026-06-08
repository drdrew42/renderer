package Renderer::Controller::AdminInspect;
use Mojo::Base 'Mojolicious::Controller', -signatures;

# POST /render-api/admin/inspect-cache
#
# WW3-R42: signed introspection of the per-pg_hash content cache. Lets
# operators check manifest contents, disk presence of each macro, and
# source-vs-manifest consistency without ECS Exec.
#
# Body: { pg_hash: "sha256:..." }
# Auth: Ed25519-signed by OPL (same prelude as /render-api/callback).
#
# Response:
#   {
#     pg_hash: "...",
#     exists: true/false,         # cache dir present
#     consistent: true/false,
#     report: {
#       manifest: [...],
#       macros_on_disk: [...],
#       macros_missing_from_disk: [...],
#       source_load_macros: [...],
#       load_macros_not_in_manifest: [...],
#     }
#   }
#
# When the cache dir is absent (`exists: false`), `consistent: false` and
# the report carries `reason: no_problem_dir` — same shape as a stale dir
# so callers can branch uniformly.

use Renderer::ContentCache;
use Renderer::OPLAuthed qw(verify_request);

sub inspectCache ($c) {
	my $req = verify_request($c) or return;

	my $pg_hash = $req->{pg_hash};
	unless ($pg_hash) {
		return $c->render(json => { error => 'missing pg_hash' }, status => 400);
	}

	my $exists = Renderer::ContentCache::has_problem($pg_hash);
	my ($ok, $report) = Renderer::ContentCache::verify_consistent($pg_hash);

	return $c->render(
		json => {
			pg_hash    => $pg_hash,
			exists     => $exists ? \1 : \0,
			consistent => $ok     ? \1 : \0,
			report     => $report,
		}
	);
}

1;
