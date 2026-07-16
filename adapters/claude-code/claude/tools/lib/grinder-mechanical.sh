#!/usr/bin/env bash
# grinder-mechanical.sh — Mechanical-pass-specific functions for grinder.sh
#
# Sourced by grinder.sh at startup. Provides the mechanical auto-fix pass
# logic: test command resolution, tool dispatch, prompt building, auto-fix
# execution, scanner re-run verification, and batch orchestration.
#
# Depends on: TOOLS_DIR, LIB_DIR, SCHEMA_DIR, PROJECT_DIR, GRINDER_DIR
# (session globals set by grinder.sh main())
#
# Also depends on grinder-discover.sh being sourced first (provides
# discover_resolve_runner, discover_run_scanner).
#
# Compatible with bash 3.2+ (macOS default).

GRINDER_TEST_TIMEOUT="${GRINDER_TEST_TIMEOUT:-300}"

# ---------------------------------------------------------------------------
# C1: resolve_test_command() — Test Command Resolution
# Reads: PROJECT_DIR (session)
# Writes: GRINDER_TEST_CMD, GRINDER_TEST_CMD_RESOLVED (session cache)
# ---------------------------------------------------------------------------

resolve_test_command() {
  # Return cached value if already resolved
  if [[ "${GRINDER_TEST_CMD_RESOLVED:-}" == "true" ]]; then
    echo "$GRINDER_TEST_CMD"
    return 0
  fi

  local cmd=""

  # Detection order per REQ-3:
  # 1. pyproject.toml + uv → Python pytest
  if [[ -f "$PROJECT_DIR/pyproject.toml" ]] && command -v uv >/dev/null 2>&1; then
    cmd="uv run python3 -m pytest tests/ -q"

  # 2. package.json + vitest
  elif [[ -f "$PROJECT_DIR/package.json" ]] && [[ -x "$PROJECT_DIR/node_modules/.bin/vitest" ]]; then
    cmd="npx vitest run --reporter=verbose"

  # 3. package.json + jest (no vitest)
  elif [[ -f "$PROJECT_DIR/package.json" ]] && [[ -x "$PROJECT_DIR/node_modules/.bin/jest" ]]; then
    cmd="npx jest --verbose"

  # 4. tests/*.sh files
  elif ls "$PROJECT_DIR"/tests/test_*.sh >/dev/null 2>&1; then
    local test_files=""
    for f in "$PROJECT_DIR"/tests/test_*.sh; do
      [[ -f "$f" ]] || continue
      if [[ -n "$test_files" ]]; then
        test_files="$test_files && bash $f"
      else
        test_files="bash $f"
      fi
    done
    cmd="$test_files"
  fi

  # Cache result
  GRINDER_TEST_CMD="$cmd"
  GRINDER_TEST_CMD_RESOLVED=true
  export GRINDER_TEST_CMD GRINDER_TEST_CMD_RESOLVED

  if [[ -z "$cmd" ]]; then
    echo "mechanical: no test command resolved -- skipping test verification" >&2
  fi

  echo "$cmd"
}

# ---------------------------------------------------------------------------
# C2: run_tests_for_project() — Test Execution Wrapper
# Reads: GRINDER_TEST_CMD (from C1), PROJECT_DIR (session)
# Returns: exit code from test command
# ---------------------------------------------------------------------------

run_tests_for_project() {
  if [[ -z "${GRINDER_TEST_CMD:-}" ]]; then
    return 0
  fi

  # Resolve timeout binary
  local timeout_cmd=""
  if command -v timeout >/dev/null 2>&1; then
    timeout_cmd="timeout"
  elif command -v gtimeout >/dev/null 2>&1; then
    timeout_cmd="gtimeout"
  else
    echo "mechanical: no timeout command available -- running tests without timeout" >&2
  fi

  local rc=0
  if [[ -n "$timeout_cmd" ]]; then
    (cd "$PROJECT_DIR" && "$timeout_cmd" "$GRINDER_TEST_TIMEOUT" bash -c "$GRINDER_TEST_CMD" >/dev/null 2>&1) || rc=$?
  else
    (cd "$PROJECT_DIR" && bash -c "$GRINDER_TEST_CMD" >/dev/null 2>&1) || rc=$?
  fi

  # EC-3.1: Timeout (exit 124)
  if [[ $rc -eq 124 ]]; then
    echo "mechanical: test command timed out after ${GRINDER_TEST_TIMEOUT}s" >&2
    return 1
  fi

  # EC-3.2: Command not found (exit 127)
  if [[ $rc -eq 127 ]]; then
    echo "mechanical: test runner binary missing -- disabling test verification for remaining batches" >&2
    GRINDER_TEST_CMD=""
    export GRINDER_TEST_CMD
    return 0
  fi

  return $rc
}

