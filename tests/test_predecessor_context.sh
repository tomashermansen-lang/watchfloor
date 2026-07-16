#!/usr/bin/env bash
# Test suite for predecessor-context.py (backlog #64).
#
# Verifies the phase-tuned predecessor-context helper produces the right
# context shape for each consuming phase, falls back cleanly when a
# dependency has no metadata, and respects argv error semantics.
#
# Hermetic: builds synthetic plan.yaml + synthetic git repo in $TMPDIR
# per test case. No real autopilot, no real network, no real claude.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HELPER="$REPO_ROOT/adapters/claude-code/claude/tools/predecessor-context.py"

PASS=0
FAIL=0
FAILED_NAMES=()
TMP_DIRS=()

new_tmp() {
  local d
  d=$(mktemp -d "${TMPDIR:-/tmp}/predctx.XXXXXX")
  TMP_DIRS+=("$d")
  echo "$d"
}

cleanup_all() {
  local d
  for d in "${TMP_DIRS[@]+"${TMP_DIRS[@]}"}"; do
    [[ -d "$d" ]] && rm -rf "$d"
  done
}
trap cleanup_all EXIT

check() {
  local name="$1"
  shift
  if "$@"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    echo "  FAIL: $name" >&2
  fi
}

# check_not: passes when the predicate FAILS (logical negation).
check_not() {
  local name="$1"
  shift
  if "$@"; then
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$name")
    echo "  FAIL: $name (expected predicate to fail)" >&2
  else
    PASS=$((PASS + 1))
  fi
}

# Helper: write a synthetic plan with the given task dicts.
# Args: $1 = tmpdir, $2 = yaml content (after schema_version block)
write_plan() {
  local d="$1"
  local body="$2"
  cat > "$d/plan.yaml" <<EOF
schema_version: "2.0.0"
name: "test-plan"
vision: "test"
users: ["test"]
success_criteria: []
scope: {in: [], out: []}
tech_stack: {languages: [], frameworks: []}
existing_infrastructure_to_reuse: []
test_targets: []
setup: {commands: []}
kill_criteria: []
design_notes: []
risks: []
phases:
- id: ph1
  name: "Phase 1"
  description: "test phase"
  tasks:
$body
EOF
}

# Helper: init synthetic git repo with one commit per dep so commit refs resolve.
init_git_with_commits() {
  local d="$1"
  shift
  git -C "$d" init -q --template='' 2>/dev/null
  git -C "$d" config user.email test@test.local
  git -C "$d" config user.name test
  : > "$d/initial"
  git -C "$d" add initial
  git -C "$d" commit -q -m initial
  local sha
  for label in "$@"; do
    echo "content for $label" > "$d/$label.txt"
    git -C "$d" add "$label.txt"
    git -C "$d" commit -q -m "feat($label): test"
    sha=$(git -C "$d" rev-parse HEAD)
    echo "$label=$sha"
  done
}

