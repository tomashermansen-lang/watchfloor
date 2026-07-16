#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Autopilot v2 — fully autonomous SDLC pipeline
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#  Usage:
#    bash ~/.claude/tools/autopilot.sh <task-id>               # from worktree
#    bash ~/.claude/tools/autopilot.sh --full <task-id>        # from main project
#    bash ~/.claude/tools/autopilot.sh --from <phase> <task>   # resume from phase
#
#  --full mode: creates worktree, runs pipeline, commits, merges, cleans up
#  Default mode: runs pipeline in current worktree, stops after QA
#
#  --from <phase>: skip all phases before <phase> (resume after failure).
#    Valid phases: ba plan testplan review implement qa static-analysis commit
#    Example: --from static-analysis resumes after a timed-out /implement.
#
#  --stop-after-phase <phase-name>: halt cleanly after <phase-name>
#    completes. Every phase up to AND INCLUDING <phase-name> runs; phases
#    after it are skipped, the post-commit Finalize/Done block is NOT
#    run, the worktree is preserved, autopilot-summary.json is written
#    with status=partial, and the process exits 0. Composes with --from
#    so long as the stop phase does not precede the from phase in
#    PHASE_ORDER. Opt-in only; no env-var fallback. Examples:
#      --stop-after-phase plan <task>                  run /ba and /plan, halt
#      --from testplan --stop-after-phase implement <task>
#                                                      run testplan→implement
#
#  Pipeline (full):  /ba → /plan → /plan --step testplan → /team-review → /implement → /qa → /static-analysis → /commit
#  Pipeline (light): /ba → /plan → /plan --step testplan → /review → /implement → /qa → /static-analysis → /commit
#
#  Each phase runs via claude -p (headless mode) with stream-json output.
#  No TUI, no tmux — clean structured output piped to log file.
#
#  Prerequisites:
#    - claude CLI (npm install -g @anthropic-ai/claude-code)
#    - python3 (for NDJSON stream processing)
#    - coreutils (brew install coreutils) — provides gtimeout for phase timeout
#    - Project CLAUDE.md must have a pipeline: manifest block (toolchain, smoke_test, contracts)
#    - SONAR_TOKEN env var (set in global ~/.claude/settings.json, deployed via sync.sh restore)
#
#  Pause control (operator-initiated graceful stop):
#    Create ${WORKDIR}/autopilot.PAUSE from inside the worktree
#    (e.g., `touch autopilot.PAUSE`) and the next inter-phase boundary
#    will log `Paused at phase boundary <phase>`, emit SessionEnd
#    `paused at <phase>` to the dashboard, and exit 0. The phase in
#    flight always completes (including its commit) before the check
#    fires — pause is between-phase only, never mid-phase. A stale
#    autopilot.PAUSE left over from a prior session is auto-removed
#    with a warning at session start so the new run is not falsely
#    paused. Symmetric to chain.PAUSE in autopilot-chain.sh:413.
#
#  Environment variables (optional):
#    - DEVIATION_TRACKER_DISABLE=1    Kill switch for the deviation hook (REQ-12).
#                                      Set to disable phase_results writes for the
#                                      current run; default: unset (hook active).
#    - DEVIATION_TRACKER_TIMEOUT=<s>  Tracker subprocess timeout in seconds (REQ-5).
#                                      Default: 10. Positive integer only.
#    - LOCAL_LLM_ROUTING=1            Enable Ollama routing for selected phases.
#                                      Default unset (Anthropic path). Only the literal
#                                      string '1' enables; any other value disables.
#    - LOCAL_LLM_PHASES=<comma-list>  Comma-separated PHASE_ORDER subset (e.g.
#                                      'ba,plan,testplan,implement,static-analysis').
#                                      Required when LOCAL_LLM_ROUTING=1. See
#                                      adapters/claude-code/claude/tools/LOCAL_LLM_HARNESS.md.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Location of this script's own directory — used to resolve paths to
# sibling helpers in claude/tools/lib/ (manifest_parser, finalize_result).
AUTOPILOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Source shared libraries
# shellcheck source=lib/claude-session-lib.sh
source "${AUTOPILOT_DIR}/lib/claude-session-lib.sh"
# shellcheck source=lib/merge-lock.sh
source "${AUTOPILOT_DIR}/lib/merge-lock.sh"
# shellcheck source=lib/phase-selector.sh
source "${AUTOPILOT_DIR}/lib/phase-selector.sh"
# shellcheck source=lib/sonar-preflight.sh
source "${AUTOPILOT_DIR}/lib/sonar-preflight.sh"
# shellcheck source=lib/autopilot-trust-check.sh
source "${AUTOPILOT_DIR}/lib/autopilot-trust-check.sh"
# shellcheck source=lib/worktree-reaper.sh
source "${AUTOPILOT_DIR}/lib/worktree-reaper.sh"
# shellcheck source=lib/autopilot-pause.sh
source "${AUTOPILOT_DIR}/lib/autopilot-pause.sh"
# shellcheck source=lib/lifecycle-emit.sh
source "${AUTOPILOT_DIR}/lib/lifecycle-emit.sh"

# Write the reason for an exit-2 (blocked) condition to a sentinel file
# in PLAN_DIR so chain.sh can record it in blocked_tasks. Four known
# reasons today: "dirty_main" (preflight detected uncommitted changes
# on main), "merge_conflict" (commit-finalize.sh's merge step failed),
# "lock_timeout" (acquire_merge_lock waited > MERGE_LOCK_MAX_WAIT), and
# "unknown_runner_flag:<bad_flag>" (R17 — arg-parse hit an unknown CLI
# flag, typically from a task's runner.flags entry).
#
# Sentinel path: $(dirname "$CHAIN_MERGE_LOCK")/.chain-blocked-reason-$TASK
# The lock file's parent IS the plan dir; deriving from CHAIN_MERGE_LOCK
# avoids requiring chain.sh to pass plan_dir as a separate env var.
#
# Silent no-op when CHAIN_MERGE_LOCK is unset (standalone autopilot run,
# not chain-managed) or the path can't be written. Defensive: never
# fail because of sentinel-write issues — the exit-code itself is the
# load-bearing signal; the sentinel is a hint.
#
# Defined BEFORE the arg-parse loop so the arg-parse default arm can
# write `unknown_runner_flag:<bad_flag>` from $1 — bash does not hoist
# function declarations, so positioning matters here.
_write_chain_blocked_reason() {
  local reason="$1"
  if [[ -z "${CHAIN_MERGE_LOCK:-}" ]]; then
    return 0
  fi
  local plan_dir
  plan_dir=$(dirname "$CHAIN_MERGE_LOCK")
  if [[ ! -d "$plan_dir" ]]; then
    return 0
  fi
  # Validate task ID matches simple identifier with a length cap. The
  # charset blocks shell metacharacters (the value lands inside a quoted
  # parameter expansion in the redirect target, so the cap is purely a
  # hygiene + DoS guard, not an injection fix). {1,64} aligns with
  # lifecycle-emit.sh, status_helper.py, and validation.py — the
  # repo-wide safe-identifier shape.
  if [[ ! "${TASK:-}" =~ ^[a-zA-Z0-9_-]{1,64}$ ]]; then
    return 0
  fi
  echo "$reason" > "${plan_dir}/.chain-blocked-reason-${TASK}" 2>/dev/null || true
}

