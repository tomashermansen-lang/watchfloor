#!/usr/bin/env bash
# test_deviation_assessor_agent.sh — structural test for the
# deviation-assessor Claude Code agent definition. Asserts:
#   - frontmatter shape (name, description, tools allow/deny list)
#   - body content (phase_result schema, 12 deviation enum values,
#     4 input-field references, banned-phrases list, reasoning-required
#     protocol)
#   - sample_input.json fixture shape
#   - cross-doc consistency between body and fixture on artifact-ref name
#   - branch diff scope vs main
#   - <5s wall-clock runtime (REQ-8)
#
# Reads files only. Issues no `claude -p` calls, no network calls,
# and no edits to tracked files.
#
# Usage: bash tests/test_deviation_assessor_agent.sh
# Exits 0 on all-pass, 1 on any failure or runtime breach.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
AGENT_FILE="$REPO_DIR/adapters/claude-code/claude/agents/deviation-assessor.md"
FIXTURE="$REPO_DIR/tests/fixtures/deviation_assessor/sample_input.json"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

START=$SECONDS

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

teardown() {
  local runtime=$((SECONDS - START))
  if [[ $runtime -gt 5 ]]; then
    echo "RUNTIME EXCEEDED 5s: ${runtime}s" >&2
    exit 1
  fi
}
trap teardown EXIT

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------

# Extract YAML frontmatter (between the first two --- lines).
extract_frontmatter() {
  awk '/^---$/{c++; next} c==1' "$AGENT_FILE"
}

# Extract markdown body (everything after the second ---).
extract_body() {
  awk '/^---$/{c++; next} c==2' "$AGENT_FILE"
}

# Substring presence check on body.
body_has_substring() {
  extract_body | grep -Fq -- "$1"
}

# -----------------------------------------------------------------------------
# Frontmatter checks (Scenario A → REQ-1, REQ-2, REQ-3)
# -----------------------------------------------------------------------------

a1_frontmatter_parses() {
  [[ -f "$AGENT_FILE" ]] || { echo "  agent file missing: $AGENT_FILE"; return 1; }
  extract_frontmatter | python3 -c "
import sys, yaml
yaml.safe_load(sys.stdin.read())
" 2>/dev/null
}
check "A1: frontmatter parses as YAML" a1_frontmatter_parses

a2_name_is_deviation_assessor() {
  extract_frontmatter | python3 -c "
import sys, yaml
d = yaml.safe_load(sys.stdin.read()) or {}
assert d.get('name') == 'deviation-assessor', f'name={d.get(\"name\")!r}'
" 2>&1
}
check "A2: name == deviation-assessor" a2_name_is_deviation_assessor

a3_description_at_least_120_chars() {
  extract_frontmatter | python3 -c "
import sys, yaml
d = yaml.safe_load(sys.stdin.read()) or {}
desc = d.get('description', '')
assert isinstance(desc, str), f'description not a string: {type(desc).__name__}'
assert len(desc) >= 120, f'len={len(desc)}'
" 2>&1
}
check "A3: description length >= 120" a3_description_at_least_120_chars

a4_tools_includes_read_bash_grep() {
  extract_frontmatter | python3 -c "
import sys, yaml
d = yaml.safe_load(sys.stdin.read()) or {}
t = d.get('tools')
tokens = t if isinstance(t, list) else [s.strip() for s in str(t).split(',')]
for required in ('Read', 'Bash', 'Grep'):
    assert required in tokens, f'{required} not in tools={tokens}'
" 2>&1
}
check "A4: tools includes Read, Bash, Grep" a4_tools_includes_read_bash_grep

a5_tools_excludes_edit_and_write() {
  extract_frontmatter | python3 -c "
import sys, yaml
d = yaml.safe_load(sys.stdin.read()) or {}
t = d.get('tools')
tokens = t if isinstance(t, list) else [s.strip() for s in str(t).split(',')]
assert 'Edit' not in tokens, f'Edit present in tools={tokens}'
assert 'Write' not in tokens, f'Write present in tools={tokens}'
" 2>&1
}
check "A5: tools excludes Edit and Write" a5_tools_excludes_edit_and_write

# -----------------------------------------------------------------------------
# Body checks (Scenario B → REQ-4, REQ-5, REQ-6)
# -----------------------------------------------------------------------------

