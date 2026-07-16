#!/usr/bin/env bash
# test-schema-sync.sh — monorepo schema-sync presence check (post-T2 layout).
#
# T2 deleted the vendored dashboard/schema/ directory and moved the canonical
# schema to <monorepo>/core/schema/. This script enforces that layout:
#   - dashboard/schema/ must NOT exist (T-SC-2: drift detection)
#   - core/schema/execution-plan.schema.json must exist (T-SC-1)
#   - the SKIP prologue from T2 must be gone (T-SC-3: structural self-check)
#
# Usage: bash dashboard/tests/test-schema-sync.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MONOREPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CORE_SCHEMA="$MONOREPO_ROOT/core/schema/execution-plan.schema.json"
DASHBOARD_SCHEMA_DIR="$MONOREPO_ROOT/dashboard/schema"
SELF="$MONOREPO_ROOT/dashboard/tests/test-schema-sync.sh"

# T-SC-1: core/schema/execution-plan.schema.json present
if [ ! -f "$CORE_SCHEMA" ]; then
  echo "FAIL: monorepo schema not found: $CORE_SCHEMA"
  echo "  T2 should have moved the canonical schema here; check core/schema/."
  exit 1
fi

# T-SC-2: dashboard/schema/ absent — vendored copy must not reappear
if [ -d "$DASHBOARD_SCHEMA_DIR" ]; then
  echo "FAIL: stale vendored schema directory found: $DASHBOARD_SCHEMA_DIR"
  echo "  T2 deleted it; a re-creation indicates drift back toward the pre-merge layout."
  exit 1
fi

# T-SC-3: this script's own short-circuit prologue from T2 must be gone
# (T2 prepended `echo "SKIP: ..."; exit 0` ahead of any real logic)
if head -5 "$SELF" | grep -qE '^echo "SKIP[^"]*";?[[:space:]]*$|^exit 0$'; then
  if head -5 "$SELF" | grep -q 'echo "SKIP'; then
    echo "FAIL: T2 SKIP prologue still present in $SELF"
    exit 1
  fi
fi

echo "schema sync: monorepo layout ok"
exit 0
