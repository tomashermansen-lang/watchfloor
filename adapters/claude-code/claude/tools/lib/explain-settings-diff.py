#!/usr/bin/env python3
"""Heuristic explainer for diffs of claude/settings.json.

Reads two file paths (old, new) and prints a plain-language summary in
Danish, with security-relevant changes marked ⚠. Used by sync.sh diff
--explain in preference to the generic LLM explainer for this single
high-stakes file.

Usage: python3 explain-settings-diff.py <old> <new>

Stdout: one bullet per detected change.
Stderr: errors (parse failures etc).
Exit: 0 on success, 2 on parse failure.
"""

import json
import sys

SECURITY_PERMS_KEYS = {"allow", "deny"}
SECURITY_HOOK_EVENTS = {
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "PermissionRequest",
    "Stop",
    "TaskCompleted",
}


def load(path: str) -> dict:
    try:
        with open(path) as f:
            return json.load(f)
    except FileNotFoundError:
        return {}
    except json.JSONDecodeError as e:
        print(f"Error: cannot parse {path}: {e}", file=sys.stderr)
        sys.exit(2)


def diff_lists(old: list, new: list) -> tuple[list, list]:
    """Return (added, removed) preserving order; treats lists as sets of
    string-or-json-serialised elements."""

    def key(item):
        return item if isinstance(item, str) else json.dumps(item, sort_keys=True)

    old_keys = {key(x): x for x in old}
    new_keys = {key(x): x for x in new}
    added = [v for k, v in new_keys.items() if k not in old_keys]
    removed = [v for k, v in old_keys.items() if k not in new_keys]
    return added, removed


def explain_permissions(old_perms: dict, new_perms: dict) -> list[str]:
    """Classify each permission change as ✓ HARDEN, ⚠ DANGER, or ◦ NEUTRAL.

    Mapping (semantic, not just security-relevant):
      added to deny      → ✓ HARDEN  (more guardrails)
      removed from deny  → ⚠ DANGER  (guardrail removed)
      added to allow     → ⚠ DANGER  (more permissive)
      removed from allow → ✓ HARDEN  (more restrictive — friction = friend)
    """
    bullets = []

    # deny rules
    deny_added, deny_removed = diff_lists(old_perms.get("deny", []), new_perms.get("deny", []))
    if deny_added:
        bullets.append(
            f"✓ HARDEN: tilføjet {len(deny_added)} deny-regel/regler: "
            + ", ".join(repr(a) for a in deny_added[:5])
            + (f" (+{len(deny_added) - 5} mere)" if len(deny_added) > 5 else "")
        )
    if deny_removed:
        bullets.append(
            f"⚠ DANGER: FJERNET {len(deny_removed)} deny-regel/regler "
            "(guardrail svækket): "
            + ", ".join(repr(r) for r in deny_removed[:5])
            + (f" (-{len(deny_removed) - 5} mere)" if len(deny_removed) > 5 else "")
        )

    # allow rules
    allow_added, allow_removed = diff_lists(old_perms.get("allow", []), new_perms.get("allow", []))
    if allow_added:
        bullets.append(
            f"⚠ DANGER: tilføjet {len(allow_added)} allow-regel/regler "
            "(udvider tilladelser): "
            + ", ".join(repr(a) for a in allow_added[:5])
            + (f" (+{len(allow_added) - 5} mere)" if len(allow_added) > 5 else "")
        )
    if allow_removed:
        bullets.append(
            f"✓ HARDEN: fjernet {len(allow_removed)} allow-regel/regler "
            "(mere prompt-friction): "
            + ", ".join(repr(r) for r in allow_removed[:5])
            + (f" (-{len(allow_removed) - 5} mere)" if len(allow_removed) > 5 else "")
        )

    # defaultMode change — direction matters
    old_mode = old_perms.get("defaultMode")
    new_mode = new_perms.get("defaultMode")
    if old_mode != new_mode:
        # acceptEdits/bypassPermissions are more permissive; default/ask/plan are stricter
        permissive = {"acceptEdits", "bypassPermissions", "auto", "dontAsk"}
        old_p = old_mode in permissive
        new_p = new_mode in permissive
        if old_p and not new_p:
            tag = "✓ HARDEN"
        elif new_p and not old_p:
            tag = "⚠ DANGER"
        else:
            tag = "⚠ DANGER"  # any change to security-critical setting is conservatively flagged
        bullets.append(f"{tag}: permissions.defaultMode {old_mode!r} → {new_mode!r}")

    return bullets