b1_body_contains_phase_result_field_names() {
  for field in phase timestamp conformance acceptance_status deviations; do
    body_has_substring "$field" || { echo "  body missing field: $field"; return 1; }
  done
  return 0
}
check "B1: body contains 5 phase_result field names" b1_body_contains_phase_result_field_names

b2_body_contains_enum_constraints() {
  body_has_substring "aligned | deviated" || { echo "  body missing 'aligned | deviated'"; return 1; }
  body_has_substring "met | partial | unmet" || { echo "  body missing 'met | partial | unmet'"; return 1; }
  body_has_substring "date-time" || { echo "  body missing 'date-time'"; return 1; }
  return 0
}
check "B2: body contains enum constraints + date-time" b2_body_contains_enum_constraints

b3_body_contains_all_12_deviation_enum_values() {
  for enum in \
    scope_change requirement_added requirement_dropped strategy_change \
    integration_gap gate_logic_drift error_reporting_tautology factual_error \
    test_tautology sycophancy acceptance_reinterpretation \
    architectural_change_without_anchor; do
    body_has_substring "$enum" || { echo "  body missing enum: $enum"; return 1; }
  done
  return 0
}
check "B3: body lists all 12 deviation type enum values" b3_body_contains_all_12_deviation_enum_values

b4_body_names_4_input_fields() {
  body_has_substring "heuristic_flags" || { echo "  body missing 'heuristic_flags'"; return 1; }
  body_has_substring "task.acceptance" || { echo "  body missing 'task.acceptance'"; return 1; }
  body_has_substring "task.prompt" || { echo "  body missing 'task.prompt'"; return 1; }
  if ! body_has_substring "commit_ref" && ! body_has_substring "commit_sha"; then
    echo "  body missing both 'commit_ref' and 'commit_sha'"
    return 1
  fi
  body_has_substring "modified_files" || { echo "  body missing 'modified_files'"; return 1; }
  return 0
}
check "B4: body names 4 input fields" b4_body_names_4_input_fields

b5_body_contains_4_banned_phrases() {
  for phrase in "all green" "looks good" "no concerns" "meets all criteria"; do
    body_has_substring "$phrase" || { echo "  body missing banned phrase: $phrase"; return 1; }
  done
  return 0
}
check "B5: body contains 4 banned phrases" b5_body_contains_4_banned_phrases

b6_body_contains_reasoning_protocol_sentence() {
  body_has_substring "the reason field must be a causal claim and the evidence field must be a quoted excerpt or path:line reference"
}
check "B6: body contains reasoning-required protocol sentence" b6_body_contains_reasoning_protocol_sentence

# -----------------------------------------------------------------------------
# Fixture checks (Scenario C → REQ-7)
# -----------------------------------------------------------------------------

c1_fixture_parses_as_json() {
  [[ -f "$FIXTURE" ]] || { echo "  fixture missing: $FIXTURE"; return 1; }
  python3 -c "
import json, sys
json.load(open(sys.argv[1]))
" "$FIXTURE" 2>&1
}
check "C1: fixture parses as JSON" c1_fixture_parses_as_json

c2_fixture_heuristic_flags_is_list_of_strings() {
  python3 -c "
import json, sys
o = json.load(open(sys.argv[1]))
hf = o.get('heuristic_flags')
assert isinstance(hf, list), f'heuristic_flags not a list: {type(hf).__name__}'
assert all(isinstance(x, str) for x in hf), f'heuristic_flags items not all strings: {hf!r}'
" "$FIXTURE" 2>&1
}
check "C2: fixture.heuristic_flags is list of strings" c2_fixture_heuristic_flags_is_list_of_strings

c3_fixture_task_acceptance_and_prompt() {
  python3 -c "
import json, sys
o = json.load(open(sys.argv[1]))
task = o.get('task')
assert isinstance(task, dict), f'task not a dict: {type(task).__name__}'
assert isinstance(task.get('acceptance'), list), f'task.acceptance not a list'
assert isinstance(task.get('prompt'), str), f'task.prompt not a string'
" "$FIXTURE" 2>&1
}
check "C3: fixture.task.acceptance is list, fixture.task.prompt is string" c3_fixture_task_acceptance_and_prompt

