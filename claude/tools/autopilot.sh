#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Autopilot v2 — fully autonomous SDLC pipeline
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#  Usage:
#    bash ~/.claude/tools/autopilot.sh <task-id>               # from worktree
#    bash ~/.claude/tools/autopilot.sh --full <task-id>        # from main project
#
#  --full mode: creates worktree, runs pipeline, commits, merges, cleans up
#  Default mode: runs pipeline in current worktree, stops after QA
#
#  Pipeline (full):  /ba → /plan → /team-review → /implement → /static-analysis → /team-qa → /commit
#  Pipeline (light): /ba → /plan → /review → /implement → /static-analysis → /qa → /commit
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
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

# ── Parse arguments ──────────────────────────────────────
FULL_MODE=false
PIPELINE="auto"
while [[ "${1:-}" == --* ]]; do
  case "$1" in
    --full) FULL_MODE=true; shift ;;
    --pipeline) PIPELINE="${2:?--pipeline requires 'full' or 'light'}"; shift 2 ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

TASK="${1:?Usage: autopilot.sh [--full] [--pipeline full|light] <task-id>}"
FEATURE_DIR="docs/INPROGRESS_Feature_${TASK}"
LOG_FILE=""  # set after WORKDIR is resolved
PROJECTS_ROOT="${PROJECTS_ROOT:-$HOME/Projekter}"
DASHBOARD_DATA="${CLAUDE_DASHBOARD_DATA:-$PROJECTS_ROOT/claude-agent-dashboard/data/sessions.jsonl}"
AUTOPILOT_SID="autopilot-${TASK}-$(date +%s)"
ALLOWED_TOOLS="Read,Edit,Write,Bash,Grep,Glob,Agent,SendMessage,Skill"

PHASE_TIMEOUT=1800      # 30 min max per phase (safety valve)
EXTRA_SYSTEM_PROMPT=""  # per-phase system prompt addition (set before run_gated_phase)
MAX_TURNS_DEFAULT=75    # BA, Plan, Static Analysis, Commit (observed max: 62)
MAX_TURNS_TEAM=200      # Team Review, Team QA (observed max: 120, agents + discussion)
MAX_TURNS_IMPLEMENT=200 # TDD cycles (observed max: 80, headroom for large features)
MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT  # per-phase override (set before run_gated_phase)

# ── Helpers ──────────────────────────────────────────────

log() {
  local msg="[$(date '+%H:%M:%S')] $1"
  echo -e "$msg"
  # Emit to NDJSON stream (if initialized) so the dashboard can display it
  if [[ -n "${STREAM_FILE:-}" && -f "${STREAM_FILE:-}" ]]; then
    local clean_msg
    clean_msg=$(echo -e "$1" | sed $'s/\x1b\\[[0-9;]*m//g')
    printf '{"type":"orchestrator","msg":"%s","ts":"%s"}\n' \
      "$(echo "$clean_msg" | sed 's/"/\\"/g')" \
      "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$STREAM_FILE"
  fi
}

phase_header() {
  echo ""
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}${CYAN}  Phase: $1${NC}"
  echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
}

dashboard_event() {
  local event=$1 phase=$2 msg=${3:-""}
  local ts branch cwd json
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  branch=$(git branch --show-current 2>/dev/null || echo "unknown")
  cwd=$(pwd)
  json=$(printf '{"sid":"%s","cwd":"%s","branch":"%s","event":"%s","type":"autopilot","msg":"%s","ts":"%s","atype":"%s"}' \
    "$AUTOPILOT_SID" "$cwd" "$branch" "$event" "${phase}: ${msg}" "$ts" "autopilot")
  echo "$json" >> "$DASHBOARD_DATA" 2>/dev/null || true
}

check_artifact() {
  local file=$1 phase=$2
  if [[ -f "$file" ]]; then
    log "${GREEN}✓${NC} $phase artifact found: $file"
    return 0
  else
    log "${RED}✗${NC} $phase artifact missing: $file"
    return 1
  fi
}

