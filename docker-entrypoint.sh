#!/bin/bash
# docker-entrypoint.sh — pre-launch tasks for the renderer container.
#
# Responsibilities:
#   1. Wipe the on-disk content cache by default (opt out with PRESERVE_CACHE),
#      so a fresh deploy never serves stale content from a prior format/version.
#   2. Apply the RSERVE_HOST override to lib/PG/conf/pg_config.yml when set
#      (was previously inlined in the Dockerfile CMD).
#   3. exec the passed-in CMD (hypnotoad) so signals propagate cleanly.

set -e

RENDER_ROOT="${RENDER_ROOT:-/usr/app}"

# A. Cache wipe (default-on, opt-out via PRESERVE_CACHE)
if [ -z "$PRESERVE_CACHE" ]; then
    rm -rf "$RENDER_ROOT/private/problems" "$RENDER_ROOT/private/macros"
    echo "[entrypoint] content cache wiped (PRESERVE_CACHE unset)"
else
    echo "[entrypoint] content cache preserved (PRESERVE_CACHE=$PRESERVE_CACHE)"
fi

# B. RSERVE_HOST substitution
if [ -n "$RSERVE_HOST" ]; then
    sed -i "s/host: webwork-rserve/host: $RSERVE_HOST/" lib/PG/conf/pg_config.yml
    echo "[entrypoint] applied RSERVE_HOST override: $RSERVE_HOST"
fi

# C. Hand off to CMD
exec "$@"
