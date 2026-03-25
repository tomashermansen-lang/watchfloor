#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Dotfiles Sync — copies config between repo and home folder
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#  Usage:
#    sync.sh save     Copy from home → repo (after manual edits)
#    sync.sh restore  Copy from repo → home (new machine setup)
#    sync.sh diff     Show what's different
#    sync.sh status   Show which files are tracked
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── File mapping: repo path → home path ─────────────────
declare -a MAPPINGS=(
  "claude/settings.json:$HOME/.claude/settings.json"
  "claude/CLAUDE.md:$HOME/.claude/CLAUDE.md"
  "start-system.sh:$HOME/start-system.sh"
)

# Directory mappings (entire directories synced)
declare -a DIR_MAPPINGS=(
  "claude/commands:$HOME/.claude/commands"
  "claude/agents:$HOME/.claude/agents"
  "claude/skills:$HOME/.claude/skills"
  "claude/tools:$HOME/.claude/tools"
  "claude/hooks:$HOME/.claude/hooks"
  "claude/rules:$HOME/.claude/rules"
  "claude/plans:$HOME/.claude/plans"
  "claude/schema:$HOME/.claude/schema"
  "claude/templates:$HOME/.claude/templates"
)

# ── Functions ───────────────────────────────────────────

copy_file() {
  local src=$1 dst=$2 label=$3
  if [[ -f "$src" ]]; then
    mkdir -p "$(dirname "$dst")"
    cp "$src" "$dst"
    echo -e "  ${GREEN}✓${NC} $label"
  else
    echo -e "  ${RED}✗${NC} $label (source missing: $src)"
  fi
}

sync_dir() {
  local src=$1 dst=$2 label=$3
  if [[ -d "$src" ]]; then
    mkdir -p "$dst"
    rsync -a --delete "$src/" "$dst/"
    local count
    count=$(find "$src" -type f | wc -l | tr -d ' ')
    echo -e "  ${GREEN}✓${NC} $label ($count files)"
  else
    echo -e "  ${RED}✗${NC} $label (source missing: $src)"
  fi
}

sync_memory_save() {
  # Copy only memory/ subdirs from ~/.claude/projects/ (skip conversation transcripts)
  local src_base="$HOME/.claude/projects"
  local dst_base="$REPO_DIR/claude/project-memory"
  local count=0

  mkdir -p "$dst_base"
  find "$src_base" -type d -name 'memory' 2>/dev/null | while read -r mem_dir; do
    local project_dir
    project_dir=$(basename "$(dirname "$mem_dir")")
    local dst="$dst_base/$project_dir"
    mkdir -p "$dst"
    rsync -a --delete "$mem_dir/" "$dst/"
    ((count++)) || true
  done
  count=$(find "$dst_base" -type f -not -name '.DS_Store' | wc -l | tr -d ' ')
  echo -e "  ${GREEN}✓${NC} claude/project-memory/ ($count files across projects)"
}