# ── Parse arguments ──────────────────────────────────────
FULL_MODE=false
PIPELINE="auto"
START_FROM=""
STOP_AFTER_PHASE=""
_STOP_AFTER_PHASE_SEEN=false
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --full) FULL_MODE=true; shift ;;
    --pipeline) PIPELINE="${2:?--pipeline requires 'full' or 'light'}"; shift 2 ;;
    --from) START_FROM="${2:?--from requires a phase name (ba|plan|testplan|review|implement|qa|static-analysis|commit)}"; shift 2 ;;
    --stop-after-phase)
      # Explicit guard so missing-value exits 2 (R10/I3.6) — bash's
      # ${2:?msg} would exit 1, which violates the contract.
      if [[ $# -lt 2 ]]; then
        echo "Error: --stop-after-phase requires a phase name" >&2
        echo "Valid phases: ${PHASE_ORDER[*]}" >&2
        exit 2
      fi
      STOP_AFTER_PHASE="$2"; _STOP_AFTER_PHASE_SEEN=true; shift 2 ;;
    *)
      # Component D1 — write unknown_runner_flag sentinel so the chain
      # can surface `chain_blocked reason=unknown_runner_flag bad_flag=$1`
      # (R14, R16, R17). _write_chain_blocked_reason silently no-ops when
      # CHAIN_MERGE_LOCK is unset (standalone autopilot run), so direct
      # CLI users still see the existing stderr message + non-zero exit.
      # TASK is not set yet during arg-parse — temporarily populate it
      # from the trailing positional so the sentinel path resolves.
      # `_last_arg=("${@: -1}")` is the bash 3.2-safe way to capture a
      # single positional slice without tripping shellcheck SC2124.
      _last_arg=("${@: -1}")
      TASK="${_last_arg[0]:-}"
      unset _last_arg
      _write_chain_blocked_reason "unknown_runner_flag:$1"
      echo "Unknown flag: $1" >&2
      exit 2
      ;;
  esac
done

# Validate --from value against PHASE_ORDER (sourced from phase-selector.sh).
if [[ -n "$START_FROM" ]]; then
  validate_phase_name "$START_FROM" || exit 1
fi

# Validate --stop-after-phase against PHASE_ORDER. Contract: exit 2 on
# rejection (R9/I3.2). validate_phase_name returns 1; `|| exit 2` lifts
# the code to honour the contract. An explicit empty value
# (--stop-after-phase "") was seen but is not a PHASE_ORDER member —
# the SEEN sentinel routes it through validate so R9 fires on
# "Invalid phase: ''".
if [[ "$_STOP_AFTER_PHASE_SEEN" == true ]]; then
  validate_phase_name "$STOP_AFTER_PHASE" || exit 2
fi

# Local-LLM routing: validate LOCAL_LLM_PHASES against PHASE_ORDER and
# probe the Ollama daemon. Both helpers gate internally on
# LOCAL_LLM_ROUTING="1"; when routing is disabled, both are no-ops
# (zero curl invocation, zero env mutation — R8 + R13). The parsed
# array MUST exist before the preflight so the comma-joined phase
# list in the success log is correct.
validate_local_llm_phases
ollama_preflight_check

# Composition guard (R20/AS10): --stop-after-phase must not precede
# --from in PHASE_ORDER. Both names have already passed
# validate_phase_name so phase_index cannot fail; the `|| exit 2`
# defence keeps a future refactor that drops the prior validation from
# producing empty-string arithmetic under set -u.
if [[ -n "$START_FROM" && -n "$STOP_AFTER_PHASE" ]]; then
  _from_idx=$(phase_index "$START_FROM") || exit 2
  _stop_idx=$(phase_index "$STOP_AFTER_PHASE") || exit 2
  if (( _stop_idx < _from_idx )); then
    echo "Error: --stop-after-phase $STOP_AFTER_PHASE precedes --from $START_FROM in PHASE_ORDER" >&2
    echo "Valid order requires: phase_index(--stop-after-phase) >= phase_index(--from)" >&2
    exit 2
  fi
  unset _from_idx _stop_idx
fi

TASK="${1:?Usage: autopilot.sh [--full] [--pipeline full|light] [--from <phase>] <task-id>}"
FEATURE_DIR="docs/INPROGRESS_Feature_${TASK}"
export LOG_FILE=""  # set after WORKDIR is resolved
PROJECTS_ROOT="${PROJECTS_ROOT:-$HOME/Projekter}"
export DASHBOARD_DATA="${CLAUDE_DASHBOARD_DATA:-$PROJECTS_ROOT/dotfiles/dashboard/data/sessions.jsonl}"
AUTOPILOT_SID="autopilot-${TASK}-$(date +%s)"
export AUTOPILOT_SID
export ALLOWED_TOOLS="Read,Edit,Write,Bash,Grep,Glob,Agent,SendMessage,Skill"

export PHASE_TIMEOUT="${PHASE_TIMEOUT:-1800}"                  # 30 min default safety valve (BA, Plan, solo Review, solo QA — produce docs)
PHASE_TIMEOUT_IMPLEMENT="${PHASE_TIMEOUT_IMPLEMENT:-5400}"      # 90 min for Implement — bumped 2026-05-06 from 60 min: TDD on large features routinely overruns; previous default forced retry-loops on poc-watchfloor T0.2-class refactors
PHASE_TIMEOUT_TEAM="${PHASE_TIMEOUT_TEAM:-7200}"                # 120 min for Team Review / Team QA — bumped 2026-05-06 from 60 min: poc-watchfloor T0.2 team-review hit the 60-min watchdog mid-synthesis-write after substantive work was complete; 7-8 specialist fan-out + Fixer pass routinely needs >60 min on full-pipeline tasks

# Eager-exit watchdog (autopilot-eager-exit, BACKLOG #54).
# Fires after the agent's `result` event when the phase NDJSON's mtime
# stays unchanged for EAGER_EXIT_IDLE_S seconds. Mtime advance resets the
# countdown. SIGTERM → wait EAGER_EXIT_GRACE_S → SIGKILL on the leader's
# process group. EAGER_EXIT_DISABLE=1 (or EAGER_EXIT_IDLE_S=0) is a
# one-flag rollback that preserves the gtimeout PHASE_TIMEOUT outer cap.
export EAGER_EXIT_IDLE_S="${EAGER_EXIT_IDLE_S:-60}"
export EAGER_EXIT_GRACE_S="${EAGER_EXIT_GRACE_S:-5}"
export EAGER_EXIT_DISABLE="${EAGER_EXIT_DISABLE:-}"

EXTRA_SYSTEM_PROMPT=""  # per-phase system prompt addition (set before run_gated_phase)
MAX_TURNS_DEFAULT=75    # BA, Plan, Static Analysis, Commit (observed max: 62)
MAX_TURNS_TEAM=200      # Team Review, Team QA (observed max: 120, agents + discussion)
MAX_TURNS_IMPLEMENT=200 # TDD cycles (observed max: 80, headroom for large features)
MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT  # per-phase override (set before run_gated_phase)

# ── Helpers ──────────────────────────────────────────────

log() {
  local msg
  msg="[$(date '+%H:%M:%S')] $1"
  echo -e "$msg"
  # Emit to NDJSON stream (if initialized) so the dashboard can display it
  if [[ -n "${STREAM_FILE:-}" && -f "${STREAM_FILE:-}" ]]; then
    local clean_msg
    clean_msg=$(echo -e "$1" | sed $'s/\x1b\\[[0-9;]*m//g')
    printf '{"type":"orchestrator","msg":"%s","ts":"%s"}\n' \
      "${clean_msg//\"/\\\"}" \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$STREAM_FILE"
  fi
}


# ── Worktree cleanup ─────────────────────────────────────

cleanup_worktree() {
  local worktree_dir="$1" branch="$2" main_dir="$3"
  if [[ -z "$worktree_dir" || -z "$branch" || -z "$main_dir" ]]; then
    return 0
  fi
  cd "$main_dir"
  reap_worktree_orphans "$worktree_dir"
  git worktree remove --force "$worktree_dir" 2>/dev/null || true
  rm -rf "$worktree_dir" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
  git branch -D "$branch" 2>/dev/null || true
}

# ── Project manifest parser ──────────────────────────────
# `parse_manifest` now lives in lib/claude-session-lib.sh (sourced above),
# co-located with its consumer run_integration_gate and shared with
# autopilot-chain.sh's phase integration gate. Single definition — see the lib.

# _write_chain_blocked_reason is defined above (before the arg-parse loop)
# so the arg-parse default arm can call it on unknown flags. See the
# function header for the sentinel contract.

preflight_check() {
  local project_dir="$1"
  local claude_md="${project_dir}/CLAUDE.md"
  local failed=false

  log "${CYAN}Running pre-flight checks...${NC}"

  # Strip sandbox proxy env vars (break httpx, tiktoken, pip)
  unset ALL_PROXY HTTPS_PROXY HTTP_PROXY all_proxy https_proxy http_proxy 2>/dev/null || true
  log "${GREEN}✓${NC} Sandbox proxy vars stripped"

  # Git cleanliness check — parallels commit-finalize.sh git_clean step at end of run.
  # Without this, uncommitted tracked changes survive the run and cause false-fail at
  # finalize after 100+ min of pipeline work. Filter matches the finalize check exactly:
  # tracked modifications/additions/deletions only (untracked '??' files not flagged here,
  # since they're often intentional WIP outside autopilot's scope).
  local dirty
  dirty=$(git -C "$project_dir" status --porcelain 2>/dev/null | grep -v '^??' | head -5 || true)
  if [[ -n "$dirty" ]]; then
    log "${YELLOW}⏸${NC}  Uncommitted tracked changes in $project_dir:"
    while IFS= read -r line; do log "    $line"; done <<< "$dirty"
    log "  Operator-resolvable: commit, stash, or revert. Then re-run chain (no flag needed)."
    log "  Override (not recommended): AUTOPILOT_SKIP_GIT_CHECK=1"
    if [[ "${AUTOPILOT_SKIP_GIT_CHECK:-0}" == "1" ]]; then
      log "${YELLOW}⚠${NC} AUTOPILOT_SKIP_GIT_CHECK=1 set — proceeding (will cause git_clean fail at finalize)"
    else
      if [[ "$FULL_MODE" == true && -n "${WORKDIR:-}" && -n "${MAIN_DIR:-}" ]]; then
        cleanup_worktree "$WORKDIR" "feature/${TASK}" "$MAIN_DIR"
      fi
      # Route to chain orchestrator's blocked_tasks via exit code 2 + reason
      # sentinel. Operator-resolvable state issue (dirty main is not a code
      # defect; it's an operator/timing condition that auto-resolves once
      # main is committed/stashed). Symmetry with merge-conflict and
      # lock-timeout exits.
      _write_chain_blocked_reason "dirty_main"
      exit 2
    fi
  else
    log "${GREEN}✓${NC} Git clean (no uncommitted tracked changes)"
  fi

  if [[ ! -f "$claude_md" ]]; then
    log "${RED}✗${NC} No CLAUDE.md found at $claude_md"
    log "  Create one with a pipeline: manifest block. Example:"
    log "    pipeline:"
    log "      toolchain:"
    log "        python: [ruff, mypy]"
    log "      smoke_test:"
    log "        - curl -sf http://localhost:8100/api/health"
    log "      contracts: []"
    log "  See ~/Projekter/dotfiles/docs/INPROGRESS_Plan_autopilot-hardening/PLAN.md for details."
    if [[ "$FULL_MODE" == true && -n "${WORKDIR:-}" && -n "${MAIN_DIR:-}" ]]; then
      cleanup_worktree "$WORKDIR" "feature/${TASK}" "$MAIN_DIR"
    fi
    exit 1
  fi

  local manifest
  manifest=$(parse_manifest "$project_dir")
  if [[ -z "$manifest" ]]; then
    log "${RED}✗${NC} No pipeline: manifest found in $claude_md"
    log "  Add a pipeline: block to your CLAUDE.md. Example:"
    log "    pipeline:"
    log "      toolchain:"
    log "        python: [ruff, mypy]"
    log "      smoke_test:"
    log "        - curl -sf http://localhost:8100/api/health"
    log "      contracts: []"
    if [[ "$FULL_MODE" == true && -n "${WORKDIR:-}" && -n "${MAIN_DIR:-}" ]]; then
      cleanup_worktree "$WORKDIR" "feature/${TASK}" "$MAIN_DIR"
    fi
    exit 1
  fi

  # Detect project Python (venv > uv > system)
  # Quote the path to handle spaces in directory names
  local project_python="python3"
  if [[ -x "$project_dir/.venv/bin/python" ]]; then
    project_python="\"$project_dir/.venv/bin/python\""
  elif command -v uv &>/dev/null && [[ -f "$project_dir/pyproject.toml" ]]; then
    project_python="uv run python"
  fi
  log "  Using Python: $project_python"

  # Check toolchain
  while IFS='|' read -r type key value; do
    case "$type" in
      TOOLCHAIN)
        case "$key" in
          python)
            if command -v "$value" &>/dev/null; then
              log "${GREEN}✓${NC} Python tool: $value (global)"
            elif [[ -x "${project_dir}/.venv/bin/${value}" ]]; then
              log "${GREEN}✓${NC} Python tool: $value (venv)"
            elif eval "$project_python -c \"import $value\"" 2>/dev/null; then
              log "${GREEN}✓${NC} Python tool: $value (importable)"
            else
              log "${RED}✗${NC} Python tool missing: $value — install with: pip install $value (or add to project deps)"
              failed=true
            fi
            ;;
          node)
            # Try from frontend directories where node_modules lives
            local node_found=false
            for frontend_dir in "$project_dir/ui" "$project_dir/ui_react/frontend" "$project_dir/dashboard/app" "$project_dir/app" "$project_dir/frontend"; do
              if [[ -d "$frontend_dir/node_modules" ]]; then
                if (cd "$frontend_dir" && npx "$value" --version &>/dev/null 2>&1); then
                  node_found=true
                  break
                fi
              fi
            done
            if [[ "$node_found" == false ]]; then
              # Also try from project root as fallback
              if npx "$value" --version &>/dev/null 2>&1; then
                node_found=true
              fi
            fi
            if [[ "$node_found" == false ]]; then
              log "${RED}✗${NC} Node tool missing: $value (checked ui/, ui_react/frontend/, app/, frontend/)"
              failed=true
            else
              log "${GREEN}✓${NC} Node tool: $value"
            fi
            ;;
          imports)
            if ! eval "$project_python -c \"import $value\"" 2>/dev/null; then
              log "${RED}✗${NC} Python import failed: $value"
              failed=true
            else
              log "${GREEN}✓${NC} Python import: $value"
            fi
            ;;
          network)
            if ! curl -sf --max-time 5 "https://$value" > /dev/null 2>&1; then
              log "${RED}✗${NC} Network host unreachable: $value"
              failed=true
            else
              log "${GREEN}✓${NC} Network host: $value"
            fi
            ;;
          infra)
            if ! command -v "$value" &>/dev/null; then
              log "${YELLOW}⚠${NC} Infra tool missing (non-blocking): $value"
            else
              log "${GREEN}✓${NC} Infra tool: $value"
            fi
            ;;
        esac
        ;;
    esac
  done <<< "$manifest"

  if [[ "$failed" == true ]]; then
    log "${RED}Pre-flight failed. Fix the environment before running autopilot.${NC}"
    # Clean up worktree if full mode created one
    if [[ "$FULL_MODE" == true && -n "${WORKDIR:-}" && -n "${MAIN_DIR:-}" ]]; then
      log "Cleaning up worktree after pre-flight failure..."
      cleanup_worktree "$WORKDIR" "feature/${TASK}" "$MAIN_DIR"
    fi
    exit 1
  fi

  # ── Phase-specific preconditions (warn-level — don't fail, but surface gaps upfront) ──
  # Catches tooling gaps that would silently SKIP or FAIL in later phases (e.g.,
  # /static-analysis runs sonar-scanner + pytest-cov + vitest coverage; if those
  # tools are missing, the phase reports SKIP after the operator already burned
  # 1-2h on earlier phases). Surface ALL gaps upfront so operator can install
  # tools before kickoff or accept the skips with eyes open.
  preflight_static_analysis_preconditions "$project_dir" "$project_python" "$manifest"

  # ── pyproject.toml dev-deps verification ──
  # Catches the failure pattern observed 2026-05-04 where a feature run hit
  # "uv pip install pytest-cov / types-PyYAML" tunnel-error loops because a
  # dev-only declared dep was missing from the worktree's .venv. The
  # tool-dependency-policy rule forbids fly-installs; this preflight ensures
  # the operator knows BEFORE phase 1 that the venv is incomplete instead
  # of discovering it 30 min in. Warn-level, never blocking — uv may not be
  # on PATH and not all projects use uv.
  preflight_pyproject_dev_deps "$project_dir" "$project_python"

  log "${GREEN}✓${NC} Pre-flight checks passed"
}

