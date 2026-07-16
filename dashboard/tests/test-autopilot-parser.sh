#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

echo "=== Autopilot Parser Unit Tests ==="

cd "$PROJECT_ROOT"
python3 -m unittest tests.test_autopilot_helpers -v

echo "All autopilot parser tests passed."