sync_memory_restore() {
  local src_base="$REPO_DIR/claude/project-memory"
  local dst_base="$HOME/.claude/projects"
  local count=0

  if [[ ! -d "$src_base" ]]; then
    echo -e "  ${RED}✗${NC} claude/project-memory/ (not in repo)"
    return
  fi

  for project_dir in "$src_base"/*/; do
    local project_name
    project_name=$(basename "$project_dir")
    local dst="$dst_base/$project_name/memory"
    mkdir -p "$dst"
    rsync -a "$project_dir/" "$dst/"
    ((count++)) || true
  done
  echo -e "  ${GREEN}✓${NC} claude/project-memory/ → restored $count projects"
}

do_save() {
  echo -e "${BOLD}${CYAN}── Saving: home → repo ──${NC}"
  echo ""

  for mapping in "${MAPPINGS[@]}"; do
    local repo_path="${mapping%%:*}"
    local home_path="${mapping##*:}"
    copy_file "$home_path" "$REPO_DIR/$repo_path" "$repo_path"
  done

  for mapping in "${DIR_MAPPINGS[@]}"; do
    local repo_path="${mapping%%:*}"
    local home_path="${mapping##*:}"
    sync_dir "$home_path" "$REPO_DIR/$repo_path" "$repo_path/"
  done

  sync_memory_save

  echo ""
  echo -e "${GREEN}Saved. Run 'git diff' to review, then commit.${NC}"
}

do_restore() {
  echo -e "${BOLD}${CYAN}── Restoring: repo → home ──${NC}"
  echo ""

  for mapping in "${MAPPINGS[@]}"; do
    local repo_path="${mapping%%:*}"
    local home_path="${mapping##*:}"
    copy_file "$REPO_DIR/$repo_path" "$home_path" "$repo_path → $home_path"
  done

  for mapping in "${DIR_MAPPINGS[@]}"; do
    local repo_path="${mapping%%:*}"
    local home_path="${mapping##*:}"
    sync_dir "$REPO_DIR/$repo_path" "$home_path" "$repo_path/ → $home_path/"
  done

  sync_memory_restore

  # Make start-system.sh executable
  chmod +x "$HOME/start-system.sh" 2>/dev/null || true

  echo ""
  echo -e "${GREEN}Restored. Restart Claude Code for settings to take effect.${NC}"
}

do_diff() {
  echo -e "${BOLD}${CYAN}── Differences: repo vs home ──${NC}"
  echo ""

  local diffs=0
  for mapping in "${MAPPINGS[@]}"; do
    local repo_path="${mapping%%:*}"
    local home_path="${mapping##*:}"
    if [[ ! -f "$home_path" ]]; then
      echo -e "  ${RED}MISSING${NC} $home_path"
      ((diffs++))
    elif ! diff -q "$REPO_DIR/$repo_path" "$home_path" &>/dev/null; then
      echo -e "  ${RED}CHANGED${NC} $repo_path"
      diff --color=auto "$REPO_DIR/$repo_path" "$home_path" | head -20
      echo ""
      ((diffs++))
    else
      echo -e "  ${GREEN}OK${NC}      $repo_path"
    fi
  done

  for mapping in "${DIR_MAPPINGS[@]}"; do
    local repo_path="${mapping%%:*}"
    local home_path="${mapping##*:}"
    if [[ ! -d "$home_path" ]]; then
      echo -e "  ${RED}MISSING${NC} $home_path/"
      ((diffs++))
    else
      local dir_diff
      dir_diff=$(diff -rq "$REPO_DIR/$repo_path" "$home_path" 2>/dev/null | head -10)
      if [[ -n "$dir_diff" ]]; then
        echo -e "  ${RED}CHANGED${NC} $repo_path/"
        echo "$dir_diff" | head -5
        ((diffs++))
      else
        echo -e "  ${GREEN}OK${NC}      $repo_path/"
      fi
    fi
  done

  echo ""
  if [[ $diffs -eq 0 ]]; then
    echo -e "  ${GREEN}Everything in sync.${NC}"
  else
    echo -e "  ${RED}$diffs item(s) differ.${NC} Run 'sync.sh save' or 'sync.sh restore'."
  fi
}

do_status() {
  echo -e "${BOLD}${CYAN}── Tracked files ──${NC}"
  echo ""

  for mapping in "${MAPPINGS[@]}"; do
    local repo_path="${mapping%%:*}"
    local home_path="${mapping##*:}"
    local repo_ok="" home_ok=""
    [[ -f "$REPO_DIR/$repo_path" ]] && repo_ok="repo" || repo_ok="----"
    [[ -f "$home_path" ]] && home_ok="home" || home_ok="----"
    echo -e "  [$repo_ok] [$home_ok]  $repo_path"
  done

  for mapping in "${DIR_MAPPINGS[@]}"; do
    local repo_path="${mapping%%:*}"
    local home_path="${mapping##*:}"
    local repo_count=0 home_count=0
    [[ -d "$REPO_DIR/$repo_path" ]] && repo_count=$(find "$REPO_DIR/$repo_path" -type f | wc -l | tr -d ' ')
    [[ -d "$home_path" ]] && home_count=$(find "$home_path" -type f | wc -l | tr -d ' ')
    echo -e "  [${repo_count}f]   [${home_count}f]    $repo_path/"
  done
}

# ── Main ────────────────────────────────────────────────
case "${1:-}" in
  save)    do_save ;;
  restore) do_restore ;;
  diff)    do_diff ;;
  status)  do_status ;;
  *)
    echo "Usage: $0 {save|restore|diff|status}"
    echo ""
    echo "  save     Copy from home folder → this repo"
    echo "  restore  Copy from this repo → home folder"
    echo "  diff     Show differences between repo and home"
    echo "  status   Show which files exist where"
    exit 1
    ;;
esac