# ---------------------------------------------------------------------------
# C3: resolve_mechanical_tools() — Tool Dispatch
# Reads: GRINDER_DIR (session), discover_resolve_runner() (grinder-discover.sh)
# Args: $1 = pass_id
# Output: space-separated list of scanner names
# ---------------------------------------------------------------------------

resolve_mechanical_tools() {
  local pass_id="${1:-pass-mechanical}"
  local plan_file="$GRINDER_DIR/grinder-plan.yaml"

  if [[ ! -f "$plan_file" ]]; then
    echo "mechanical: no grinder-plan.yaml found" >&2
    return 1
  fi

  # Extract scanner names from batch file extensions in the plan
  local file_extensions
  file_extensions=$(python3 -c "
import yaml, sys
with open(sys.argv[1]) as f:
    d = yaml.safe_load(f)
exts = set()
for p in d.get('passes', []):
    if p['id'] == sys.argv[2]:
        for b in p.get('batches', []):
            for f in b.get('files', []):
                ext = f.rsplit('.', 1)[-1] if '.' in f else ''
                exts.add(ext)
for e in sorted(exts):
    print(e)
" "$plan_file" "$pass_id" 2>/dev/null)

  # Map file extensions to mechanical scanners
  local scanners=""
  while IFS= read -r ext; do
    [[ -z "$ext" ]] && continue
    case "$ext" in
      sh) scanners="$scanners shellcheck" ;;
      py) scanners="$scanners ruff" ;;
      js|ts|jsx|tsx)
        [[ "$scanners" != *"eslint"* ]] && scanners="$scanners eslint"
        ;;
    esac
  done <<< "$file_extensions"

  # Verify each scanner is available
  local available=""
  for scanner in $scanners; do
    local runner
    runner=$(discover_resolve_runner "$scanner")
    local binary="${runner%% *}"
    if command -v "$binary" >/dev/null 2>&1; then
      if [[ -n "$available" ]]; then
        available="$available $scanner"
      else
        available="$scanner"
      fi
    else
      echo "mechanical: $scanner not available -- skipping" >&2
    fi
  done

  echo "$available"
}

# ---------------------------------------------------------------------------
# C4: build_mechanical_prompt() — Prompt Template Builder
# Reads: discover_run_scanner() (grinder-discover.sh)
# Args: $1 = scanner, $2.. = batch files
# Output: prompt string to stdout
# ---------------------------------------------------------------------------

