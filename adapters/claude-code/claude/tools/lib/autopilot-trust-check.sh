#!/bin/bash
# autopilot-trust-check.sh — pre-flight constraint enforcement.
#
# Implements "Constraint A" from docs/architecture/security-layers.md:
# autopilot must only run on low-trust-input scenarios — known projects,
# no untrusted external content, no fork-review work.
#
# Why: autopilot bypasses interactive permission prompts and can perform
# in-zone destructive operations (rm, force-push, auto-merge) without a
# human in the loop. Constraint A removes ~75-80% of practical
# prompt-injection attack surface by refusing scenarios where untrusted
# attacker-controlled content reaches the agent.
#
# Sourced by autopilot.sh; provides:
#   trust_check_main_dir <dir> <task-id>  → exits 1 on blocker, 0 on warn/ok
#
# Override: AUTOPILOT_FORCE_RUN=1 bypasses blockers (use sparingly, audit
# the override in commit history).

set -uo pipefail

# Default trust list — derived from gh CLI's logged-in user. Override
# with AUTOPILOT_TRUSTED_OWNERS="user1,org1,user2" (comma-separated).
_trust_check_default_owners() {
    if command -v gh &>/dev/null; then
        local user
        user=$(gh api user --jq .login 2>/dev/null)
        if [[ -n "$user" ]]; then
            echo "$user"
            return 0
        fi
    fi
    # Fallback: derive from git config user.email's local part.
    # Handles GitHub's noreply format `<id>+<username>@users.noreply.github.com`
    # by stripping both the trailing @... and the leading <digits>+.
    local email_user
    email_user=$(git config --global user.email 2>/dev/null \
        | sed -E 's/@.*//; s/^[0-9]+\+//')
    [[ -n "$email_user" ]] && echo "$email_user"
}

# Returns 0 if owner is in trust list, 1 otherwise
_trust_check_owner_trusted() {
    local owner="$1" trusted="$2"
    # Lowercase via tr (portable to bash 3 on macOS).
    local owner_lc
    owner_lc=$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')
    local IFS=','
    for t in $trusted; do
        local t_lc
        t_lc=$(printf '%s' "$t" | tr '[:upper:]' '[:lower:]')
        if [[ "$owner_lc" == "$t_lc" ]]; then
            return 0
        fi
    done
    return 1
}

# Extract owner from a git remote URL.
# Examples:
#   git@github.com:tomashermansen/dotfiles.git → tomashermansen
#   https://github.com/some-org/repo.git       → some-org
#   git@gitlab.com:foo/bar.git                  → foo
_trust_check_extract_owner() {
    local url="$1"
    # SSH form: git@host:owner/repo.git
    if [[ "$url" =~ ^[^@]+@[^:]+:([^/]+)/.* ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    # HTTPS form: https://host/owner/repo
    if [[ "$url" =~ ^https?://[^/]+/([^/]+)/.* ]]; then
        echo "${BASH_REMATCH[1]}"
        return 0
    fi
    # Local file path or unknown — empty owner
    echo ""
}

# Main entry point. Echoes findings; exits 1 on blocker unless
# AUTOPILOT_FORCE_RUN=1.
trust_check_main_dir() {
    local main_dir="$1" task="${2:-unknown}"
    local trusted_owners="${AUTOPILOT_TRUSTED_OWNERS:-$(_trust_check_default_owners)}"

    if [[ -z "$trusted_owners" ]]; then
        echo "⚠ trust-check: no trusted owners configured (gh CLI not logged in, no git user.email)" >&2
        echo "  Set AUTOPILOT_TRUSTED_OWNERS=username1,org2 to enable trust checking" >&2
        # Don't block — just warn. User has chosen to run without trust list.
        return 0
    fi

    local -a blockers=()
    local -a warnings=()

    # 1. Inspect git remotes — ALL non-local remotes must be in trust list
    if [[ -d "$main_dir/.git" ]] || git -C "$main_dir" rev-parse --git-dir &>/dev/null; then
        local remote_lines
        remote_lines=$(git -C "$main_dir" remote -v 2>/dev/null | awk '$3=="(fetch)"{print $1"\t"$2}')
        while IFS=$'\t' read -r name url; do
            [[ -z "$url" ]] && continue
            local owner
            owner=$(_trust_check_extract_owner "$url")
            if [[ -z "$owner" ]]; then
                # Local or unknown — allow
                continue
            fi
            if ! _trust_check_owner_trusted "$owner" "$trusted_owners"; then
                blockers+=("untrusted git remote: $name → $url (owner '$owner' not in trust list)")
            fi
        done <<< "$remote_lines"
    fi

    # 2. Detect fork status via gh CLI
    if command -v gh &>/dev/null; then
        local is_fork
        is_fork=$(gh repo view "$main_dir" --json isFork -q .isFork 2>/dev/null || echo "")
        if [[ "$is_fork" == "true" ]]; then
            blockers+=("repository is a fork — running autopilot on fork-review work is high-risk")
        fi
    fi

    # 3. Detect risk keywords in task name
    case "$task" in
        *fork*|*external*|*untrusted*|*audit-pr*|*review-pr*|*pr-review*)
            warnings+=("task name '$task' contains risk-keyword (fork/external/untrusted/PR-review)")
            ;;
    esac

    # 4. Print findings
    if [[ ${#blockers[@]} -gt 0 ]]; then
        echo "" >&2
        echo "✗ AUTOPILOT TRUST-CHECK FAILED — Constraint A violated:" >&2
        for b in "${blockers[@]}"; do
            echo "  • $b" >&2
        done
        echo "" >&2
        echo "Trusted owners: $trusted_owners" >&2
        echo "" >&2
        echo "Why this matters: autopilot has Bash auto-approved and auto-merges to main." >&2
        echo "Untrusted remotes can deliver prompt-injection via tool output, README, etc." >&2
        echo "" >&2
        echo "Options:" >&2
        echo "  1. Run interactively (claude in this dir, no autopilot)" >&2
        echo "  2. Add owner to trust list: AUTOPILOT_TRUSTED_OWNERS=user1,org2" >&2
        echo "  3. Override (not recommended): AUTOPILOT_FORCE_RUN=1" >&2
        echo "" >&2
        if [[ "${AUTOPILOT_FORCE_RUN:-0}" != "1" ]]; then
            return 1
        fi
        echo "  ⚠ Bypassed via AUTOPILOT_FORCE_RUN=1" >&2
    fi

    if [[ ${#warnings[@]} -gt 0 ]]; then
        echo "⚠ Trust-check warnings:" >&2
        for w in "${warnings[@]}"; do
            echo "  • $w" >&2
        done
        echo "  (continuing — warnings are advisory only)" >&2
    fi

    return 0
}

# If executed directly, run a self-test
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    target="${1:-$PWD}"
    task="${2:-self-test}"
    if trust_check_main_dir "$target" "$task"; then
        echo "✓ trust-check passed for: $target ($task)"
    else
        echo "✗ trust-check failed for: $target ($task)"
        exit 1
    fi
fi
