#!/usr/bin/env bash
# 02-render-parity.sh — Verify raw params vs JWT produce identical rendered output.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/problems.sh"

echo "=== Render Parity Tests ==="

# Helper: compare raw render vs JWE render for a given set of params.
# Usage: parity_test DESCRIPTION PARAM...
parity_test_jwe() {
    local desc="$1"
    shift
    local raw_resp jwe_resp raw_hash jwe_hash

    raw_resp=$(render_raw "$@")
    jwe_resp=$(render_via_jwe "$@")

    raw_hash=$(hash_html "$raw_resp")
    jwe_hash=$(hash_html "$jwe_resp")

    assert_eq "$jwe_hash" "$raw_hash" "JWE parity: $desc"
}

parity_test_jws() {
    local desc="$1"
    shift
    local raw_resp jws_resp raw_hash jws_hash

    raw_resp=$(render_raw "$@")
    jws_resp=$(render_via_jws "$@")

    raw_hash=$(hash_html "$raw_resp")
    jws_hash=$(hash_html "$jws_resp")

    assert_eq "$jws_hash" "$raw_hash" "JWS parity: $desc"
}

# Basic problem, default params
parity_test_jwe "basic problem, defaults" \
    "problemSource=${PROBLEM_BASIC}" "problemSeed=42"

# Basic problem with isInstructor
parity_test_jwe "basic problem, isInstructor=1" \
    "problemSource=${PROBLEM_BASIC}" "problemSeed=42" "isInstructor=1"

# Basic problem with showCorrectAnswers
parity_test_jwe "basic problem, instructor + showCorrectAnswers" \
    "problemSource=${PROBLEM_BASIC}" "problemSeed=42" "isInstructor=1" "showCorrectAnswers=1"

# Seed-sensitive problem with seed=42
parity_test_jwe "random problem, seed=42" \
    "problemSource=${PROBLEM_RANDOM}" "problemSeed=42"

# Seed-sensitive problem with seed=99999
parity_test_jwe "random problem, seed=99999" \
    "problemSource=${PROBLEM_RANDOM}" "problemSeed=99999"

# Multi-answer problem
parity_test_jwe "multi-answer problem" \
    "problemSource=${PROBLEM_MULTI}" "problemSeed=42"

# JWS parity (HS256 signed instead of encrypted)
parity_test_jws "basic problem via JWS" \
    "problemSource=${PROBLEM_BASIC}" "problemSeed=42"

# Verify different seeds produce different output
RESP_42=$(render_raw "problemSource=${PROBLEM_RANDOM}" "problemSeed=42")
RESP_99=$(render_raw "problemSource=${PROBLEM_RANDOM}" "problemSeed=99999")
HASH_42=$(hash_html "$RESP_42")
HASH_99=$(hash_html "$RESP_99")
assert_ne "$HASH_42" "$HASH_99" "Different seeds produce different renderedHTML"

summary "render parity tests"