# ═══════════════════════════════════════════════════════════════════════
# T1: empty deps → empty output, exit 0
# ═══════════════════════════════════════════════════════════════════════
T1=$(new_tmp)
write_plan "$T1" "
  - id: standalone
    name: \"standalone task\"
    task_type: development
    status: pending
    what: \"x\"
    why: \"y\"
    where: {modify: []}
    acceptance: [\"a\"]
    prompt: \"/start standalone\"
    depends: []"
out=$(python3 "$HELPER" --plan "$T1/plan.yaml" --task standalone --phase ba 2>"$T1/err")
ec=$?
check "T1.1: empty deps → empty stdout" test -z "$out"
check "T1.2: empty deps → exit 0" test "$ec" -eq 0

# ═══════════════════════════════════════════════════════════════════════
# T2: missing plan file → exit 3
# ═══════════════════════════════════════════════════════════════════════
T2=$(new_tmp)
python3 "$HELPER" --plan "$T2/nope.yaml" --task x --phase ba >"$T2/out" 2>"$T2/err" || ec=$?
check "T2.1: missing plan → exit 3" test "${ec:-0}" -eq 3
check "T2.2: missing plan → stderr non-empty" test -s "$T2/err"

# ═══════════════════════════════════════════════════════════════════════
# T3: unknown phase → exit 2
# ═══════════════════════════════════════════════════════════════════════
T3=$(new_tmp)
write_plan "$T3" "
  - id: x
    name: x
    task_type: development
    status: pending
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start x
    depends: []"
python3 "$HELPER" --plan "$T3/plan.yaml" --task x --phase nonsense >"$T3/out" 2>"$T3/err" || ec=$?
check "T3.1: unknown phase → exit 2" test "${ec:-0}" -eq 2

# ═══════════════════════════════════════════════════════════════════════
# T4: task not found → exit 3
# ═══════════════════════════════════════════════════════════════════════
T4=$(new_tmp)
write_plan "$T4" "
  - id: real-task
    name: x
    task_type: development
    status: pending
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start real-task
    depends: []"
python3 "$HELPER" --plan "$T4/plan.yaml" --task missing-task --phase ba >"$T4/out" 2>"$T4/err" || ec=$?
check "T4.1: missing task → exit 3" test "${ec:-0}" -eq 3

# ═══════════════════════════════════════════════════════════════════════
# T5: dep without metadata → fallback message
# ═══════════════════════════════════════════════════════════════════════
T5=$(new_tmp)
write_plan "$T5" "
  - id: legacy-dep
    name: x
    task_type: development
    status: done
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start legacy-dep
    depends: []
  - id: consumer
    name: y
    task_type: development
    status: pending
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start consumer
    depends: [legacy-dep]"
out=$(python3 "$HELPER" --plan "$T5/plan.yaml" --task consumer --phase ba 2>"$T5/err")
check "T5.1: fallback msg includes dep id" grep -q "legacy-dep" <<<"$out"
check "T5.2: fallback msg mentions artifact path" grep -q "fall back to reading" <<<"$out"
check "T5.3: fallback msg points at REQUIREMENTS.md" grep -q "REQUIREMENTS.md" <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# T6: /ba phase — shadow only, no interfaces, no diff
# ═══════════════════════════════════════════════════════════════════════
T6=$(new_tmp)
init_git_with_commits "$T6" "dep1" > "$T6/commits.txt"
dep1_sha=$(grep "^dep1=" "$T6/commits.txt" | cut -d= -f2)
write_plan "$T6" "
  - id: dep1
    name: x
    task_type: development
    status: done
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start dep1
    depends: []
    codebase_snapshot:
      commit_ref: $dep1_sha
      modules_changed:
        - path: src/foo.py
          role: \"foo helper\"
          lines: 10
      interfaces_introduced:
        - name: foo_func
          defined_in: src/foo.py
          signature: \"foo_func(x: int) -> int\"
      tests_added:
        - tests/test_foo.py
    predecessor_context:
      constraints: \"Always validate input via assert_int\"
      rejected: \"Rejected raising ValueError — uses sentinel return instead\"
      contract: \"Callers import foo_func from src.foo\"
  - id: consumer
    name: y
    task_type: development
    status: pending
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start consumer
    depends: [dep1]"
out=$(python3 "$HELPER" --plan "$T6/plan.yaml" --task consumer --phase ba --repo-root "$T6" 2>"$T6/err")
check "T6.1: /ba shows constraints"      grep -q "Always validate input via assert_int" <<<"$out"
check "T6.2: /ba shows contract"         grep -q "Callers import foo_func from src.foo" <<<"$out"
check "T6.3: /ba shows rejected"         grep -q "Rejected raising ValueError" <<<"$out"
check_not "T6.4: /ba omits interfaces"       grep -q "interfaces:" <<<"$out"
check_not "T6.5: /ba omits diff_stat"        grep -q "diff_stat:" <<<"$out"
check_not "T6.6: /ba omits diff body"        grep -q "^    diff:" <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# T7: /plan phase — shadow + interfaces + diff stat, no full diff
# ═══════════════════════════════════════════════════════════════════════
out=$(python3 "$HELPER" --plan "$T6/plan.yaml" --task consumer --phase plan --repo-root "$T6" 2>"$T6/err")
check "T7.1: /plan shows constraints"  grep -q "Always validate input" <<<"$out"
check "T7.2: /plan shows interfaces"   grep -q "foo_func" <<<"$out"
check "T7.3: /plan shows diff_stat"    grep -q "diff_stat:" <<<"$out"
check "T7.4: /plan shows modules"      grep -q "src/foo.py" <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# T8: /implement phase — shadow + interfaces + diff stat + full diff
# ═══════════════════════════════════════════════════════════════════════
out=$(python3 "$HELPER" --plan "$T6/plan.yaml" --task consumer --phase implement --repo-root "$T6" 2>"$T6/err")
check "T8.1: /implement shows diff body" grep -q "^  diff:" <<<"$out"
check "T8.2: /implement shows constraints" grep -q "Always validate input" <<<"$out"
check "T8.3: /implement shows interfaces" grep -q "foo_func" <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# T9: /qa phase — interfaces + tests_added, no shadow, no diff
# ═══════════════════════════════════════════════════════════════════════
out=$(python3 "$HELPER" --plan "$T6/plan.yaml" --task consumer --phase qa --repo-root "$T6" 2>"$T6/err")
check "T9.1: /qa shows tests_added"    grep -q "tests/test_foo.py" <<<"$out"
check "T9.2: /qa shows interfaces"     grep -q "foo_func" <<<"$out"
check_not "T9.3: /qa omits constraints"    grep -q "constraints:" <<<"$out"
check_not "T9.4: /qa omits diff body"      grep -q "^  diff:" <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# T10: incomplete (status=pending) dep → skipped silently
# ═══════════════════════════════════════════════════════════════════════
T10=$(new_tmp)
write_plan "$T10" "
  - id: not-done-yet
    name: x
    task_type: development
    status: pending
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start not-done-yet
    depends: []
  - id: consumer
    name: y
    task_type: development
    status: pending
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start consumer
    depends: [not-done-yet]"
out=$(python3 "$HELPER" --plan "$T10/plan.yaml" --task consumer --phase ba 2>"$T10/err")
check "T10.1: incomplete dep produces empty output" test -z "$out"

# ═══════════════════════════════════════════════════════════════════════
# T11: skipped dep → emitted (like done)
# ═══════════════════════════════════════════════════════════════════════
T11=$(new_tmp)
write_plan "$T11" "
  - id: skipped-dep
    name: x
    task_type: development
    status: skipped
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start skipped-dep
    depends: []
    predecessor_context:
      contract: \"This task was skipped — no implementation\"
  - id: consumer
    name: y
    task_type: development
    status: pending
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start consumer
    depends: [skipped-dep]"
out=$(python3 "$HELPER" --plan "$T11/plan.yaml" --task consumer --phase ba 2>"$T11/err")
check "T11.1: skipped dep emits ctx" grep -q "skipped-dep" <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# T12: line-truncation cap
# ═══════════════════════════════════════════════════════════════════════
T12=$(new_tmp)
long_text=""
for i in 1 2 3 4 5 6 7 8 9 10; do
  long_text+="line $i constraint\n"
done
write_plan "$T12" "
  - id: chatty-dep
    name: x
    task_type: development
    status: done
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start chatty-dep
    depends: []
    predecessor_context:
      constraints: |
$(printf '        line %s constraint\n' 1 2 3 4 5 6 7 8 9 10)
  - id: consumer
    name: y
    task_type: development
    status: pending
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start consumer
    depends: [chatty-dep]"
out=$(python3 "$HELPER" --plan "$T12/plan.yaml" --task consumer --phase ba --max-lines-per-dep 3 2>"$T12/err")
check "T12.1: truncation marker appears" grep -q "more lines truncated" <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# T13: symbol map — /implement and /review emit per-file symbols for
# files listed in modules_changed, using either cs.symbol_map (pre-
# extracted) or on-the-fly via extract_symbols.py.
# ═══════════════════════════════════════════════════════════════════════
T13=$(new_tmp)
init_git_with_commits "$T13" "symap-dep" > "$T13/commits.txt"
sym_sha=$(grep "^symap-dep=" "$T13/commits.txt" | cut -d= -f2)
# Add a real python file with known functions to the synthetic worktree
# so on-the-fly extraction has something to read.
mkdir -p "$T13/src"
cat > "$T13/src/widget.py" <<'PY'
def alpha():
    return 1

def beta(x: int) -> int:
    return x + 1
PY
write_plan "$T13" "
  - id: symap-dep
    name: x
    task_type: development
    status: done
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start symap-dep
    depends: []
    codebase_snapshot:
      commit_ref: $sym_sha
      modules_changed:
        - path: src/widget.py
          role: \"widget helper\"
          lines: 5
  - id: consumer
    name: y
    task_type: development
    status: pending
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start consumer
    depends: [symap-dep]"
out=$(python3 "$HELPER" --plan "$T13/plan.yaml" --task consumer --phase implement --repo-root "$T13" 2>"$T13/err")
check "T13.1: /implement emits symbol map header" \
  grep -q "symbols \[src/widget.py\]:" <<<"$out"
check "T13.2: /implement lists alpha" grep -q "alpha" <<<"$out"
check "T13.3: /implement lists beta" grep -q "beta" <<<"$out"

# /ba does NOT include symbols (profile says symbol_map: False)
out_ba=$(python3 "$HELPER" --plan "$T13/plan.yaml" --task consumer --phase ba --repo-root "$T13" 2>"$T13/err")
if grep -q "symbols \[" <<<"$out_ba"; then
  FAIL=$((FAIL + 1))
  FAILED_NAMES+=("T13.4: /ba omits symbol map")
  echo "  FAIL: T13.4: /ba omits symbol map (saw 'symbols [' in output)" >&2
else
  PASS=$((PASS + 1))
fi

# Persisted symbol map (cs["symbol_map"]) takes precedence over on-the-fly
T14=$(new_tmp)
init_git_with_commits "$T14" "pers-dep" > "$T14/commits.txt"
pers_sha=$(grep "^pers-dep=" "$T14/commits.txt" | cut -d= -f2)
# NOTE: no actual src file — extractor would return empty; persisted map
# proves the consumer reads cs.symbol_map first.
write_plan "$T14" "
  - id: pers-dep
    name: x
    task_type: development
    status: done
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start pers-dep
    depends: []
    codebase_snapshot:
      commit_ref: $pers_sha
      modules_changed:
        - path: virtual/persisted-only.py
          role: \"persisted\"
          lines: 10
      symbol_map:
        virtual/persisted-only.py:
          - name: persisted_func
            kind: function
            line_start: 5
            line_end: 8
  - id: consumer
    name: y
    task_type: development
    status: pending
    what: x
    why: y
    where: {modify: []}
    acceptance: [a]
    prompt: /start consumer
    depends: [pers-dep]"
out=$(python3 "$HELPER" --plan "$T14/plan.yaml" --task consumer --phase implement --repo-root "$T14" 2>"$T14/err")
check "T14.1: persisted symbol map surfaces" grep -q "persisted_func" <<<"$out"

# ═══════════════════════════════════════════════════════════════════════
# Final report
# ═══════════════════════════════════════════════════════════════════════
echo
echo "Results: $PASS passed, $FAIL failed"
if [[ $FAIL -gt 0 ]]; then
  echo "Failed:" >&2
  for n in "${FAILED_NAMES[@]+"${FAILED_NAMES[@]}"}"; do
    echo "  - $n" >&2
  done
  exit 1
fi
exit 0
