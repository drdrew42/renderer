#!/usr/bin/env bash
# helpers.sh — Shared test utilities for renderer CI tests
# Provides HTTP helpers, assertion functions, and TAP-style output.

set -euo pipefail

BASE_URL="${BASE_URL:-http://localhost:3000}"
CURL_TIMEOUT="${CURL_TIMEOUT:-30}"

# Counters
_PASS=0
_FAIL=0
_TOTAL=0

# Colors (disabled if not a terminal)
if [[ -t 1 ]]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    NC='\033[0m'
else
    GREEN='' RED='' YELLOW='' NC=''
fi

# ── HTTP Helpers ──────────────────────────────────────────────

# render_raw PARAM=VALUE ...
# POST form params to /render-api with _format=json. Prints JSON response.
render_raw() {
    local data=()
    for param in "$@"; do
        data+=(--data-urlencode "$param")
    done
    data+=(--data-urlencode "_format=json")
    curl -sf --max-time "$CURL_TIMEOUT" -X POST "${data[@]}" "${BASE_URL}/render-api" 2>/dev/null
}

# render_via_jwe PARAM=VALUE ...
# First get JWE from /render-api/jwe, then render with problemJWT=<token>.
render_via_jwe() {
    local data=()
    for param in "$@"; do
        data+=(--data-urlencode "$param")
    done
    local token
    token=$(curl -sf --max-time "$CURL_TIMEOUT" -X POST "${data[@]}" "${BASE_URL}/render-api/jwe" 2>/dev/null)
    if [[ -z "$token" ]]; then
        echo "ERROR: Failed to get JWE token" >&2
        return 1
    fi
    curl -sf --max-time "$CURL_TIMEOUT" -X POST \
        -d "problemJWT=${token}" \
        -d "_format=json" \
        "${BASE_URL}/render-api" 2>/dev/null
}

# render_via_jws PARAM=VALUE ...
# Same as render_via_jwe but uses /render-api/jwt (HS256 signed).
render_via_jws() {
    local data=()
    for param in "$@"; do
        data+=(--data-urlencode "$param")
    done
    local token
    token=$(curl -sf --max-time "$CURL_TIMEOUT" -X POST "${data[@]}" "${BASE_URL}/render-api/jwt" 2>/dev/null)
    if [[ -z "$token" ]]; then
        echo "ERROR: Failed to get JWS token" >&2
        return 1
    fi
    curl -sf --max-time "$CURL_TIMEOUT" -X POST \
        -d "problemJWT=${token}" \
        -d "_format=json" \
        "${BASE_URL}/render-api" 2>/dev/null
}

# http_status METHOD URL [DATA_PARAMS...]
# Returns HTTP status code only.
http_status() {
    local method="$1" url="$2"
    shift 2
    local data=()
    for param in "$@"; do
        data+=(--data-urlencode "$param")
    done
    curl -s -o /dev/null -w '%{http_code}' --max-time "$CURL_TIMEOUT" \
        -X "$method" ${data[@]+"${data[@]}"} "${BASE_URL}${url}" 2>/dev/null
}

# http_get URL
# GET request, returns body.
http_get() {
    curl -sf --max-time "$CURL_TIMEOUT" "${BASE_URL}$1" 2>/dev/null
}

# ── Normalization ─────────────────────────────────────────────

# normalize_html HTML_STRING
# Reduces HTML to tag structure + text content, stripping attributes.
# This avoids false diffs from non-deterministic attribute ordering
# (Perl hash iteration order) while preserving structural differences
# like instructor-only elements, extra inputs, etc.
#
# Specifically:
#   1. Remove hidden inputs entirely (JWT tokens, session state)
#   2. Replace opening tags with just tag names: <div class="foo" id="bar"> → <div>
#   3. Collapse whitespace
normalize_html() {
    local html="$1"
    echo "$html" \
        | sed -E 's/<input[^>]*type="hidden"[^>]*>//g' \
        | sed -E 's/<(\/?)([a-zA-Z][a-zA-Z0-9]*)[^>]*>/<\1\2>/g' \
        | tr -s '[:space:]' ' ' \
        | sed 's/^ //;s/ $//'
}

