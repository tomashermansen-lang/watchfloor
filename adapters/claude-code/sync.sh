#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  Dotfiles Sync — copies config between repo and home folder
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#  Usage:
#    sync.sh save              Copy from home → repo (after manual edits)
#    sync.sh restore           Copy from repo → home — DEFAULTS to explained diff + Y/N
#    sync.sh diff              Show what's different — DEFAULTS to explained diff
#    sync.sh status            Show which files are tracked
#
#  Flags:
#    --no-explain  skip plain-language explainer, show raw diff instead
#    --no-diff     skip diff display entirely (and skip Y/N — restore only)
#    --yes / -y    show diff, skip Y/N prompt (restore only)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
# Explanation is the safer default: heuristic + LLM forklaring inden Y/N gør
# det reelt brugbart at læse pending-deploys. Pass --no-explain for raw diff.
EXPLAIN=1  # 0 = raw diff, 1 = heuristik + LLM forklaring (default)
NO_DIFF=0  # set to 1 by 'restore --no-diff' (skip diff display + prompt)
YES=0      # set to 1 by 'restore --yes' (show diff, skip prompt)

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── File mapping: repo path → home path ─────────────────
declare -a MAPPINGS=(
  "claude/settings.json:$HOME/.claude/settings.json"
  "claude/CLAUDE.md:$HOME/.claude/CLAUDE.md"
  "../../start-system.sh:$HOME/start-system.sh"
)

# Directory mappings (entire directories synced)
#
# Note on what's NOT synced:
# - `claude/plans/` is excluded by design. ~/.claude/plans/ is an
#   operator-local accumulator: Claude Code's Plan tool auto-saves plan
#   documents there with random adjective-verb-noun names (e.g.
#   `agile-booping-whisper.md`). These are session-specific work, not
#   shared infrastructure, and shouldn't propagate between machines via
#   sync. The directory is gitignored anyway.
declare -a DIR_MAPPINGS=(
  "claude/commands:$HOME/.claude/commands"
  "claude/agents:$HOME/.claude/agents"
  "claude/skills:$HOME/.claude/skills"
  "claude/tools:$HOME/.claude/tools"
  "claude/hooks:$HOME/.claude/hooks"
  "claude/rules:$HOME/.claude/rules"
  "../../core/schema:$HOME/.claude/schema"
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
    # Exclude Python bytecode caches and editor cruft — these get created
    # locally during testing/dev and must NOT propagate to ~/.claude/.
    # Mirrors .gitignore intent (untracked) at the rsync layer (uncopied).
    rsync -a --delete \
      --exclude='__pycache__/' \
      --exclude='*.pyc' \
      --exclude='*.pyo' \
      --exclude='.pytest_cache/' \
      --exclude='.mypy_cache/' \
      --exclude='.ruff_cache/' \
      --exclude='.DS_Store' \
      "$src/" "$dst/"
    local count
    count=$(find "$src" -type f \
      -not -path '*/__pycache__/*' \
      -not -name '*.pyc' \
      -not -name '*.pyo' \
      -not -path '*/.pytest_cache/*' \
      -not -path '*/.mypy_cache/*' \
      -not -path '*/.ruff_cache/*' \
      -not -name '.DS_Store' \
      | wc -l | tr -d ' ')
    echo -e "  ${GREEN}✓${NC} $label ($count files)"
  else
    echo -e "  ${RED}✗${NC} $label (source missing: $src)"
  fi
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

  echo ""
  echo -e "${GREEN}Saved. Run 'git diff' to review, then commit.${NC}"
}

strip_ansi() {
  # Remove ANSI escape sequences for clean log output
  sed $'s/\x1b\\[[0-9;]*m//g'
}