preflight_pyproject_dev_deps() {
  # Verify every package in pyproject.toml [project.optional-dependencies] dev
  # is importable from the project venv. Skips gracefully if no pyproject.toml
  # or no dev-deps section. Outputs warn-level findings.
  local project_dir="$1"
  local project_python="$2"
  local pyproject="$project_dir/pyproject.toml"

  if [[ ! -f "$pyproject" ]]; then
    return 0
  fi

  # Extract dev = [...] block via python (handles multi-line lists & comments).
  local missing_pkgs
  missing_pkgs=$(eval "$project_python" <<PYEOF 2>/dev/null || true
import importlib, importlib.util, sys, re
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib
    except ImportError:
        sys.exit(0)
try:
    with open("$pyproject", "rb") as f:
        data = tomllib.load(f)
except Exception:
    sys.exit(0)
deps = (data.get("project", {})
            .get("optional-dependencies", {})
            .get("dev", []))
# Mapping for packages whose import name differs from their PyPI name.
import_aliases = {
    "pytest-cov": "pytest_cov",
    "types-PyYAML": "yaml",  # types-PyYAML provides stubs for "yaml"
    "types-pyyaml": "yaml",
}
missing = []
for dep in deps:
    pkg = re.split(r"[<>=!~;\s]", dep, 1)[0].strip()
    if not pkg:
        continue
    import_name = import_aliases.get(pkg, pkg.replace("-", "_"))
    spec = importlib.util.find_spec(import_name)
    if spec is None:
        missing.append(pkg)
print("\\n".join(missing))
PYEOF
  )

  if [[ -z "$missing_pkgs" ]]; then
    return 0
  fi

  log "${YELLOW}⚠${NC} pyproject.toml dev-deps missing in venv:"
  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    log "    $pkg"
  done <<< "$missing_pkgs"
  log "  Run \`uv sync --extra dev\` to provision before starting autopilot."
  log "  Phases that need these will fail — fly-install is forbidden by"
  log "  tool-dependency-policy (sandbox blocks pythonhosted.org)."
}

preflight_static_analysis_preconditions() {
  # Read declared preconditions from the parsed manifest (PRECONDITION|... records).
  # Each project's CLAUDE.md `pipeline.preconditions:` block declares what
  # /static-analysis (and other phases) need. Generic preflight; nothing hard-coded
  # per project. If no preconditions declared, this function is a silent no-op.
  local project_dir="$1"
  local project_python="$2"
  local manifest="$3"
  local has_warning=false
  local check_count=0

  # Extract PRECONDITION records from manifest
  local preconditions
  preconditions=$(echo "$manifest" | grep '^PRECONDITION|' || true)
  if [[ -z "$preconditions" ]]; then
    return 0
  fi

  log "${CYAN}Phase preconditions (warn-only, from CLAUDE.md pipeline.preconditions:)...${NC}"

  while IFS='|' read -r _ kind params; do
    [[ -z "$kind" ]] && continue
    check_count=$((check_count + 1))
    # Parse params: key1=value1;key2=value2
    local reason=""
    local value=""
    local file=""
    local dep=""
    local path=""
    local url=""
    IFS=';' read -ra param_pairs <<< "$params"
    for pair in "${param_pairs[@]}"; do
      [[ -z "$pair" ]] && continue
      local k="${pair%%=*}"
      local v="${pair#*=}"
      case "$k" in
        reason) reason="$v" ;;
        value) value="$v" ;;
        file) file="$v" ;;
        dep) dep="$v" ;;
        path) path="$v" ;;
        url) url="$v" ;;
      esac
    done

    case "$kind" in
      python_import)
        if eval "$project_python -c \"import $value\"" 2>/dev/null; then
          log "${GREEN}✓${NC} python_import: $value"
        else
          log "${YELLOW}⚠${NC} python_import MISSING: $value"
          [[ -n "$reason" ]] && log "    Reason: $reason"
          has_warning=true
        fi
        ;;
      package_dep)
        local full_file="$project_dir/$file"
        if [[ -f "$full_file" ]] && grep -q "\"$dep\"" "$full_file" 2>/dev/null; then
          log "${GREEN}✓${NC} package_dep: $dep in $file"
        else
          log "${YELLOW}⚠${NC} package_dep MISSING: $dep not in $file"
          [[ -n "$reason" ]] && log "    Reason: $reason"
          has_warning=true
        fi
        ;;
      file_exists)
        if [[ -f "$project_dir/$path" ]]; then
          log "${GREEN}✓${NC} file_exists: $path"
        else
          log "${YELLOW}⚠${NC} file_exists MISSING: $path"
          [[ -n "$reason" ]] && log "    Reason: $reason"
          has_warning=true
        fi
        ;;
      http_reachable)
        if curl -sf -m 3 "$url" >/dev/null 2>&1; then
          log "${GREEN}✓${NC} http_reachable: $url"
        else
          log "${YELLOW}⚠${NC} http_reachable FAILED: $url"
          [[ -n "$reason" ]] && log "    Reason: $reason"
          has_warning=true
        fi
        ;;
      *)
        log "${YELLOW}⚠${NC} unknown precondition kind: $kind (params: $params)"
        log "    Supported kinds: python_import, package_dep, file_exists, http_reachable"
        has_warning=true
        ;;
    esac
  done <<< "$preconditions"

  if [[ "$has_warning" == true ]]; then
    log "${YELLOW}One or more declared preconditions failed. Affected phases may SKIP/FAIL.${NC}"
    log "${YELLOW}Press Ctrl+C now to fix, or proceed and accept the impact. (Continuing in 5s...)${NC}"
    sleep 5
  else
    log "${GREEN}✓${NC} All $check_count declared preconditions satisfied"
  fi
}

run_smoke_with_retry() {
  # Execute a smoke-test command with bounded retries and escalating backoff.
  # Backoff sequence (5s, 15s) lets macOS finish async worktree/pycache cleanup
  # that can momentarily break import/read paths right after a merge.
  #
  # Args: $1 = shell command to eval
  # Returns: 0 if any attempt succeeds, non-zero if all attempts fail
  local cmd="$1"
  local max_attempts=3
  local backoffs=(5 15)
  local attempt=1
  while [[ $attempt -le $max_attempts ]]; do
    if eval "$cmd" 2>&1; then
      if [[ $attempt -gt 1 ]]; then
        log "${GREEN}✓${NC} $cmd (passed on attempt $attempt — transient failure recovered)"
      fi
      return 0
    fi
    if [[ $attempt -lt $max_attempts ]]; then
      local wait_s=${backoffs[$((attempt - 1))]}
      log "${YELLOW}⚠${NC} Smoke test failed (attempt $attempt/$max_attempts) — likely transient post-merge; retrying after ${wait_s}s..."
      sleep "$wait_s"
    fi
    attempt=$((attempt + 1))
  done
  log "${RED}✗${NC} Smoke test failed (persistent across $max_attempts attempts): $cmd"
  return 1
}

