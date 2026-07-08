package Renderer::Version;
use strict;
use warnings;

use Exporter 'import';
our @EXPORT_OK = qw(pg_version renderer_version renderer_release);

# PG version: PGcore sets $ENV{PG_VERSION} at module load from lib/PG/VERSION.
# 'unknown' before PGcore is loaded, which shouldn't happen in request paths
# but is defensible as a cold-start value.
sub pg_version { return $ENV{PG_VERSION} // 'unknown' }

# Renderer version: no built-in $VERSION; deployments set it via env from
# `git describe` at build (baked). This is the BUILD identity — the exact
# commit — and is what audit, telemetry, and federation registration report as
# the provenance of the running code. Falls back to 'unknown'.
sub renderer_version { return $ENV{VERSION} // 'unknown' }

# Release label (LTC-078): named at promote and injected at runtime via
# RELEASE_VERSION on the task def. Deploy is ecrpromote (retag, no rebuild), so
# the release is NOT known at build and cannot be baked — hence a runtime env,
# not $VERSION. undef until the promote step sets it. Reported on /health only;
# NOT used for audit/telemetry/federation, which want the exact commit.
sub renderer_release { return $ENV{RELEASE_VERSION} }

1;