# Run a phase with artifact gate and one auto-retry
# Usage: run_gated_phase <command> <phase_name> <workdir> <artifact_file> <commit_msg> <track_artifact>
run_gated_phase() {
  local command=$1 phase_name=$2 workdir=$3 artifact=$4 commit_msg=$5 track_artifact=$6
  local attempt=1
  local max_attempts=2

  while [[ $attempt -le $max_attempts ]]; do
    PHASE_START=$(date +%s)

    local phase_exit=0
    run_phase "$command" "$phase_name" "$workdir" || phase_exit=$?

    if [[ $phase_exit -ne 0 ]]; then
      if [[ $attempt -lt $max_attempts ]]; then
        log "${YELLOW}⚠${NC} $phase_name failed (attempt $attempt/$max_attempts) — retrying..."
        attempt=$((attempt + 1))
        continue
      fi
      fail_pipeline "$phase_name" "$phase_name failed after $max_attempts attempts. Stopping."
      return 1  # unreachable (fail_pipeline exits) but makes intent clear
    fi

    if check_artifact "$artifact" "$phase_name"; then
      commit_phase "$commit_msg" "$workdir" "$TASK"
      track_phase "$phase_name" "completed" "$(( $(date +%s) - PHASE_START ))" "$track_artifact"
      return 0
    fi

    if [[ $attempt -lt $max_attempts ]]; then
      log "${YELLOW}⚠${NC} $phase_name completed but artifact missing — retrying (attempt $((attempt+1))/$max_attempts)..."
      attempt=$((attempt + 1))
    else
      fail_pipeline "$phase_name" "$phase_name artifact missing after $max_attempts attempts. Stopping."
      return 1  # unreachable
    fi
  done
}

# ── Stream processor ─────────────────────────────────────
# Reads NDJSON from claude -p --output-format stream-json
# Extracts human-readable content to stdout (which tee sends to log)

process_stream() {
  # Use python3 -u for unbuffered output (prevents tee/pipe stalls)
  python3 -u -c '
import sys, json, re

_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\r")

def strip_ansi(s):
    return _ANSI_RE.sub("", s)

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        event = json.loads(line)
    except json.JSONDecodeError:
        continue

    etype = event.get("type", "")

    # Assistant text output
    if etype == "assistant":
        msg = event.get("message", {})
        for block in msg.get("content", []):
            if block.get("type") == "text":
                text = strip_ansi(block.get("text", ""))
                if text.strip():
                    print(text, flush=True)
            elif block.get("type") == "tool_use":
                name = block.get("name", "")
                inp = block.get("input", {})
                desc = inp.get("description", inp.get("command", inp.get("pattern", inp.get("prompt", ""))))
                if isinstance(desc, str) and len(desc) > 150:
                    desc = desc[:150] + "..."
                print(f"  ⏺ {name}({desc})", flush=True)

    # Tool results
    elif etype == "user":
        msg = event.get("message", {})
        for block in msg.get("content", []):
            if block.get("type") == "tool_result":
                content = strip_ansi(block.get("content", "") if isinstance(block.get("content"), str) else "")
                if content.strip():
                    # Show first few lines of tool output
                    lines = content.strip().split("\n")
                    for l in lines[:5]:
                        print(f"  ⎿ {l[:150]}", flush=True)
                    if len(lines) > 5:
                        print(f"  ⎿ ... ({len(lines) - 5} more lines)", flush=True)

    # Final result
    elif etype == "result":
        status = event.get("subtype", "")
        cost = event.get("total_cost_usd", 0)
        duration = event.get("duration_ms", 0) / 1000
        turns = event.get("num_turns", 0)
        print(f"\n  ═══ Result: {status} | {turns} turns | {duration:.0f}s | ${cost:.2f}", flush=True)
        if event.get("is_error"):
            result_text = event.get("result", "")
            if result_text:
                print(f"  ERROR: {result_text[:300]}", flush=True)
' 2>/dev/null || true
}

