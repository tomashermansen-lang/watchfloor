#!/usr/bin/env bash
# Lint dashboard test fixtures: every test-*.sh that spawns a server
# (uvicorn dashboard.server… or python… serve.py) must source the
# preflight helper and call port_preflight before the spawn line. See
# docs/INPROGRESS_Feature_preflight-enforcement-linter/REQUIREMENTS.md
# R1–R13 for the full contract.
set -euo pipefail

# Repo-root resolution. Two-step assignment avoids the
# `A || B && C` operator-precedence trap that would otherwise concat
# git's output with the fallback's output. Fallback climbs five levels
# from the linter's location so AS-9 holds even when invoked outside a
# git tree.
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || \
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"

# Tunable constants (R13). Adding a new spawn pattern is a one-line
# extension to SPAWN_RE; adding a new test directory is a SCAN_DIR /
# SCAN_GLOB edit. No loop body changes required.
HELPER="dashboard/tests/_lib/port-preflight.sh"
SCAN_DIR="dashboard/tests"
SCAN_GLOB="test-*.sh"
SPAWN_RE='uvicorn dashboard\.server|python[0-9.]* .*serve\.py'
SOURCE_RE='source .*port-preflight\.sh|^[[:space:]]*\..*port-preflight\.sh'
CALL_RE='port_preflight '

# R4 — graceful skip when helper is absent. Runs BEFORE any directory
# scan so the stderr warning is deterministic regardless of corpus.
if [ ! -f "$REPO_ROOT/$HELPER" ]; then
  printf 'lint/test-fixture-uses-preflight: helper %s not found — skipping\n' "$HELPER" >&2
  exit 0
fi

OFFENDERS=()

# `find` with a `sort` pin keeps OFFENDERS ordering deterministic
# across filesystems (R11 + T21 byte-identical re-runs).
while IFS= read -r file; do
  [ -z "$file" ] && continue

  # Strip comment lines (first non-whitespace char is `#`). The
  # POSIX-portable [[:space:]] form works under both GNU and BSD grep;
  # `\s` is GNU/PCRE-only.
  non_comment="$(grep -vE '^[[:space:]]*#' "$file" || true)"

  # R2 — spawn detection. Conditional grep stays compatible with
  # `set -e` (a bare `grep -q` returning 1 would abort the script).
  if ! printf '%s\n' "$non_comment" | grep -qE "$SPAWN_RE"; then
    continue
  fi

  # R3 — compliance: BOTH a source line AND a call line must exist
  # among non-comment lines.
  has_source=0
  has_call=0
  if printf '%s\n' "$non_comment" | grep -qE "$SOURCE_RE"; then has_source=1; fi
  if printf '%s\n' "$non_comment" | grep -qE "$CALL_RE"; then has_call=1; fi

  if [ "$has_source" -eq 1 ] && [ "$has_call" -eq 1 ]; then
    continue
  fi

  rel="${file#"$REPO_ROOT"/}"
  OFFENDERS+=("$rel")
done < <(find "$REPO_ROOT/$SCAN_DIR" -maxdepth 1 -name "$SCAN_GLOB" -type f 2>/dev/null | sort)

# R5 / R6 — reporting.
if [ "${#OFFENDERS[@]}" -eq 0 ]; then
  exit 0
fi

{
  printf 'LINT FAIL: tests spawn a server without preflight:\n'
  for path in "${OFFENDERS[@]}"; do
    printf '  %s\n' "$path"
  done
  # shellcheck disable=SC2016 # $PORT is a literal placeholder in the diagnostic, not a shell expansion.
  printf '  Source dashboard/tests/_lib/port-preflight.sh and call port_preflight $PORT before spawn.\n'
} >&2

exit 1