postmerge_check() {
  local project_dir="$1"
  local claude_md="${project_dir}/CLAUDE.md"

  if [[ ! -f "$claude_md" ]]; then
    return 0
  fi

  local manifest
  manifest=$(parse_manifest "$project_dir")
  local has_smoke=false

  while IFS='|' read -r type value; do
    if [[ "$type" == "SMOKE" ]]; then
      has_smoke=true
      break
    fi
  done <<< "$manifest"

  if [[ "$has_smoke" == false ]]; then
    log "${YELLOW}⚠${NC} No pipeline.smoke_test configured — skipping post-merge checks"
    log "  Add smoke_test commands to the pipeline: block in CLAUDE.md to verify merges."
    return 0
  fi

  log "${CYAN}Running post-merge smoke test...${NC}"
  cd "$project_dir"

  # Clear stale caches that can produce transient failures immediately
  # post-merge (stale __pycache__ from pre-merge imports, test framework
  # fixture caches). Safe to skip if not present.
  find . -type d -name __pycache__ -not -path "*/node_modules/*" -not -path "*/.venv/*" -print0 2>/dev/null | xargs -0 rm -rf 2>/dev/null || true
  find . -type d -name ".pytest_cache" -not -path "*/node_modules/*" -not -path "*/.venv/*" -print0 2>/dev/null | xargs -0 rm -rf 2>/dev/null || true

  # pnpm deps reconcile — pnpm's runDepsStatusCheck aborts the smoke
  # test if package.json or pnpm-lock.yaml changed in the merge but
  # node_modules is stale. `pnpm install` is fast when nothing
  # changed and idempotent. Observed during terminal-socket-hook
  # post-merge smoke (2026-05-16) where 1598 tests passed manually
  # after a single `pnpm install` but the autopilot retried 3× with
  # the stale node_modules and failed each time.
  if command -v pnpm >/dev/null 2>&1; then
    while IFS= read -r -d '' lock; do
      local pkg_dir
      pkg_dir=$(dirname "$lock")
      log "  pnpm install in $pkg_dir (post-merge deps reconcile)"
      if ! (cd "$pkg_dir" && pnpm install --prefer-offline --silent) >/dev/null 2>&1; then
        log "${YELLOW}  pnpm install in $pkg_dir failed — smoke may surface as stale-deps error${NC}"
      fi
    done < <(find . -name "pnpm-lock.yaml" -not -path "*/node_modules/*" -maxdepth 4 -print0 2>/dev/null)
  fi

  # Allow filesystem to settle after merge + cache cleanup
  sleep 2

  while IFS='|' read -r type value; do
    if [[ "$type" == "SMOKE" ]]; then
      log "  Running: $value"
      if ! run_smoke_with_retry "$value"; then
        return 1
      fi
    fi
  done <<< "$manifest"

  log "${GREEN}✓${NC} Post-merge smoke test passed"
  return 0
}

contract_check() {
  local project_dir="$1"
  local claude_md="${project_dir}/CLAUDE.md"

  if [[ ! -f "$claude_md" ]]; then
    return 0
  fi

  local manifest
  manifest=$(parse_manifest "$project_dir")
  local has_contracts=false

  while IFS='|' read -r type rest; do
    if [[ "$type" == CONTRACT_* ]]; then
      has_contracts=true
      break
    fi
  done <<< "$manifest"

  if [[ "$has_contracts" == false ]]; then
    return 0
  fi

  log "${CYAN}Running contract checks...${NC}"
  cd "$project_dir"
  local failed=false
  local grep_pattern="" grep_source="" grep_max=""

  while IFS='|' read -r type value; do
    case "$type" in
      CONTRACT_TEST)
        log "  Running contract test: $value"
        # Detect Python tool runner (matches static-analysis-conventions.md):
        # uv > project venv > system python
        local pytest_cmd=""
        if [[ -f "${project_dir}/pyproject.toml" ]] && command -v uv &>/dev/null; then
          pytest_cmd="uv run pytest"
        elif [[ -x "${project_dir}/.venv/bin/pytest" ]]; then
          pytest_cmd="${project_dir}/.venv/bin/pytest"
        else
          pytest_cmd="python3 -m pytest"
        fi
        if ! $pytest_cmd "$value" -q 2>&1; then
          log "${RED}✗${NC} Contract test failed: $value"
          failed=true
        else
          log "${GREEN}✓${NC} Contract test passed: $value"
        fi
        ;;
      CONTRACT_GREP)
        grep_pattern="$value"
        ;;
      CONTRACT_SOURCE)
        grep_source="$value"
        ;;
      CONTRACT_MAX)
        grep_max="$value"
        if [[ -n "$grep_pattern" && -n "$grep_source" && -n "$grep_max" ]]; then
          log "  Checking: $grep_pattern in $grep_source (max: $grep_max)"
          local violations
          violations=$(find . \( -path "./$grep_source" -name "*.tsx" -o -path "./$grep_source" -name "*.ts" \) -print0 2>/dev/null | \
            xargs -0 grep -n "$grep_pattern" 2>/dev/null | \
            grep -oE '[0-9]+' | \
            awk -v max="$grep_max" '$1 > max {print}' || true)
          if [[ -n "$violations" ]]; then
            log "${RED}✗${NC} Contract violation: values exceeding $grep_max found"
            failed=true
          else
            log "${GREEN}✓${NC} Contract check passed: $grep_pattern <= $grep_max"
          fi
          grep_pattern="" grep_source="" grep_max=""
        fi
        ;;
    esac
  done <<< "$manifest"

  if [[ "$failed" == true ]]; then
    return 1
  fi
  return 0
}

# ── Pre-flight checks ─────────────────────────────────────

# Check claude is available
if ! command -v claude &>/dev/null; then
  echo -e "${RED}Error: claude CLI not found.${NC}"
  exit 1
fi

# Check python3 is available (for stream processing)
if ! command -v python3 &>/dev/null; then
  echo -e "${RED}Error: python3 is required for stream processing.${NC}"
  exit 1
fi

# ── Full mode: create worktree first ─────────────────────

WORKDIR=$(pwd)

if [[ "$FULL_MODE" == true ]]; then
  # Must be on main
  BRANCH=$(git branch --show-current)
  if [[ "$BRANCH" != "main" && "$BRANCH" != "master" ]]; then
    echo -e "${RED}Error: --full mode must be run from main branch. You're on $BRANCH.${NC}"
    exit 1
  fi

  # Check worktree script exists
  if [[ ! -f scripts/worktree.sh ]]; then
    echo -e "${RED}Error: scripts/worktree.sh not found. Are you in the project root?${NC}"
    exit 1
  fi

  # Determine main dir and any existing worktree up-front — with --from we
  # reuse an existing worktree (resume after earlier phases produced it);
  # without --from we require a clean slate.
  MAIN_DIR=$(pwd)
  EXISTING_WORKDIR=$(git worktree list | awk -v t="feature/${TASK}" '$0 ~ t {print $1}')

  if [[ -n "$EXISTING_WORKDIR" && -d "$EXISTING_WORKDIR" ]]; then
    if [[ -n "$START_FROM" ]]; then
      echo -e "${CYAN}Reusing existing worktree for ${TASK} at ${EXISTING_WORKDIR}${NC}"
      WORKDIR="$EXISTING_WORKDIR"
    else
      echo -e "${RED}Error: Worktree already exists at ${EXISTING_WORKDIR}.${NC}"
      echo -e "${RED}  Use --from <phase> to resume, or remove the worktree first:${NC}"
      echo -e "${RED}    git worktree remove --force \"$EXISTING_WORKDIR\"${NC}"
      exit 1
    fi
  else
    echo -e "${CYAN}Creating worktree for ${TASK}...${NC}"
    if ! bash scripts/worktree.sh new "$TASK"; then
      echo -e "${RED}Error: Failed to create worktree for ${TASK}. Check if it already exists: git worktree list${NC}"
      exit 1
    fi
    WORKDIR=$(git worktree list | awk -v t="feature/${TASK}" '$0 ~ t {print $1}')
  fi

  if [[ -z "$WORKDIR" || ! -d "$WORKDIR" ]]; then
    # Fallback to convention: ../<project>-<task>/
    PROJECT_NAME=$(basename "$MAIN_DIR")
    WORKDIR="$MAIN_DIR/../${PROJECT_NAME%%-*}-${TASK}"
  fi

  if [[ ! -d "$WORKDIR" ]]; then
    WORKDIR="$MAIN_DIR/../$(basename "$MAIN_DIR")-${TASK}"
  fi

  if [[ ! -d "$WORKDIR" ]]; then
    echo -e "${RED}Error: Worktree not found. Expected at: $WORKDIR${NC}"
    exit 1
  fi

  cd "$WORKDIR"
  WORKDIR=$(pwd)
  log "Worktree: $WORKDIR"
else
  # Must be in a worktree, not main
  BRANCH=$(git branch --show-current)
  if [[ "$BRANCH" == "main" || "$BRANCH" == "master" ]]; then
    echo -e "${RED}Error: You're on $BRANCH. Run from a feature worktree, or use --full from main.${NC}"
    exit 1
  fi
  WORKDIR=$(pwd)
  MAIN_DIR=$(git worktree list | head -1 | awk '{print $1}')
fi

# ── Kill orphaned autopilot processes for this task ──────
# A previous autopilot run may have left Claude processes writing to the
# same stream file. Kill them before we truncate.
if pkill -f "claude.*${TASK}" 2>/dev/null; then
  sleep 2  # let processes exit cleanly
  log "${YELLOW}⚠${NC} Killed orphaned Claude processes for task: ${TASK}"
fi

