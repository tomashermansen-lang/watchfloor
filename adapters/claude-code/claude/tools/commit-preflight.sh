#!/usr/bin/env bash
set -euo pipefail

# ── commit-preflight.sh ──
# Gathers pre-commit context in a single execution.
# Standard mode: test results + git status + diff + recent commits
# Flow mode (--flow): adds branch, worktree, QA report, uncommitted checks
# Ratchet mode (--ratchet): tier-classified findings + suppression scan
#
# Usage:
#   commit-preflight.sh [--flow] [--ratchet] [--test-cmd CMD]
#
# Output: JSON to stdout. All diagnostics to stderr.
# Exit: Always 0 for standard/flow. Ratchet exits 1 on block.

# ── Init ratchet flag before error trap ──
RATCHET=false

# ── Error trap: ensure valid JSON on crash ──
_bail() {
  if [ "${RATCHET}" = "true" ]; then
    jq -n --arg error "$1" '{"ok":false,"ratchet":true,"error":$error}' 2>/dev/null \
      || printf '{"ok":false,"ratchet":true,"error":"internal error"}\n'
    exit 1
  else
    jq -n --arg error "$1" '{"ok":false,"error":$error}' 2>/dev/null \
      || printf '{"ok":false,"error":"internal error"}\n'
    exit 0
  fi
}
trap '_bail "unexpected error at line $LINENO"' ERR

# ── Dependency checks ──
command -v jq >/dev/null 2>&1 || { _bail "jq not found — install with: brew install jq"; }
command -v git >/dev/null 2>&1 || { _bail "git not available"; }

# ── Verify we're in a git repo ──
git rev-parse --git-dir >/dev/null 2>&1 || { _bail "not a git repository"; }

# ── Resolve SCRIPT_DIR ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ── Parse arguments ──
FLOW=false
TEST_CMD=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --flow) FLOW=true; shift ;;
    --ratchet) RATCHET=true; shift ;;
    --test-cmd) TEST_CMD="$2"; shift 2 ;;
    *) shift ;;
  esac
done

# ── Mutual exclusion: --ratchet + --flow ──
if [ "$RATCHET" = "true" ] && [ "$FLOW" = "true" ]; then
  echo "--ratchet and --flow are mutually exclusive" >&2
  exit 1
fi

