#!/usr/bin/env bash
# integration_trigger_matches — the §5 conditional-trigger decision for the
# orchestrator integration gate (real integration gates). Given a phase's
# changed files and the manifest's trigger globs, decide whether the heavy
# integration suite should FIRE (the phase touched the project's declared infra
# surface) or be SKIPPED (per-task gates already covered it). Pure function,
# unit-tested in isolation here before 3b-2 wires it into autopilot-chain.sh.
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/adapters/claude-code/claude/tools/lib/claude-session-lib.sh"

PASS=0
FAIL=0
check() { if "$2"; then echo "  ok: $1"; PASS=$((PASS + 1)); else echo "  FAIL: $1"; FAIL=$((FAIL + 1)); fi; }

# fire <globs> <files>: source the lib, call the matcher, echo "rc=N".
fire() {
  bash -c "
    source '$LIB' 2>/dev/null
    integration_trigger_matches \"\$1\" \"\$2\"; echo \"rc=\$?\"
  " _ "$1" "$2"
}

test_match_fires() {
  local o; o=$(fire "dashboard/**" $'dashboard/server/app.py\nREADME.md')
  echo "$o" | grep -qx 'rc=0' || { echo "    a changed file under the glob must FIRE; got: $o"; return 1; }
}
check "matches glob → fire (rc=0)" test_match_fires

test_no_match_skips() {
  local o; o=$(fire "dashboard/**" $'tests/foo.py\nREADME.md')
  echo "$o" | grep -qx 'rc=1' || { echo "    no file under any glob must SKIP; got: $o"; return 1; }
}
check "no file under any glob → skip (rc=1)" test_no_match_skips

test_second_glob_matches() {
  local o; o=$(fire $'dashboard/**\ncore/schema/**' "core/schema/execution-plan.schema.json")
  echo "$o" | grep -qx 'rc=0' || { echo "    a match on any glob must fire; got: $o"; return 1; }
}
check "matches any of multiple globs → fire" test_second_glob_matches

test_empty_globs_always_fires() {
  # No declared trigger ⇒ the gate is always eligible (manifest "trigger absent"
  # semantics) — fail-open so an unscoped project still gets integration cover.
  local o; o=$(fire "" "anything.py")
  echo "$o" | grep -qx 'rc=0' || { echo "    empty globs must fire (always eligible); got: $o"; return 1; }
}
check "empty globs → always fire" test_empty_globs_always_fires

test_empty_files_skips() {
  local o; o=$(fire "dashboard/**" "")
  echo "$o" | grep -qx 'rc=1' || { echo "    no changed files → skip; got: $o"; return 1; }
}
check "empty file list → skip" test_empty_files_skips

test_prefix_collision_no_match() {
  # `dashboard/**` must NOT match a sibling dir that merely shares the prefix.
  local o; o=$(fire "dashboard/**" "dashboardX/y.py")
  echo "$o" | grep -qx 'rc=1' || { echo "    prefix-only collision must not match; got: $o"; return 1; }
}
check "prefix collision (dashboardX) → no match" test_prefix_collision_no_match

test_deep_nesting_matches() {
  local o; o=$(fire "adapters/claude-code/claude/tools/**" "adapters/claude-code/claude/tools/lib/x.sh")
  echo "$o" | grep -qx 'rc=0' || { echo "    ** must match across directory depth; got: $o"; return 1; }
}
check "** matches deep nested path → fire" test_deep_nesting_matches

test_exact_file_glob() {
  local o; o=$(fire "pipeline.yaml" $'pipeline.yaml\nfoo.py')
  echo "$o" | grep -qx 'rc=0' || { echo "    an exact-file trigger must match that file; got: $o"; return 1; }
}
check "exact-file glob matches → fire" test_exact_file_glob

test_exact_file_glob_no_false_positive() {
  local o; o=$(fire "pipeline.yaml" "pipeline.yaml.bak")
  echo "$o" | grep -qx 'rc=1' || { echo "    exact-file trigger must not match a different file; got: $o"; return 1; }
}
check "exact-file glob does not over-match" test_exact_file_glob_no_false_positive

echo ""
echo "test_integration_trigger: $PASS passed, $FAIL failed"
[[ "$FAIL" == "0" ]]