# ── Pre-flight: Sync feature branch with origin/main ─────
# Rebase the feature branch on latest origin/main to pick up commits
# made while this task was queued or paused (parallel chain runs,
# manual hotfixes on main). Catches main-divergence conflicts at task
# start — smallest conflict surface — instead of at final merge where
# 2-3h of phase work is at risk on a rebase failure.
#
# Skip via NO_PRE_REBASE=1 (offline use, manual rebase already done).
# Skipped silently if origin/main is unreachable or worktree is dirty.
if [[ "${NO_PRE_REBASE:-0}" != "1" && "${NO_PRE_REBASE:-false}" != "true" ]]; then
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet HEAD 2>/dev/null; then
    log "${YELLOW}⚠${NC} Pre-flight: worktree has uncommitted changes — skipping rebase (would lose changes)"
  elif git fetch origin main 2>/dev/null; then
    REBASE_EXIT=0
    git rebase origin/main 2>/dev/null || REBASE_EXIT=$?
    if [[ $REBASE_EXIT -ne 0 ]]; then
      git rebase --abort 2>/dev/null || true
      RETRY_CMD="bash claude/tools/autopilot.sh --full --pipeline $PIPELINE"
      [[ -n "${START_FROM:-}" ]] && RETRY_CMD="$RETRY_CMD --from $START_FROM"
      RETRY_CMD="$RETRY_CMD $TASK"
      echo -e "${RED}Pre-flight: feature/${TASK} has conflicts with origin/main${NC}" >&2
      echo -e "${RED}  Resolve manually before retrying:${NC}" >&2
      echo -e "${YELLOW}    cd $WORKDIR${NC}" >&2
      echo -e "${YELLOW}    git fetch origin main && git rebase origin/main${NC}" >&2
      echo -e "${YELLOW}    # resolve conflicts, git add <files>, git rebase --continue${NC}" >&2
      echo -e "${YELLOW}    cd $MAIN_DIR && $RETRY_CMD${NC}" >&2
      echo -e "${YELLOW}  Or skip rebase entirely: NO_PRE_REBASE=1 $RETRY_CMD${NC}" >&2
      exit 1
    fi
    log "Pre-flight: feature/${TASK} synced with origin/main (rebase OK)"
  else
    log "${YELLOW}⚠${NC} Pre-flight: could not fetch origin/main — skipping rebase (offline?)"
  fi
fi

# ── Initialize ───────────────────────────────────────────

mkdir -p .planning
mkdir -p "$FEATURE_DIR"
STREAM_FILE="${WORKDIR}/${FEATURE_DIR}/autopilot-stream.ndjson"
# Append across restarts so resumed runs preserve the prior session's
# trace (chain-events.ndjson follows the same model). A session-boundary
# marker is emitted as the first record of each new run so consumers can
# scan for "where did the latest session start". Status-helper's
# `started` handler unconditionally overwrites `started_at`, so the
# dashboard elapsed-timer still reflects the active run.
{ printf '{"type":"orchestrator","msg":"--- session start ---","ts":"%s"}\n' \
    "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$STREAM_FILE"; } 2>/dev/null || true

# Emit the local-LLM preflight-success NDJSON event (R16). No-op when
# routing is disabled or the parsed list is empty — STREAM_FILE stays
# byte-identical to the default path.
emit_local_llm_preflight_ok "$STREAM_FILE"

# controls-07 #14 — tee stdout+stderr to a persistent log file in the
# feature dir, mirroring the chain.sh pattern. When a feature autopilot
# dies silently (kill -9, segfault, OOM) the structured stream may end
# mid-phase with no terminal lifecycle event; the raw log is the
# operator's only path to post-mortem the exit. The tee preserves the
# pane stream so the chain orchestrator's display + the WS terminal
# viewer continue to work.
# Defensive: `|| true` keeps the script alive in restricted sandboxes
# where /dev/fd process substitution is blocked.
exec > >(tee -a "${WORKDIR}/${FEATURE_DIR}/autopilot-stdout.log") 2>&1 || true
BRANCH=$(git branch --show-current)

echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║  AUTOPILOT: ${TASK}"
echo "  ║  Branch: ${BRANCH}"
echo "  ║  Mode: $([ "$FULL_MODE" = true ] && echo 'Full (worktree → merge)' || echo 'Pipeline only')"
echo "  ║  Pipeline: ${PIPELINE} $([ "$PIPELINE" = 'full' ] && echo '(BA→Plan→Team Review→Implement→Static Analysis→Team QA)' || echo '(BA→Plan→Review→Implement→Static Analysis→QA)')"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"

# Clean any stale autopilot.PAUSE left over from a previous run before
# entering the phase loop. Without this, a leftover PAUSE would fire the
# first check_pause_file at the top of phase ba and exit before any work
# runs — surprising behaviour and not what the operator intended.
_stale_pause_cleanup

# Resolve YAML_FILE unconditionally so the deviation hook can fire under
# every --pipeline mode (auto, full, light). Multi-plan resolution is
# task-id-aware via resolve_plan_yaml_worktree_aware (claude-session-lib.sh):
# in chain mode the worktree's plan copy is preferred so tracker writes
# flow through the feature branch's commits + merge, keeping main clean
# during the run. Falls back to MAIN_DIR for standalone runs where no
# worktree exists. Defensive guard: if MAIN_DIR isn't set yet (shouldn't
# happen at this point, but guard anyway), yield empty string and skip.
if [[ -z "${MAIN_DIR:-}" ]]; then
  log "WARN: MAIN_DIR unset before YAML_FILE resolution"
  YAML_FILE=""
else
  YAML_FILE=$(resolve_plan_yaml_worktree_aware "$TASK" "${WORKDIR:-}" "$MAIN_DIR")
fi
export YAML_FILE
export TASK

# PLAN_FILE: stable alias of YAML_FILE that downstream phase agents read
# instead of re-globbing docs/INPROGRESS_Plan_*/execution-plan.yaml on
# every claude -p invocation. Plan-detection SKILL honors this first; the
# Glob path remains as a fallback when PLAN_FILE is empty/unset (e.g.
# standalone flow commands invoked outside autopilot). Saves 5–7 Glob
# calls per multi-phase run (canary A/B/C antipattern, 2026-05-24).
PLAN_FILE="$YAML_FILE"
export PLAN_FILE

# Auto-detect pipeline from execution plan YAML if not specified
if [[ "$PIPELINE" == "auto" ]]; then
  PIPELINE=""  # clear the "auto" marker so the YAML lookup + default fallback can take effect
  if [[ -n "$YAML_FILE" ]]; then
    # Look for pipeline field on the task
    PIPELINE=$(grep -A 5 "id: ${TASK}$" "$YAML_FILE" 2>/dev/null | grep "pipeline:" | head -1 | awk '{print $2}' || true)
  fi
  PIPELINE=${PIPELINE:-full}
fi

# Validate pipeline value
if [[ "$PIPELINE" != "full" && "$PIPELINE" != "light" ]]; then
  echo -e "${RED}Error: --pipeline must be 'full' or 'light', got '$PIPELINE'${NC}"
  exit 1
fi

# Footgun fix (2026-06-02): honor the task's runner.env (esp. MODEL_PER_PHASE)
# from the plan on a DIRECT run, the way autopilot-chain.sh already does for
# chained runs. Without this, `autopilot.sh <task>` silently ignored a per-task
# model override and an all-Opus canary executed as Sonnet. The explicit
# environment still wins (per-invocation prefix / per-shell export).
apply_plan_runner_env "$YAML_FILE" "$TASK"

# Phase tracking for summary
declare -a PHASE_NAMES=()
declare -a PHASE_STATUSES=()
declare -a PHASE_DURATIONS=()
declare -a PHASE_ARTIFACTS=()
SUMMARY_FILE="${WORKDIR}/${FEATURE_DIR}/autopilot-summary.json"
START_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
PIPELINE_STATUS="success"

declare -a PHASE_COSTS=()

write_summary() {
  local end_ts
  end_ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  local project
  project=$(basename "$MAIN_DIR")

  # Build phases JSON array
  local phases="["
  for i in "${!PHASE_NAMES[@]}"; do
    local artifact="${PHASE_ARTIFACTS[$i]}"
    [[ "$artifact" == "null" ]] && artifact="null" || artifact="\"$artifact\""
    local cost="${PHASE_COSTS[$i]:-0}"
    [[ $i -gt 0 ]] && phases+=","
    phases+=$(printf '{"name":"%s","status":"%s","duration_s":%s,"cost":%s,"artifact":%s}' \
      "${PHASE_NAMES[$i]}" "${PHASE_STATUSES[$i]}" "${PHASE_DURATIONS[$i]}" "$cost" "$artifact")
  done
  phases+="]"

  mkdir -p "$(dirname "$SUMMARY_FILE")" 2>/dev/null || true
  cat > "$SUMMARY_FILE" <<EOJSON
{
  "task": "${TASK}",
  "project": "${project}",
  "branch": "${BRANCH}",
  "workdir": "${WORKDIR}",
  "start_ts": "${START_TS}",
  "end_ts": "${end_ts}",
  "duration_s": ${TOTAL_DURATION},
  "phases": ${phases},
  "status": "${PIPELINE_STATUS}"
}
EOJSON
  log "Summary written to: $SUMMARY_FILE"
}

log "Autopilot started for task: $TASK"
log "Worktree: $WORKDIR"
log "Branch: $BRANCH"
log "Full mode: $FULL_MODE"
log "Pipeline: $PIPELINE"
if [[ -n "$START_FROM" ]]; then
  log "${YELLOW}Resume mode: starting from '${START_FROM}' — skipping: $(skipped_phases)${NC}"
fi
if [[ -n "$STOP_AFTER_PHASE" ]]; then
  log "${YELLOW}Stop mode: halting after phase '${STOP_AFTER_PHASE}'${NC}"
fi
dashboard_event "SessionStart" "autopilot" "Starting autonomous pipeline for $TASK"
lifecycle_emit_started "$STREAM_FILE" "$TASK"

# ── Constraint A pre-flight (low-trust scope only) ───────
# Refuses to run if git remotes point at untrusted owners or repository
# is a fork. Eliminates ~75-80% of practical prompt-injection surface
# by ensuring autopilot only operates on user-owned projects.
# Override: AUTOPILOT_FORCE_RUN=1 (audit usage in commit history).
# See docs/architecture/security-layers.md (constraint A) for rationale.
if ! trust_check_main_dir "$MAIN_DIR" "$TASK"; then
  log "${RED}✗ Trust-check failed. Refusing to run autopilot.${NC}"
  if [[ "$FULL_MODE" == true && -n "${WORKDIR:-}" && -n "${MAIN_DIR:-}" ]]; then
    cleanup_worktree "$WORKDIR" "feature/${TASK}" "$MAIN_DIR"
  fi
  exit 1
fi

# ── Project manifest pre-flight ──────────────────────────
preflight_check "$MAIN_DIR"

