#!/usr/bin/env bash
# 03-answer-cycle.sh — Render → submit → verify scoring.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/lib/helpers.sh"
source "$SCRIPT_DIR/lib/problems.sh"

echo "=== Answer Cycle Tests ==="

# ── Single answer: correct ────────────────────────────────────

# Step 1: Render as instructor to discover answer field name + correct value
INST_RESP=$(render_raw "problemSource=${PROBLEM_BASIC}" "problemSeed=42" "isInstructor=1")

# Extract the answer field name (e.g., AnSwEr0001)
ANS_NAME=$(echo "$INST_RESP" | jq -r '.answers | keys[0]')
CORRECT_VAL=$(echo "$INST_RESP" | jq -r ".answers.\"$ANS_NAME\".correct_ans")

assert_ne "$ANS_NAME" "" "Discovered answer field name: $ANS_NAME"
assert_ne "$CORRECT_VAL" "" "Discovered correct answer: $CORRECT_VAL"

# Step 2: Render as student to get JWT tokens
STU_RESP=$(render_raw "problemSource=${PROBLEM_BASIC}" "problemSeed=42")
PROB_JWT=$(echo "$STU_RESP" | jq -r '.JWT.problem')
SESS_JWT=$(echo "$STU_RESP" | jq -r '.JWT.session')

# Step 3: Submit correct answer
SUBMIT_RESP=$(curl -sf --max-time "$CURL_TIMEOUT" -X POST \
    -d "problemJWT=${PROB_JWT}" \
    -d "sessionJWT=${SESS_JWT}" \
    -d "${ANS_NAME}=${CORRECT_VAL}" \
    -d "submitAnswers=1" \
    -d "answersSubmitted=1" \
    -d "_format=json" \
    "${BASE_URL}/render-api" 2>/dev/null)

SCORE=$(echo "$SUBMIT_RESP" | jq -r '.problem_result.score')
assert_eq "$SCORE" "1" "Correct answer scores 1"

# Step 4: Submit wrong answer
WRONG_RESP=$(curl -sf --max-time "$CURL_TIMEOUT" -X POST \
    -d "problemJWT=${PROB_JWT}" \
    -d "sessionJWT=${SESS_JWT}" \
    -d "${ANS_NAME}=999" \
    -d "submitAnswers=1" \
    -d "answersSubmitted=1" \
    -d "_format=json" \
    "${BASE_URL}/render-api" 2>/dev/null)

WRONG_SCORE=$(echo "$WRONG_RESP" | jq -r '.problem_result.score')
assert_eq "$WRONG_SCORE" "0" "Wrong answer scores 0"

# ── Multi-answer: partial credit ──────────────────────────────

MULTI_INST=$(render_raw "problemSource=${PROBLEM_MULTI}" "problemSeed=42" "isInstructor=1")

# Get both answer field names and correct values
ANS1_NAME=$(echo "$MULTI_INST" | jq -r '.answers | keys[0]')
ANS2_NAME=$(echo "$MULTI_INST" | jq -r '.answers | keys[1]')
ANS1_CORRECT=$(echo "$MULTI_INST" | jq -r ".answers.\"$ANS1_NAME\".correct_ans")
ANS2_CORRECT=$(echo "$MULTI_INST" | jq -r ".answers.\"$ANS2_NAME\".correct_ans")

# Render as student
MULTI_STU=$(render_raw "problemSource=${PROBLEM_MULTI}" "problemSeed=42")
MULTI_PROB_JWT=$(echo "$MULTI_STU" | jq -r '.JWT.problem')
MULTI_SESS_JWT=$(echo "$MULTI_STU" | jq -r '.JWT.session')

# Submit 1/2 correct (first correct, second wrong)
PARTIAL_RESP=$(curl -sf --max-time "$CURL_TIMEOUT" -X POST \
    -d "problemJWT=${MULTI_PROB_JWT}" \
    -d "sessionJWT=${MULTI_SESS_JWT}" \
    -d "${ANS1_NAME}=${ANS1_CORRECT}" \
    -d "${ANS2_NAME}=999" \
    -d "submitAnswers=1" \
    -d "answersSubmitted=1" \
    -d "_format=json" \
    "${BASE_URL}/render-api" 2>/dev/null)

PARTIAL_SCORE=$(echo "$PARTIAL_RESP" | jq -r '.problem_result.score')
assert_eq "$PARTIAL_SCORE" "0.5" "1/2 correct scores 0.5"

# Submit both correct
FULL_RESP=$(curl -sf --max-time "$CURL_TIMEOUT" -X POST \
    -d "problemJWT=${MULTI_PROB_JWT}" \
    -d "sessionJWT=${MULTI_SESS_JWT}" \
    -d "${ANS1_NAME}=${ANS1_CORRECT}" \
    -d "${ANS2_NAME}=${ANS2_CORRECT}" \
    -d "submitAnswers=1" \
    -d "answersSubmitted=1" \
    -d "_format=json" \
    "${BASE_URL}/render-api" 2>/dev/null)

FULL_SCORE=$(echo "$FULL_RESP" | jq -r '.problem_result.score')
assert_eq "$FULL_SCORE" "1" "2/2 correct scores 1"

summary "answer cycle tests"

# previewAnswers was retired — MathQuill renders inline as the student types,
# so the separate "preview without grading" mode is no longer needed. Any inbound
# previewAnswers param is now silently ignored.