# Compute aggregate risk level from a captured diff output. Returns one of:
#   NONE   — nothing changed
#   LOW    — only HARDEN / NEUTRAL classifications
#   MEDIUM — 1-2 DANGER on non-critical paths
#   HIGH   — 3+ DANGER, OR any DANGER on critical security paths, OR any
#            CRITICAL banner (trust-chain modification)
# Outputs the level on stdout; counts via stderr-not-needed.
compute_risk_level() {
  local out="$1"
  local danger_count harden_count neutral_count
  # `|| true` because grep -c returns 1 when count is zero
  danger_count=$(printf '%s' "$out" | grep -c "⚠ DANGER" || true)
  harden_count=$(printf '%s' "$out" | grep -c "✓ HARDEN" || true)
  neutral_count=$(printf '%s' "$out" | grep -c "◦ NEUTRAL" || true)

  # No changes at all — caller usually has its own check, this is a safety
  if [[ $danger_count -eq 0 && $harden_count -eq 0 && $neutral_count -eq 0 ]]; then
    if ! printf '%s' "$out" | grep -qE 'CHANGED|MISSING'; then
      echo "NONE"
      return
    fi
  fi

  # Critical-path triggers — auto-bump to HIGH
  local has_critical=0
  if printf '%s' "$out" | grep -q "⚠⚠⚠ CRITICAL"; then
    has_critical=1  # trust-chain file modification
  fi
  # sandbox-disable
  if printf '%s' "$out" | grep -qE "sandbox.enabled.*true.*→.*false"; then
    has_critical=1
  fi
  # allow-unsandboxed-commands turned on
  if printf '%s' "$out" | grep -qE "allowUnsandboxedCommands.*false.*→.*true"; then
    has_critical=1
  fi
  # PreToolUse-hook removal (loses runtime guardrail)
  if printf '%s' "$out" | grep -qE "FJERNET PreToolUse-hook"; then
    has_critical=1
  fi
  # defaultMode → bypassPermissions
  if printf '%s' "$out" | grep -qE 'defaultMode.*bypassPermissions'; then
    has_critical=1
  fi
  # Removal of credential-paths from denyRead (re-exposes secrets)
  if printf '%s' "$out" | grep -qE "denyRead.*FJERNET.*\.ssh|denyRead.*FJERNET.*\.aws|denyRead.*FJERNET.*Keychains"; then
    has_critical=1
  fi

  if [[ $has_critical -eq 1 ]]; then
    echo "HIGH"
  elif [[ $danger_count -ge 3 ]]; then
    echo "HIGH"
  elif [[ $danger_count -ge 1 ]]; then
    echo "MEDIUM"
  else
    echo "LOW"
  fi
}

# Pretty-print the risk summary. Takes (level, output) and writes a banner
# to stdout. Banner includes counts and action-guidance keyed to the level.
print_risk_summary() {
  local level="$1" out="$2"
  local danger_count harden_count neutral_count
  danger_count=$(printf '%s' "$out" | grep -c "⚠ DANGER" || true)
  harden_count=$(printf '%s' "$out" | grep -c "✓ HARDEN" || true)
  neutral_count=$(printf '%s' "$out" | grep -c "◦ NEUTRAL" || true)

  local color emoji guidance
  case "$level" in
    NONE)
      color="$GREEN"; emoji="✓"; guidance="ingen ændringer at deploye"
      ;;
    LOW)
      color="$GREEN"; emoji="🟢"
      guidance="kun strammende ændringer — kan godkendes uden at læse hver linje"
      ;;
    MEDIUM)
      color="$YELLOW"; emoji="🟡"
      guidance="læs ⚠ DANGER-linjer omhyggeligt før godkendelse"
      ;;
    HIGH)
      color="$RED"; emoji="🔴"
      guidance="læs HVER linje + verificér at ændringerne er bevidste"
      ;;
  esac

  echo ""
  echo -e "${BOLD}${color}═══════════════════════════════════════════════════════════════${NC}"
  echo -e "${BOLD}${color}  RISK: ${emoji} ${level}${NC}"
  echo -e "  ⚠ ${danger_count} DANGER · ✓ ${harden_count} HARDEN · ◦ ${neutral_count} NEUTRAL"
  echo ""
  echo -e "  → ${guidance}"

  if [[ "$level" == "HIGH" ]]; then
    echo ""
    echo -e "${BOLD}${RED}  CRITICAL TRIGGERS:${NC}"
    if printf '%s' "$out" | grep -q "⚠⚠⚠ CRITICAL"; then
      echo -e "  - trust-chain file modification (explainer's own prompt/script)"
    fi
    if printf '%s' "$out" | grep -qE "sandbox.enabled.*true.*→.*false"; then
      echo -e "  - sandbox.enabled set to false (KILLS kernel sandbox)"
    fi
    if printf '%s' "$out" | grep -qE "allowUnsandboxedCommands.*false.*→.*true"; then
      echo -e "  - allowUnsandboxedCommands enabled (sandbox-escape allowed)"
    fi
    if printf '%s' "$out" | grep -qE "FJERNET PreToolUse-hook"; then
      echo -e "  - PreToolUse hook removed (loses runtime guardrail)"
    fi
    if printf '%s' "$out" | grep -qE 'defaultMode.*bypassPermissions'; then
      echo -e "  - defaultMode set to bypassPermissions (no permission checks)"
    fi
    if printf '%s' "$out" | grep -qE "denyRead.*FJERNET.*\.ssh|denyRead.*FJERNET.*\.aws|denyRead.*FJERNET.*Keychains"; then
      echo -e "  - credential-path read-deny removed (~/.ssh / ~/.aws / Keychains exposed)"
    fi
    if [[ $danger_count -ge 3 ]] && ! printf '%s' "$out" | grep -q "⚠⚠⚠ CRITICAL"; then
      echo -e "  - ${danger_count} DANGER classifications in single deploy"
    fi
  fi

  echo -e "${BOLD}${color}═══════════════════════════════════════════════════════════════${NC}"
  echo ""
}