# ── Execution plan guards ────────────────────────────────
if [[ -n "${YAML_FILE:-}" ]]; then
  # UI task guard — use fixed-string grep + awk filter to avoid regex-special
  # chars in $TASK (e.g. '.' '*' '[') matching unintended rows. -F makes the
  # literal "id: <task>" match exact; the awk post-filter enforces the trailing
  # field-boundary so "id: foo-bar" does not match when TASK="foo".
  # F12: two bugs combined:
  #   (a) `$0!=t` causes BSD awk on macOS to error because bash escapes `!`
  #       to `\!` even in non-interactive scripts (history expansion artefact).
  #   (b) `$0==t` compares the full YAML line (e.g. "      - id: task-name")
  #       against the bare search token ("id: task-name") — they can never
  #       be equal, so the filter always exited at NR==1 and the ui: field
  #       was never reached, making the guard silently dead on real plans.
  # Fix: use substr to test that the line ENDS with the token (suffix-exact
  # match), and invert to avoid `!` entirely. Works for all YAML indentation
  # levels; rejects prefix-only matches (TASK="foo" vs id="foo-bar").
  TASK_UI=$(grep -A 10 -F "id: ${TASK}" "$YAML_FILE" 2>/dev/null \
    | awk -v t="id: ${TASK}" 'NR==1{if(substr($0,length($0)-length(t)+1)==t)next; exit} NR>1' \
    | grep "ui:" | head -1 | awk '{print $2}' || true)
  if [[ "$TASK_UI" == "true" ]]; then
    log "${RED}ERROR: Task has ui: true in execution plan. Autopilot skips /ux and /manualtest — not suitable for UI tasks.${NC}"
    log "Run this task in flow mode instead: /start ${TASK}"
    if [[ "$FULL_MODE" == true && -n "${WORKDIR:-}" && -n "${MAIN_DIR:-}" ]]; then
      cleanup_worktree "$WORKDIR" "feature/${TASK}" "$MAIN_DIR"
    fi
    exit 1
  fi

  # Dependency check — verify all depends are done/skipped
  # F6: read path/task_id from environment (already exported above) rather
  # than shell-interpolating into the heredoc — prevents single-quote
  # injection if $TASK contains ' or regex metacharacters.
  TASK_DEPS=$(python3 -c "
import os, re, sys
path = os.environ['YAML_FILE']
task_id = os.environ['TASK']
with open(path) as f:
    content = f.read()

# Find the task block and extract depends list
pattern = r'- id: ' + re.escape(task_id) + r'\n((?:[ \t]+\w.*\n)*)'
match = re.search(pattern, content)
if not match:
    sys.exit(0)

block = match.group(1)
deps_match = re.search(r'depends:\s*\[([^\]]*)\]', block)
if not deps_match:
    sys.exit(0)

deps = [d.strip() for d in deps_match.group(1).split(',') if d.strip()]
for dep in deps:
    # Find this dep's status
    dep_pattern = r'- id: ' + re.escape(dep) + r'\n((?:[ \t]+\w.*\n)*)'
    dep_match = re.search(dep_pattern, content)
    if dep_match:
        status_match = re.search(r'status:\s*(\w+)', dep_match.group(1))
        status = status_match.group(1) if status_match else 'unknown'
    else:
        status = 'not_found'
    if status not in ('done', 'skipped'):
        print(f'{dep}:{status}')
" 2>/dev/null || true)

  if [[ -n "$TASK_DEPS" ]]; then
    log "${RED}ERROR: Task '${TASK}' has unmet dependencies:${NC}"
    while IFS=':' read -r dep status; do
      log "  ${RED}✗${NC} $dep (status: $status)"
    done <<< "$TASK_DEPS"
    log "Complete these tasks first, or set their status to 'done'/'skipped' in the execution plan."
    if [[ "$FULL_MODE" == true && -n "${WORKDIR:-}" && -n "${MAIN_DIR:-}" ]]; then
      cleanup_worktree "$WORKDIR" "feature/${TASK}" "$MAIN_DIR"
    fi
    exit 1
  fi
fi

TOTAL_START=$(date +%s)

# Helper: fail pipeline, write summary, and exit
fail_pipeline() {
  local phase=$1 msg=$2
  PIPELINE_STATUS="failed"
  track_phase "$phase" "failed" "0" "null"
  TOTAL_END=$(date +%s)
  TOTAL_DURATION=$(( TOTAL_END - TOTAL_START ))
  write_summary
  log "${RED}${msg}${NC}"
  dashboard_event "SessionEnd" "autopilot" "failed at ${phase}"
  # Preserve the worktree on failure — work done so far (REQUIREMENTS.md,
  # PLAN.md, etc.) is valuable for retry. User can clean up manually or
  # re-run autopilot from the worktree.
  if [[ "$FULL_MODE" == true && -n "${WORKDIR:-}" ]]; then
    log "${YELLOW}⚠${NC} Worktree preserved at: $WORKDIR"
    log "  To retry: cd \"$MAIN_DIR\" && bash ~/.claude/tools/autopilot.sh --full ${TASK}"
    log "  To clean up:"
    log "    rm -rf \"$WORKDIR\" && cd \"$MAIN_DIR\" && git worktree prune"
    # Only suggest branch deletion if branch still exists
    if git branch --list "feature/${TASK}" 2>/dev/null | grep -q .; then
      log "    git branch -D feature/${TASK}"
    fi
  fi
  exit 1
}

# ── Phase 1: BA ──────────────────────────────────────────

if phase_enabled "ba"; then
  check_pause_file "ba"
  MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT
  run_gated_phase "/ba flow autopilot ${TASK}" "Business Analysis" "$WORKDIR" \
    "${FEATURE_DIR}/REQUIREMENTS.md" "define requirements" "REQUIREMENTS.md" "ba"
  lifecycle_emit_phase_complete "$STREAM_FILE" "$TASK" "ba"
  should_stop_after_phase "ba" && stop_after_phase_exit "ba"
fi

# ── Phase 2: Plan ────────────────────────────────────────
# Use --step plan so /plan creates ONLY PLAN.md and skips Step 12
# (TESTPLAN generation). The dedicated Phase 3 below produces TESTPLAN.md
# via --step testplan as a separately gated artifact. Without --step plan,
# the default-mode flow generated both files in this phase, then Phase 3
# duplicated the testplan work — observed 2026-05-04 on ts-type-contracts.

if phase_enabled "plan"; then
  check_pause_file "plan"
  EXTRA_SYSTEM_PROMPT="YOUR ONLY TASK: Create PLAN.md (architecture plan only). Run /plan flow autopilot ${TASK} --step plan. This means: read REQUIREMENTS.md, design the components and architecture, write docs/INPROGRESS_Feature_${TASK}/PLAN.md, commit it, and STOP. Do NOT write TESTPLAN.md. Do NOT proceed to Step 12 (test plan generation) — that is Phase 3's job. Your deliverable is exactly one file: PLAN.md."
  MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT
  run_gated_phase "/plan flow autopilot ${TASK} --step plan" "Architecture Plan" "$WORKDIR" \
    "${FEATURE_DIR}/PLAN.md" "architect plan" "PLAN.md" "plan"
  export EXTRA_SYSTEM_PROMPT=""
  lifecycle_emit_phase_complete "$STREAM_FILE" "$TASK" "plan"
  should_stop_after_phase "plan" && stop_after_phase_exit "plan"
fi

# ── Phase 3: Test Plan ─────────────────────────────────
# 2026-05-04: testplan now runs BEFORE review (was after). Rationale:
# review must see PLAN.md AND TESTPLAN.md so missing test scenarios get
# fixed in review-fix loop, not slip through to qa. /plan owns testplan
# generation now (Step 12) — autopilot uses --step testplan to gate
# the artifact independently of the architecture-only --step plan run.

if phase_enabled "testplan"; then
  check_pause_file "testplan"
  # Extra system prompt for the test plan phase — picked up by run_phase()
  EXTRA_SYSTEM_PROMPT="YOUR ONLY TASK: Create TESTPLAN.md. Run /plan flow autopilot ${TASK} --step testplan. This means: read REQUIREMENTS.md and PLAN.md, analyze test patterns with test-explorer, write docs/INPROGRESS_Feature_${TASK}/TESTPLAN.md, commit it, and STOP. Do NOT write any implementation code. Do NOT modify PLAN.md. Your deliverable is exactly one file: TESTPLAN.md."
  MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT

  run_gated_phase "/plan flow autopilot ${TASK} --step testplan" "Test Plan" "$WORKDIR" \
    "${FEATURE_DIR}/TESTPLAN.md" "test plan" "TESTPLAN.md" "testplan"

  export EXTRA_SYSTEM_PROMPT=""
  lifecycle_emit_phase_complete "$STREAM_FILE" "$TASK" "testplan"
  should_stop_after_phase "testplan" && stop_after_phase_exit "testplan"
fi

# ── Phase 4: Review ──────────────────────────────────────

if phase_enabled "review"; then
  check_pause_file "review"
  _team_review_timeout_bumped=false
  if [[ "$PIPELINE" == "full" ]]; then
    REVIEW_CMD="/team-review flow autopilot ${TASK}"
    REVIEW_NAME="Team Review"
    REVIEW_ARTIFACT="TEAM_REVIEW.md"
    MAX_TURNS_PHASE=$MAX_TURNS_TEAM
    _saved_phase_timeout="$PHASE_TIMEOUT"
    export PHASE_TIMEOUT="$PHASE_TIMEOUT_TEAM"
    _team_review_timeout_bumped=true
  else
    REVIEW_CMD="/review flow autopilot ${TASK}"
    REVIEW_NAME="Review"
    REVIEW_ARTIFACT="REVIEW.md"
    MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT
  fi

  run_gated_phase "$REVIEW_CMD" "$REVIEW_NAME" "$WORKDIR" \
    "${FEATURE_DIR}/${REVIEW_ARTIFACT}" "team review" "$REVIEW_ARTIFACT" "review"

  if [[ "$_team_review_timeout_bumped" == true ]]; then
    export PHASE_TIMEOUT="$_saved_phase_timeout"
  fi
  lifecycle_emit_phase_complete "$STREAM_FILE" "$TASK" "review"
  should_stop_after_phase "review" && stop_after_phase_exit "review"
fi

# ── Phase 4b: Implement ─────────────────────────────────

if phase_enabled "implement"; then
  check_pause_file "implement"
  # Ensure test database is running before implementation (avoids Docker socket permission issues inside sandbox)
  log "Pre-flight: ensuring test database is running..."
  if command -v docker &>/dev/null; then
    docker compose -f "$MAIN_DIR/docker-compose.yml" up -d db-test 2>/dev/null || \
    docker compose -f "$WORKDIR/docker-compose.yml" up -d db-test 2>/dev/null || \
      log "${YELLOW}⚠${NC} Could not start test DB — tests may fail"
    sleep 3
  fi

  MAX_TURNS_PHASE=$MAX_TURNS_IMPLEMENT
  _saved_phase_timeout="$PHASE_TIMEOUT"
  export PHASE_TIMEOUT="$PHASE_TIMEOUT_IMPLEMENT"
  PHASE_START=$(date +%s)
  # Preventive deliverable contract (contract-only; /implement keeps its
  # existing hard-fail and is NOT auto-retried — a re-run of the priciest
  # phase is too costly to trigger automatically). Steers attempt 1 to write
  # AND commit instead of ending the turn mid-narration (Opus-4.8 failure,
  # canary-models 2026-06-02). Restored after so it does not leak downstream.
  _implement_saved_extra="${EXTRA_SYSTEM_PROMPT:-}"
  EXTRA_SYSTEM_PROMPT="${_implement_saved_extra:+${_implement_saved_extra}

}$(build_deliverable_contract "the implementation and its tests are written AND committed to git for ${TASK}")"
  run_phase "/implement flow autopilot ${TASK}" "Implementation (TDD)" "$WORKDIR" "implement" || {
    export PHASE_TIMEOUT="$_saved_phase_timeout"
    EXTRA_SYSTEM_PROMPT="$_implement_saved_extra"
    fail_pipeline "Implement" "Implementation failed. Stopping."
  }
  export PHASE_TIMEOUT="$_saved_phase_timeout"
  EXTRA_SYSTEM_PROMPT="$_implement_saved_extra"
  commit_phase "implement" "$WORKDIR" "$TASK"
  # Post-/implement guard (canary D failure mode, 2026-05-24): fail loud
  # when the agent left source-file changes uncommitted. Without this,
  # QA-in-worktree passes against transient state that vanishes on the
  # next git checkout, and $14+ of work silently disappears.
  if ! assert_implement_committed_sources "$WORKDIR"; then
    fail_pipeline "Implement" "Implementation source files left uncommitted — see error block above"
  fi
  track_phase "Implement" "completed" "$(( $(date +%s) - PHASE_START ))" "null"
  lifecycle_emit_phase_complete "$STREAM_FILE" "$TASK" "implement"
  should_stop_after_phase "implement" && stop_after_phase_exit "implement"
