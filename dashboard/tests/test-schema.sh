#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR/.."
VALIDATOR="$PROJECT_ROOT/tools/validate-plan.py"
PASS=0
FAIL=0
TOTAL=0

TMPDIR_BASE="$PROJECT_ROOT/.test-tmp-schema"
rm -rf "$TMPDIR_BASE"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

assert_exit() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected exit: $expected"
    echo "    actual exit:   $actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$haystack" | grep -q "$needle"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    output: $haystack"
  fi
}

run_validator() {
  local file="$1"
  python3 "$VALIDATOR" "$file" 2>&1
}

# ─── C1: Structural Validation ───────────────────────────────────────

test_valid_minimal_plan() {
  local f="$TMPDIR_BASE/minimal.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test Plan",
  "phases": []
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "valid minimal plan exits 0" "0" "$exit_code"
}

test_valid_full_plan() {
  local f="$TMPDIR_BASE/full.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Full Plan",
  "description": "A complete test plan",
  "created": "2026-02-23T10:00:00Z",
  "sources": [{"name": "impl-plan", "path": "plan.md"}],
  "extensions": {"custom": "data"},
  "phases": [
    {
      "id": "setup",
      "name": "Phase 0: Setup",
      "description": "Bootstrap the project",
      "extensions": {"priority": "high"},
      "tasks": [
        {
          "id": "docker-setup",
          "name": "Docker Setup",
          "description": "Configure Docker Compose",
          "status": "done",
          "depends": [],
          "prompt": "/implement docker",
          "acceptance": ["Docker compose up works", "All services healthy"],
          "parallel_group": "infra",
          "last_updated": "2026-02-23T10:00:00Z",
          "extensions": {"assignee": "agent-1"}
        },
        {
          "id": "db-init",
          "name": "Database Init",
          "status": "pending",
          "depends": ["docker-setup"]
        }
      ],
      "gate": {
        "name": "Setup Gate",
        "checklist": ["All tests green", "Docker compose up"],
        "passed": true,
        "command": "bash tests/run-all.sh"
      }
    }
  ]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "valid full plan exits 0" "0" "$exit_code"
}

test_missing_schema_version() {
  local f="$TMPDIR_BASE/no-version.json"
  cat > "$f" <<'EOF'
{
  "name": "Test Plan",
  "phases": []
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "missing schema_version exits 1" "1" "$exit_code"
  assert_contains "error mentions schema_version" "schema_version" "$out"
}

test_missing_name() {
  local f="$TMPDIR_BASE/no-name.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "phases": []
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "missing name exits 1" "1" "$exit_code"
  assert_contains "error mentions name" "name" "$out"
}

test_invalid_status_enum() {
  local f="$TMPDIR_BASE/bad-status.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [{
      "id": "t1",
      "name": "Task 1",
      "status": "unknown"
    }]
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "invalid status enum exits 1" "1" "$exit_code"
  assert_contains "error mentions status" "status" "$out"
}

test_valid_status_enums() {
  for status in pending wip "done" failed skipped; do
    local f="$TMPDIR_BASE/status-$status.json"
    cat > "$f" <<EOF
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [{"id": "t1", "name": "Task", "status": "$status"}]
  }]
}
EOF
    local out exit_code=0
    out=$(run_validator "$f") || exit_code=$?
    assert_exit "status '$status' exits 0" "0" "$exit_code"
  done
}

test_invalid_task_id_pattern() {
  local f="$TMPDIR_BASE/bad-id.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [{"id": "Bad Task ID!", "name": "Task", "status": "pending"}]
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "invalid task ID pattern exits 1" "1" "$exit_code"
  assert_contains "error mentions id" "id" "$out"
}

test_phase_with_gate() {
  local f="$TMPDIR_BASE/gate.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [],
    "gate": {
      "name": "Quality Gate",
      "checklist": ["Tests pass"],
      "passed": false
    }
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "phase with gate exits 0" "0" "$exit_code"
}