# Run a single phase via claude -p (headless mode)
run_phase() {
  local command=$1
  local phase_name=$2
  local workdir=$3
  local start_time=$(date +%s)

  phase_header "$phase_name"
  dashboard_event "PhaseStart" "$phase_name" "running"

  log "Running: $command"

  # Inject phase start marker into NDJSON stream
  printf '{"type":"phase","phase":"%s","status":"running","ts":"%s"}\n' \
    "$phase_name" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$STREAM_FILE"

  # Headless system prompt: reinforce single-phase completion at checkpoints
  local headless_prompt="HEADLESS MODE: You are running ONE PHASE of an autonomous pipeline. At any checkpoint that says 'Continue?' with options like [yes/plan/amend/stop], automatically select the first option (yes/plan) and execute the On [yes] block. Do not wait for user input. Complete all steps of THIS PHASE in a single run.

CRITICAL: When the checkpoint says 'STOP — open a new chat and run: /foo flow', you MUST STOP. Do NOT run the next command yourself. The autopilot orchestrator controls phase sequencing — each phase runs in a separate session. Your job is to complete the current phase, produce its artifact, and stop.

SEARCH EXCLUSIONS: NEVER read or search *.ndjson files or autopilot-summary.json. These are pipeline logs that contain embedded code from previous runs — they pollute search results. Always use glob exclusions: --glob '!*.ndjson' for Grep, or skip docs/DONE_Feature_* and docs/INPROGRESS_Feature_*/*.ndjson paths.

AGENT TEAMS: When spawning reviewer agents for team phases (team-review, team-qa):
1. ALWAYS set run_in_background: true and give each agent a unique name (e.g. 'ba-reviewer', 'architect-reviewer'). This keeps them alive for cross-reviewer discussion and suggestion voting via SendMessage.
2. ALWAYS set model: 'opus' to give agents the full 1M token context window. Sonnet only gets 200k even with [1m] suffix.
3. Do NOT spawn reviewers in foreground mode — they will shut down before the discussion phase."

  # Run claude in headless mode with stream-json output
  # Raw NDJSON → stream file (for dashboard), processed text → terminal
  local exit_code=0
  local session_id=""
  cd "$workdir"

  # Stream NDJSON to file + terminal processor
  # Use timeout if available (GNU coreutils), otherwise run without timeout
  local timeout_cmd=""
  if command -v timeout &>/dev/null; then
    timeout_cmd="timeout $PHASE_TIMEOUT"
  elif command -v gtimeout &>/dev/null; then
    timeout_cmd="gtimeout $PHASE_TIMEOUT"
  fi

  # Temp file to capture this phase's session_id (avoids reading shared stream file)
  local sid_file
  sid_file=$(mktemp "${TMPDIR:-/tmp}/autopilot-sid.XXXXXX")

  # Phase-local NDJSON capture (avoids python pipe that can silently drop output)
  local phase_ndjson
  phase_ndjson=$(mktemp "${TMPDIR:-/tmp}/autopilot-phase.XXXXXX")

  # Strip sandbox proxy vars from claude subprocess — they break httpx, tiktoken, pip
  # inside the agent's Bash tool calls (the pre-flight unset only affects this shell)
  $timeout_cmd env -u ALL_PROXY -u HTTPS_PROXY -u HTTP_PROXY \
    -u all_proxy -u https_proxy -u http_proxy \
    claude -p "$command" \
    --output-format stream-json \
    --verbose \
    --max-turns "$MAX_TURNS_PHASE" \
    --allowedTools "$ALLOWED_TOOLS" \
    --append-system-prompt "${headless_prompt}${EXTRA_SYSTEM_PROMPT:+

${EXTRA_SYSTEM_PROMPT}}" \
    < /dev/null 2>/dev/null \
    | tee -a "$STREAM_FILE" \
    | tee "$phase_ndjson" \
    | process_stream \
    || exit_code=$?

  # Extract session_id from this phase's output only (not the shared stream)
  session_id=$(python3 -c "
import json
with open('$phase_ndjson') as f:
    for line in f:
        try:
            e = json.loads(line.strip())
            sid = e.get('session_id')
            if sid:
                print(sid)
                break
        except: pass
" 2>/dev/null || echo "")
  rm -f "$phase_ndjson"

  # Resume loop: if phase stopped at a checkpoint, continue
  # Only triggers when the LAST LINE of result text is a checkpoint prompt.
  # Team phases embed "Continue?" mid-text as instructions — that's not a real checkpoint.
  local resume_count=0
  local max_resumes=3
  while [[ $exit_code -eq 0 && -n "$session_id" && $resume_count -lt $max_resumes ]]; do
    # Extract the last result's text from the phase-local NDJSON (not shared stream)
    local last_result
    last_result=$(tail -5 "$STREAM_FILE" | python3 -c "
import sys, json
for line in sys.stdin:
    try:
        e = json.loads(line.strip())
        if e.get('type') == 'result':
            print(e.get('result', ''))
    except: pass
" 2>/dev/null || echo "")

    # Only resume if:
    # 1. Result ends with a checkpoint prompt (Continue? [...])
    # 2. The checkpoint does NOT contain "STOP" — flow checkpoints with STOP
    #    mean the agent completed correctly and the orchestrator handles sequencing.
    #    Resuming after STOP creates a wasted session that re-does finished work.
    local tail_of_result
    tail_of_result=$(echo "$last_result" | tail -3)
    if echo "$tail_of_result" | grep -q "Continue?.*\[" && \
       ! echo "$last_result" | grep -q "STOP"; then
      resume_count=$((resume_count + 1))
      log "Checkpoint detected — resuming (attempt $resume_count/$max_resumes)"

      # Extract the approval keyword from checkpoint text
      local keyword
      keyword=$(echo "$last_result" | grep -o '\[.*/ amend / stop\]' | head -1 | sed 's/\[\([a-z]*\).*/\1/')
      keyword=${keyword:-yes}

      claude -p "$keyword" \
        --resume "$session_id" \
        --output-format stream-json \
        --verbose \
        --max-turns "$MAX_TURNS_PHASE" \
        --allowedTools "$ALLOWED_TOOLS" \
        < /dev/null 2>/dev/null \
        | tee -a "$STREAM_FILE" \
        | process_stream \
        || exit_code=$?
    else
      break
    fi
  done

  # Inject phase end marker into NDJSON stream
  printf '{"type":"phase","phase":"%s","status":"%s","duration_s":%d,"ts":"%s"}\n' \
    "$phase_name" "$([ $exit_code -eq 0 ] && echo completed || echo failed)" \
    "$(($(date +%s) - start_time))" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$STREAM_FILE"

  local end_time=$(date +%s)
  local duration=$(( end_time - start_time ))

  if [[ $exit_code -eq 124 ]]; then
    log "${RED}✗${NC} Phase timed out after ${PHASE_TIMEOUT}s"
    dashboard_event "PhaseStop" "$phase_name" "timed out after ${PHASE_TIMEOUT}s"
    return 1
  elif [[ $exit_code -ne 0 ]]; then
    log "${RED}✗${NC} Phase failed (exit code: $exit_code)"
    dashboard_event "PhaseStop" "$phase_name" "failed in ${duration}s"
    return 1
  fi

  log "Phase completed in ${duration}s"
  dashboard_event "PhaseStop" "$phase_name" "completed in ${duration}s"
  return 0
}