def hook_repr(hook: dict) -> str:
    """Compact representation of a single hook entry."""
    cmd = hook.get("command", "?")
    # Truncate long commands
    if len(cmd) > 80:
        cmd = cmd[:77] + "..."
    if hook.get("async"):
        return f"async: {cmd}"
    return cmd


def explain_hooks(old_hooks: dict, new_hooks: dict) -> list[str]:
    """Hooks are guardrails — adding usually HARDENs, removing usually DANGERs.

    Non-security hook events (e.g. PreCompact) are marked NEUTRAL.
    """
    bullets = []
    all_events = set(old_hooks) | set(new_hooks)
    for event in sorted(all_events):
        old_entries = old_hooks.get(event, [])
        new_entries = new_hooks.get(event, [])

        def flatten(entries):
            pairs = []
            for entry in entries:
                m = entry.get("matcher", "*")
                for h in entry.get("hooks", []):
                    pairs.append((m, hook_repr(h)))
            return pairs

        old_pairs = flatten(old_entries)
        new_pairs = flatten(new_entries)
        added = [p for p in new_pairs if p not in old_pairs]
        removed = [p for p in old_pairs if p not in new_pairs]
        is_security = event in SECURITY_HOOK_EVENTS
        for matcher, cmd in added:
            tag = "✓ HARDEN" if is_security else "◦ NEUTRAL"
            bullets.append(f"{tag}: tilføjet {event}-hook (matcher={matcher!r}): {cmd}")
        for matcher, cmd in removed:
            tag = "⚠ DANGER" if is_security else "◦ NEUTRAL"
            bullets.append(f"{tag}: FJERNET {event}-hook (matcher={matcher!r}): {cmd}")
    return bullets


def explain_env(old_env: dict, new_env: dict) -> list[str]:
    """Env-vars: added/changed are conservatively flagged DANGER (could be a
    leaked credential or a config-flag toggling something off).
    Removed is HARDEN (one less variable, one less leak surface)."""
    bullets = []
    for key in set(old_env) | set(new_env):
        if key not in old_env:
            bullets.append(
                f"⚠ DANGER: tilføjet env-variabel: {key} (værdi ikke vist — kan være credential)"
            )
        elif key not in new_env:
            bullets.append(f"✓ HARDEN: fjernet env-variabel: {key}")
        elif old_env[key] != new_env[key]:
            bullets.append(f"⚠ DANGER: ændret env-variabel: {key} (værdi ikke vist)")
    return bullets