test_gate_missing_checklist() {
  local f="$TMPDIR_BASE/gate-no-checklist.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [],
    "gate": {
      "name": "Quality Gate",
      "passed": false
    }
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "gate missing checklist exits 1" "1" "$exit_code"
  assert_contains "error mentions checklist" "checklist" "$out"
}

test_empty_phases_array() {
  local f="$TMPDIR_BASE/empty-phases.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": []
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "empty phases array exits 0" "0" "$exit_code"
}

test_phase_with_zero_tasks() {
  local f="$TMPDIR_BASE/zero-tasks.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{"id": "p1", "name": "Phase 1", "tasks": []}]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "phase with zero tasks exits 0" "0" "$exit_code"
}

test_extensions_at_all_levels() {
  local f="$TMPDIR_BASE/extensions.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "extensions": {"plan-level": true},
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "extensions": {"phase-level": 42},
    "tasks": [{
      "id": "t1",
      "name": "Task",
      "status": "pending",
      "extensions": {"task-level": "data"}
    }]
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "extensions at all levels exits 0" "0" "$exit_code"
}

test_sources_array() {
  local f="$TMPDIR_BASE/sources.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "sources": [
    {"name": "Implementation Plan", "path": "plan.md"},
    {"name": "Setup Plan", "path": "setup.md"}
  ],
  "phases": []
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "sources array exits 0" "0" "$exit_code"
}

test_large_plan() {
  local f="$TMPDIR_BASE/large.json"
  # Generate a plan with 100 tasks across 10 phases
  python3 -c "
import json
phases = []
for p in range(10):
    tasks = []
    for t in range(10):
        tasks.append({'id': f'p{p}-t{t}', 'name': f'Task {t}', 'status': 'pending'})
    phases.append({'id': f'phase-{p}', 'name': f'Phase {p}', 'tasks': tasks})
plan = {'schema_version': '1.0.0', 'name': 'Large Plan', 'phases': phases}
print(json.dumps(plan))
" > "$f"
  local out exit_code=0
  # macOS: use perl-based timeout if coreutils timeout unavailable
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout 5 python3 "$VALIDATOR" "$f" 2>&1) || exit_code=$?
  else
    out=$(perl -e 'alarm 5; exec @ARGV' python3 "$VALIDATOR" "$f" 2>&1) || exit_code=$?
  fi
  assert_exit "large plan (100 tasks) exits 0 within 5s" "0" "$exit_code"
}

# ─── C2: Semantic Validation ─────────────────────────────────────────

test_valid_depends_reference() {
  local f="$TMPDIR_BASE/valid-deps.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [
      {"id": "task-a", "name": "A", "status": "done"},
      {"id": "task-b", "name": "B", "status": "pending", "depends": ["task-a"]}
    ]
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "valid depends reference exits 0" "0" "$exit_code"
}

test_invalid_depends_reference() {
  local f="$TMPDIR_BASE/bad-deps.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [
      {"id": "task-a", "name": "A", "status": "pending", "depends": ["nonexistent-id"]}
    ]
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "invalid depends reference exits 1" "1" "$exit_code"
  assert_contains "error names unknown task" "nonexistent-id" "$out"
}

test_circular_dependency() {
  local f="$TMPDIR_BASE/circular.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [
      {"id": "task-a", "name": "A", "status": "pending", "depends": ["task-b"]},
      {"id": "task-b", "name": "B", "status": "pending", "depends": ["task-a"]}
    ]
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "circular dependency exits 1" "1" "$exit_code"
  assert_contains "error mentions circular" "ircular" "$out"
}

test_globally_unique_task_ids() {
  local f="$TMPDIR_BASE/unique-ids.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [
    {"id": "p1", "name": "P1", "tasks": [{"id": "task-a", "name": "A", "status": "pending"}]},
    {"id": "p2", "name": "P2", "tasks": [{"id": "task-b", "name": "B", "status": "pending"}]}
  ]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "globally unique task IDs exits 0" "0" "$exit_code"
}