# Commit phase artifacts (since -p mode can't auto-approve checkpoints)
commit_phase() {
  local phase_name=$1
  local workdir=$2
  local feature=$3
  cd "$workdir"
  local feature_dir="docs/INPROGRESS_Feature_${feature}"
  if git status --porcelain -- "$feature_dir/" 2>/dev/null | grep -q .; then
    git add "$feature_dir/" 2>/dev/null || true
    git commit -m "docs(${feature}): ${phase_name}" --no-verify 2>/dev/null || true
    log "${GREEN}✓${NC} Phase artifacts committed"
  fi
}

# ── Worktree cleanup ─────────────────────────────────────

cleanup_worktree() {
  local worktree_dir="$1" branch="$2" main_dir="$3"
  if [[ -z "$worktree_dir" || -z "$branch" || -z "$main_dir" ]]; then
    return 0
  fi
  cd "$main_dir"
  git worktree remove --force "$worktree_dir" 2>/dev/null || true
  rm -rf "$worktree_dir" 2>/dev/null || true
  git worktree prune 2>/dev/null || true
  git branch -D "$branch" 2>/dev/null || true
}

# ── Project manifest parser ──────────────────────────────
# Reads pipeline.toolchain, pipeline.smoke_test, and pipeline.contracts
# from the project's CLAUDE.md

