#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Plan Helpers Unit Tests ==="

cd "$PROJECT_ROOT"
python3 -m pytest tests/test_plan_helpers.py -v

echo "All plan helper tests passed."