# ═══════════════════════════════════════════════════════════════════════════
# RATCHET MODE
# ═══════════════════════════════════════════════════════════════════════════
if [ "$RATCHET" = "true" ]; then

  # ── Validate git diff base ──
  DIFF_BASE="${RATCHET_DIFF_BASE:-main}"
  if ! git merge-base "$DIFF_BASE" HEAD >/dev/null 2>&1; then
    echo "ratchet: no common ancestor between $DIFF_BASE and HEAD" >&2
    jq -n '{"ok":false,"ratchet":true,"error":"no common ancestor with main"}'
    exit 1
  fi

  # ── Resolve deferred-findings path ──
  PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
  DEFERRED_PATH="${DEFERRED_FINDINGS_PATH:-$PROJECT_ROOT/docs/grinder/deferred-findings.json}"

  # ── Temp files with cleanup ──
  RATCHET_TMP=$(mktemp -d "${TMPDIR:-/tmp}/ratchet-XXXXXX")
  # shellcheck disable=SC2329  # invoked indirectly via trap
  _ratchet_cleanup() { rm -rf "$RATCHET_TMP"; }
  trap '_ratchet_cleanup' EXIT INT TERM HUP

  # ── Step 1: Discover scanners ──
  discover_json=$(python3 "$SCRIPT_DIR/lib/ratchet-discover.py" --project-root "$PROJECT_ROOT" 2>/dev/null || echo '{"scanners":[],"warnings":["discover failed"]}')
  warnings_json=$(echo "$discover_json" | jq -c '.warnings // []')

  # Log warnings to stderr
  echo "$discover_json" | jq -r '.warnings[]? // empty' >&2 || true

  # ── Step 2: Run scanners and accumulate findings ──
  scanner_errors=()
  all_findings="$RATCHET_TMP/all-findings.json"
  echo "[]" > "$all_findings"

  scanner_count=$(echo "$discover_json" | jq '.scanners | length')
  if [ "$scanner_count" -gt 0 ]; then
  for i in $(seq 0 $((scanner_count - 1))); do
    tool=$(echo "$discover_json" | jq -r ".scanners[$i].tool")
    # Build command as shell-safe string via jq
    scanner_cmd=$(echo "$discover_json" | jq -r "[.scanners[$i].command[] | @sh] | join(\" \")")

    scanner_out="$RATCHET_TMP/scanner-$tool.json"
    eval_exit=0
    (eval "$scanner_cmd") > "$scanner_out" 2>/dev/null || eval_exit=$?
    if [ "$eval_exit" -eq 0 ]; then
      # Merge into accumulated findings
      if [ -s "$scanner_out" ] && jq -e '.' "$scanner_out" >/dev/null 2>&1; then
        jq -s 'add // []' "$all_findings" "$scanner_out" > "$RATCHET_TMP/merged.json"
        mv "$RATCHET_TMP/merged.json" "$all_findings"
      fi
    else
      scanner_errors+=("$tool")
      echo "ratchet: scanner $tool failed, continuing" >&2
    fi
  done
  fi

  # ── Step 3: Classify findings into tiers ──
  classify_stderr="$RATCHET_TMP/classify.err"
  classify_json=$(python3 "$SCRIPT_DIR/lib/ratchet-classify.py" --diff-base "$DIFF_BASE" < "$all_findings" 2>"$classify_stderr") || true
  if [ -z "$classify_json" ]; then
    classify_json='{"must_fix":[],"should_fix":[],"may_defer":[]}'
    echo "ratchet: classifier failed — treating as empty results" >&2
    warnings_json=$(echo "$warnings_json" | jq '. + ["classifier failed"]')
  fi

  must_fix=$(echo "$classify_json" | jq -c '.must_fix // []')
  should_fix=$(echo "$classify_json" | jq -c '.should_fix // []')
  may_defer=$(echo "$classify_json" | jq -c '.may_defer // []')

  # ── Step 4: SHOULD-fix deferral check ──
  unresolved_should=()
  if [ "$(echo "$should_fix" | jq 'length')" -gt 0 ]; then
    # Load deferred entries via plan_yaml_deferred — single dispatch point
    # for both 1.x JSON and 2.0 YAML graph sources.
    deferred_ids="[]"
    plan_yaml_helper="$SCRIPT_DIR/lib/plan_yaml_deferred.py"
    if [ -f "$plan_yaml_helper" ]; then
      raw_deferred=$(python3 "$plan_yaml_helper" dump -- "$DEFERRED_PATH" 2>/dev/null || echo "[]")
    elif [ -f "$DEFERRED_PATH" ]; then
      raw_deferred=$(cat "$DEFERRED_PATH")
    else
      raw_deferred="[]"
    fi
    if echo "$raw_deferred" | jq -e '.' >/dev/null 2>&1; then
      deferred_ids=$(echo "$raw_deferred" | jq -c '[.[].finding_id]')
    else
      echo "ratchet: deferred source is corrupt" >&2
      jq -n '{"ok":false,"ratchet":true,"error":"deferred source corrupt"}'
      exit 1
    fi

    # Check each SHOULD-fix finding — single jq pass extracts unresolved IDs
    unresolved_should=()
    while IFS= read -r fid; do
      [ -z "$fid" ] && continue
      unresolved_should+=("$fid")
      echo "SHOULD-fix finding requires deferred-findings.json entry or fix: $fid" >&2
    done < <(
      echo "$should_fix" | jq -r --argjson deferred "$deferred_ids" '
        .[] | select(.id as $fid | $deferred | index($fid) | not) | .id
      '
    )
  fi

  # ── Step 5: MAY-defer auto-log ──
  autolog_json="[]"
  if [ "$(echo "$may_defer" | jq 'length')" -gt 0 ]; then
    autolog_json=$(echo "$may_defer" | python3 "$SCRIPT_DIR/lib/ratchet-autolog.py" --deferred "$DEFERRED_PATH" 2>/dev/null || echo "[]")
  fi

  # ── Step 6: Suppression scan ──
  suppressions=$(python3 "$SCRIPT_DIR/lib/ratchet-suppression.py" --diff-base "$DIFF_BASE" 2>/dev/null || echo "[]")

  # Print suppression violations to stderr
  supp_count=$(echo "$suppressions" | jq 'length')
  if [ "$supp_count" -gt 0 ]; then
    echo "$suppressions" | jq -r '.[] | "inline suppression rejected on changed line \(.file):\(.line) — use deferred-findings.json instead"' >&2
  fi

  # ── Step 7: Run tests if --test-cmd provided ──
  tests_result="null"
  test_output_ratchet=""
  if [ -n "$TEST_CMD" ]; then
    test_raw=""
    test_exit=0
    test_raw=$(eval "$TEST_CMD" 2>&1) || test_exit=$?
    if [ "$test_exit" -eq 0 ]; then
      tests_result="true"
    else
      tests_result="false"
    fi
    test_output_ratchet=$(echo "$test_raw" | tail -30 | tr -d '\000-\010\013\014\016-\037\177')
  fi

  # ── Step 8: Print MUST-fix findings to stderr ──
  mf_count=$(echo "$must_fix" | jq 'length')
  if [ "$mf_count" -gt 0 ]; then
    echo "$must_fix" | jq -r '.[] | "MUST-fix: \(.file):\(.line) \(.rule) (\(.severity))"' >&2
  fi

  # ── Step 9: Determine ok status ──
  ok="true"
  if [ "$mf_count" -gt 0 ] || [ "${#unresolved_should[@]}" -gt 0 ] || [ "$supp_count" -gt 0 ]; then
    ok="false"
  fi
  if [ "$tests_result" = "false" ]; then
    ok="false"
  fi

  # ── Step 10: Compute summary counts ──
  auto_logged_count=$(echo "$autolog_json" | jq '[.[] | select(.auto_logged == true)] | length' 2>/dev/null || echo "0")

  # Add scanner errors to warnings
  for err_tool in "${scanner_errors[@]+"${scanner_errors[@]}"}"; do
    warnings_json=$(echo "$warnings_json" | jq --arg t "$err_tool" '. + ["scanner failed: " + $t]')
  done

  # ── Step 11: Assemble and emit JSON output ──
  jq -n \
    --argjson ok "$ok" \
    --argjson must_fix "$must_fix" \
    --argjson should_fix "$should_fix" \
    --argjson may_defer "$may_defer" \
    --argjson suppressions "$suppressions" \
    --argjson warnings "$warnings_json" \
    --argjson mf_count "$mf_count" \
    --argjson sf_count "$(echo "$should_fix" | jq 'length')" \
    --argjson md_count "$(echo "$may_defer" | jq 'length')" \
    --argjson supp_count "$supp_count" \
    --argjson auto_logged "$auto_logged_count" \
    --argjson tests_passed "$tests_result" \
    --arg test_output "$test_output_ratchet" \
    '{
      ok: $ok,
      ratchet: true,
      must_fix: $must_fix,
      should_fix: $should_fix,
      may_defer: $may_defer,
      suppressions: $suppressions,
      warnings: $warnings,
      summary: {
        must_fix_count: $mf_count,
        should_fix_count: $sf_count,
        may_defer_count: $md_count,
        suppression_count: $supp_count,
        auto_logged_count: $auto_logged
      }
    } + (if $tests_passed != null then {tests_passed: $tests_passed, test_output: $test_output} else {} end)'

  if [ "$ok" = "true" ]; then
    exit 0
  else
    exit 1
  fi
