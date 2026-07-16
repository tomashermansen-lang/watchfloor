#!/bin/bash
# PreToolUse hook: filesystem allowlist for Edit/Write/NotebookEdit.
#
# WHY: Claude Code's macOS Seatbelt sandbox only wraps Bash subprocesses.
# Edit/Write/NotebookEdit run in the parent process and bypass the kernel
# sandbox entirely (verified empirically 2026-04-25). This hook implements
# the allowlist in user-space — same effect, no kernel guarantee.
#
# ALLOWLIST mirrors sandbox.filesystem.allowWrite in settings.json so Bash
# and Edit/Write/NotebookEdit have the same write-grænse.
#
# Returns exit 2 to deny with stderr feedback to Claude (per Claude Code
# PreToolUse contract). Returns 0 on allow or graceful no-op (missing
# file_path, malformed input).

set -uo pipefail

INPUT=$(cat)

# Extract file_path. tool_input.file_path is canonical, .file is fallback for
# rare tools. Missing field → graceful no-op (don't break other matchers).
FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // .tool_input.file // ""' 2>/dev/null || echo "")

[ -z "$FILE_PATH" ] && exit 0

# Canonicalize: expand ~, resolve symlinks, handle non-existent files.
# (Done before BOTH explicit-deny and allowlist checks so traversal/symlinks
# can't bypass either layer.)
# We use Python because macOS realpath requires existence and lacks the
# robustness we need for write targets (which often don't exist yet).
CANONICAL=$(python3 - "$FILE_PATH" <<'PY'
import os, sys
p = sys.argv[1]
p = os.path.expanduser(p)
if not os.path.isabs(p):
    p = os.path.abspath(p)
if os.path.exists(p) or os.path.islink(p):
    p = os.path.realpath(p)
else:
    parent = os.path.dirname(p) or "/"
    base = os.path.basename(p)
    parent = os.path.realpath(parent)
    p = os.path.join(parent, base)
print(p)
PY
)

# Explicit deny list — defense in depth.
# These paths would be denied by the allowlist anyway (none are in ALLOWED),
# but listing them here makes intent explicit and survives any future
# widening of the allowlist (e.g. if someone adds "$HOME/.claude" they'd
# still be blocked from settings.json).
EXPLICIT_DENY=(
    "$HOME/.claude/settings.json"
    "$HOME/.claude/settings.local.json"
    "$HOME/.claude/CLAUDE.md"
    "$HOME/.claude/hooks"
    "$HOME/.claude/agents"
    "$HOME/.claude/commands"
    "$HOME/.claude/skills"
    "$HOME/.claude/rules"
)

for prefix in "${EXPLICIT_DENY[@]}"; do
    prefix="${prefix%/}"
    if [[ "$CANONICAL" == "$prefix" ]] || [[ "$CANONICAL" == "$prefix/"* ]]; then
        cat >&2 <<EOF
ALLOWLIST: write to '$CANONICAL' is explicitly denied (runtime-config protection).

This path holds Claude Code's own runtime configuration — modifying it from
within a session would let the agent rewrite its own permissions, hooks,
agents, commands, skills, or rules. Source-of-truth lives in
~/Projekter/dotfiles/. To deploy config changes:

  cd ~/Projekter/dotfiles
  # edit the source files (this allowlist permits writes here)
  bash sync.sh diff --explain
  bash sync.sh restore   # human-approved deploy with audit log
EOF
        exit 2
    fi
done

# Allowlist: every prefix that matches sandbox.filesystem.allowWrite.
# Trailing slash stripped; matching is "exact OR prefix-with-slash" so that
# e.g. "$HOME/.docker" does NOT match "$HOME/.dockerfoo".
ALLOWED=(
    "$HOME/Projekter"
    "/tmp"
    "/private/tmp"
    "${TMPDIR:-/tmp}"
    "$HOME/.cache"
    "$HOME/.docker"
    "$HOME/.npm/_logs"
    "$HOME/.claude/debug"
)

for prefix in "${ALLOWED[@]}"; do
    prefix="${prefix%/}"
    # macOS resolves $TMPDIR (/var/folders/.../T/) through /private/var. Compare
    # against the canonical form too.
    canonical_prefix=$(python3 -c "import os,sys; print(os.path.realpath(sys.argv[1]))" "$prefix" 2>/dev/null || echo "$prefix")
    for p in "$prefix" "$canonical_prefix"; do
        if [[ "$CANONICAL" == "$p" ]] || [[ "$CANONICAL" == "$p/"* ]]; then
            exit 0
        fi
    done
done

cat >&2 <<EOF
ALLOWLIST: write to '$CANONICAL' is outside the trust zone.

Allowed prefixes (mirrors sandbox.filesystem.allowWrite):
$(printf '  - %s\n' "${ALLOWED[@]}")

If you intended to deploy config changes to ~/.claude/, edit them in
~/Projekter/dotfiles/ instead and run 'bash sync.sh restore' on the host.
EOF
exit 2