parse_manifest() {
  local claude_md="$1"
  if [[ ! -f "$claude_md" ]]; then
    return 0
  fi
  python3 -c "
import re, sys

with open('$claude_md') as f:
    content = f.read()

# Extract pipeline: block (YAML-like in markdown)
m = re.search(r'^pipeline:\s*\n((?:[ \t]+.*\n)*)', content, re.MULTILINE)
if not m:
    sys.exit(0)

block = m.group(1)
section = None
for line in block.split('\n'):
    stripped = line.strip()
    if not stripped or stripped.startswith('#'):
        continue
    # Detect section headers
    if stripped.startswith('toolchain:'):
        section = 'toolchain'
        continue
    if stripped.startswith('smoke_test:'):
        section = 'smoke_test'
        continue
    if stripped.startswith('contracts:'):
        section = 'contracts'
        continue
    # Parse items
    if section == 'toolchain':
        if ':' in stripped:
            key, val = stripped.split(':', 1)
            key = key.strip()
            items = [x.strip().strip('[]') for x in val.split(',')]
            items = [x for x in items if x]
            for item in items:
                print(f'TOOLCHAIN|{key}|{item}')
    elif section == 'smoke_test':
        if stripped.startswith('- '):
            cmd = stripped[2:].strip()
            print(f'SMOKE|{cmd}')
    elif section == 'contracts':
        if 'test:' in stripped:
            val = stripped.split('test:', 1)[1].strip()
            print(f'CONTRACT_TEST|{val}')
        elif 'grep:' in stripped:
            val = stripped.split('grep:', 1)[1].strip().strip('\"')
            print(f'CONTRACT_GREP|{val}')
        elif 'source:' in stripped:
            val = stripped.split('source:', 1)[1].strip()
            print(f'CONTRACT_SOURCE|{val}')
        elif 'max_value:' in stripped:
            val = stripped.split('max_value:', 1)[1].strip()
            print(f'CONTRACT_MAX|{val}')
" 2>/dev/null || true
}

preflight_check() {
  local project_dir="$1"
  local claude_md="${project_dir}/CLAUDE.md"
  local failed=false

  log "${CYAN}Running pre-flight checks...${NC}"

  # Strip sandbox proxy env vars (break httpx, tiktoken, pip)
  unset ALL_PROXY HTTPS_PROXY HTTP_PROXY all_proxy https_proxy http_proxy 2>/dev/null || true
  log "${GREEN}✓${NC} Sandbox proxy vars stripped"

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
  manifest=$(parse_manifest "$claude_md")
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
            for frontend_dir in "$project_dir/ui" "$project_dir/ui_react/frontend" "$project_dir/app" "$project_dir/frontend"; do
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

  log "${GREEN}✓${NC} Pre-flight checks passed"
}