fi

# ── Phase 5: QA ──────────────────────────────────────────
# 2026-04-29: QA now runs BEFORE static-analysis. Earlier order (static
# before qa) created a quality bypass: qa fix loops modify source code
# (solo /qa fix-and-reverify; /team-qa Fixer subagent), and those changes
# were never re-validated by SonarQube/coverage. Static-analysis now
# always sees the final state that will be committed. Doc was updated in
# 6fe1fd2 but autopilot.sh was forgotten — this commit catches up.

if phase_enabled "qa"; then
  check_pause_file "qa"
  _team_qa_timeout_bumped=false
  if [[ "$PIPELINE" == "full" ]]; then
    QA_CMD="/team-qa flow autopilot ${TASK}"
    QA_NAME="Team QA"
    QA_ARTIFACT="TEAM_QA.md"
    MAX_TURNS_PHASE=$MAX_TURNS_TEAM
    _saved_phase_timeout="$PHASE_TIMEOUT"
    export PHASE_TIMEOUT="$PHASE_TIMEOUT_TEAM"
    _team_qa_timeout_bumped=true
  else
    QA_CMD="/qa flow autopilot ${TASK}"
    QA_NAME="QA"
    QA_ARTIFACT="QA_REPORT.md"
    MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT
  fi

  run_gated_phase "$QA_CMD" "$QA_NAME" "$WORKDIR" \
    "${FEATURE_DIR}/${QA_ARTIFACT}" "team QA" "$QA_ARTIFACT" "qa"

  if [[ "$_team_qa_timeout_bumped" == true ]]; then
    export PHASE_TIMEOUT="$_saved_phase_timeout"
  fi
  lifecycle_emit_phase_complete "$STREAM_FILE" "$TASK" "qa"
  should_stop_after_phase "qa" && stop_after_phase_exit "qa"
fi

# ── Phase 6: Static Analysis ─────────────────────────────

if phase_enabled "static-analysis"; then
  check_pause_file "static-analysis"
  # Preflight: if the project uses SonarQube (sonar-project.properties in main),
  # ensure the server is reachable and the gitignored properties file has been
  # copied to the worktree. Hard-fail if SonarQube is required but unreachable —
  # silent degradation was the original pain point.
  if ! sonar_preflight "$MAIN_DIR" "$WORKDIR"; then
    fail_pipeline "Static Analysis" "SonarQube required (sonar-project.properties present in $MAIN_DIR) but unreachable. Start it with: start-system sonarqube"
  fi

  MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT
  run_gated_phase "/static-analysis flow autopilot ${TASK}" "Static Analysis" "$WORKDIR" \
    "${FEATURE_DIR}/STATIC_ANALYSIS.md" "static analysis" "STATIC_ANALYSIS.md" "static-analysis"
  lifecycle_emit_phase_complete "$STREAM_FILE" "$TASK" "static-analysis"
  should_stop_after_phase "static-analysis" && stop_after_phase_exit "static-analysis"
  # NOTE: the integration suite is NOT run here. Integration is a property of a
  # PHASE's combined tasks, not a single feature task (real integration gates
  # §5) — running the heavy git-fixture / server-bound suites per task is pure
  # cost with no emergent signal. It now runs ONCE per phase, conditionally
  # (path-trigger), at the phase gate in autopilot-chain.sh (evaluate_gate →
  # phase-integration-gate.sh). A feature task never owns the integration run.
fi

# ── Phase 7: Commit ──────────────────────────────────────

if phase_enabled "commit"; then
  check_pause_file "commit"
  MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT
  PHASE_START=$(date +%s)
  run_phase "/commit flow autopilot ${TASK}" "Commit & Merge" "$WORKDIR" "commit" || {
    fail_pipeline "Commit" "Commit phase had issues — check manually."
  }
  track_phase "Commit" "completed" "$(( $(date +%s) - PHASE_START ))" "null"
  lifecycle_emit_phase_complete "$STREAM_FILE" "$TASK" "commit"
  should_stop_after_phase "commit" && stop_after_phase_exit "commit"
fi

# ── Phase 8: Finalize (--full mode) / Done ────────────────
# In full mode, commit-finalize.sh handles doc rename, plan update,
# merge, push, and cleanup deterministically. /done is not needed
# because finalize covers the same operations as a bash script.
# In default mode (no merge), run /done for plan status updates.

