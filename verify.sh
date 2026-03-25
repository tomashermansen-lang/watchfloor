#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Claude Code Pipeline — Verify Installation
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

pass() { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}⚠${NC} $1"; WARNINGS=$((WARNINGS + 1)); }
fail() { echo -e "  ${RED}✗${NC} $1"; ERRORS=$((ERRORS + 1)); }

echo -e "${BOLD}Claude Code Pipeline — Verify${NC}"
echo "==============================="
echo ""

# ── Commands ────────────────────────────────────────────
echo -e "${BOLD}Commands${NC}"
CMD_DIR="$HOME/.claude/commands"
EXPECTED_CMDS=(ba commit docs done grill health hotfix idea implement manualtest plan plan-project productmanager qa refactor review start start-hotfix static-analysis status team-qa team-review ux)
for cmd in "${EXPECTED_CMDS[@]}"; do
  if [[ -f "$CMD_DIR/$cmd.md" ]]; then
    pass "$cmd"
  else
    fail "$cmd — missing from $CMD_DIR/"
  fi
done
echo ""

# ── Agents ──────────────────────────────────────────────
echo -e "${BOLD}Agents${NC}"
AGENT_DIR="$HOME/.claude/agents"
EXPECTED_AGENTS=(analyst architect canary code-reviewer dependency-auditor devops-engineer fixer lead-developer performance-engineer qa-engineer security-auditor test-explorer ux-designer)
for agent in "${EXPECTED_AGENTS[@]}"; do
  if [[ -f "$AGENT_DIR/$agent.md" ]]; then
    pass "$agent"
  else
    fail "$agent — missing from $AGENT_DIR/"
  fi
done
echo ""

# ── Hooks ───────────────────────────────────────────────
echo -e "${BOLD}Hooks${NC}"
HOOK_DIR="$HOME/.claude/hooks"
for hook in tdd-gate.sh lint-on-edit.sh log-bash.sh log-permissions.sh notify-macos.sh; do
  if [[ -f "$HOOK_DIR/$hook" ]]; then
    if [[ -x "$HOOK_DIR/$hook" ]]; then
      pass "$hook"
    else
      warn "$hook — exists but not executable (run: chmod +x $HOOK_DIR/$hook)"
    fi
  else
    fail "$hook — missing from $HOOK_DIR/"
  fi
done
echo ""

# ── Tools ───────────────────────────────────────────────
echo -e "${BOLD}Tools${NC}"
TOOL_DIR="$HOME/.claude/tools"
for tool in autopilot.sh commit-finalize.sh commit-preflight.sh done-verify.sh start-validate.sh validate-plan.py; do
  if [[ -f "$TOOL_DIR/$tool" ]]; then
    pass "$tool"
  else
    fail "$tool — missing from $TOOL_DIR/"
  fi
done
echo ""

# ── Settings ────────────────────────────────────────────
echo -e "${BOLD}Settings${NC}"
SETTINGS="$HOME/.claude/settings.json"
if [[ -f "$SETTINGS" ]]; then
  pass "settings.json exists"
  if jq -e '.sandbox.enabled == true' "$SETTINGS" &>/dev/null; then
    pass "Sandbox enabled"
  else
    warn "Sandbox not enabled in settings.json"
  fi
  if jq -e '.hooks | length > 0' "$SETTINGS" &>/dev/null; then
    pass "Hooks configured"
  else
    warn "No hooks found in settings.json"
  fi
else
  fail "settings.json — missing from ~/.claude/"
fi
echo ""

# ── Project dirs config ─────────────────────────────────
echo -e "${BOLD}Configuration${NC}"
if [[ -f "$HOME/.claude/project-dirs.conf" ]]; then
  pass "project-dirs.conf exists"
  # shellcheck disable=SC1091
  source "$HOME/.claude/project-dirs.conf"
  if [[ -d "${PROJECTS_ROOT:-}" ]]; then
    pass "PROJECTS_ROOT=$PROJECTS_ROOT (exists)"
  else
    warn "PROJECTS_ROOT=${PROJECTS_ROOT:-unset} (directory not found)"
  fi
else
  warn "project-dirs.conf not found — using defaults"
fi

if [[ -f "$HOME/start-system.sh" ]]; then
  pass "~/start-system.sh installed"
else
  warn "~/start-system.sh not found"
fi
echo ""

# ── Summary ─────────────────────────────────────────────
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
if [[ $ERRORS -eq 0 && $WARNINGS -eq 0 ]]; then
  echo -e "${BOLD}${GREEN}  All checks passed!${NC}"
elif [[ $ERRORS -eq 0 ]]; then
  echo -e "${BOLD}${YELLOW}  Passed with $WARNINGS warning(s)${NC}"
else
  echo -e "${BOLD}${RED}  $ERRORS error(s), $WARNINGS warning(s)${NC}"
  echo "  Re-run install.sh or check the errors above."
fi
echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
exit $ERRORS
