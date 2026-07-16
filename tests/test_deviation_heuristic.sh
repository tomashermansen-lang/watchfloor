#!/usr/bin/env bash
# test_deviation_heuristic.sh — bash unit tests for compute_phase_ratios.
#
# Usage: bash tests/test_deviation_heuristic.sh
# Exits 0 iff passed == 8 and failed == 0.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
LIB="$REPO_DIR/adapters/claude-code/claude/tools/lib/deviation-assess.sh"
FIXTURES="$REPO_DIR/tests/fixtures/deviation_heuristic"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

check() {
  local name="$1"
  shift
  if "$@"; then
    echo -e "${GREEN}✓${NC} $name"
    passed=$((passed + 1))
  else
    echo -e "${RED}✗${NC} $name"
    failed=$((failed + 1))
  fi
}

TEST_DIR="${TMPDIR:-/tmp}/test-deviation-heuristic-$$"

setup() {
  rm -rf "$TEST_DIR"
  mkdir -p "$TEST_DIR"
}

teardown() {
  rm -rf "$TEST_DIR"
}
trap teardown EXIT
setup

# Per-test stderr capture file. Path is unique-per-PID; tests that run
# sequentially can share the file safely because each test truncates it
# (`: >"$err_file"`) before each invocation that needs an isolated read.
make_err_file() {
  local f="$TEST_DIR/stderr-$$-$RANDOM"
  : >"$f"
  echo "$f"
}

# --- T1 ----------------------------------------------------------------------

test_aligned_when_all_ratios_within_threshold() (
  unset DEVIATION_DECLARED_FILES DEVIATION_ACTUAL_FILES \
        DEVIATION_LINES_ESTIMATE DEVIATION_ACTUAL_LOC \
        DEVIATION_AC_COUNT DEVIATION_ACTUAL_AC_COUNT \
        DEVIATION_HEURISTIC_THRESHOLD

  local err_file
  err_file=$(make_err_file)
  trap 'rm -f "$err_file"' RETURN

  local declared actual lines_estimate actual_loc ac_count actual_ac_count
  declared=$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1])).get("aligned",[{}])[0].get("declared_files",[])))' "$FIXTURES/cases.json")
  actual=$(python3 -c 'import json,sys; print("\n".join(json.load(open(sys.argv[1])).get("aligned",[{}])[0].get("actual_files",[])))' "$FIXTURES/cases.json")
  lines_estimate=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("aligned",[{}])[0].get("lines_estimate",0))' "$FIXTURES/cases.json")
  actual_loc=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("aligned",[{}])[0].get("actual_loc",0))' "$FIXTURES/cases.json")
  ac_count=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("aligned",[{}])[0].get("ac_count",0))' "$FIXTURES/cases.json")
  actual_ac_count=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("aligned",[{}])[0].get("actual_ac_count",0))' "$FIXTURES/cases.json")

  local out
  out=$(PATH=/dev/null/bin:$PATH \
    DEVIATION_DECLARED_FILES="$declared" \
    DEVIATION_ACTUAL_FILES="$actual" \
    DEVIATION_LINES_ESTIMATE="$lines_estimate" \
    DEVIATION_ACTUAL_LOC="$actual_loc" \
    DEVIATION_AC_COUNT="$ac_count" \
    DEVIATION_ACTUAL_AC_COUNT="$actual_ac_count" \
    bash -c 'source "$0"; compute_phase_ratios' "$LIB" 2>"$err_file")
  local err
  err=$(<"$err_file")

  [[ "$out" == "aligned" ]] || { echo "stdout: '$out' (expected 'aligned')"; return 1; }
  [[ -z "$err" ]] || { echo "stderr non-empty: '$err'"; return 1; }
  return 0
)

# --- T2 ----------------------------------------------------------------------

test_flagged_when_files_ratio_exceeds_threshold() (
  unset DEVIATION_DECLARED_FILES DEVIATION_ACTUAL_FILES \
        DEVIATION_LINES_ESTIMATE DEVIATION_ACTUAL_LOC \
        DEVIATION_AC_COUNT DEVIATION_ACTUAL_AC_COUNT \
        DEVIATION_HEURISTIC_THRESHOLD

  local err_file
  err_file=$(make_err_file)
  trap 'rm -f "$err_file"' RETURN

  local out
  out=$(DEVIATION_DECLARED_FILES=$'a.sh' \
        DEVIATION_ACTUAL_FILES=$'a.sh\nb.sh\nc.sh\nd.sh\ne.sh' \
        DEVIATION_LINES_ESTIMATE=100 \
        DEVIATION_ACTUAL_LOC=100 \
        DEVIATION_AC_COUNT=4 \
        DEVIATION_ACTUAL_AC_COUNT=4 \
        bash -c 'source "$0"; compute_phase_ratios' "$LIB" 2>"$err_file")

  [[ "$out" == $'flagged\nfiles' ]] || { printf "stdout: %q (expected flagged+files)\n" "$out"; return 1; }
  return 0
)

# --- T3 ----------------------------------------------------------------------