do_restore() {
  # Pre-flight: dotfiles working tree must be clean so HEAD matches what
  # gets deployed. Otherwise the audit trail (git log) is misleading.
  if [[ -n "$(git -C "$REPO_DIR" status --porcelain 2>/dev/null)" ]]; then
    echo -e "${RED}✗ Aborting: dotfiles working tree has uncommitted changes.${NC}" >&2
    echo "" >&2
    echo "Commit or stash changes first so HEAD reflects what gets deployed:" >&2
    git -C "$REPO_DIR" status --short >&2
    exit 1
  fi

  # Show diff + prompt unless --no-diff
  local diff_capture=""
  if [[ "$NO_DIFF" != "1" ]]; then
    # Capture once, echo to stdout, also keep a clean copy for the audit log.
    # Avoids `tee /dev/tty` which fails when invoked without a controlling tty.
    diff_capture=$(do_diff 2>&1)
    printf '%s\n' "$diff_capture"
    diff_capture=$(printf '%s' "$diff_capture" | strip_ansi)
    echo ""

    if [[ "$YES" != "1" ]]; then
      local ans
      read -r -p "Proceed with restore? [y/N]: " ans
      case "$ans" in
        y|Y|yes|YES) ;;
        *)
          echo "Aborted."
          exit 0
          ;;
      esac
    fi
  fi

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

  # Make start-system.sh executable
  chmod +x "$HOME/start-system.sh" 2>/dev/null || true

  # Audit log: every successful deploy gets a markdown record committed to
  # the repo. Provides forensic trail for "what was deployed when" so a
  # later audit can `git log docs/sync-log/` to reconstruct.
  local ts log_file head_sha
  ts="$(date -u '+%Y-%m-%dT%H-%M-%SZ')"
  log_file="$REPO_DIR/docs/sync-log/${ts}.md"
  head_sha="$(git -C "$REPO_DIR" rev-parse --short HEAD)"
  mkdir -p "$(dirname "$log_file")"
  {
    echo "# Sync deploy: ${ts}"
    echo ""
    echo "- **Approved by:** $(whoami)"
    echo "- **Repo HEAD at deploy:** ${head_sha}"
    echo "- **Trigger:** \`bash sync.sh restore${NO_DIFF:+ --no-diff}${YES:+ --yes}${EXPLAIN:+ --explain}\`"
    echo ""
    echo "## Diff at deploy time"
    echo ""
    if [[ -n "$diff_capture" ]]; then
      echo '```'
      printf '%s\n' "$diff_capture"
      echo '```'
    else
      echo "_No diff captured (--no-diff was set)._"
    fi
  } > "$log_file"

  if git -C "$REPO_DIR" add "$log_file" 2>/dev/null \
     && git -C "$REPO_DIR" commit -q -m "docs(sync-log): deploy ${ts}" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} audit log committed: docs/sync-log/${ts}.md"
  else
    echo -e "  ${RED}!${NC} audit log written but not committed (git failed)"
  fi

  echo ""
  echo -e "${GREEN}Restored. Restart Claude Code for settings to take effect.${NC}"
}

do_diff() {
  # Stream the per-file output to stdout AND capture it to a temp file so we
  # can compute the aggregate risk level after all classifications are in.
  # Tee gives the user real-time output during the (occasionally slow) LLM
  # calls; the captured copy feeds compute_risk_level + print_risk_summary.
  local tmpdir outfile
  tmpdir="${TMPDIR:-/tmp}"
  outfile="$tmpdir/sync-diff-$$.txt"
  : > "$outfile"
  do_diff_inner | tee "$outfile"

  local out level
  out=$(cat "$outfile" 2>/dev/null || echo "")
  rm -f "$outfile"
  level=$(compute_risk_level "$out")
  print_risk_summary "$level" "$out"
}