test_duplicate_task_ids() {
  local f="$TMPDIR_BASE/dup-ids.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [
    {"id": "p1", "name": "P1", "tasks": [{"id": "task-a", "name": "A", "status": "pending"}]},
    {"id": "p2", "name": "P2", "tasks": [{"id": "task-a", "name": "A2", "status": "pending"}]}
  ]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "duplicate task IDs exits 1" "1" "$exit_code"
  assert_contains "error names duplicate ID" "task-a" "$out"
}

test_self_referencing_depends() {
  local f="$TMPDIR_BASE/self-ref.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [
      {"id": "task-a", "name": "A", "status": "pending", "depends": ["task-a"]}
    ]
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "self-referencing depends exits 1" "1" "$exit_code"
  assert_contains "error mentions circular or self" "ircular" "$out"
}

# ─── C6: Template Validation ─────────────────────────────────────────

test_template_greenfield() {
  local f="$PROJECT_ROOT/templates/template-greenfield.yaml"
  if [ ! -f "$f" ]; then
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: template-greenfield.yaml not found"
    return
  fi
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "template-greenfield validates" "0" "$exit_code"
}

test_template_feature() {
  local f="$PROJECT_ROOT/templates/template-feature.yaml"
  if [ ! -f "$f" ]; then
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: template-feature.yaml not found"
    return
  fi
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "template-feature validates" "0" "$exit_code"
}

test_template_refactor() {
  local f="$PROJECT_ROOT/templates/template-refactor.yaml"
  if [ ! -f "$f" ]; then
    TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
    echo "  FAIL: template-refactor.yaml not found"
    return
  fi
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "template-refactor validates" "0" "$exit_code"
}

