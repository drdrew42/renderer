package Renderer::Version;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(pg_version renderer_version);

# PG version: PGcore sets $ENV{PG_VERSION} at module load from lib/PG/VERSION.
# 'unknown' before PGcore is loaded, which shouldn't happen in request paths
# but is defensible as a cold-start value.
sub pg_version { return $ENV{PG_VERSION} // 'unknown' }

# Renderer version: no built-in $VERSION; deployments may set via env.
# Falls back to 'unknown' rather than guessing.
sub renderer_version { return $ENV{RENDERER_VERSION} // 'unknown' }

1;
