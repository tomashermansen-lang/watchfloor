#!/usr/bin/env bash
# Stop hook — forces an autopilot phase to PRODUCE its required file artifact
# before the agent is allowed to end its turn.
#
# Closes the FOUNDATIONAL failure (canary-models 2026-06-02): a model emits a
# text-only "Let me check… / Now I'll…" message with NO tool call, which
# headless `claude -p` reads as stop_reason=end_turn — so the phase finishes
# with no artifact. A system-prompt contract only nudges; this enforces. When
# the artifact is missing the hook returns a `block` decision, which Claude
# Code feeds back as "keep going" WITHOUT consuming the --max-turns budget, in
# the SAME session (context preserved, no cold re-run).
#
# Scope: a strict no-op unless PHASE_ARTIFACT_PATH is set (only the orchestrator
# sets it, per gated phase), so every other Claude Code session is unaffected.
# Safety: fail-OPEN — any error or missing dependency exits 0 so a hook bug can
# never wedge the pipeline (mirrors the dashboard fail-silent-hooks rule). The
# per-session forced-continuation count is capped well under Claude Code's hard
# 8-block ceiling; past the cap the hook defers to run_gated_phase's cold retry.
set -uo pipefail

# Read the Stop-hook stdin payload. Never fail on a read error.
input="$(cat 2>/dev/null || true)"

# Gate: only active when the launching phase declared a file artifact.
artifact="${PHASE_ARTIFACT_PATH:-}"
[[ -z "$artifact" ]] && exit 0

# Already produced → allow the stop.
[[ -f "$artifact" ]] && exit 0

# Bound forced continuations per session (default 3; hard ceiling is 8).
max_forced="${PHASE_ARTIFACT_MAX_FORCED:-3}"
[[ "$max_forced" =~ ^[0-9]+$ ]] || max_forced=3

# session_id keys the counter so each phase (new session) starts fresh.
sid="$(printf '%s' "$input" | sed -n 's/.*"session_id"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
[[ -z "$sid" ]] && sid="nosession"
state_dir="${PHASE_ARTIFACT_STATE_DIR:-${TMPDIR:-/tmp}/claude-artifact-stop-guard}"
mkdir -p "$state_dir" 2>/dev/null || true
counter_file="$state_dir/$sid"
count="$(cat "$counter_file" 2>/dev/null || echo 0)"
[[ "$count" =~ ^[0-9]+$ ]] || count=0

# Past the cap → stop forcing; let the orchestrator's retry/fail take over.
if (( count >= max_forced )); then
  exit 0
fi
printf '%s\n' "$(( count + 1 ))" > "$counter_file" 2>/dev/null || true

reason="You have not created the required artifact ${artifact}. Create it NOW by calling the Write tool with that exact path — do not end your turn with only a description of what you will do next. Producing this file is the only way to complete this phase."

# Emit the block decision. Prefer python3 for robust JSON encoding; if it is
# somehow unavailable, fail open (allow the stop) rather than emit broken JSON.
if command -v python3 >/dev/null 2>&1; then
  python3 -c 'import json,sys; print(json.dumps({"decision":"block","reason":sys.argv[1]}))' "$reason"
fi
exit 0
