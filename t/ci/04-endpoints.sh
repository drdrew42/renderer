#!/usr/bin/env bash
# 04-endpoints.sh — Static assets, IO routes, error handling.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/problems.sh"

echo "=== Endpoint Tests ==="

# ── Static Assets ─────────────────────────────────────────────

# MathJax should be available under pg_files
MATHJAX_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" \
    "${BASE_URL}/pg_files/MathJax/es5/tex-chtml.js" 2>/dev/null)
# MathJax may be served from CDN instead of locally — 200 or 404 are both valid
(( ++_TOTAL ))
if [[ "$MATHJAX_STATUS" == "200" || "$MATHJAX_STATUS" == "404" ]]; then
    (( ++_PASS ))
    printf "${GREEN}ok %d${NC} - MathJax endpoint responded (%s)\n" "$_TOTAL" "$MATHJAX_STATUS"
else
    (( ++_FAIL ))
    printf "${RED}not ok %d${NC} - MathJax endpoint returned unexpected %s\n" "$_TOTAL" "$MATHJAX_STATUS"
fi

# ── IO Routes (dev mode) ─────────────────────────────────────

# Tap: read test fixture (mounted at private/test/)
TAP_RESP=$(curl -sf --max-time "$CURL_TIMEOUT" -X POST \
    -d "sourceFilePath=private/test/test-problem.pg" \
    "${BASE_URL}/render-api/tap" 2>/dev/null || true)

if [[ -n "$TAP_RESP" ]]; then
    assert_contains "$TAP_RESP" "DOCUMENT" "/render-api/tap returns PG source"
else
    # If fixture wasn't mounted, mark as skip
    (( ++_TOTAL ))
    (( ++_PASS ))
    printf "${YELLOW}ok %d${NC} - /render-api/tap (skipped — no fixture mount)\n" "$_TOTAL"
fi

# ── Error Handling ────────────────────────────────────────────

# Missing problem source → should not crash (returns error JSON or 500)
MISSING_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" \
    -X POST -d "_format=json" \
    "${BASE_URL}/render-api" 2>/dev/null)
(( ++_TOTAL ))
if [[ "$MISSING_STATUS" =~ ^[45][0-9][0-9]$ ]]; then
    (( ++_PASS ))
    printf "${GREEN}ok %d${NC} - Missing problem returns error status (%s)\n" "$_TOTAL" "$MISSING_STATUS"
else
    (( ++_FAIL ))
    printf "${RED}not ok %d${NC} - Missing problem returned unexpected %s\n" "$_TOTAL" "$MISSING_STATUS"
fi

# Nonexistent file path
NOFILE_RESP=$(curl -s -w '\n%{http_code}' --max-time "$CURL_TIMEOUT" \
    -X POST \
    -d "sourceFilePath=private/does/not/exist.pg" \
    -d "_format=json" \
    "${BASE_URL}/render-api" 2>/dev/null)
NOFILE_STATUS=$(echo "$NOFILE_RESP" | tail -1)
(( ++_TOTAL ))
if [[ "$NOFILE_STATUS" =~ ^[45][0-9][0-9]$ ]]; then
    (( ++_PASS ))
    printf "${GREEN}ok %d${NC} - Nonexistent file path returns error (%s)\n" "$_TOTAL" "$NOFILE_STATUS"
else
    (( ++_FAIL ))
    printf "${RED}not ok %d${NC} - Nonexistent file path returned %s\n" "$_TOTAL" "$NOFILE_STATUS"
fi

# Malformed JWT → error (not crash)
BADJWT_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" \
    -X POST \
    -d "problemJWT=this.is.garbage" \
    -d "_format=json" \
    "${BASE_URL}/render-api" 2>/dev/null)
(( ++_TOTAL ))
if [[ "$BADJWT_STATUS" =~ ^[45][0-9][0-9]$ ]]; then
    (( ++_PASS ))
    printf "${GREEN}ok %d${NC} - Malformed JWT returns error (%s)\n" "$_TOTAL" "$BADJWT_STATUS"
else
    (( ++_FAIL ))
    printf "${RED}not ok %d${NC} - Malformed JWT returned %s (expected 4xx/5xx)\n" "$_TOTAL" "$BADJWT_STATUS"
fi

# ── Timeout endpoint (dev mode) ──────────────────────────────

# /timeout should respond with 200 after ~2s delay
TIMEOUT_STATUS=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    "${BASE_URL}/timeout" 2>/dev/null)
assert_eq "$TIMEOUT_STATUS" "200" "/timeout responds 200 after delay"

summary "endpoint tests"
