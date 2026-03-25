#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Claude Code Pipeline — Install
#
#  Deploys commands, agents, skills, hooks, rules, tools,
#  templates, and schema to ~/.claude/ via sync.sh.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo -e "${BOLD}Claude Code Pipeline — Install${NC}"
echo "================================="
echo ""

# ── Check platform ──────────────────────────────────────
if [[ "$(uname)" != "Darwin" ]]; then
  echo -e "${RED}ERROR:${NC} This pipeline requires macOS (Seatbelt sandbox)."
  echo "  See REQUIREMENTS.md for details."
  exit 1
fi

# ── Check prerequisites ─────────────────────────────────
MISSING=0
check_cmd() {
  local cmd=$1 name=$2 install=$3
  if command -v "$cmd" &>/dev/null; then
    local version
    version=$("$cmd" --version 2>&1 | head -1)
    echo -e "  ${GREEN}✓${NC} $name ($version)"
  else
    echo -e "  ${RED}✗${NC} $name not found"
    echo -e "    Install: ${CYAN}$install${NC}"
    MISSING=$((MISSING + 1))
  fi
}

echo -e "${BOLD}Checking prerequisites...${NC}"
echo ""
check_cmd "claude" "Claude Code CLI" "npm install -g @anthropic-ai/claude-code"
check_cmd "python3" "Python 3" "brew install python3"
check_cmd "jq" "jq" "brew install jq"
check_cmd "git" "git" "xcode-select --install"
check_cmd "tmux" "tmux (for autopilot)" "brew install tmux"
echo ""

if [[ $MISSING -gt 0 ]]; then
  echo -e "${RED}$MISSING prerequisite(s) missing. Install them and re-run.${NC}"
  exit 1
fi

# ── Configure projects root ─────────────────────────────
echo -e "${BOLD}Configuration${NC}"
echo ""
DEFAULT_ROOT="$HOME/Projects"
read -rp "  Projects root directory [$DEFAULT_ROOT]: " PROJECTS_ROOT
PROJECTS_ROOT="${PROJECTS_ROOT:-$DEFAULT_ROOT}"

# Expand ~ if used
PROJECTS_ROOT="${PROJECTS_ROOT/#\~/$HOME}"

if [[ ! -d "$PROJECTS_ROOT" ]]; then
  read -rp "  $PROJECTS_ROOT does not exist. Create it? [Y/n]: " CREATE
  if [[ "${CREATE:-Y}" =~ ^[Yy]$ ]]; then
    mkdir -p "$PROJECTS_ROOT"
    echo -e "  ${GREEN}✓${NC} Created $PROJECTS_ROOT"
  else
    echo -e "${YELLOW}Skipped — you'll need to create it before using start-system.sh${NC}"
  fi
fi

# ── Write project-dirs.conf ─────────────────────────────
mkdir -p "$HOME/.claude"
cat > "$HOME/.claude/project-dirs.conf" <<EOF
# Claude Code Pipeline — Project directories
# Override individual project paths or set the root for all.
PROJECTS_ROOT="$PROJECTS_ROOT"
EOF
echo -e "  ${GREEN}✓${NC} Wrote ~/.claude/project-dirs.conf"

# ── Template settings.json ──────────────────────────────
# Update the sandbox allowWrite path to match the user's projects root
SETTINGS_SRC="$SCRIPT_DIR/claude/settings.json"
SETTINGS_DST="$HOME/.claude/settings.json"

if [[ -f "$SETTINGS_DST" ]]; then
  echo ""
  echo -e "  ${YELLOW}⚠${NC} ~/.claude/settings.json already exists."
  read -rp "  Overwrite with pipeline settings? [y/N]: " OVERWRITE
  if [[ ! "${OVERWRITE:-N}" =~ ^[Yy]$ ]]; then
    echo -e "  ${CYAN}Skipped${NC} — keeping existing settings.json"
    echo "  You can merge manually from: $SETTINGS_SRC"
  else
    # Replace ~/Projects with user's actual path in the sandbox config
    sed "s|~/Projects|~/${PROJECTS_ROOT#$HOME/}|g" "$SETTINGS_SRC" > "$SETTINGS_DST"
    echo -e "  ${GREEN}✓${NC} Wrote ~/.claude/settings.json (sandbox: ~/${PROJECTS_ROOT#$HOME/})"
  fi
else
  sed "s|~/Projects|~/${PROJECTS_ROOT#$HOME/}|g" "$SETTINGS_SRC" > "$SETTINGS_DST"
  echo -e "  ${GREEN}✓${NC} Wrote ~/.claude/settings.json (sandbox: ~/${PROJECTS_ROOT#$HOME/})"
fi

# ── Deploy via sync.sh ──────────────────────────────────
echo ""
echo -e "${BOLD}Deploying pipeline files...${NC}"
bash "$SCRIPT_DIR/sync.sh" restore
echo ""

# ── Install start-system.sh ─────────────────────────────
cp "$SCRIPT_DIR/start-system.sh" "$HOME/start-system.sh"
chmod +x "$HOME/start-system.sh"
echo -e "  ${GREEN}✓${NC} Installed ~/start-system.sh"

# ── Summary ─────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Installation complete!${NC}"
echo ""
echo "  Next steps:"
echo "    1. Run ${CYAN}bash verify.sh${NC} to confirm everything is working"
echo "    2. Restart Claude Code to pick up the new settings"
echo "    3. Try ${CYAN}/status${NC} in Claude Code to see available commands"
echo ""
echo "  Optional — install the Agent Dashboard for real-time monitoring:"
echo "    https://github.com/tomashermansen-lang/claude-agent-dashboard"
echo ""
