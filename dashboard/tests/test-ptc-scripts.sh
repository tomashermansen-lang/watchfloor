#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
COMMIT_PREFLIGHT="$PROJECT_ROOT/tools/commit-preflight.sh"
DONE_VERIFY="$PROJECT_ROOT/tools/done-verify.sh"
START_VALIDATE="$PROJECT_ROOT/tools/start-validate.sh"
PASS=0
FAIL=0
TOTAL=0

# IMPORTANT: temp dir MUST live outside the dotfiles tree. If it lived
# under $PROJECT_ROOT (i.e. inside dotfiles), git operations in
# setup_git_repo's nested test repos could walk up and hit dotfiles'
# .git on any failure path — and on 2026-05-02 they did, rewriting
# refs/heads/main and refs/heads/feature/watchfloor-brand-tokens to
# the test fixture commits. Using mktemp -d (which honours $TMPDIR)
# puts test repos in /var/folders/.../T or /tmp where there is no
# parent git repo to escape into.
TMPDIR_BASE=$(mktemp -d "${TMPDIR:-/tmp}/ptc-tests.XXXXXX")
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ── Assertion helpers ──

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    actual: $haystack"
  fi
}

assert_json_field() {
  local label="$1" json="$2" field="$3" expected="$4"
  local actual
  actual=$(echo "$json" | jq -r "$field" 2>/dev/null)
  assert_eq "$label" "$expected" "$actual"
}

assert_json_bool() {
  local label="$1" json="$2" field="$3" expected="$4"
  local actual
  actual=$(echo "$json" | jq "$field" 2>/dev/null)
  assert_eq "$label" "$expected" "$actual"
}

assert_valid_json_output() {
  local label="$1" output="$2"
  TOTAL=$((TOTAL + 1))
  if echo "$output" | jq -e . >/dev/null 2>&1; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — not valid JSON: $output"
  fi
}

# ── Setup helpers ──

setup_git_repo() {
  local dir="$TMPDIR_BASE/repo-$$-$RANDOM"
  mkdir -p "$dir"
  # Canonicalise via `cd && pwd -P` so the path matches what
  # `git rev-parse --show-toplevel` will return later. macOS symlinks
  # /tmp -> /private/tmp, so the raw $TMPDIR-derived path differs from
  # the path git sees through the .git directory; without this resolve
  # T13 (and any future test comparing against worktree paths) fails
  # on string-equality.
  dir=$(cd "$dir" && pwd -P)
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@test.com"
  git -C "$dir" config user.name "Test"
  git -C "$dir" commit --allow-empty -m "initial commit" -q
  echo "$dir"
}

setup_worktree() {
  local main="$1" feature="$2"
  git -C "$main" branch "feature/$feature" 2>/dev/null || true
  local wt_dir="$TMPDIR_BASE/wt-$feature-$$-$RANDOM"
  git -C "$main" worktree add "$wt_dir" "feature/$feature" -q 2>/dev/null
  echo "$wt_dir"
}

cleanup_worktree() {
  local main="$1" wt_dir="$2"
  git -C "$main" worktree remove "$wt_dir" --force 2>/dev/null || true
}

# ═══════════════════════════════════════════════════════
# commit-preflight.sh — Standard Mode (T1-T7)
# ═══════════════════════════════════════════════════════

test_T1_standard_tests_pass() {
  local repo
  repo=$(setup_git_repo)
  echo "hello" > "$repo/file.txt"
  git -C "$repo" add file.txt
  local out
  out=$(cd "$repo" && bash "$COMMIT_PREFLIGHT" --test-cmd "true" 2>/dev/null)

  assert_valid_json_output "T1: valid JSON" "$out"
  assert_json_bool "T1: ok is true" "$out" ".ok" "true"
  assert_json_bool "T1: tests_passed is true" "$out" ".tests_passed" "true"
  # status should show the staged file
  local status
  status=$(echo "$out" | jq -r '.status')
  assert_contains "T1: status shows file" "file.txt" "$status"
}

