#!/usr/bin/env bash
# Run the project test suite.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO_ROOT"

python3 -m pytest tests/ -v "$@"