test_flagged_when_loc_ratio_exceeds_threshold() (
  unset DEVIATION_DECLARED_FILES DEVIATION_ACTUAL_FILES \
        DEVIATION_LINES_ESTIMATE DEVIATION_ACTUAL_LOC \
        DEVIATION_AC_COUNT DEVIATION_ACTUAL_AC_COUNT \
        DEVIATION_HEURISTIC_THRESHOLD

  local err_file
  err_file=$(make_err_file)
  trap 'rm -f "$err_file"' RETURN

  local out
  out=$(DEVIATION_DECLARED_FILES=$'a.sh\nb.sh' \
        DEVIATION_ACTUAL_FILES=$'a.sh\nb.sh' \
        DEVIATION_LINES_ESTIMATE=100 \
        DEVIATION_ACTUAL_LOC=200 \
        DEVIATION_AC_COUNT=4 \
        DEVIATION_ACTUAL_AC_COUNT=4 \
        bash -c 'source "$0"; compute_phase_ratios' "$LIB" 2>"$err_file")

  [[ "$out" == $'flagged\nloc' ]] || { printf "stdout: %q (expected flagged+loc)\n" "$out"; return 1; }
  return 0
)

# --- T4 ----------------------------------------------------------------------

test_flagged_when_ac_coverage_ratio_exceeds_threshold() (
  unset DEVIATION_DECLARED_FILES DEVIATION_ACTUAL_FILES \
        DEVIATION_LINES_ESTIMATE DEVIATION_ACTUAL_LOC \
        DEVIATION_AC_COUNT DEVIATION_ACTUAL_AC_COUNT \
        DEVIATION_HEURISTIC_THRESHOLD

  local err_file
  err_file=$(make_err_file)
  trap 'rm -f "$err_file"' RETURN

  local out
  out=$(DEVIATION_DECLARED_FILES=$'a.sh\nb.sh' \
        DEVIATION_ACTUAL_FILES=$'a.sh\nb.sh' \
        DEVIATION_LINES_ESTIMATE=100 \
        DEVIATION_ACTUAL_LOC=100 \
        DEVIATION_AC_COUNT=4 \
        DEVIATION_ACTUAL_AC_COUNT=1 \
        bash -c 'source "$0"; compute_phase_ratios' "$LIB" 2>"$err_file")

  [[ "$out" == $'flagged\nac_coverage' ]] || { printf "stdout: %q (expected flagged+ac_coverage)\n" "$out"; return 1; }
  return 0
)

# --- T5 ----------------------------------------------------------------------

test_flagged_lists_multiple_failing_ratios_in_canonical_order() (
  unset DEVIATION_DECLARED_FILES DEVIATION_ACTUAL_FILES \
        DEVIATION_LINES_ESTIMATE DEVIATION_ACTUAL_LOC \
        DEVIATION_AC_COUNT DEVIATION_ACTUAL_AC_COUNT \
        DEVIATION_HEURISTIC_THRESHOLD

  local err_file
  err_file=$(make_err_file)
  trap 'rm -f "$err_file"' RETURN

  local out
  out=$(DEVIATION_DECLARED_FILES=$'a.sh' \
        DEVIATION_ACTUAL_FILES=$'a.sh\nb.sh' \
        DEVIATION_LINES_ESTIMATE=100 \
        DEVIATION_ACTUAL_LOC=200 \
        DEVIATION_AC_COUNT=4 \
        DEVIATION_ACTUAL_AC_COUNT=2 \
        bash -c 'source "$0"; compute_phase_ratios' "$LIB" 2>"$err_file")

  [[ "$out" == $'flagged\nfiles\nloc\nac_coverage' ]] || { echo "stdout: '$out' (expected canonical-ordered four lines)"; return 1; }
  return 0
)

# --- T6 ----------------------------------------------------------------------

test_fallback_skips_files_ratio_when_declared_empty() (
  unset DEVIATION_DECLARED_FILES DEVIATION_ACTUAL_FILES \
        DEVIATION_LINES_ESTIMATE DEVIATION_ACTUAL_LOC \
        DEVIATION_AC_COUNT DEVIATION_ACTUAL_AC_COUNT \
        DEVIATION_HEURISTIC_THRESHOLD

  local err_file
  err_file=$(make_err_file)
  trap 'rm -f "$err_file"' RETURN

  # Setup A — verdict aligned (LOC and AC at 1.0; declared empty).
  local out_a err_a
  out_a=$(DEVIATION_DECLARED_FILES="" \
          DEVIATION_ACTUAL_FILES=$'a.sh\nb.sh' \
          DEVIATION_LINES_ESTIMATE=100 \
          DEVIATION_ACTUAL_LOC=100 \
          DEVIATION_AC_COUNT=4 \
          DEVIATION_ACTUAL_AC_COUNT=4 \
          bash -c 'source "$0"; compute_phase_ratios' "$LIB" 2>"$err_file")
  err_a=$(<"$err_file")
  [[ "$out_a" == "aligned" ]] || { echo "Setup A stdout: '$out_a' (expected 'aligned')"; return 1; }
  [[ -z "$err_a" ]] || { echo "Setup A stderr non-empty: '$err_a'"; return 1; }

  # Setup B — declared empty, loc-ratio = 2.0; verdict flagged with loc only
  # (files name MUST NOT appear).
  : >"$err_file"
  local out_b
  out_b=$(DEVIATION_DECLARED_FILES="" \
          DEVIATION_ACTUAL_FILES=$'a.sh\nb.sh' \
          DEVIATION_LINES_ESTIMATE=100 \
          DEVIATION_ACTUAL_LOC=200 \
          DEVIATION_AC_COUNT=4 \
          DEVIATION_ACTUAL_AC_COUNT=4 \
          bash -c 'source "$0"; compute_phase_ratios' "$LIB" 2>"$err_file")
  [[ "$out_b" == $'flagged\nloc' ]] || { printf "Setup B stdout: %q (expected flagged+loc)\n" "$out_b"; return 1; }
  return 0
)