test_T2_standard_tests_fail() {
  local repo
  repo=$(setup_git_repo)
  local out
  out=$(cd "$repo" && bash "$COMMIT_PREFLIGHT" --test-cmd "echo 'FAIL: something broke'; exit 1" 2>/dev/null)

  assert_valid_json_output "T2: valid JSON" "$out"
  assert_json_bool "T2: ok is false" "$out" ".ok" "false"
  assert_json_bool "T2: tests_passed is false" "$out" ".tests_passed" "false"
  local test_output
  test_output=$(echo "$out" | jq -r '.test_output')
  assert_contains "T2: test_output has failure" "FAIL" "$test_output"
}

test_T3_no_test_runner() {
  local repo
  repo=$(setup_git_repo)
  # No --test-cmd and no ./scripts/run_tests.sh
  local out
  out=$(cd "$repo" && bash "$COMMIT_PREFLIGHT" 2>/dev/null)

  assert_valid_json_output "T3: valid JSON" "$out"
  assert_json_bool "T3: ok is false" "$out" ".ok" "false"
  # tests_passed should be null
  local tp
  tp=$(echo "$out" | jq '.tests_passed')
  assert_eq "T3: tests_passed is null" "null" "$tp"
}

test_T4_clean_working_tree() {
  local repo
  repo=$(setup_git_repo)
  local out
  out=$(cd "$repo" && bash "$COMMIT_PREFLIGHT" --test-cmd "true" 2>/dev/null)

  assert_valid_json_output "T4: valid JSON" "$out"
  assert_json_bool "T4: ok is true" "$out" ".ok" "true"
  local status
  status=$(echo "$out" | jq -r '.status')
  assert_eq "T4: status is empty" "" "$status"
}