# hash_html JSON_RESPONSE
# Extract .renderedHTML, normalize, sha256sum.
hash_html() {
    local json="$1"
    local html
    html=$(echo "$json" | jq -r '.renderedHTML // empty')
    if [[ -z "$html" ]]; then
        echo "ERROR: No renderedHTML in response" >&2
        return 1
    fi
    normalize_html "$html" | shasum -a 256 | awk '{print $1}'
}

# ── Assertions ────────────────────────────────────────────────

# assert_eq ACTUAL EXPECTED DESCRIPTION
assert_eq() {
    local actual="$1" expected="$2" desc="$3"
    (( _TOTAL++ ))
    if [[ "$actual" == "$expected" ]]; then
        (( _PASS++ ))
        printf "${GREEN}ok %d${NC} - %s\n" "$_TOTAL" "$desc"
    else
        (( _FAIL++ ))
        printf "${RED}not ok %d${NC} - %s\n" "$_TOTAL" "$desc"
        printf "  expected: %s\n  got:      %s\n" "$expected" "$actual"
    fi
}

# assert_ne ACTUAL UNEXPECTED DESCRIPTION
assert_ne() {
    local actual="$1" unexpected="$2" desc="$3"
    (( _TOTAL++ ))
    if [[ "$actual" != "$unexpected" ]]; then
        (( _PASS++ ))
        printf "${GREEN}ok %d${NC} - %s\n" "$_TOTAL" "$desc"
    else
        (( _FAIL++ ))
        printf "${RED}not ok %d${NC} - %s\n" "$_TOTAL" "$desc"
        printf "  expected anything except: %s\n" "$unexpected"
    fi
}

# assert_status METHOD URL EXPECTED_STATUS DESCRIPTION [DATA_PARAMS...]
assert_status() {
    local method="$1" url="$2" expected="$3" desc="$4"
    shift 4
    local status
    status=$(http_status "$method" "$url" "$@")
    assert_eq "$status" "$expected" "$desc"
}

# assert_contains HAYSTACK NEEDLE DESCRIPTION
assert_contains() {
    local haystack="$1" needle="$2" desc="$3"
    (( _TOTAL++ ))
    if [[ "$haystack" == *"$needle"* ]]; then
        (( _PASS++ ))
        printf "${GREEN}ok %d${NC} - %s\n" "$_TOTAL" "$desc"
    else
        (( _FAIL++ ))
        printf "${RED}not ok %d${NC} - %s\n" "$_TOTAL" "$desc"
        printf "  expected to contain: %s\n" "$needle"
    fi
}

# assert_json_field JSON_STRING JQ_FILTER DESCRIPTION
# Passes if jq filter returns non-null, non-empty.
assert_json_field() {
    local json="$1" filter="$2" desc="$3"
    local val
    val=$(echo "$json" | jq -r "$filter // empty" 2>/dev/null)
    (( _TOTAL++ ))
    if [[ -n "$val" ]]; then
        (( _PASS++ ))
        printf "${GREEN}ok %d${NC} - %s\n" "$_TOTAL" "$desc"
    else
        (( _FAIL++ ))
        printf "${RED}not ok %d${NC} - %s\n" "$_TOTAL" "$desc"
        printf "  jq filter '%s' returned empty\n" "$filter"
    fi
}

# assert_json_eq JSON_STRING JQ_FILTER EXPECTED DESCRIPTION
assert_json_eq() {
    local json="$1" filter="$2" expected="$3" desc="$4"
    local val
    val=$(echo "$json" | jq -r "$filter // empty" 2>/dev/null)
    assert_eq "$val" "$expected" "$desc"
}

# ── Summary ───────────────────────────────────────────────────

summary() {
    local suite="${1:-tests}"
    echo ""
    if (( _FAIL > 0 )); then
        printf "${RED}FAIL${NC}: %d/%d %s passed\n" "$_PASS" "$_TOTAL" "$suite"
        return 1
    else
        printf "${GREEN}PASS${NC}: %d/%d %s passed\n" "$_PASS" "$_TOTAL" "$suite"
        return 0
    fi
}
