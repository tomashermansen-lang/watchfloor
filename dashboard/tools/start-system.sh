#!/usr/bin/env bash
# Thin delegator — forwards to the canonical start-system.sh.
# Single source of truth: <repo-root>/start-system.sh, falling back to
# ~/start-system.sh. See DN-8 / RSK-5 in the
# poc-watchfloor-autopilot-control execution plan.
set -euo pipefail

resolve_toplevel() {
  # Defensive: bound the git call so a pathological git/PATH (EC-9.5)
  # cannot cause the delegator to hang. The 1-second budget is far
  # more than a healthy git rev-parse needs (~ms).
  if command -v timeout >/dev/null 2>&1; then
    timeout 1 git rev-parse --show-toplevel 2>/dev/null || true
  else
    git rev-parse --show-toplevel 2>/dev/null || true
  fi
}

resolve_canonical() {
  local toplevel="$1"
  if [[ -n "$toplevel" && -x "$toplevel/start-system.sh" ]]; then
    printf '%s\n' "$toplevel/start-system.sh"
    return 0
  fi
  if [[ -x "$HOME/start-system.sh" ]]; then
    printf '%s\n' "$HOME/start-system.sh"
    return 0
  fi
  return 1
}

toplevel="$(resolve_toplevel)"
if ! canonical="$(resolve_canonical "$toplevel")"; then
  reported_root="${toplevel:-$(pwd)}"
  printf 'start-system.sh delegator: neither %s/start-system.sh nor %s/start-system.sh is executable\n' \
    "$reported_root" "$HOME" >&2
  exit 1
fi

exec "$canonical" "$@"