if [[ "$FULL_MODE" == true ]]; then
  phase_header "Merge & Cleanup"

  cd "$MAIN_DIR"
  git checkout main 2>/dev/null || true
  git pull origin main --ff-only 2>/dev/null || true

  # Check if /commit flow already completed everything
  BRANCH_EXISTS=$(git branch --list "feature/${TASK}" 2>/dev/null)

  if [[ -n "$BRANCH_EXISTS" ]]; then
    # Check if the branch is already fully merged into main
    UNMERGED=$(git log --oneline "main..feature/${TASK}" 2>/dev/null | wc -l | tr -d ' ')
    # Capture finalize output once; parse with the pytest-covered module
    # in claude/tools/lib/finalize_result.py. Temp file lets us run both
    # --ok and --merge-failed against the same stream without re-invoking
    # commit-finalize.sh.
    FINALIZE_LOG="$(mktemp -t autopilot-finalize.XXXXXX)"
    # Compose cleanup to handle both FINALIZE_LOG and merge lock
    finalize_cleanup() {
      rm -f "$FINALIZE_LOG"
      [[ -n "${CHAIN_MERGE_LOCK:-}" ]] && rm -f "$CHAIN_MERGE_LOCK"
    }
    trap finalize_cleanup EXIT

    # Acquire merge lock if running under autopilot-chain.
    # Lock-timeout (exit 2) is a "blocked" condition (operator-resolvable)
    # per the chain exit-code contract — another finalize is taking longer
    # than MERGE_LOCK_MAX_WAIT. Skip merge gracefully so the chain routes
    # the task to blocked_tasks; auto-resumes on next chain run when the
    # other finalize lets go of the lock.
    LOCK_TIMEOUT=false
    if [[ -n "${CHAIN_MERGE_LOCK:-}" ]]; then
      LOCK_RC=0
      acquire_merge_lock "$CHAIN_MERGE_LOCK" || LOCK_RC=$?
      if [[ "$LOCK_RC" -eq 2 ]]; then
        log "${YELLOW}⏸${NC}  Merge lock timeout — another finalize is holding the lock"
        log "  Skipping finalize for this run; chain will retry on next iteration"
        LOCK_TIMEOUT=true
        _write_chain_blocked_reason "lock_timeout"
      elif [[ "$LOCK_RC" -ne 0 ]]; then
        log "${RED}✗${NC} Merge lock acquire failed (exit $LOCK_RC)"
        PIPELINE_STATUS="failed"
      fi
    fi

    if [[ "$LOCK_TIMEOUT" == "true" ]]; then
      # Skip merge entirely — chain will route to blocked_tasks via
      # exit code 2. All phase work is on the feature branch; only
      # the merge step is deferred until the lock holder releases.
      PIPELINE_STATUS="blocked"
    elif [[ "$UNMERGED" -eq 0 ]]; then
      log "${GREEN}✓${NC} Branch already merged — cleaning up only"
      # Run finalize with --skip-merge (already merged)
      bash ~/.claude/tools/commit-finalize.sh \
        --task "$TASK" --worktree "$WORKDIR" --main "$MAIN_DIR" \
        --branch "feature/${TASK}" --stream "$STREAM_FILE" --skip-merge 2>&1 \
        | tee "$FINALIZE_LOG" | tee /dev/stderr >/dev/null
    else
      # Branch has unmerged commits — run full finalize
      log "Running commit-finalize.sh (full)..."

      # Commit any remaining docs on the feature branch first
      if [[ -d "$WORKDIR" ]]; then
        cd "$WORKDIR"
        git add "docs/INPROGRESS_Feature_${TASK}/" "docs/DONE_Feature_${TASK}/" 2>/dev/null || true
        git commit -m "docs(${TASK}): pipeline artifacts" --no-verify 2>/dev/null || true
        cd "$MAIN_DIR"
      fi

      bash ~/.claude/tools/commit-finalize.sh \
        --task "$TASK" --worktree "$WORKDIR" --main "$MAIN_DIR" \
        --branch "feature/${TASK}" --stream "$STREAM_FILE" 2>&1 \
        | tee "$FINALIZE_LOG" | tee /dev/stderr >/dev/null
    fi

    # On lock-timeout, finalize was skipped entirely — no log to parse,
    # PIPELINE_STATUS already set to "blocked". Skip the parsing block
    # to avoid spurious "merge ended without a merge step" warnings on
    # an empty FINALIZE_LOG.
    if [[ "$LOCK_TIMEOUT" != "true" ]]; then

    # Extract the trailing JSON line (last line starting with `{` after lstrip)
    FINALIZE_JSON=$(awk '/^[[:space:]]*\{/ {last=$0} END {print last}' "$FINALIZE_LOG")

    # Log the JSON result to the NDJSON stream
    if [[ -n "${STREAM_FILE:-}" && -f "${STREAM_FILE:-}" && -n "$FINALIZE_JSON" ]]; then
      printf '{"type":"finalize","result":%s,"ts":"%s"}\n' \
        "$FINALIZE_JSON" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$STREAM_FILE"
    fi

    # Check if finalize succeeded — delegate to pytest-covered module
    # Distinguish three finalize outcomes (RETRO Deviation 11 fix):
    #   1. Merge succeeded AND all post-merge steps succeeded → success.
    #   2. Merge succeeded BUT some later step failed (stash_pop conflict
    #      caught by the ea373ca defensive guard, push retry exhausted,
    #      etc.) → success-with-warnings. The feature is on main; cleanup
    #      hit a recoverable hiccup. We log the warning but keep
    #      PIPELINE_STATUS=success so the chain orchestrator does not
    #      respawn (and so the operator-facing banner reflects truth).
    #   3. Merge failed → real failure. Worktree preserved for manual
    #      resolution; PIPELINE_STATUS=failed.
    MERGE_SUCCEEDED=$(python3 "${AUTOPILOT_DIR}/lib/finalize_result.py" --merge-succeeded < "$FINALIZE_LOG" 2>/dev/null || echo "False")
    MERGE_FAILED=$(python3 "${AUTOPILOT_DIR}/lib/finalize_result.py" --merge-failed < "$FINALIZE_LOG" 2>/dev/null || echo "False")
    POST_MERGE_WARN=$(python3 "${AUTOPILOT_DIR}/lib/finalize_result.py" --post-merge-warnings < "$FINALIZE_LOG" 2>/dev/null || echo "False")

    if [[ "$MERGE_FAILED" == "True" ]]; then
      log "${RED}✗${NC} Merge failed — worktree and branch preserved for manual resolution"
      log "  Resolve conflicts, then run: bash ~/.claude/tools/commit-finalize.sh --task $TASK --worktree $WORKDIR --main $MAIN_DIR --branch feature/${TASK}"
      # Distinguish "blocked by merge conflict" from "real implementation
      # failure". Operator-resolvable: all phase work is done, the only
      # thing missing is a clean merge to main. Chain.sh will treat exit 2
      # as a "blocked" state and surface a recovery banner instead of
      # quietly skipping the task on next restart.
      PIPELINE_STATUS="blocked"
    elif [[ "$MERGE_SUCCEEDED" != "True" ]]; then
      # Merge step never reached — finalize aborted before getting there
      # (skip-merge mode uses a different code path). Treat as failed.
      log "${YELLOW}⚠${NC} Finalize ended without a merge step — treating as failure"
      PIPELINE_STATUS="failed"
    elif [[ "$POST_MERGE_WARN" == "True" ]]; then
      # Merge landed; cleanup hit a recoverable issue.
      log "${YELLOW}⚠${NC} Finalize completed with post-merge warnings — feature is on main, cleanup needs manual review"
      log "  Inspect: $FINALIZE_LOG (will be removed below)"
    fi

    fi  # end of `if [[ "$LOCK_TIMEOUT" != "true" ]]` post-finalize parsing

    # Release merge lock after finalize. Safe even on LOCK_TIMEOUT — we
    # never acquired in that case, so release_merge_lock is a no-op
    # (rm -f on a path the holder still owns is safe; rm -f on a missing
    # path is a no-op).
    if [[ -n "${CHAIN_MERGE_LOCK:-}" && "$LOCK_TIMEOUT" != "true" ]]; then
      release_merge_lock "$CHAIN_MERGE_LOCK"
    fi

    rm -f "$FINALIZE_LOG"
    trap - EXIT
  else
    log "${GREEN}✓${NC} Branch already merged and cleaned up by /commit flow"
    if [[ -d "$WORKDIR" ]]; then
      rm -rf "$WORKDIR" 2>/dev/null || true
      git worktree prune 2>/dev/null || true
      log "${GREEN}✓${NC} Lingering worktree directory removed"
    fi
  fi

  # Post-merge smoke test
  postmerge_check "$MAIN_DIR" || {
    log "${RED}✗${NC} Post-merge smoke test failed — merge is done but the build is broken"
    log "Fix manually on main before starting the next task"
    PIPELINE_STATUS="failed"
  }

  # Contract checks
  contract_check "$MAIN_DIR" || {
    log "${RED}✗${NC} Contract checks failed after merge"
    PIPELINE_STATUS="failed"
  }

  track_phase "Finalize" "completed" "0" "null"

  # Write summary BEFORE worktree is gone — target the main repo's docs
  TOTAL_END=$(date +%s)
  TOTAL_DURATION=$(( TOTAL_END - TOTAL_START ))
  SUMMARY_FILE="${MAIN_DIR}/docs/DONE_Feature_${TASK}/autopilot-summary.json"
  write_summary
else
  # Default mode (no merge) — run /done for plan status updates
  check_pause_file "done"
  export MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT
  PHASE_START=$(date +%s)
  run_phase "/done flow autopilot ${TASK}" "Done" "$WORKDIR" || {
    log "${YELLOW}⚠${NC} Done phase had issues — non-blocking"
  }
  track_phase "Done" "completed" "$(( $(date +%s) - PHASE_START ))" "null"
fi

# ── Done ─────────────────────────────────────────────────

# Compute duration (full mode already wrote summary above)
if [[ -z "${TOTAL_END:-}" ]]; then
  TOTAL_END=$(date +%s)
  TOTAL_DURATION=$(( TOTAL_END - TOTAL_START ))
fi
TOTAL_MINUTES=$(( TOTAL_DURATION / 60 ))
TOTAL_SECONDS=$(( TOTAL_DURATION % 60 ))

# Write summary for non-full mode (full mode wrote it before cleanup)
if [[ "$FULL_MODE" != true ]]; then
  write_summary
fi

echo ""
if [[ "$PIPELINE_STATUS" == "success" ]]; then
  echo -e "${BOLD}${GREEN}"
  echo "  ╔═══════════════════════════════════════════════════╗"
  echo "  ║  AUTOPILOT COMPLETE                               ║"
  echo "  ║  Task: ${TASK}"
  echo "  ║  Duration: ${TOTAL_MINUTES}m ${TOTAL_SECONDS}s"
  echo "  ╚═══════════════════════════════════════════════════╝"
  echo -e "${NC}"
  dashboard_event "SessionEnd" "autopilot" "completed in ${TOTAL_MINUTES}m ${TOTAL_SECONDS}s"
  log "Autopilot completed successfully for $TASK"
elif [[ "$PIPELINE_STATUS" == "blocked" ]]; then
  echo -e "${BOLD}${YELLOW}"
  echo "  ╔═══════════════════════════════════════════════════╗"
  echo "  ║  AUTOPILOT BLOCKED — merge conflict, work intact  ║"
  echo "  ║  Task: ${TASK}"
  echo "  ║  Duration: ${TOTAL_MINUTES}m ${TOTAL_SECONDS}s"
  echo "  ╠═══════════════════════════════════════════════════╣"
  echo "  ║  Worktree + branch preserved for manual resolve.  ║"
  echo "  ║  All phase work landed on the feature branch —   ║"
  echo "  ║  only the merge to main needs human intervention. ║"
  echo "  ║                                                   ║"
  echo "  ║  Resolve, then re-run:                            ║"
  echo "  ║    bash ~/.claude/tools/commit-finalize.sh \\     ║"
  echo "  ║      --task ${TASK} \\"
  echo "  ║      --worktree ${WORKDIR} \\"
  echo "  ║      --main ${MAIN_DIR} \\"
  echo "  ║      --branch feature/${TASK}"
  echo "  ║                                                   ║"
  echo "  ║  Chain auto-resumes on next run — no flag needed. ║"
  echo "  ╚═══════════════════════════════════════════════════╝"
  echo -e "${NC}"
  dashboard_event "SessionEnd" "autopilot" "blocked after ${TOTAL_MINUTES}m ${TOTAL_SECONDS}s — merge conflict"
  log "Autopilot BLOCKED for $TASK — merge conflict, manual resolution required"
else
  echo -e "${BOLD}${RED}"
  echo "  ╔═══════════════════════════════════════════════════╗"
  echo "  ║  AUTOPILOT FAILED                                 ║"
  echo "  ║  Task: ${TASK}"
  echo "  ║  Duration: ${TOTAL_MINUTES}m ${TOTAL_SECONDS}s"
  echo "  ╚═══════════════════════════════════════════════════╝"
  echo -e "${NC}"
  dashboard_event "SessionEnd" "autopilot" "failed after ${TOTAL_MINUTES}m ${TOTAL_SECONDS}s"
  log "Autopilot FAILED for $TASK — check output above"
fi
log "Total duration: ${TOTAL_MINUTES}m ${TOTAL_SECONDS}s"
log "Stream: $STREAM_FILE"

# Explicit exit-code contract for chain.sh consumption:
#   0 = success
#   2 = blocked (merge conflict, operator-resolvable, work preserved)
#   1 = real failure (every other path) — implicit via script-end-on-error
#       or earlier `exit 1` in the script.
if [[ "$PIPELINE_STATUS" == "blocked" ]]; then
  exit 2
fi
if [[ "$PIPELINE_STATUS" == "failed" ]]; then
  exit 1
fi
exit 0