# --- T7 ----------------------------------------------------------------------

test_fallback_aligned_when_all_inputs_missing() (
  unset DEVIATION_DECLARED_FILES DEVIATION_ACTUAL_FILES \
        DEVIATION_LINES_ESTIMATE DEVIATION_ACTUAL_LOC \
        DEVIATION_AC_COUNT DEVIATION_ACTUAL_AC_COUNT \
        DEVIATION_HEURISTIC_THRESHOLD

  local err_file
  err_file=$(make_err_file)
  trap 'rm -f "$err_file"' RETURN

  local out err
  out=$(DEVIATION_DECLARED_FILES="" \
        DEVIATION_ACTUAL_FILES="" \
        DEVIATION_LINES_ESTIMATE="" \
        DEVIATION_ACTUAL_LOC="" \
        DEVIATION_AC_COUNT="" \
        DEVIATION_ACTUAL_AC_COUNT="" \
        bash -c 'source "$0"; compute_phase_ratios' "$LIB" 2>"$err_file")
  err=$(<"$err_file")

  [[ "$out" == "aligned" ]] || { echo "stdout: '$out' (expected 'aligned')"; return 1; }
  [[ -z "$err" ]] || { echo "stderr non-empty: '$err'"; return 1; }
  return 0
)

# --- T8 ----------------------------------------------------------------------

test_invalid_threshold_emits_warning_and_uses_default() (
  unset DEVIATION_DECLARED_FILES DEVIATION_ACTUAL_FILES \
        DEVIATION_LINES_ESTIMATE DEVIATION_ACTUAL_LOC \
        DEVIATION_AC_COUNT DEVIATION_ACTUAL_AC_COUNT \
        DEVIATION_HEURISTIC_THRESHOLD

  local err_file
  err_file=$(make_err_file)
  trap 'rm -f "$err_file"' RETURN

  local bad
  for bad in "abc" " 1.5 " "1.5e0" "+1.5"; do
    : >"$err_file"
    local out err
    out=$(DEVIATION_HEURISTIC_THRESHOLD="$bad" \
          DEVIATION_DECLARED_FILES=$'a.sh' \
          DEVIATION_ACTUAL_FILES=$'a.sh' \
          DEVIATION_LINES_ESTIMATE=100 \
          DEVIATION_ACTUAL_LOC=100 \
          DEVIATION_AC_COUNT=4 \
          DEVIATION_ACTUAL_AC_COUNT=4 \
          bash -c 'source "$0"; compute_phase_ratios' "$LIB" 2>"$err_file")
    err=$(<"$err_file")

    echo "$err" | grep -q "WARNING: DEVIATION_HEURISTIC_THRESHOLD invalid, using 1.5" \
      || { echo "form '$bad' missing WARNING (stderr: '$err')"; return 1; }
    [[ "$out" == "aligned" ]] \
      || { echo "form '$bad' verdict='$out', expected 'aligned' at default 1.5"; return 1; }
  done
  return 0
)

# --- runner ------------------------------------------------------------------

check "test_aligned_when_all_ratios_within_threshold"             test_aligned_when_all_ratios_within_threshold
check "test_flagged_when_files_ratio_exceeds_threshold"           test_flagged_when_files_ratio_exceeds_threshold
check "test_flagged_when_loc_ratio_exceeds_threshold"             test_flagged_when_loc_ratio_exceeds_threshold
check "test_flagged_when_ac_coverage_ratio_exceeds_threshold"     test_flagged_when_ac_coverage_ratio_exceeds_threshold
check "test_flagged_lists_multiple_failing_ratios_in_canonical_order" test_flagged_lists_multiple_failing_ratios_in_canonical_order
check "test_fallback_skips_files_ratio_when_declared_empty"       test_fallback_skips_files_ratio_when_declared_empty
check "test_fallback_aligned_when_all_inputs_missing"             test_fallback_aligned_when_all_inputs_missing
check "test_invalid_threshold_emits_warning_and_uses_default"     test_invalid_threshold_emits_warning_and_uses_default

echo "Results: ${passed} passed, ${failed} failed"
[[ $passed -eq 8 && $failed -eq 0 ]]
