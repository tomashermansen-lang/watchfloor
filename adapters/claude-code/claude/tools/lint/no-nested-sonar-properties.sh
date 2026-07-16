#!/usr/bin/env bash
# Lint: enforce that sonar-project.properties lives ONLY at the repo
# root. Nested copies (e.g., dashboard/sonar-project.properties) take
# precedence when sonar-scanner is invoked from the subdir and silently
# spawn ghost projects in SonarQube keyed on the nested file's
# projectKey. The 2026-04-29 dashboard subtree merge left such a
# nested copy in place; it was deleted on 2026-05-20 along with this
# lint that prevents a future recurrence (Guard B of the three-guard
# anti-ghost-project hardening).
set -euo pipefail

# Repo-root resolution. Mirrors test-fixture-uses-preflight.sh so the
# linter works both inside and outside a git tree (the fallback climbs
# five levels from the linter's location).
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || \
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"

OFFENDERS=()

# Find every sonar-project.properties under the repo root, pruning the
# directories where they legitimately do NOT belong (vendored deps,
# build outputs, archive folders). The root copy is allowed; everything
# else fails the lint.
while IFS= read -r file; do
  [ -z "$file" ] && continue
  rel="${file#"$REPO_ROOT"/}"
  if [[ "$rel" == "sonar-project.properties" ]]; then
    continue
  fi
  OFFENDERS+=("$rel")
done < <(find "$REPO_ROOT" \
  \( -type d \( -name node_modules -o -name .venv -o -name .git \
              -o -name dist -o -name build -o -name __pycache__ \
              -o -path "*/docs/DONE_*" \) -prune \) \
  -o -type f -name "sonar-project.properties" -print \
  2>/dev/null | sort)

if [ "${#OFFENDERS[@]}" -eq 0 ]; then
  exit 0
fi

{
  printf 'LINT FAIL: nested sonar-project.properties files found:\n'
  for path in "${OFFENDERS[@]}"; do
    printf '  %s\n' "$path"
  done
  printf '\n'
  printf 'Only the repo-root sonar-project.properties is allowed. Nested\n'
  printf 'copies take precedence when sonar-scanner runs from that subdir\n'
  printf 'and silently spawn ghost projects in SonarQube keyed on the\n'
  printf 'nested file'\''s projectKey. Delete the nested file and rely on\n'
  printf 'the repo-root properties file.\n'
} >&2

exit 1
