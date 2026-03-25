#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Claude Code Pipeline — Uninstall
#
#  Removes deployed pipeline files from ~/.claude/.
#  Does NOT remove settings.json (you may have customized it).
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
NC='\033[0m'

echo -e "${BOLD}Claude Code Pipeline — Uninstall${NC}"
echo "=================================="
echo ""

read -rp "This will remove all pipeline commands, agents, skills, hooks, rules, tools, templates, and schema from ~/.claude/. Continue? [y/N]: " CONFIRM
if [[ ! "${CONFIRM:-N}" =~ ^[Yy]$ ]]; then
  echo "Cancelled."
  exit 0
fi

echo ""

remove_dir() {
  local dir=$1 name=$2
  if [[ -d "$dir" ]]; then
    rm -rf "$dir"
    echo -e "  ${GREEN}✓${NC} Removed $name"
  else
    echo -e "  ${YELLOW}—${NC} $name (not found, skipping)"
  fi
}

remove_dir "$HOME/.claude/commands" "commands"
remove_dir "$HOME/.claude/agents" "agents"
remove_dir "$HOME/.claude/skills" "skills"
remove_dir "$HOME/.claude/hooks" "hooks"
remove_dir "$HOME/.claude/rules" "rules"
remove_dir "$HOME/.claude/tools" "tools"
remove_dir "$HOME/.claude/templates" "templates"
remove_dir "$HOME/.claude/schema" "schema"
remove_dir "$HOME/.claude/project-memory" "project-memory"

# Remove CLAUDE.md
if [[ -f "$HOME/.claude/CLAUDE.md" ]]; then
  rm "$HOME/.claude/CLAUDE.md"
  echo -e "  ${GREEN}✓${NC} Removed CLAUDE.md"
fi

# Remove project-dirs.conf
if [[ -f "$HOME/.claude/project-dirs.conf" ]]; then
  rm "$HOME/.claude/project-dirs.conf"
  echo -e "  ${GREEN}✓${NC} Removed project-dirs.conf"
fi

# Remove start-system.sh
if [[ -f "$HOME/start-system.sh" ]]; then
  rm "$HOME/start-system.sh"
  echo -e "  ${GREEN}✓${NC} Removed ~/start-system.sh"
fi

echo ""
echo -e "${YELLOW}Note:${NC} ~/.claude/settings.json was NOT removed."
echo "  If you want to reset it, delete it manually or restore Claude Code defaults."
echo ""
echo -e "${GREEN}Uninstall complete.${NC} Restart Claude Code to apply changes."