test_T5_test_output_truncation() {
  local repo
  repo=$(setup_git_repo)
  # Generate 100 lines of output
  local cmd="for i in \$(seq 1 100); do echo \"line \$i\"; done"
  local out
  out=$(cd "$repo" && bash "$COMMIT_PREFLIGHT" --test-cmd "bash -c '$cmd'" 2>/dev/null)

  assert_valid_json_output "T5: valid JSON" "$out"
  local line_count
  line_count=$(echo "$out" | jq -r '.test_output' | wc -l | tr -d ' ')
  TOTAL=$((TOTAL + 1))
  if [ "$line_count" -le 30 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T5: test_output has $line_count lines (expected <= 30)"
  fi
}

test_T6_special_chars_in_filenames() {
  local repo
  repo=$(setup_git_repo)
  echo "data" > "$repo/file with spaces.txt"
  echo "more" > "$repo/quotes'here.txt"
  git -C "$repo" add -A
  local out
  out=$(cd "$repo" && bash "$COMMIT_PREFLIGHT" --test-cmd "true" 2>/dev/null)

  assert_valid_json_output "T6: valid JSON despite special chars" "$out"
  assert_json_bool "T6: ok is true" "$out" ".ok" "true"
}

test_T7_stdout_only_json() {
  local repo
  repo=$(setup_git_repo)
  local stdout_out stderr_out
  local ptc_stderr="${TMPDIR:-/tmp}/ptc-test-stderr"
  stdout_out=$(cd "$repo" && bash "$COMMIT_PREFLIGHT" --test-cmd "true" 2>"$ptc_stderr")
  stderr_out=$(cat "$ptc_stderr" 2>/dev/null || true)
  rm -f "$ptc_stderr"

  assert_valid_json_output "T7: stdout is valid JSON" "$stdout_out"
  # stdout should parse as exactly one JSON object (no extra text)
  local obj_count
  obj_count=$(echo "$stdout_out" | jq -s 'length' 2>/dev/null)
  assert_eq "T7: stdout is exactly one JSON object" "1" "$obj_count"
}

# ═══════════════════════════════════════════════════════
# commit-preflight.sh — Flow Mode (T8-T13)
# ═══════════════════════════════════════════════════════

test_T8_flow_happy_path() {
  local repo wt_dir
  repo=$(setup_git_repo)
  wt_dir=$(setup_worktree "$repo" "test-feat")

  local out
  out=$(cd "$wt_dir" && bash "$COMMIT_PREFLIGHT" --flow --test-cmd "true" 2>/dev/null)

  assert_valid_json_output "T8: valid JSON" "$out"
  assert_json_bool "T8: ok is true" "$out" ".ok" "true"
  assert_json_bool "T8: is_worktree is true" "$out" ".is_worktree" "true"
  local branch
  branch=$(echo "$out" | jq -r '.branch')
  assert_contains "T8: branch starts with feature/" "feature/" "$branch"

  cleanup_worktree "$repo" "$wt_dir"
}

test_T9_flow_not_in_worktree() {
  local repo
  repo=$(setup_git_repo)
  local out
  out=$(cd "$repo" && bash "$COMMIT_PREFLIGHT" --flow --test-cmd "true" 2>/dev/null)

  assert_valid_json_output "T9: valid JSON" "$out"
  assert_json_bool "T9: ok is false" "$out" ".ok" "false"
  assert_json_bool "T9: is_worktree is false" "$out" ".is_worktree" "false"
}

test_T10_flow_detached_head() {
  local repo wt_dir
  repo=$(setup_git_repo)
  wt_dir=$(setup_worktree "$repo" "detach-feat")
  git -C "$wt_dir" checkout --detach 2>/dev/null

  local out
  out=$(cd "$wt_dir" && bash "$COMMIT_PREFLIGHT" --flow --test-cmd "true" 2>/dev/null)

  assert_valid_json_output "T10: valid JSON" "$out"
  assert_json_bool "T10: ok is false" "$out" ".ok" "false"
  local branch
  branch=$(echo "$out" | jq '.branch')
  assert_eq "T10: branch is null" "null" "$branch"

  cleanup_worktree "$repo" "$wt_dir"
}

test_T11_flow_qa_report_present() {
  local repo wt_dir
  repo=$(setup_git_repo)
  wt_dir=$(setup_worktree "$repo" "qa-feat")
  mkdir -p "$wt_dir/docs/INPROGRESS_Feature_qa-feat"
  touch "$wt_dir/docs/INPROGRESS_Feature_qa-feat/QA_REPORT.md"

  local out
  out=$(cd "$wt_dir" && bash "$COMMIT_PREFLIGHT" --flow --test-cmd "true" 2>/dev/null)

  assert_valid_json_output "T11: valid JSON" "$out"
  assert_json_bool "T11: has_qa_report is true" "$out" ".has_qa_report" "true"

  cleanup_worktree "$repo" "$wt_dir"
}

test_T12_flow_qa_report_missing() {
  local repo wt_dir
  repo=$(setup_git_repo)
  wt_dir=$(setup_worktree "$repo" "noqa-feat")

  local out
  out=$(cd "$wt_dir" && bash "$COMMIT_PREFLIGHT" --flow --test-cmd "true" 2>/dev/null)

  assert_valid_json_output "T12: valid JSON" "$out"
  assert_json_bool "T12: has_qa_report is false" "$out" ".has_qa_report" "false"

  cleanup_worktree "$repo" "$wt_dir"
}

test_T13_flow_main_worktree_path() {
  local repo wt_dir
  repo=$(setup_git_repo)
  wt_dir=$(setup_worktree "$repo" "main-path-feat")

  local out
  out=$(cd "$wt_dir" && bash "$COMMIT_PREFLIGHT" --flow --test-cmd "true" 2>/dev/null)

  assert_valid_json_output "T13: valid JSON" "$out"
  local main_wt
  main_wt=$(echo "$out" | jq -r '.main_worktree')
  assert_eq "T13: main_worktree matches repo" "$repo" "$main_wt"

  cleanup_worktree "$repo" "$wt_dir"
}

# ═══════════════════════════════════════════════════════
# done-verify.sh (T14-T20)
# ═══════════════════════════════════════════════════════

test_T14_all_clean() {
  local repo
  repo=$(setup_git_repo)
  # Create a "done" feature: branch merged, worktree removed, docs DONE_
  git -C "$repo" checkout -b "feature/clean-feat" -q
  git -C "$repo" commit --allow-empty -m "feat(clean-feat): add feature" -q
  git -C "$repo" checkout main -q
  git -C "$repo" merge "feature/clean-feat" -q --no-edit
  git -C "$repo" branch -d "feature/clean-feat" -q
  mkdir -p "$repo/docs/DONE_Feature_clean-feat"

  local out
  out=$(cd "$repo" && bash "$DONE_VERIFY" "clean-feat" 2>/dev/null)

  assert_valid_json_output "T14: valid JSON" "$out"
  assert_json_bool "T14: all_clean is true" "$out" ".all_clean" "true"
  assert_json_bool "T14: worktree_removed is true" "$out" ".worktree_removed" "true"
  assert_json_bool "T14: branch_deleted is true" "$out" ".branch_deleted" "true"
  assert_json_bool "T14: is_merged is true" "$out" ".is_merged" "true"
  assert_json_field "T14: docs_status is done" "$out" ".docs_status" "done"
}

test_T15_worktree_exists() {
  local repo wt_dir
  repo=$(setup_git_repo)
  wt_dir=$(setup_worktree "$repo" "wt-exists")

  local out
  out=$(cd "$repo" && bash "$DONE_VERIFY" "wt-exists" 2>/dev/null)

  assert_valid_json_output "T15: valid JSON" "$out"
  assert_json_bool "T15: all_clean is false" "$out" ".all_clean" "false"
  assert_json_bool "T15: worktree_removed is false" "$out" ".worktree_removed" "false"

  cleanup_worktree "$repo" "$wt_dir"
}

test_T16_branch_exists() {
  local repo
  repo=$(setup_git_repo)
  git -C "$repo" branch "feature/branch-exists" 2>/dev/null
  mkdir -p "$repo/docs/DONE_Feature_branch-exists"

  local out
  out=$(cd "$repo" && bash "$DONE_VERIFY" "branch-exists" 2>/dev/null)

  assert_valid_json_output "T16: valid JSON" "$out"
  assert_json_bool "T16: all_clean is false" "$out" ".all_clean" "false"
  assert_json_bool "T16: branch_deleted is false" "$out" ".branch_deleted" "false"
}

test_T17_docs_inprogress() {
  local repo
  repo=$(setup_git_repo)
  # Simulate merged but docs not renamed
  git -C "$repo" checkout -b "feature/inprog-feat" -q
  git -C "$repo" commit --allow-empty -m "feat(inprog-feat): feature" -q
  git -C "$repo" checkout main -q
  git -C "$repo" merge "feature/inprog-feat" -q --no-edit
  git -C "$repo" branch -d "feature/inprog-feat" -q
  mkdir -p "$repo/docs/INPROGRESS_Feature_inprog-feat"

  local out
  out=$(cd "$repo" && bash "$DONE_VERIFY" "inprog-feat" 2>/dev/null)

  assert_valid_json_output "T17: valid JSON" "$out"
  assert_json_field "T17: docs_status is inprogress" "$out" ".docs_status" "inprogress"
}

test_T18_docs_missing() {
  local repo
  repo=$(setup_git_repo)
  # Merged feature, no docs folder at all
  git -C "$repo" checkout -b "feature/nodocs-feat" -q
  git -C "$repo" commit --allow-empty -m "feat(nodocs-feat): feature" -q
  git -C "$repo" checkout main -q
  git -C "$repo" merge "feature/nodocs-feat" -q --no-edit
  git -C "$repo" branch -d "feature/nodocs-feat" -q

  local out
  out=$(cd "$repo" && bash "$DONE_VERIFY" "nodocs-feat" 2>/dev/null)

  assert_valid_json_output "T18: valid JSON" "$out"
  assert_json_field "T18: docs_status is missing" "$out" ".docs_status" "missing"
}

test_T19_no_feature_arg() {
  local repo
  repo=$(setup_git_repo)
  local out
  out=$(cd "$repo" && bash "$DONE_VERIFY" 2>/dev/null)

  assert_valid_json_output "T19: valid JSON" "$out"
  assert_json_bool "T19: ok is false" "$out" ".ok" "false"
  local err
  err=$(echo "$out" | jq -r '.error')
  assert_contains "T19: error explains" "feature" "$err"
}

test_T20_no_short_circuit() {
  local repo wt_dir
  repo=$(setup_git_repo)
  # Multiple failures: worktree exists AND branch exists
  wt_dir=$(setup_worktree "$repo" "multi-fail")

  local out
  out=$(cd "$repo" && bash "$DONE_VERIFY" "multi-fail" 2>/dev/null)

  assert_valid_json_output "T20: valid JSON" "$out"
  # Both fields should be present and false (not short-circuited)
  assert_json_bool "T20: worktree_removed is false" "$out" ".worktree_removed" "false"
  assert_json_bool "T20: branch_deleted is false" "$out" ".branch_deleted" "false"

  cleanup_worktree "$repo" "$wt_dir"
}

# ═══════════════════════════════════════════════════════
# start-validate.sh (T21-T25)
# ═══════════════════════════════════════════════════════

test_T21_start_happy_path() {
  local repo
  repo=$(setup_git_repo)
  local out
  out=$(cd "$repo" && bash "$START_VALIDATE" "new-feat" 2>/dev/null)

  assert_valid_json_output "T21: valid JSON" "$out"
  assert_json_bool "T21: ok is true" "$out" ".ok" "true"
  assert_json_bool "T21: is_main_project is true" "$out" ".is_main_project" "true"
  assert_json_bool "T21: feature_exists is false" "$out" ".feature_exists" "false"
}

test_T22_already_in_worktree() {
  local repo wt_dir
  repo=$(setup_git_repo)
  wt_dir=$(setup_worktree "$repo" "existing-wt")

  local out
  out=$(cd "$wt_dir" && bash "$START_VALIDATE" "another-feat" 2>/dev/null)

  assert_valid_json_output "T22: valid JSON" "$out"
  assert_json_bool "T22: ok is false" "$out" ".ok" "false"
  assert_json_bool "T22: is_main_project is false" "$out" ".is_main_project" "false"

  cleanup_worktree "$repo" "$wt_dir"
}

test_T23_feature_branch_exists() {
  local repo
  repo=$(setup_git_repo)
  git -C "$repo" branch "feature/dup-feat" 2>/dev/null

  local out
  out=$(cd "$repo" && bash "$START_VALIDATE" "dup-feat" 2>/dev/null)

  assert_valid_json_output "T23: valid JSON" "$out"
  assert_json_bool "T23: ok is false" "$out" ".ok" "false"
  assert_json_bool "T23: feature_exists is true" "$out" ".feature_exists" "true"
  assert_json_bool "T23: existing_branch is true" "$out" ".existing_branch" "true"
}

test_T24_feature_worktree_exists() {
  local repo wt_dir
  repo=$(setup_git_repo)
  wt_dir=$(setup_worktree "$repo" "wt-dup-feat")

  local out
  out=$(cd "$repo" && bash "$START_VALIDATE" "wt-dup-feat" 2>/dev/null)

  assert_valid_json_output "T24: valid JSON" "$out"
  assert_json_bool "T24: ok is false" "$out" ".ok" "false"
  assert_json_bool "T24: feature_exists is true" "$out" ".feature_exists" "true"
  local existing_wt
  existing_wt=$(echo "$out" | jq -r '.existing_worktree')
  TOTAL=$((TOTAL + 1))
  if [ "$existing_wt" != "null" ] && [ -n "$existing_wt" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T24: existing_worktree should be set"
  fi

  cleanup_worktree "$repo" "$wt_dir"
}

test_T25_no_feature_arg() {
  local repo
  repo=$(setup_git_repo)
  local out
  out=$(cd "$repo" && bash "$START_VALIDATE" 2>/dev/null)

  assert_valid_json_output "T25: valid JSON" "$out"
  assert_json_bool "T25: ok is false" "$out" ".ok" "false"
  local err
  err=$(echo "$out" | jq -r '.error')
  assert_contains "T25: error explains" "feature" "$err"
}

# ═══════════════════════════════════════════════════════
# Error handling (T26-T27)
# ═══════════════════════════════════════════════════════

test_T26_outside_git_repo() {
  # Must be outside project tree so git rev-parse fails
  local dir
  dir=$(mktemp -d "${TMPDIR:-/tmp}/ptc-no-git-XXXXXX")

  local out ret

  ret=0
  out=$(cd "$dir" && bash "$COMMIT_PREFLIGHT" --test-cmd "true" 2>/dev/null) || ret=$?
  assert_eq "T26a: commit-preflight exit 0" "0" "$ret"
  assert_valid_json_output "T26a: valid JSON" "$out"
  assert_json_bool "T26a: ok is false" "$out" ".ok" "false"

  ret=0
  out=$(cd "$dir" && bash "$DONE_VERIFY" "test" 2>/dev/null) || ret=$?
  assert_eq "T26b: done-verify exit 0" "0" "$ret"
  assert_valid_json_output "T26b: valid JSON" "$out"
  assert_json_bool "T26b: ok is false" "$out" ".ok" "false"

  ret=0
  out=$(cd "$dir" && bash "$START_VALIDATE" "test" 2>/dev/null) || ret=$?
  assert_eq "T26c: start-validate exit 0" "0" "$ret"
  assert_valid_json_output "T26c: valid JSON" "$out"
  assert_json_bool "T26c: ok is false" "$out" ".ok" "false"

  rm -rf "$dir"
}

test_T27_all_scripts_exit_zero() {
  local repo
  repo=$(setup_git_repo)
  local ret

  # Commit preflight with failing tests
  ret=0
  cd "$repo" && bash "$COMMIT_PREFLIGHT" --test-cmd "exit 1" >/dev/null 2>&1 || ret=$?
  assert_eq "T27a: commit-preflight exit 0 on test fail" "0" "$ret"

  # Done verify with missing feature
  ret=0
  cd "$repo" && bash "$DONE_VERIFY" >/dev/null 2>&1 || ret=$?
  assert_eq "T27b: done-verify exit 0 on missing arg" "0" "$ret"

  # Start validate with missing feature
  ret=0
  cd "$repo" && bash "$START_VALIDATE" >/dev/null 2>&1 || ret=$?
  assert_eq "T27c: start-validate exit 0 on missing arg" "0" "$ret"
}

# ── Run all tests ──

echo "=== PTC Script Tests ==="
echo ""

echo "--- commit-preflight.sh (standard) ---"
test_T1_standard_tests_pass
test_T2_standard_tests_fail
test_T3_no_test_runner
test_T4_clean_working_tree
test_T5_test_output_truncation
test_T6_special_chars_in_filenames
test_T7_stdout_only_json

echo "--- commit-preflight.sh (flow) ---"
test_T8_flow_happy_path
test_T9_flow_not_in_worktree
test_T10_flow_detached_head
test_T11_flow_qa_report_present
test_T12_flow_qa_report_missing
test_T13_flow_main_worktree_path

echo "--- done-verify.sh ---"
test_T14_all_clean
test_T15_worktree_exists
test_T16_branch_exists
test_T17_docs_inprogress
test_T18_docs_missing
test_T19_no_feature_arg
test_T20_no_short_circuit

echo "--- start-validate.sh ---"
test_T21_start_happy_path
test_T22_already_in_worktree
test_T23_feature_branch_exists
test_T24_feature_worktree_exists
test_T25_no_feature_arg

echo "--- Error handling ---"
test_T26_outside_git_repo
test_T27_all_scripts_exit_zero

echo ""
echo "---"
printf "Tests: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
  echo "PTC script tests FAILED."
  exit 1
fi

echo "All PTC script tests passed."
exit 0