def explain_sandbox(old_sb: dict, new_sb: dict) -> list[str]:
    """Sandbox-changes — direction matters explicitly."""
    bullets = []
    if not old_sb and not new_sb:
        return bullets

    # enabled: false=⚠ DANGER, true=✓ HARDEN
    if old_sb.get("enabled") != new_sb.get("enabled"):
        was, now = old_sb.get("enabled"), new_sb.get("enabled")
        tag = "⚠ DANGER" if now is False else "✓ HARDEN"
        bullets.append(f"{tag}: sandbox.enabled {json.dumps(was)} → {json.dumps(now)}")

    # allowUnsandboxedCommands: true is more permissive
    if old_sb.get("allowUnsandboxedCommands") != new_sb.get("allowUnsandboxedCommands"):
        was, now = old_sb.get("allowUnsandboxedCommands"), new_sb.get("allowUnsandboxedCommands")
        tag = "⚠ DANGER" if now is True else "✓ HARDEN"
        bullets.append(
            f"{tag}: sandbox.allowUnsandboxedCommands {json.dumps(was)} → {json.dumps(now)}"
        )

    # autoAllowBashIfSandboxed: true is more permissive (less prompt friction)
    if old_sb.get("autoAllowBashIfSandboxed") != new_sb.get("autoAllowBashIfSandboxed"):
        was, now = old_sb.get("autoAllowBashIfSandboxed"), new_sb.get("autoAllowBashIfSandboxed")
        tag = "⚠ DANGER" if now is True else "✓ HARDEN"
        bullets.append(
            f"{tag}: sandbox.autoAllowBashIfSandboxed {json.dumps(was)} → {json.dumps(now)}"
        )

    # Network domains: added=⚠ (more egress), removed=✓ (tighter)
    old_net = old_sb.get("network", {}).get("allowedDomains", [])
    new_net = new_sb.get("network", {}).get("allowedDomains", [])
    added, removed = diff_lists(old_net, new_net)
    if added:
        bullets.append(
            f"⚠ DANGER: sandbox.network: tilføjet {len(added)} domæne(r) "
            f"(udvider egress): {', '.join(added)}"
        )
    if removed:
        bullets.append(
            f"✓ HARDEN: sandbox.network: fjernet {len(removed)} domæne(r) "
            f"(snævrer egress): {', '.join(removed)}"
        )

    # Filesystem allowWrite: added=⚠ (more writable), removed=✓ (tighter)
    old_fs = old_sb.get("filesystem", {})
    new_fs = new_sb.get("filesystem", {})
    aw_added, aw_removed = diff_lists(old_fs.get("allowWrite", []), new_fs.get("allowWrite", []))
    if aw_added:
        bullets.append(
            f"⚠ DANGER: sandbox.allowWrite: tilføjet {len(aw_added)} path(s) "
            f"(flere mapper skrivbare): {', '.join(aw_added)}"
        )
    if aw_removed:
        bullets.append(
            f"✓ HARDEN: sandbox.allowWrite: fjernet {len(aw_removed)} path(s): "
            f"{', '.join(aw_removed)}"
        )

    # Filesystem denyRead: added=✓ (more paths blocked), removed=⚠ (less)
    dr_added, dr_removed = diff_lists(old_fs.get("denyRead", []), new_fs.get("denyRead", []))
    if dr_added:
        bullets.append(
            f"✓ HARDEN: sandbox.denyRead: tilføjet {len(dr_added)} path(s) "
            f"(flere private paths blokeret): {', '.join(dr_added[:8])}"
            + (f" (+{len(dr_added) - 8} mere)" if len(dr_added) > 8 else "")
        )
    if dr_removed:
        bullets.append(
            f"⚠ DANGER: sandbox.denyRead: fjernet {len(dr_removed)} path(s) "
            f"(eksponerer private data): {', '.join(dr_removed)}"
        )
    return bullets


def explain(old: dict, new: dict) -> list[str]:
    bullets = []
    bullets.extend(explain_permissions(old.get("permissions", {}), new.get("permissions", {})))
    bullets.extend(explain_hooks(old.get("hooks", {}), new.get("hooks", {})))
    bullets.extend(explain_env(old.get("env", {}), new.get("env", {})))
    bullets.extend(explain_sandbox(old.get("sandbox", {}), new.get("sandbox", {})))
    # Catch-all: top-level keys not handled above — neutral by default
    handled = {"permissions", "hooks", "env", "sandbox"}
    for key in set(old) | set(new):
        if key in handled:
            continue
        if old.get(key) != new.get(key):
            bullets.append(f"◦ NEUTRAL: ændret top-level felt: {key}")
    return bullets


def main():
    if len(sys.argv) != 3:
        print("Usage: explain-settings-diff.py <old> <new>", file=sys.stderr)
        sys.exit(2)
    old = load(sys.argv[1])
    new = load(sys.argv[2])
    bullets = explain(old, new)
    if not bullets:
        print("  (no structural changes detected — formatting/whitespace only)")
        return
    has_danger = any("⚠ DANGER" in b for b in bullets)
    has_harden = any("✓ HARDEN" in b for b in bullets)
    if has_danger:
        print(
            "Heuristik (⚠ DANGER = svækker sikkerhed, ✓ HARDEN = strammer, ◦ NEUTRAL = ingen sikkerhedseffekt):"
        )
    elif has_harden:
        print("Heuristik (✓ HARDEN = strammer sikkerhed, ◦ NEUTRAL = ingen sikkerhedseffekt):")
    else:
        print("Heuristik:")
    for b in bullets:
        print(f"  {b}")


if __name__ == "__main__":
    main()
