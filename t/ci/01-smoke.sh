#!/usr/bin/env bash
# 01-smoke.sh — Health check, basic render, response structure validation.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/problems.sh"

echo "=== Smoke Tests ==="

# Health endpoint
assert_status "GET" "/health" "200" "GET /health returns 200"

# Editor UI available in dev mode
assert_status "GET" "/" "200" "GET / (editor UI) returns 200 in dev mode"

# Basic render
RESP=$(render_raw "problemSource=${PROBLEM_BASIC}" "problemSeed=42")

assert_json_field "$RESP" '.renderedHTML' "Response has .renderedHTML"
assert_json_field "$RESP" '.JWT.problem' "Response has .JWT.problem (non-empty)"
assert_json_field "$RESP" '.JWT.session' "Response has .JWT.session (non-empty)"

# Score should be 0 (no answers submitted)
SCORE=$(echo "$RESP" | jq -r '.problem_result.score // empty')
assert_eq "$SCORE" "0" "Score is 0 with no answers submitted"

# Debug block should exist
assert_json_field "$RESP" '.debug' "Response has .debug block"

# Resources block should exist
assert_json_field "$RESP" '.resources' "Response has .resources block"

# renderedHTML should contain a form input for the answer
HTML=$(echo "$RESP" | jq -r '.renderedHTML')
assert_contains "$HTML" "input" "renderedHTML contains input element"

# Instructor mode adds answers and inputs to response
RESP_INST=$(render_raw "problemSource=${PROBLEM_BASIC}" "problemSeed=42" "isInstructor=1")
assert_json_field "$RESP_INST" '.answers' "Instructor response has .answers"
assert_json_field "$RESP_INST" '.inputs' "Instructor response has .inputs"

# Non-instructor should NOT have answers
NO_ANSWERS=$(echo "$RESP" | jq -r '.answers // empty')
assert_eq "$NO_ANSWERS" "" "Non-instructor response has no .answers"

summary "smoke tests"
