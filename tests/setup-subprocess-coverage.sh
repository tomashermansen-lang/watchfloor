#!/usr/bin/env bash
# tests/setup-subprocess-coverage.sh
#
# Installs the .pth file that coverage.py needs to trace subprocess Python
# invocations. Idempotent — safe to run on every test invocation; cheap when
# already installed (single -f check).
#
# Why:
#   coverage.py's official subprocess-tracing mechanism (docs §"Measuring
#   sub-processes") requires every Python interpreter that the test suite
#   spawns to call `coverage.process_startup()` at site init. The standard
#   way to wire this is a .pth file in the venv's site-packages — Python's
#   site module auto-processes .pth files BEFORE any user code runs,
#   conditional on the COVERAGE_PROCESS_START env var being set.
#
#   Without this, `subprocess.run([sys.executable, "validate-plan.py", ...])`
#   in our tests exercises validate-plan.py's lines but coverage.py never
#   sees them. The dashboard reports a misleading-low number; the honest
#   coverage is invisible.
#
# When to run:
#   - Once after `uv sync` recreates the venv.
#   - Automatically prepended by tests/run-cov.sh.
#   - Idempotent if .pth already present.
#
# Why a .pth file specifically (not sitecustomize.py at repo root):
#   sitecustomize is imported by Python's `site` module AFTER site-packages
#   are added to sys.path but BEFORE user code can extend sys.path. A
#   sitecustomize.py at repo root is invisible to site at that moment;
#   only files actually IN site-packages are discoverable. A .pth file is
#   the documented, supported extension point.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

if [[ ! -d ".venv" ]]; then
  echo "Error: no .venv at repo root. Run 'uv sync --extra dev' first." >&2
  exit 1
fi

SITE_PACKAGES=$(.venv/bin/python -c "import site; print(site.getsitepackages()[0])")
PTH="$SITE_PACKAGES/coverage_subprocess.pth"

# A .pth file's content is interpreted by Python's site module at startup.
# Lines starting with "import" are exec'd; other lines are treated as paths
# to add to sys.path. We rely on coverage.process_startup() to be a no-op
# unless COVERAGE_PROCESS_START is set, so this is safe to keep installed
# at all times — only the coverage-aware test run actually activates it.
EXPECTED='import coverage; coverage.process_startup()'

if [[ -f "$PTH" ]] && [[ "$(cat "$PTH")" == "$EXPECTED" ]]; then
  exit 0  # already installed, no-op
fi

echo "Installing subprocess coverage hook → $PTH"
printf '%s\n' "$EXPECTED" > "$PTH"
echo "OK: subprocess coverage will activate whenever COVERAGE_PROCESS_START is set."