fi

# ═══════════════════════════════════════════════════════════════════════════
# STANDARD / FLOW MODE (unchanged)
# ═══════════════════════════════════════════════════════════════════════════

# ── Auto-detect test command if not provided ──
if [ -z "$TEST_CMD" ]; then
  if [ -x "./scripts/run_tests.sh" ]; then
    TEST_CMD="./scripts/run_tests.sh"
  fi
fi

# ── tests-green-sha skip optimization ──
# /implement (Step 5), /qa (after fix loop), and /static-analysis (after
# fix loop) each write the marker `.tests-green-sha` when they exit with
# tests + lint + type-check green. If commit-preflight is invoked and HEAD
# (or the diff since the marker) does not require a re-test, skip the full
# rerun. Three skip paths, ordered most-specific first:
#
#   (1) HEAD == marker_sha                    — exact state proved green
#   (2) diff since marker is docs/markdown    — no behavioral change
#   (3) diff since marker is purely
#       `fix(<scope>): resolve static analysis
#       findings` commits                     — fix-loop commits land
#                                               between /static-analysis
#                                               and /commit and the
#                                               fix-loop already ran tests
#
# 4-min savings per feature in the common case. Guarded by
# COMMIT_PREFLIGHT_FORCE_TESTS=1 escape.
qa_skip_reason=""
if [ -n "$TEST_CMD" ] && [ "${COMMIT_PREFLIGHT_FORCE_TESTS:-0}" != "1" ]; then
  # Find the marker — it lives next to the active feature docs.
  qa_marker=""
  for candidate in docs/INPROGRESS_Feature_*/.tests-green-sha; do
    if [ -f "$candidate" ]; then
      qa_marker="$candidate"
      break
    fi
  done

  if [ -n "$qa_marker" ]; then
    qa_sha=$(tr -d '[:space:]' < "$qa_marker" 2>/dev/null || echo "")
    head_sha=$(git rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$qa_sha" ] && [ -n "$head_sha" ] && [ "$qa_sha" = "$head_sha" ]; then
      qa_skip_reason="HEAD ($head_sha) matches .tests-green-sha — tests skipped"
    elif [ -n "$qa_sha" ] && [ -n "$head_sha" ]; then
      # HEAD moved — check if the diff is purely test-irrelevant.
      changed=$(git diff --name-only "$qa_sha" HEAD 2>/dev/null || true)
      non_doc=$(echo "$changed" | grep -vE '^docs/|\.md$' || true)
      if [ -z "$non_doc" ] && [ -n "$changed" ]; then
        qa_skip_reason="only docs/markdown changed since .tests-green-sha — tests skipped"
      else
        # Path 3: all commits since the marker are static-analysis fix
        # commits. The fix loop already ran tests after the final fix
        # landed; rerunning them here is the redundancy this optimization
        # exists to remove.
        commit_subjects=$(git log --pretty=format:'%s' "$qa_sha..HEAD" 2>/dev/null || true)
        if [ -n "$commit_subjects" ]; then
          non_static_fix=$(echo "$commit_subjects" \
            | grep -vE '^fix\([^)]+\): resolve static analysis findings$' \
            | grep -vE '^docs\([^)]+\): static analysis report$' \
            || true)
          if [ -z "$non_static_fix" ]; then
            qa_skip_reason="only static-analysis fix commits since .tests-green-sha — tests skipped"
          fi
        fi
      fi
    fi
  fi
fi

# ── Run tests (or skip if .tests-green-sha matches) ──
tests_passed="null"
test_output=""
if [ -n "$qa_skip_reason" ]; then
  tests_passed="true"
  test_output="$qa_skip_reason"
elif [ -n "$TEST_CMD" ]; then
  test_raw=""
  test_exit=0
  test_raw=$(eval "$TEST_CMD" 2>&1) || test_exit=$?
  if [ "$test_exit" -eq 0 ]; then
    tests_passed="true"
  else
    tests_passed="false"
  fi
  # Truncate to last 30 lines, strip control chars
  test_output=$(echo "$test_raw" | tail -30 | tr -d '\000-\010\013\014\016-\037\177')
fi

# ── Gather git context ──
status=$(git status --short 2>/dev/null || true)
diff_stat=$(git diff --stat 2>/dev/null || true)
recent_commits=$(git log --oneline -5 2>/dev/null || true)

# ── Standard mode output ──
if [ "$FLOW" = "false" ]; then
  ok="true"
  error=""
  if [ "$tests_passed" = "false" ]; then
    ok="false"
    error="tests failed"
  elif [ "$tests_passed" = "null" ]; then
    ok="false"
    error="no test runner found (use --test-cmd or create ./scripts/run_tests.sh)"
  fi

  jq -n \
    --argjson ok "$ok" \
    --argjson tests_passed "$tests_passed" \
    --arg test_output "$test_output" \
    --arg status "$status" \
    --arg diff_stat "$diff_stat" \
    --arg recent_commits "$recent_commits" \
    --arg error "$error" \
    '{ok:$ok, tests_passed:$tests_passed, test_output:$test_output, status:$status, diff_stat:$diff_stat, recent_commits:$recent_commits} + (if $error != "" then {error:$error} else {} end)'
  exit 0
fi

# ── Flow mode: additional context ──
branch=$(git branch --show-current 2>/dev/null || true)

# Determine if we're in a worktree (not the main worktree)
is_worktree=false
main_worktree=""
wt_porcelain=$(git worktree list --porcelain 2>/dev/null || true)
# First worktree listed is always the main one
main_worktree=$(echo "$wt_porcelain" | head -1 | sed 's/^worktree //')
current_dir=$(pwd -P)
if [ "$current_dir" != "$main_worktree" ]; then
  is_worktree=true
fi

# Check for QA report
has_qa_report=false
# Extract feature name from branch (feature/foo → foo)
if [ -n "$branch" ]; then
  feature_name="${branch##*/}"
  # Check docs/*<feature>*/QA_REPORT.md or TEAM_QA.md
  if compgen -G "docs/*${feature_name}*/QA_REPORT.md" >/dev/null 2>&1 || \
     compgen -G "docs/*${feature_name}*/TEAM_QA.md" >/dev/null 2>&1; then
    has_qa_report=true
  fi
fi

uncommitted="$status"

# Determine ok status for flow mode
ok="true"
error=""
if [ "$is_worktree" = "false" ]; then
  ok="false"
  error="not in a worktree — /commit flow must run from a feature worktree"
elif [ -z "$branch" ]; then
  ok="false"
  error="detached HEAD — cannot determine branch"
elif [ "$tests_passed" = "false" ]; then
  ok="false"
  error="tests failed"
elif [ "$tests_passed" = "null" ]; then
  ok="false"
  error="no test runner found (use --test-cmd or create ./scripts/run_tests.sh)"
fi

jq -n \
  --argjson ok "$ok" \
  --argjson tests_passed "$tests_passed" \
  --arg test_output "$test_output" \
  --argjson is_worktree "$is_worktree" \
  --arg main_worktree "$main_worktree" \
  --argjson has_qa_report "$has_qa_report" \
  --arg uncommitted "$uncommitted" \
  --arg error "$error" \
  --arg branch_str "${branch:-}" \
  '{ok:$ok, tests_passed:$tests_passed, test_output:$test_output, branch:(if $branch_str == "" then null else $branch_str end), is_worktree:$is_worktree, main_worktree:$main_worktree, has_qa_report:$has_qa_report, uncommitted:$uncommitted} + (if $error != "" then {error:$error} else {} end)'

exit 0