do_diff_inner() {
  local title="── Differences: repo vs home ──"
  [[ "$EXPLAIN" == "1" ]] && title="── Differences (with explanations): repo vs home ──"
  echo -e "${BOLD}${CYAN}${title}${NC}"
  echo ""

  if [[ "$EXPLAIN" == "1" ]]; then
    # shellcheck disable=SC1090
    source "$REPO_DIR/claude/tools/lib/explain-diff.sh"
  fi

  local diffs=0
  for mapping in "${MAPPINGS[@]}"; do
    local repo_path="${mapping%%:*}"
    local home_path="${mapping##*:}"
    if [[ ! -f "$home_path" ]]; then
      echo -e "  ${RED}MISSING${NC} $home_path"
      diffs=$((diffs + 1))
    elif ! diff -q "$REPO_DIR/$repo_path" "$home_path" &>/dev/null; then
      echo -e "  ${RED}CHANGED${NC} $repo_path"
      if [[ "$EXPLAIN" == "1" ]]; then
        explain_path "$REPO_DIR/$repo_path" "$home_path" "$repo_path" | sed 's/^/    /'
      else
        # `|| true` masks diff's exit-1 (files differ) so set -euo pipefail
        # doesn't silently abort the loop after the first changed file.
        diff --color=auto "$REPO_DIR/$repo_path" "$home_path" | head -20 || true
      fi
      echo ""
      diffs=$((diffs + 1))
    else
      echo -e "  ${GREEN}OK${NC}      $repo_path"
    fi
  done

  for mapping in "${DIR_MAPPINGS[@]}"; do
    local repo_path="${mapping%%:*}"
    local home_path="${mapping##*:}"
    if [[ ! -d "$home_path" ]]; then
      echo -e "  ${RED}MISSING${NC} $home_path/"
      diffs=$((diffs + 1))
    else
      local dir_diff
      # `|| true` masks diff's exit-1 (dirs differ) so set -euo pipefail
      # doesn't silently abort the for-loop on the first directory with diffs.
      # Excludes mirror copy_dir's rsync --exclude list (lines 82-88) so the
      # diff output matches what cp will actually deploy. Without this, the
      # diff shows pycache/.DS_Store/etc. as drift even though they're never
      # copied — pure noise that triggers misleading LLM-explainer warnings.
      dir_diff=$(diff -rq \
        -x '__pycache__' -x '*.pyc' -x '*.pyo' \
        -x '.pytest_cache' -x '.mypy_cache' -x '.ruff_cache' \
        -x '.DS_Store' \
        "$REPO_DIR/$repo_path" "$home_path" 2>/dev/null | head -10 || true)
      if [[ -n "$dir_diff" ]]; then
        echo -e "  ${RED}CHANGED${NC} $repo_path/"
        if [[ "$EXPLAIN" == "1" ]]; then
          explain_dir "$REPO_DIR/$repo_path" "$home_path" "$repo_path" | sed 's/^/    /'
        else
          echo "$dir_diff" | head -5
        fi
        diffs=$((diffs + 1))
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
CMD="${1:-}"
shift || true
# Parse flags
for arg in "$@"; do
  case "$arg" in
    --explain)    EXPLAIN=1 ;;  # explicit (default — kept for clarity / scripts)
    --no-explain) EXPLAIN=0 ;;  # opt-out of LLM-explainer, fall back to raw diff
    --no-diff)    NO_DIFF=1; YES=1 ;;  # implies --yes (no diff means no prompt)
    --yes|-y)     YES=1 ;;
    *) ;;
  esac
done

case "$CMD" in
  save)    do_save ;;
  restore) do_restore ;;
  diff)    do_diff ;;
  status)  do_status ;;
  *)
    cat <<'EOF'
Usage: sync.sh {save|restore|diff|status} [flags]

  save                          Copy from home folder → this repo
  restore                       Copy from repo → home folder
                                  Default: explained diff + Y/N prompt
  diff                          Show differences (default: explained)
  status                        Show which files exist where

Flags:
  --no-explain                  Skip plain-language explainer; show raw diff
  --no-diff                     (restore) Skip diff display + Y/N prompt entirely
  --yes / -y                    (restore) Show diff, skip Y/N prompt
EOF
    exit 1
    ;;
esac