test_templates_have_content() {
  for tpl in greenfield feature refactor; do
    local f="$PROJECT_ROOT/templates/template-$tpl.yaml"
    if [ ! -f "$f" ]; then
      TOTAL=$((TOTAL + 1)); FAIL=$((FAIL + 1))
      echo "  FAIL: template-$tpl.yaml not found"
      continue
    fi
    # Convert to JSON and check for at least 1 phase with 1 task
    local phases
    phases=$(python3 -c "
import sys, json
try:
    import yaml
    plan = yaml.safe_load(open('$f'))
except ImportError:
    plan = json.load(open('$f'))
print(len(plan.get('phases', [])))
")
    assert_exit "template-$tpl has ≥1 phase" "true" "$([ "$phases" -ge 1 ] && echo true || echo false)"
  done
}

# ─── Object-form checklist items (gate-ui-auto-evaluation) ────────────

test_gate_object_checklist_validates() {
  local f="$TMPDIR_BASE/obj-checklist.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [],
    "gate": {
      "name": "Gate",
      "checklist": [{"item": "tests pass", "check": {"kind": "shell", "cmd": "npm test"}}],
      "passed": false
    }
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "object-form checklist validates" "0" "$exit_code"
}

test_gate_mixed_checklist_validates() {
  local f="$TMPDIR_BASE/mixed-checklist.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [],
    "gate": {
      "name": "Gate",
      "checklist": ["manual check", {"item": "auto", "check": {"kind": "shell", "cmd": "x"}}],
      "passed": false
    }
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "mixed string+object checklist validates" "0" "$exit_code"
}

test_gate_object_no_check_validates() {
  local f="$TMPDIR_BASE/obj-no-check.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [],
    "gate": {
      "name": "Gate",
      "checklist": [{"item": "review"}],
      "passed": false
    }
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "object with no check field validates" "0" "$exit_code"
}

test_gate_object_kind_human_validates() {
  local f="$TMPDIR_BASE/obj-human.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [],
    "gate": {
      "name": "Gate",
      "checklist": [{"item": "review", "check": {"kind": "human"}}],
      "passed": false
    }
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "object with kind=human validates" "0" "$exit_code"
}

test_gate_object_missing_item_rejects() {
  local f="$TMPDIR_BASE/obj-no-item.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [],
    "gate": {
      "name": "Gate",
      "checklist": [{"check": {"kind": "shell"}}],
      "passed": false
    }
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "object missing item field exits 1" "1" "$exit_code"
}

test_gate_object_extra_key_rejects() {
  local f="$TMPDIR_BASE/obj-extra-key.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [],
    "gate": {
      "name": "Gate",
      "checklist": [{"item": "x", "bogus": true}],
      "passed": false
    }
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "object with unknown key exits 1" "1" "$exit_code"
}

FIXTURE_DIR="$PROJECT_ROOT/tests/fixtures/plan-2.0.0"

# ─── C3: schema 2.0 dispatch & polymorphism ──────────────────────────

test_2_0_full_validates() {
  local f="$FIXTURE_DIR/full.yaml"
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "2.0 full fixture validates" "0" "$exit_code"
  assert_contains "stdout is exactly 'Valid.'" "Valid." "$out"
}

test_2_0_minimal_validates() {
  local f="$FIXTURE_DIR/minimal.yaml"
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "2.0 minimal fixture validates" "0" "$exit_code"
}

test_2_0_missing_finding_id_rejects() {
  local f="$TMPDIR_BASE/2_0_no_finding.yaml"
  python3 - "$FIXTURE_DIR/full.yaml" "$f" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh:
    plan = yaml.safe_load(fh)
for entry in plan.get("deferred", []):
    if entry.get("kind") == "code_finding":
        entry.pop("finding_id", None)
        break
with open(dst, "w") as fh:
    yaml.safe_dump(plan, fh, sort_keys=False)
PY
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "2.0 missing finding_id rejects" "1" "$exit_code"
  assert_contains "error mentions deferred path" "deferred" "$out"
  assert_contains "error mentions oneOf (finding_id branch rejected)" "oneOf" "$out"
}

test_2_0_missing_vision_rejects() {
  local f="$TMPDIR_BASE/2_0_no_vision.yaml"
  python3 - "$FIXTURE_DIR/full.yaml" "$f" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh:
    plan = yaml.safe_load(fh)
plan.pop("vision", None)
with open(dst, "w") as fh:
    yaml.safe_dump(plan, fh, sort_keys=False)
PY
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "2.0 missing vision rejects" "1" "$exit_code"
  assert_contains "error mentions vision" "vision" "$out"
}

test_2_0_forward_compat_2_99_validates() {
  local f="$TMPDIR_BASE/2_99.yaml"
  python3 - "$FIXTURE_DIR/full.yaml" "$f" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh:
    plan = yaml.safe_load(fh)
plan["schema_version"] = "2.99.0"
with open(dst, "w") as fh:
    yaml.safe_dump(plan, fh, sort_keys=False)
PY
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "schema_version 2.99.0 takes the 2.x branch" "0" "$exit_code"
}

test_2_0_additional_properties_rejects() {
  local f="$TMPDIR_BASE/2_0_extra.yaml"
  python3 - "$FIXTURE_DIR/full.yaml" "$f" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh:
    plan = yaml.safe_load(fh)
for entry in plan.get("deferred", []):
    if entry.get("kind") == "code_finding":
        entry["xyz_unknown"] = "foo"
        break
with open(dst, "w") as fh:
    yaml.safe_dump(plan, fh, sort_keys=False)
PY
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "2.0 unknown key on code_finding rejects" "1" "$exit_code"
  assert_contains "error mentions deferred path" "deferred" "$out"
}

test_2_0_empty_phases_rejects() {
  local f="$TMPDIR_BASE/2_0_empty_phases.yaml"
  python3 - "$FIXTURE_DIR/full.yaml" "$f" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh:
    plan = yaml.safe_load(fh)
plan["phases"] = []
with open(dst, "w") as fh:
    yaml.safe_dump(plan, fh, sort_keys=False)
PY
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "2.0 empty phases rejects" "1" "$exit_code"
  assert_contains "error mentions phases minItems" "phases" "$out"
}

test_2_0_two_deferred_kinds_rejects() {
  # Construct an entry whose 'kind' is a stray value that doesn't match any
  # of the four oneOf branches; oneOf returns "matches 0".
  local f="$TMPDIR_BASE/2_0_bad_kind.yaml"
  python3 - "$FIXTURE_DIR/full.yaml" "$f" <<'PY'
import sys, yaml
src, dst = sys.argv[1], sys.argv[2]
with open(src) as fh:
    plan = yaml.safe_load(fh)
plan.setdefault("deferred", []).append({
    "id": "BAD-1",
    "kind": "not_a_real_kind",
    "date": "2026-04-26",
    "description": "neither finding nor suggestion",
})
with open(dst, "w") as fh:
    yaml.safe_dump(plan, fh, sort_keys=False)
PY
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "2.0 bogus 'kind' rejects (no oneOf branch matches)" "1" "$exit_code"
  assert_contains "error cites oneOf" "oneOf" "$out"
}

test_circular_ref_does_not_loop() {
  # Build a tiny standalone schema with a self-referencing $def so the
  # cycle guard fires; then run validate_value against it directly.
  local f="$TMPDIR_BASE/circular.py"
  cat > "$f" <<'PY'
import sys, signal
sys.path.insert(0, "tools")
import importlib.util
spec = importlib.util.spec_from_file_location("validate_plan", "tools/validate-plan.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

schema = {
    "$defs": {
        "loop": {"type": "object", "properties": {"next": {"$ref": "#/$defs/loop"}}}
    },
    "$ref": "#/$defs/loop",
}

def handler(signum, frame):
    print("TIMEOUT", file=sys.stderr)
    sys.exit(2)

signal.signal(signal.SIGALRM, handler)
signal.alarm(5)

errors = mod.validate_structural({"next": {"next": {"next": {}}}}, schema)
print("\n".join(errors))
sys.exit(1 if errors else 0)
PY
  local out exit_code=0
  out=$(cd "$PROJECT_ROOT" && python3 "$f" 2>&1) || exit_code=$?
  assert_exit "circular \$ref guarded (exits within 5s)" "1" "$exit_code"
  assert_contains "error mentions circular" "circular" "$out"
}

test_gate_string_only_still_validates() {
  local f="$TMPDIR_BASE/str-only.json"
  cat > "$f" <<'EOF'
{
  "schema_version": "1.0.0",
  "name": "Test",
  "phases": [{
    "id": "p1",
    "name": "Phase 1",
    "tasks": [],
    "gate": {
      "name": "Gate",
      "checklist": ["item1", "item2"],
      "passed": false
    }
  }]
}
EOF
  local out exit_code=0
  out=$(run_validator "$f") || exit_code=$?
  assert_exit "string-only checklist still validates" "0" "$exit_code"
}

# ─── Run all tests ───────────────────────────────────────────────────

echo "=== Schema & Validation Tests ==="

# C1 structural
test_valid_minimal_plan
test_valid_full_plan
test_missing_schema_version
test_missing_name
test_invalid_status_enum
test_valid_status_enums
test_invalid_task_id_pattern
test_phase_with_gate
test_gate_missing_checklist
test_empty_phases_array
test_phase_with_zero_tasks
test_extensions_at_all_levels
test_sources_array
test_large_plan

# C2 semantic
test_valid_depends_reference
test_invalid_depends_reference
test_circular_dependency
test_globally_unique_task_ids
test_duplicate_task_ids
test_self_referencing_depends

# Object-form checklist items
test_gate_object_checklist_validates
test_gate_mixed_checklist_validates
test_gate_object_no_check_validates
test_gate_object_kind_human_validates
test_gate_object_missing_item_rejects
test_gate_object_extra_key_rejects
test_gate_string_only_still_validates

# C6 templates
test_template_greenfield
test_template_feature
test_template_refactor
test_templates_have_content

# C3 schema 2.0
test_2_0_full_validates
test_2_0_minimal_validates
test_2_0_missing_finding_id_rejects
test_2_0_missing_vision_rejects
test_2_0_forward_compat_2_99_validates
test_2_0_additional_properties_rejects
test_2_0_empty_phases_rejects
test_2_0_two_deferred_kinds_rejects
test_circular_ref_does_not_loop

echo ""
echo "---"
printf "Tests: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$((PASS + FAIL))"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

echo "All schema tests passed."
exit 0