c4_fixture_commit_ref_and_modified_files() {
  python3 -c "
import json, sys
o = json.load(open(sys.argv[1]))
assert ('commit_ref' in o) or ('commit_sha' in o), 'fixture missing commit_ref/commit_sha'
mf = o.get('modified_files')
assert isinstance(mf, list), f'modified_files not a list: {type(mf).__name__}'
assert all(isinstance(x, str) for x in mf), f'modified_files items not all strings: {mf!r}'
" "$FIXTURE" 2>&1
}
check "C4: fixture has (commit_ref|commit_sha) AND modified_files list of strings" c4_fixture_commit_ref_and_modified_files

# -----------------------------------------------------------------------------
# Cross-doc consistency check (EDGE-5 → REQ-5/REQ-7 alignment)
# -----------------------------------------------------------------------------

e1_body_and_fixture_agree_on_artifact_ref_name() {
  local body_has_ref body_has_sha fixture_has_ref fixture_has_sha
  if extract_body | grep -Fq "commit_ref"; then body_has_ref=1; else body_has_ref=0; fi
  if extract_body | grep -Fq "commit_sha"; then body_has_sha=1; else body_has_sha=0; fi
  fixture_has_ref=$(python3 -c "
import json, sys
print(1 if 'commit_ref' in json.load(open(sys.argv[1])) else 0)
" "$FIXTURE" 2>/dev/null) || { echo "  fixture parse failed"; return 1; }
  fixture_has_sha=$(python3 -c "
import json, sys
print(1 if 'commit_sha' in json.load(open(sys.argv[1])) else 0)
" "$FIXTURE" 2>/dev/null) || { echo "  fixture parse failed"; return 1; }
  [[ "$body_has_ref" == "$fixture_has_ref" ]] || {
    echo "  body uses commit_ref=${body_has_ref} but fixture commit_ref=${fixture_has_ref}"
    return 1
  }
  [[ "$body_has_sha" == "$fixture_has_sha" ]] || {
    echo "  body uses commit_sha=${body_has_sha} but fixture commit_sha=${fixture_has_sha}"
    return 1
  }
  return 0
}
check "E1: body and fixture agree on artifact-ref name" e1_body_and_fixture_agree_on_artifact_ref_name

# -----------------------------------------------------------------------------
# Branch diff scope check (Scenario E → REQ-9)
# -----------------------------------------------------------------------------

e2_branch_diff_scope() {
  # Skip silently when no main ref (shallow clone, detached HEAD).
  git -C "$REPO_DIR" rev-parse --verify main >/dev/null 2>&1 || {
    echo "  skipped: main ref not available"
    return 0
  }
  # Scope check is only meaningful when run on the assessor-agent feature
  # branch — on other branches (or after the assessor-agent task has been
  # merged) the diff legitimately includes unrelated files. Skip silently
  # when we are not on the target branch so this REQ-9 regression guard
  # does not produce false-positive failures across the wider test suite.
  local current_branch
  current_branch=$(git -C "$REPO_DIR" branch --show-current 2>/dev/null || echo "")
  if [[ "$current_branch" != "feature/deviation-assessor-agent" ]]; then
    echo "  skipped: not on feature/deviation-assessor-agent (current: ${current_branch:-detached})"
    return 0
  fi
  # Three-dot (merge-base) diff: only files this branch modifies, not files
  # main moved ahead on independently. The two-dot form (`git diff main`)
  # would falsely report main-only files as out-of-scope here. REQ-9
  # constrains what THIS branch modifies, which is the merge-base semantic.
  local diff_files
  diff_files=$(git -C "$REPO_DIR" diff main...HEAD --name-only 2>/dev/null) || {
    echo "  git diff failed"
    return 1
  }
  local line
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    case "$line" in
      adapters/claude-code/claude/agents/deviation-assessor.md) ;;
      tests/test_deviation_assessor_agent.sh) ;;
      tests/fixtures/deviation_assessor/sample_input.json) ;;
      docs/INPROGRESS_Feature_deviation-assessor-agent/*) ;;
      *)
        echo "  ✗ Out-of-scope file: $line"
        return 1
        ;;
    esac
  done <<EOF
$diff_files
EOF
  return 0
}
check "E2: branch diff vs main lists only the 3 created paths + docs/" e2_branch_diff_scope

# -----------------------------------------------------------------------------
# Results
# -----------------------------------------------------------------------------

echo ""
echo "Results: ${passed} passed, ${failed} failed"
[[ $failed -eq 0 ]]
