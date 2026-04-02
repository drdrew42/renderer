#!/usr/bin/env bash
# run-all.sh — Build, start container, run all test suites, report results.
# Usage: bash t/ci/run-all.sh [--no-build] [--no-pg-tests]
#
# Environment:
#   CONTAINER_NAME  — name for the test container (default: renderer-test)
#   IMAGE_NAME      — Docker image name (default: renderer-test)
#   BASE_URL        — override renderer URL (default: http://localhost:3000)
#   SKIP_BUILD      — set to 1 to skip Docker build
#   SKIP_PG_TESTS   — set to 1 to skip PG unit tests

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONTAINER_NAME="${CONTAINER_NAME:-renderer-test}"
IMAGE_NAME="${IMAGE_NAME:-renderer-test}"
export BASE_URL="${BASE_URL:-http://localhost:3000}"
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_PG_TESTS="${SKIP_PG_TESTS:-0}"

# Parse flags
for arg in "$@"; do
    case "$arg" in
        --no-build)    SKIP_BUILD=1 ;;
        --no-pg-tests) SKIP_PG_TESTS=1 ;;
    esac
done

OVERALL_EXIT=0

# ── Cleanup on exit ──────────────────────────────────────────
cleanup() {
    echo ""
    echo "=== Cleanup ==="
    if docker ps -q --filter "name=${CONTAINER_NAME}" | grep -q .; then
        docker stop "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    if docker ps -aq --filter "name=${CONTAINER_NAME}" | grep -q .; then
        docker rm "$CONTAINER_NAME" >/dev/null 2>&1 || true
    fi
    echo "Container cleaned up."
}
trap cleanup EXIT

# ── Build ────────────────────────────────────────────────────
if [[ "$SKIP_BUILD" != "1" ]]; then
    echo "=== Building Docker image ==="
    docker build -t "$IMAGE_NAME" "$REPO_ROOT"
    echo "Build complete."
else
    echo "=== Skipping Docker build ==="
fi

# ── Start Container ──────────────────────────────────────────
echo ""
echo "=== Starting container ==="

# Stop any existing container with the same name
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# Use morbo for single-process, deterministic startup.
# Mount fixtures at private/test/ for IO tests.
docker run -d \
    --name "$CONTAINER_NAME" \
    -p 3000:3000 \
    -e MOJO_MODE=development \
    -v "${SCRIPT_DIR}/fixtures:/usr/app/private/test:ro" \
    "$IMAGE_NAME" \
    morbo -l 'http://*:3000' ./script/render_app

echo "Container started. Waiting for health..."

# ── Health Poll ──────────────────────────────────────────────
MAX_ATTEMPTS=30
POLL_INTERVAL=2
for i in $(seq 1 $MAX_ATTEMPTS); do
    if curl -sf --max-time 5 "${BASE_URL}/health" >/dev/null 2>&1; then
        echo "Renderer healthy after $((i * POLL_INTERVAL))s."
        break
    fi
    if [[ $i -eq $MAX_ATTEMPTS ]]; then
        echo "FATAL: Renderer failed to start after $((MAX_ATTEMPTS * POLL_INTERVAL))s"
        echo "Container logs:"
        docker logs "$CONTAINER_NAME" 2>&1 | tail -50
        exit 1
    fi
    sleep "$POLL_INTERVAL"
done

# ── PG Unit Tests (informational) ─────────────────────────────
# PG has its own test suite under lib/PG/t/. We run it here for visibility,
# but failures do NOT block the renderer CI. PG test health is upstream's
# responsibility (openwebwork/pg). We skip directories that need external
# services (R for rserve/, xelatex for tikz_test/) since those aren't
# installed in the renderer image.
if [[ "$SKIP_PG_TESTS" != "1" ]]; then
    echo ""
    echo "=== PG Unit Tests (informational — does not block CI) ==="
    if docker exec "$CONTAINER_NAME" bash -c \
        'export PG_ROOT=/usr/app/lib/PG && cd $PG_ROOT && prove -lr \
            t/macros t/contexts t/math_objects t/pg_problems t/units 2>&1'; then
        echo "PG unit tests passed."
    else
        echo "PG unit tests had failures (see above). This is informational only."
    fi
else
    echo ""
    echo "=== Skipping PG unit tests ==="
fi

# ── Integration Test Suites ──────────────────────────────────
run_suite() {
    local script="$1"
    local name
    name="$(basename "$script" .sh)"
    echo ""
    echo "────────────────────────────────────────"
    if bash "$script"; then
        echo "Suite $name: PASS"
    else
        echo "Suite $name: FAIL"
        OVERALL_EXIT=1
    fi
}

run_suite "$SCRIPT_DIR/01-smoke.sh"
run_suite "$SCRIPT_DIR/02-render-parity.sh"
run_suite "$SCRIPT_DIR/03-answer-cycle.sh"
run_suite "$SCRIPT_DIR/04-endpoints.sh"

# ── Final Report ─────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════"
if [[ $OVERALL_EXIT -eq 0 ]]; then
    echo "ALL SUITES PASSED"
else
    echo "SOME SUITES FAILED"
fi
echo "════════════════════════════════════════"

exit $OVERALL_EXIT