build_mechanical_prompt() {
  local scanner="$1"
  shift
  local -a files=("$@")

  local prompt
  prompt="Apply deterministic auto-fixes using the project's configured linters and formatters. No creative refactoring.

Constraints:
- Do not add \`# noqa\`, \`# type: ignore\`, \`// eslint-disable\`, \`# shellcheck disable=SCxxxx\`, or any inline suppression.
- Do not modify files outside the batch file list.
- Do not refactor or rename beyond what the linter rule requires."

  case "$scanner" in
    ruff|eslint|prettier)
      prompt="$prompt

Auto-fix tools have already been run on the batch files. Verify the changes are correct and clean up any remaining issues that the auto-fixer could not resolve."
      ;;
    shellcheck)
      # Propose-only: collect findings and embed as structured context
      local findings_json=""
      findings_json=$(discover_run_scanner "shellcheck" "${files[@]}" 2>/dev/null) || true

      # Validate JSON
      # Safe: bash double-quoted expansion substitutes $findings_json literally;
      # contents are not re-parsed for command substitution (bash manual 3.5.3)
      if [[ -n "$findings_json" ]] && echo "$findings_json" | jq empty 2>/dev/null; then
        prompt="$prompt

The following shellcheck findings must be fixed in this batch:
$findings_json

Apply the fix for each finding following the shellcheck rule description.
Do not suppress with directives unless the finding is a false positive."
      else
        echo "mechanical: scanner output is not valid JSON -- skipping shellcheck embed" >&2
      fi
      ;;
  esac

  echo "$prompt"
}

# ---------------------------------------------------------------------------
# C5: run_mechanical_tools() — Direct Auto-Fix Execution
# Reads: discover_resolve_runner() (grinder-discover.sh)
# Args: $1 = scanner, $2.. = batch files
# Returns: 0 always (tool exit codes are informational)
# ---------------------------------------------------------------------------

run_mechanical_tools() {
  local scanner="$1"
  shift
  local -a files=("$@")

  # Skip propose-only tools
  case "$scanner" in
    shellcheck) return 0 ;;
  esac

  local runner
  runner=$(discover_resolve_runner "$scanner")

  case "$scanner" in
    ruff)
      # shellcheck disable=SC2086
      $runner check --fix "${files[@]}" 2>/dev/null || true
      # shellcheck disable=SC2086
      $runner format "${files[@]}" 2>/dev/null || true
      ;;
    eslint)
      # shellcheck disable=SC2086
      $runner --fix "${files[@]}" 2>/dev/null || true
      ;;
    prettier)
      # shellcheck disable=SC2086
      $runner --write "${files[@]}" 2>/dev/null || true
      ;;
  esac

  return 0
}

# ---------------------------------------------------------------------------
# C6: rerun_scanner() — Post-Fix Verification
# Reads: discover_run_scanner() (grinder-discover.sh)
# Args: $1 = scanner, $2 = pre_fix_count, $3 = batch_id, $4.. = batch files
# Returns: 0 if OK, 1 if findings increased (regression)
# Sets: RERUN_FINDINGS_AFTER (global)
# ---------------------------------------------------------------------------

rerun_scanner() {
  local scanner="$1"
  local pre_count="$2"
  local batch_id="$3"
  shift 3
  local -a files=("$@")

  # Re-run scanner
  local post_json
  post_json=$(discover_run_scanner "$scanner" "${files[@]}" 2>/dev/null) || true

  # Count findings
  local post_count=0
  if [[ -n "$post_json" && "$post_json" != "[]" ]]; then
    post_count=$(echo "$post_json" | jq 'length' 2>/dev/null) || post_count=0
  fi

  RERUN_FINDINGS_AFTER=$post_count
  export RERUN_FINDINGS_AFTER

  # Tolerance per EC-10.1
  if [[ "$pre_count" -eq 0 && "$post_count" -gt 0 ]]; then
    echo "mechanical: batch $batch_id findings increased from 0 to $post_count -- regression" >&2
    return 1
  fi

  if [[ "$pre_count" -gt 0 && "$post_count" -gt "$pre_count" ]]; then
    local delta=$((post_count - pre_count))

    if [[ "$delta" -eq 1 ]]; then
      echo "mechanical: batch $batch_id findings increased by 1 (within tolerance) -- allowing commit" >&2
      return 0
    fi

    # Check >10% increase
    local delta_pct_x100=$(( delta * 100 / pre_count ))
    if [[ "$delta_pct_x100" -gt 10 ]]; then
      echo "mechanical: batch $batch_id findings increased from $pre_count to $post_count (${delta_pct_x100}%) -- regression" >&2
      return 1
    fi
  fi

  return 0
}

# ---------------------------------------------------------------------------
# _mechanical_preflight_clean() — operator-hygiene check before batch runs
# ---------------------------------------------------------------------------
# Verifies that every file in batch_files is clean against HEAD (no
# unstaged or staged changes). If any are dirty, the batch is rejected
# before claude session spawns — because the post-claude `git add --
# <file>` would stage the union of claude's intended fixes AND the
# operator's unrelated edits, then commit everything under the grinder
# batch's commit message. That misattributes the operator's work and
# inflates the per-batch findings_after counter with scanner noise
# from the operator's diff lines.
#
# Args: list of batch_file paths (relative to PROJECT_DIR)
# Reads (session): PROJECT_DIR
# Returns: 0 if all clean (or empty arg list); 1 if any file is dirty
# Stderr: when dirty, one error line + one path-per-line + a one-line
#         operator hint to commit/stash and retry
#
# Observed 2026-05-12: when operator had uncommitted edits in
# grinder.sh and grinder.sh was in batch-001's batch_files, the batch
# commit captured the operator's 36-line _emit_orchestrator_event
# function as if grinder wrote it. Findings counter went 5521→5556
# (+35), but those were scanner findings on the operator's new lines,
# not real regressions.
_mechanical_preflight_clean() {
  local -a dirty=()
  local f
  for f in "$@"; do
    # `git diff --quiet HEAD -- <path>` exits 0 if no diff, 1 if diff.
    # Combines unstaged + staged because HEAD as the reference covers
    # both. Suppress stderr (paths outside the repo are caller's bug,
    # not preflight's concern — they'll fail the actual `git add` step
    # downstream with a recognizable error).
    if ! git diff --quiet HEAD -- "$f" 2>/dev/null; then
      dirty+=("$f")
    fi
  done
  if [[ ${#dirty[@]} -eq 0 ]]; then
    return 0
  fi
  {
    echo "mechanical: batch preflight rejected — uncommitted changes in batch_files:"
    for f in "${dirty[@]}"; do
      echo "  $f"
    done
    echo "Commit or stash these changes (or move them out of the batch's file set) and retry the batch."
  } >&2
  return 1
}

# ---------------------------------------------------------------------------
# C7: execute_mechanical_batch() — Full Mechanical Batch Orchestration
# Reads: TOOLS_DIR, LIB_DIR, PROJECT_DIR, GRINDER_DIR, STREAM_FILE,
#         AUTOPILOT_SID, DASHBOARD_DATA, ALLOWED_TOOLS (session globals)
# Args: $1=batch_id, $2=pass_kind, $3=files_json, $4=estimated_turns
# Returns: 0 on success, 1 on failure (includes preflight-dirty rejection)
# Output: key=value lines on stdout (findings_before, findings_after, files_fixed)
# ---------------------------------------------------------------------------

execute_mechanical_batch() {
  local batch_id="$1"
  local _pass_kind="$2"  # reserved for future pass-kind-specific logic
  local files_json="$3"
  local estimated_turns="$4"

  # Parse batch files into array
  local -a batch_files=()
  while IFS= read -r f; do
    [[ -n "$f" ]] && batch_files+=("$f")
  done < <(echo "$files_json" | jq -r '.[]' 2>/dev/null)

  if [[ ${#batch_files[@]} -eq 0 ]]; then
    echo "mechanical: batch $batch_id has no files" >&2
    return 1
  fi

  # Validate no path traversal in batch file paths
  for f in "${batch_files[@]}"; do
    if [[ "$f" == *".."* ]]; then
      echo "mechanical: batch $batch_id rejected — path traversal in file: $f" >&2
      return 1
    fi
  done

  # Preflight: refuse to run if any batch file has uncommitted operator
  # changes. Without this guard the post-claude `git add` step stages
  # operator edits as part of the batch commit (observed 2026-05-12,
  # _emit_orchestrator_event misattributed to batch-001).
  (
    cd "$PROJECT_DIR" || exit 1
    _mechanical_preflight_clean "${batch_files[@]}"
  ) || return 1

  # Step 1: Resolve test command (cached)
  resolve_test_command >/dev/null 2>&1

  # Step 2: Resolve mechanical tools
  local tools
  tools=$(resolve_mechanical_tools "pass-mechanical" 2>/dev/null) || tools=""
  if [[ -z "$tools" ]]; then
    # Infer from file extensions
    local first_ext="${batch_files[0]##*.}"
    case "$first_ext" in
      sh) tools="shellcheck" ;;
      py) tools="ruff" ;;
      js|ts|jsx|tsx) tools="eslint" ;;
    esac
  fi

  local primary_tool="${tools%% *}"

  # Step 3: Record untracked files for new-file tracking on revert
  local pre_untracked=""
  while IFS= read -r d; do
    [[ -z "$d" ]] && continue
    local dir_untracked
    dir_untracked=$(cd "$PROJECT_DIR" && git ls-files --others --exclude-standard "$d" 2>/dev/null || true)
    pre_untracked="$pre_untracked
$dir_untracked"
  done < <(_unique_batch_dirs "${batch_files[@]}")

  # Step 4: Pre-batch test snapshot
  local pre_test_exit=0
  local skip_test_verification=false
  run_tests_for_project || pre_test_exit=$?
  if [[ $pre_test_exit -ne 0 ]]; then
    echo "mechanical: pre-batch tests already failing (exit $pre_test_exit) -- skipping test verification for this batch" >&2
    skip_test_verification=true
  fi

  # Step 5: Count pre-fix findings (filtered to batch files only)
  local pre_findings=0
  local scanner_output_file="$GRINDER_DIR/scanner-output/${primary_tool}.json"
  if [[ -f "$scanner_output_file" ]]; then
    pre_findings=$(jq --argjson files "$files_json" \
      'if type == "array" then [.[] | select(.file as $f | $files | any(. == $f))] | length else 0 end' \
      "$scanner_output_file" 2>/dev/null) || pre_findings=0
  fi

  # EC-7.1: If scanner finds no issues in batch, skip session
  if [[ "$pre_findings" -eq 0 ]]; then
    # Check if the scanner finds anything NOW
    local current_json
    current_json=$(cd "$PROJECT_DIR" && discover_run_scanner "$primary_tool" "${batch_files[@]}" 2>/dev/null) || true
    local current_count=0
    if [[ -n "$current_json" && "$current_json" != "[]" ]]; then
      current_count=$(echo "$current_json" | jq 'length' 2>/dev/null) || current_count=0
    fi
    if [[ "$current_count" -eq 0 ]]; then
      echo "findings_before=0"
      echo "findings_after=0"
      echo "files_fixed=0"
      return 0
    fi
    pre_findings=$current_count
  fi

  # Step 6: Run auto-fix tools directly
  local abs_files=()
  for f in "${batch_files[@]}"; do
    if [[ "$f" == /* ]]; then
      abs_files+=("$f")
    else
      abs_files+=("$PROJECT_DIR/$f")
    fi
  done
  run_mechanical_tools "$primary_tool" "${abs_files[@]}"

  # Step 7: Build prompt and set EXTRA_SYSTEM_PROMPT
  local prompt
  prompt=$(build_mechanical_prompt "$primary_tool" "${batch_files[@]}")
  export EXTRA_SYSTEM_PROMPT="$prompt"

  # Step 8: Run claude session
  export PHASE_TIMEOUT="${GRINDER_BATCH_TIMEOUT:-1800}"
  export MAX_TURNS_PHASE="$estimated_turns"

  local files_list
  files_list=$(printf '%s\n' "${batch_files[@]}")

  local batch_prompt="You are running a grinder batch (mechanical pass, batch $batch_id).

Files to process:
$files_list

Apply mechanical improvements to these files following the project's CLAUDE.md conventions."

  run_phase "$batch_prompt" "grinder-$batch_id" "$PROJECT_DIR" || true
  _grinder_warn_on_turns_exhaustion "$batch_id"

  # Step 9: Re-run scanner
  RERUN_FINDINGS_AFTER=0
  if ! rerun_scanner "$primary_tool" "$pre_findings" "$batch_id" "${batch_files[@]}"; then
    # Findings increased — revert
    echo "mechanical: batch $batch_id reverted -- findings increased after fix" >&2
    _mechanical_revert_batch "${batch_files[@]}" "$pre_untracked"
    return 1
  fi

  # Step 10: Post-batch test verification
  if [[ "$skip_test_verification" == "false" ]]; then
    local post_test_exit=0
    run_tests_for_project || post_test_exit=$?
    if [[ $pre_test_exit -eq 0 && $post_test_exit -ne 0 ]]; then
      echo "mechanical: batch $batch_id reverted -- test regression detected" >&2
      _mechanical_revert_batch "${batch_files[@]}" "$pre_untracked"
      return 1
    fi
  fi

  # Step 11: Check if anything changed
  cd "$PROJECT_DIR" || return 1
  local changed_count=0
  for f in "${batch_files[@]}"; do
    if ! git diff --quiet -- "$f" 2>/dev/null; then
      changed_count=$((changed_count + 1))
    fi
  done

  # EC-6.2: No files changed
  if [[ $changed_count -eq 0 ]]; then
    echo "findings_before=$pre_findings"
    echo "findings_after=${RERUN_FINDINGS_AFTER:-0}"
    echo "files_fixed=0"
    return 0
  fi

  # Step 12: Stage batch files
  for f in "${batch_files[@]}"; do
    git add -- "$f" 2>/dev/null || true
  done

  # Step 13: Commit with REQ-6 format (NO --no-verify)
  local commit_msg="fix(grinder): pass-1-autofix / $primary_tool (batch $batch_id)"
  if ! git commit -m "$commit_msg" 2>/dev/null; then
    echo "mechanical: batch $batch_id reverted -- pre-commit hook failure" >&2
    _mechanical_revert_batch "${batch_files[@]}" "$pre_untracked"
    return 1
  fi

  # Step 14: Output findings data
  echo "findings_before=$pre_findings"
  echo "findings_after=${RERUN_FINDINGS_AFTER:-0}"
  echo "files_fixed=$changed_count"
  return 0
}

# ---------------------------------------------------------------------------
# _unique_batch_dirs() — Extract unique directory names from file paths
# Args: file paths
# Output: one directory per line (unique, deduplicated)
# ---------------------------------------------------------------------------

_unique_batch_dirs() {
  local -a dirs=()
  local f d already
  for f in "$@"; do
    d=$(dirname "$f")
    already=false
    for existing in "${dirs[@]+"${dirs[@]}"}"; do
      [[ "$existing" == "$d" ]] && { already=true; break; }
    done
    [[ "$already" == "false" ]] && dirs+=("$d")
  done
  printf '%s\n' "${dirs[@]+"${dirs[@]}"}"
}

# ---------------------------------------------------------------------------
# _mechanical_revert_batch() — Revert batch file changes
# Args: batch_files... then last arg is pre_untracked string
# ---------------------------------------------------------------------------

_mechanical_revert_batch() {
  local -a args=("$@")
  local last_idx=$(( ${#args[@]} - 1 ))
  local pre_untracked="${args[$last_idx]}"
  unset "args[$last_idx]"
  local -a batch_files=("${args[@]}")

  cd "$PROJECT_DIR" || return 1

  # Revert modified tracked files
  for f in "${batch_files[@]}"; do
    git checkout -- "$f" 2>/dev/null || true
  done

  # Find and clean new untracked files in batch directories
  local -a batch_dirs=()
  while IFS= read -r d; do
    [[ -n "$d" ]] && batch_dirs+=("$d")
  done < <(_unique_batch_dirs "${batch_files[@]}")

  local new_file_count=0
  for d in "${batch_dirs[@]+"${batch_dirs[@]}"}"; do
    local post_untracked
    post_untracked=$(git ls-files --others --exclude-standard "$d" 2>/dev/null || true)
    while IFS= read -r new_file; do
      [[ -z "$new_file" ]] && continue
      # Check if this file existed before
      if ! echo "$pre_untracked" | grep -qxF "$new_file"; then
        git clean -f -- "$new_file" 2>/dev/null || true
        new_file_count=$((new_file_count + 1))
      fi
    done <<< "$post_untracked"
  done

  if [[ $new_file_count -gt 0 ]]; then
    echo "mechanical: cleaned $new_file_count new file(s) created by session" >&2
  fi
}

# ---------------------------------------------------------------------------
# _grinder_warn_on_turns_exhaustion() — Diagnostic WARN on max-turns drain
#
# When a grinder batch's claude session terminates because it exhausted
# the turn budget mid-tool-use, append a structured "warning" line to
# $STREAM_FILE so the operator (and the dashboard's stream tail) have a
# discoverable signal that the per-pass formula needs raising for that
# batch shape. R6 from REQUIREMENTS-grinder-turn-budget.
#
# Args:
#   $1 — batch_id (string), embedded in the WARN line.
#
# Reads:
#   STREAM_FILE — env var, set by grinder.sh when the orchestrator wires
#   the persistent stream-of-events file. Required.
#
# Writes:
#   At most one JSON line appended to $STREAM_FILE, of the shape:
#     {"type":"warning","batch":"<id>",
#      "message":"WARNING: batch <id> ended mid-tool-use — consider raising MAX_TURNS_PHASE",
#      "ts":"<RFC3339-UTC>"}
#
# Returns:
#   Always 0. The helper is diagnostic — never load-bearing for revert
#   correctness. Failures (unset/unwritable STREAM_FILE, malformed
#   stream lines) are logged to stderr and swallowed.
#
# Detection:
#   Read the tail of $STREAM_FILE (~200 lines) and find the most-recent
#   `result` event. If its `subtype` is `error_max_turns` AND the
#   most-recent `assistant` event preceding it ended with
#   `stop_reason: tool_use`, emit the WARN. The conjunctive pairing
#   matches the canonical claude session output for an exhausted
#   tool-using turn (per REQUIREMENTS § OQ-3).
# ---------------------------------------------------------------------------

_grinder_warn_on_turns_exhaustion() {
  local batch_id="${1:-unknown}"

  # EC-6: STREAM_FILE unset or empty → fail soft.
  if [[ -z "${STREAM_FILE:-}" ]]; then
    echo "grinder-warn: stream file unavailable, skipping turn-budget warning for batch $batch_id" >&2
    return 0
  fi
  if [[ ! -f "$STREAM_FILE" ]]; then
    echo "grinder-warn: stream file unavailable, skipping turn-budget warning for batch $batch_id" >&2
    return 0
  fi
  if [[ ! -w "$STREAM_FILE" ]]; then
    echo "grinder-warn: stream file unavailable, skipping turn-budget warning for batch $batch_id" >&2
    return 0
  fi

  # Tail-200 strategy — see PLAN.md § C5: bounds the per-batch read to
  # O(constant) regardless of stream-file growth. The tail is piped
  # straight into the inline python parser via stdin (using ``python3
  # -c`` so the heredoc does not collide with the data stream), which
  # avoids needing a temp file in a possibly-unwritable $TMPDIR.
  #
  # Inline python parser — finds the conjunctive event pair. Exit 0 →
  # emit WARN; non-zero → no WARN.
  local parser='
import json
import sys

events = []
for raw in sys.stdin:
    raw = raw.strip()
    if not raw:
        continue
    try:
        events.append(json.loads(raw))
    except (json.JSONDecodeError, ValueError):
        continue

last_result_idx = None
for i in range(len(events) - 1, -1, -1):
    if events[i].get("type") == "result":
        last_result_idx = i
        break

if last_result_idx is None:
    sys.exit(1)
if events[last_result_idx].get("subtype") != "error_max_turns":
    sys.exit(1)

last_assistant = None
for i in range(last_result_idx - 1, -1, -1):
    if events[i].get("type") == "assistant":
        last_assistant = events[i]
        break

if last_assistant is None:
    sys.exit(1)
msg = last_assistant.get("message") or {}
if msg.get("stop_reason") != "tool_use":
    sys.exit(1)

sys.exit(0)
'
  if ! tail -n 200 "$STREAM_FILE" 2>/dev/null | python3 -c "$parser" >/dev/null 2>&1; then
    return 0
  fi

  # Conjunctive pair confirmed — append WARN line. Use jq --arg for
  # JSON-safe escaping of batch_id even though batch IDs are normally
  # ASCII-safe (RSK-9).
  local ts
  ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  local message="WARNING: batch ${batch_id} ended mid-tool-use — consider raising MAX_TURNS_PHASE"
  local warn_line
  warn_line=$(jq -nc \
    --arg id "$batch_id" \
    --arg msg "$message" \
    --arg ts "$ts" \
    '{type:"warning", batch:$id, message:$msg, ts:$ts}' 2>/dev/null) || {
    echo "grinder-warn: jq failed, skipping turn-budget warning for batch $batch_id" >&2
    return 0
  }

  printf '%s\n' "$warn_line" >> "$STREAM_FILE" 2>/dev/null || {
    echo "grinder-warn: append to stream file failed for batch $batch_id" >&2
    return 0
  }

  return 0
}