postmerge_check() {
  local project_dir="$1"
  local claude_md="${project_dir}/CLAUDE.md"

  if [[ ! -f "$claude_md" ]]; then
    return 0
  fi

  local manifest
  manifest=$(parse_manifest "$claude_md")
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

  while IFS='|' read -r type value; do
    if [[ "$type" == "SMOKE" ]]; then
      log "  Running: $value"
      if ! eval "$value" 2>&1; then
        log "${RED}✗${NC} Smoke test failed: $value"
        return 1
      fi
      log "${GREEN}✓${NC} $value"
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
  manifest=$(parse_manifest "$claude_md")
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
        if ! python3 -m pytest "$value" -q 2>&1; then
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
          violations=$(find . -path "./$grep_source" -name "*.tsx" -o -path "./$grep_source" -name "*.ts" 2>/dev/null | \
            xargs grep -n "$grep_pattern" 2>/dev/null | \
            grep -oP '\d+' | \
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

  # Create worktree
  echo -e "${CYAN}Creating worktree for ${TASK}...${NC}"
  bash scripts/worktree.sh new "$TASK"

  # Determine worktree path from git (avoids case-sensitivity issues on macOS)
  MAIN_DIR=$(pwd)
  WORKDIR=$(git worktree list | grep "feature/${TASK}" | awk '{print $1}')

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
  log "Worktree created at: $WORKDIR"
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

# ── Initialize ───────────────────────────────────────────

mkdir -p .planning
mkdir -p "$FEATURE_DIR"
STREAM_FILE="${WORKDIR}/${FEATURE_DIR}/autopilot-stream.ndjson"
echo "" > "$STREAM_FILE"
BRANCH=$(git branch --show-current)

echo -e "${BOLD}${CYAN}"
echo "  ╔═══════════════════════════════════════════════════╗"
echo "  ║  AUTOPILOT: ${TASK}"
echo "  ║  Branch: ${BRANCH}"
echo "  ║  Mode: $([ "$FULL_MODE" = true ] && echo 'Full (worktree → merge)' || echo 'Pipeline only')"
echo "  ║  Pipeline: ${PIPELINE} $([ "$PIPELINE" = 'full' ] && echo '(BA→Plan→Team Review→Implement→Static Analysis→Team QA)' || echo '(BA→Plan→Review→Implement→Static Analysis→QA)')"
echo "  ╚═══════════════════════════════════════════════════╝"
echo -e "${NC}"
# Auto-detect pipeline from execution plan YAML if not specified
if [[ "$PIPELINE" == "auto" ]]; then
  YAML_FILE=$(find "$MAIN_DIR/docs" -name "execution-plan.yaml" -path "*/INPROGRESS_Plan_*" 2>/dev/null | head -1)
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

# Phase tracking for summary
declare -a PHASE_NAMES=()
declare -a PHASE_STATUSES=()
declare -a PHASE_DURATIONS=()
declare -a PHASE_ARTIFACTS=()
SUMMARY_FILE="${WORKDIR}/${FEATURE_DIR}/autopilot-summary.json"
START_TS=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
PIPELINE_STATUS="success"

declare -a PHASE_COSTS=()

track_phase() {
  PHASE_NAMES+=("$1")
  PHASE_STATUSES+=("$2")
  PHASE_DURATIONS+=("$3")
  PHASE_ARTIFACTS+=("${4:-null}")
  # Extract cost from last result event in the NDJSON stream
  local cost
  cost=$(grep '"type":"result"' "$STREAM_FILE" 2>/dev/null | tail -1 | \
    python3 -c "import sys,json; e=json.load(sys.stdin); print(e.get('total_cost_usd',0))" 2>/dev/null || echo "0")
  PHASE_COSTS+=("${cost:-0}")
}

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
dashboard_event "SessionStart" "autopilot" "Starting autonomous pipeline for $TASK"

# ── Project manifest pre-flight ──────────────────────────
preflight_check "$MAIN_DIR"

# ── Execution plan guards ────────────────────────────────
if [[ -n "${YAML_FILE:-}" ]]; then
  # UI task guard
  TASK_UI=$(grep -A 10 "id: ${TASK}$" "$YAML_FILE" 2>/dev/null | grep "ui:" | head -1 | awk '{print $2}' || true)
  if [[ "$TASK_UI" == "true" ]]; then
    log "${RED}ERROR: Task has ui: true in execution plan. Autopilot skips /ux and /manualtest — not suitable for UI tasks.${NC}"
    log "Run this task in flow mode instead: /start ${TASK}"
    if [[ "$FULL_MODE" == true && -n "${WORKDIR:-}" && -n "${MAIN_DIR:-}" ]]; then
      cleanup_worktree "$WORKDIR" "feature/${TASK}" "$MAIN_DIR"
    fi
    exit 1
  fi

  # Dependency check — verify all depends are done/skipped
  TASK_DEPS=$(python3 -c "
import re, sys
path = '$YAML_FILE'
task_id = '$TASK'
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

MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT
run_gated_phase "/ba flow autopilot ${TASK}" "Business Analysis" "$WORKDIR" \
  "${FEATURE_DIR}/REQUIREMENTS.md" "define requirements" "REQUIREMENTS.md"

# ── Phase 2: Plan ────────────────────────────────────────

MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT
run_gated_phase "/plan flow autopilot ${TASK}" "Architecture Plan" "$WORKDIR" \
  "${FEATURE_DIR}/PLAN.md" "architect plan" "PLAN.md"

# ── Phase 3: Review ──────────────────────────────────────

if [[ "$PIPELINE" == "full" ]]; then
  REVIEW_CMD="/team-review flow autopilot ${TASK}"
  REVIEW_NAME="Team Review"
  REVIEW_ARTIFACT="TEAM_REVIEW.md"
  MAX_TURNS_PHASE=$MAX_TURNS_TEAM
else
  REVIEW_CMD="/review flow autopilot ${TASK}"
  REVIEW_NAME="Review"
  REVIEW_ARTIFACT="REVIEW.md"
  MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT
fi

run_gated_phase "$REVIEW_CMD" "$REVIEW_NAME" "$WORKDIR" \
  "${FEATURE_DIR}/${REVIEW_ARTIFACT}" "team review" "$REVIEW_ARTIFACT"

# ── Phase 4a: Test Plan ─────────────────────────────────
# Extra system prompt for the test plan phase — picked up by run_phase()
EXTRA_SYSTEM_PROMPT="YOUR ONLY TASK: Create TESTPLAN.md. Run /implement flow autopilot ${TASK} --step testplan. This means: read REQUIREMENTS.md and PLAN.md, analyze test patterns with test-explorer, write docs/INPROGRESS_Feature_${TASK}/TESTPLAN.md, commit it, and STOP. Do NOT write any implementation code. Do NOT proceed to Step 2 (TDD cycle). Your deliverable is exactly one file: TESTPLAN.md."
MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT

run_gated_phase "/implement flow autopilot ${TASK} --step testplan" "Test Plan" "$WORKDIR" \
  "${FEATURE_DIR}/TESTPLAN.md" "test plan" "TESTPLAN.md"

EXTRA_SYSTEM_PROMPT=""

# ── Phase 4b: Implement ─────────────────────────────────

# Ensure test database is running before implementation (avoids Docker socket permission issues inside sandbox)
log "Pre-flight: ensuring test database is running..."
if command -v docker &>/dev/null; then
  docker compose -f "$MAIN_DIR/docker-compose.yml" up -d db-test 2>/dev/null || \
  docker compose -f "$WORKDIR/docker-compose.yml" up -d db-test 2>/dev/null || \
    log "${YELLOW}⚠${NC} Could not start test DB — tests may fail"
  sleep 3
fi

MAX_TURNS_PHASE=$MAX_TURNS_IMPLEMENT
PHASE_START=$(date +%s)
run_phase "/implement flow autopilot ${TASK}" "Implementation (TDD)" "$WORKDIR" || {
  fail_pipeline "Implement" "Implementation failed. Stopping."
}
commit_phase "implement" "$WORKDIR" "$TASK"
track_phase "Implement" "completed" "$(( $(date +%s) - PHASE_START ))" "null"

# ── Phase 5: Static Analysis ─────────────────────────────

MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT
run_gated_phase "/static-analysis flow autopilot ${TASK}" "Static Analysis" "$WORKDIR" \
  "${FEATURE_DIR}/STATIC_ANALYSIS.md" "static analysis" "STATIC_ANALYSIS.md"

# ── Phase 6: QA ──────────────────────────────────────────

if [[ "$PIPELINE" == "full" ]]; then
  QA_CMD="/team-qa flow autopilot ${TASK}"
  QA_NAME="Team QA"
  QA_ARTIFACT="TEAM_QA.md"
  MAX_TURNS_PHASE=$MAX_TURNS_TEAM
else
  QA_CMD="/qa flow autopilot ${TASK}"
  QA_NAME="QA"
  QA_ARTIFACT="QA_REPORT.md"
  MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT
fi

run_gated_phase "$QA_CMD" "$QA_NAME" "$WORKDIR" \
  "${FEATURE_DIR}/${QA_ARTIFACT}" "team QA" "$QA_ARTIFACT"

# ── Phase 7: Commit ──────────────────────────────────────

MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT
PHASE_START=$(date +%s)
run_phase "/commit flow autopilot ${TASK}" "Commit & Merge" "$WORKDIR" || {
  fail_pipeline "Commit" "Commit phase had issues — check manually."
}
track_phase "Commit" "completed" "$(( $(date +%s) - PHASE_START ))" "null"

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
    if [[ "$UNMERGED" -eq 0 ]]; then
      log "${GREEN}✓${NC} Branch already merged — cleaning up only"
      # Run finalize with --skip-merge (already merged)
      FINALIZE_OUT=$(bash ~/.claude/tools/commit-finalize.sh \
        --task "$TASK" --worktree "$WORKDIR" --main "$MAIN_DIR" \
        --branch "feature/${TASK}" --stream "$STREAM_FILE" --skip-merge 2>&1 | tee /dev/stderr | python3 -c "import sys,json; lines=sys.stdin.read(); start=lines.rfind('{'); print(lines[start:] if start>=0 else '{}')")
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

      FINALIZE_OUT=$(bash ~/.claude/tools/commit-finalize.sh \
        --task "$TASK" --worktree "$WORKDIR" --main "$MAIN_DIR" \
        --branch "feature/${TASK}" --stream "$STREAM_FILE" 2>&1 | tee /dev/stderr | python3 -c "import sys,json; lines=sys.stdin.read(); start=lines.rfind('{'); print(lines[start:] if start>=0 else '{}')")
    fi

    # Log the JSON result to the NDJSON stream
    if [[ -n "${STREAM_FILE:-}" && -f "${STREAM_FILE:-}" ]]; then
      printf '{"type":"finalize","result":%s,"ts":"%s"}\n' \
        "$FINALIZE_OUT" "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$STREAM_FILE"
    fi

    # Check if finalize succeeded
    FINALIZE_OK=$(echo "$FINALIZE_OUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',False))" 2>/dev/null || echo "false")
    if [[ "$FINALIZE_OK" != "True" && "$FINALIZE_OK" != "true" ]]; then
      log "${YELLOW}⚠${NC} Finalize had failures — check output above"
      # Check specifically for merge failure (worktree preserved for manual resolution)
      MERGE_FAILED=$(echo "$FINALIZE_OUT" | python3 -c "
import sys, json
steps = json.load(sys.stdin).get('steps', [])
print(any(s['step'] == 'merge' and s['status'] == 'fail' for s in steps))
" 2>/dev/null || echo "false")
      if [[ "$MERGE_FAILED" == "True" ]]; then
        log "${RED}✗${NC} Merge failed — worktree and branch preserved for manual resolution"
        log "  Resolve conflicts, then run: bash ~/.claude/tools/commit-finalize.sh --task $TASK --worktree $WORKDIR --main $MAIN_DIR --branch feature/${TASK}"
      fi
      PIPELINE_STATUS="failed"
    fi
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
  MAX_TURNS_PHASE=$MAX_TURNS_DEFAULT
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
