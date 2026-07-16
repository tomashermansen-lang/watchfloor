#!/usr/bin/env bash
# tests/run-cov.sh
#
# Run the full Python test suite WITH subprocess coverage tracking.
# Produces coverage.xml at repo root suitable for sonar-scanner ingest.
#
# Why a wrapper:
#   pytest --cov alone misses every subprocess invocation. This repo
#   subprocess-tests heavily (validate-plan.py, commit-finalize.sh's Python
#   helpers, uvicorn child in test_response_compat, etc). Without the
#   wiring this script sets up, the SonarQube dashboard reports a
#   misleading-low coverage number that does not reflect what the tests
#   actually exercise.
#
# What this script does (and why each step exists):
#   1. ensure .venv/.../coverage_subprocess.pth is installed
#      → makes child Python processes auto-instrument when env var is set
#   2. set COVERAGE_PROCESS_START=$REPO_ROOT/pyproject.toml
#      → activates the hook in (1); child processes inherit by default
#   3. wipe prior .coverage* data files
#      → prevents stale data leaking into the combined report
#   4. run tests/ with pytest --cov
#   5. run dashboard/tests/ with pytest --cov --cov-append
#   6. coverage combine
#      → merges every per-process .coverage.<host>.<pid> file into .coverage
#   7. coverage xml
#      → emits the format sonar-scanner consumes
#   8. coverage report (short summary)
#
# Usage:
#   bash tests/run-cov.sh                # full combined run
#   bash tests/run-cov.sh --skip-main    # just dashboard/ tests (faster)
#   bash tests/run-cov.sh --skip-dash    # just tests/ tree

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

SKIP_MAIN=false
SKIP_DASH=false
for arg in "$@"; do
  case "$arg" in
    --skip-main) SKIP_MAIN=true ;;
    --skip-dash) SKIP_DASH=true ;;
    -h|--help)
      grep '^# ' "$0" | sed 's/^# //'
      exit 0
      ;;
  esac
done

# (1) install the subprocess-coverage hook (idempotent)
bash tests/setup-subprocess-coverage.sh

# (2) activate the hook: every child Python that imports site will look at
#     this env var and start coverage tracking against the named config.
export COVERAGE_PROCESS_START="$REPO_ROOT/pyproject.toml"

# (3) clean prior data — including the per-process .coverage.* files from
#     [tool.coverage.run] parallel=true.
rm -f .coverage .coverage.* coverage.xml

# (4) tests/ tree
if [[ "$SKIP_MAIN" != "true" ]]; then
  echo "▶ Running tests/ with subprocess coverage..."
  .venv/bin/pytest --cov --cov-report= -q --ignore=tests/test_doc_contracts.py tests/
fi

# (5) dashboard/tests/ tree — --cov-append so parent-process traces stack.
#     Child processes still write their own .coverage.<pid> files thanks
#     to the .pth hook; they merge in step 6 regardless of --cov-append.
if [[ "$SKIP_DASH" != "true" ]]; then
  echo "▶ Running dashboard/tests/ with subprocess coverage..."
  .venv/bin/pytest --cov --cov-append --cov-report= -q dashboard/tests/
fi

# (6) merge all per-process data into one .coverage file
echo "▶ Combining coverage data..."
.venv/bin/coverage combine 2>&1 || true   # 'No data to combine' is benign

# (7) emit the XML that sonar-scanner reads
echo "▶ Generating coverage.xml..."
.venv/bin/coverage xml -o coverage.xml

# (8) human-readable summary
echo
echo "─────────────────────────────────────────"
.venv/bin/coverage report --skip-covered --skip-empty | tail -3
echo "─────────────────────────────────────────"
echo "coverage.xml ready for sonar-scanner."
