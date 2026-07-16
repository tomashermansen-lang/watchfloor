#!/usr/bin/env bash
# get-findings.sh — Run a scanner, normalise output, filter deferred findings.
#
# Usage:
#   get-findings.sh [--no-filter] <tool> <scanner-command...>
#
# Flags:
#   --no-filter  Skip deferred-findings filtering (emit all normalised findings).
#                Used by commit-preflight --ratchet to get the full unfiltered set.
#
# Environment overrides:
#   PROJECT_ROOT           — project root for path normalisation (default: git root or .)
#   DEFERRED_FINDINGS_PATH — path to deferred-findings.json (default: <root>/docs/grinder/deferred-findings.json)
#
# stdout: JSON array of normalised findings (filtered or unfiltered).
# stderr: diagnostic messages and audit trail.
# Exit 0 on success, 1 on fatal error.

set -euo pipefail

# ── Parse optional flags ──
NO_FILTER=false
if [ "${1:-}" = "--no-filter" ]; then
    NO_FILTER=true
    shift
fi

# ── Usage guard ──
if [ "$#" -lt 2 ]; then
    echo "Usage: get-findings.sh [--no-filter] <tool> <scanner-command...>" >&2
    exit 1
fi

TOOL="$1"
shift

# ── Resolve SCRIPT_DIR (REQ-13) ──
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Verify sibling scripts exist
if [ ! -f "$SCRIPT_DIR/normalise-findings.py" ]; then
    echo "get-findings: normalise-findings.py not found at $SCRIPT_DIR" >&2
    exit 1
fi
if [ ! -f "$SCRIPT_DIR/lib/filter-deferred.py" ]; then
    echo "get-findings: filter-deferred.py not found at $SCRIPT_DIR/lib" >&2
    exit 1
fi

# ── Resolve PROJECT_ROOT (REQ-7) ──
if [ -z "${PROJECT_ROOT:-}" ]; then
    PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || echo ".")"
fi

# ── Resolve DEFERRED_FINDINGS_PATH (REQ-8) ──
DEFERRED_PATH="${DEFERRED_FINDINGS_PATH:-$PROJECT_ROOT/docs/grinder/deferred-findings.json}"

# ── Temp file with cleanup trap ──
TMPFILE=$(mktemp "${TMPDIR:-/tmp}/get-findings-XXXXXX")
trap 'rm -f "$TMPFILE" "$TMPFILE.err"' EXIT INT TERM HUP

# ── Execute scanner command (REQ-5: accept non-zero exit) ──
# Scanner stderr captured to $TMPFILE.err — surfaced on normaliser failure (lines 56-60)
"$@" > "$TMPFILE" 2>"$TMPFILE.err" || true

# ── Normalise ──
NORMALISED=$(python3 "$SCRIPT_DIR/normalise-findings.py" --tool "$TOOL" --project-root "$PROJECT_ROOT" < "$TMPFILE") || {
    echo "get-findings: normaliser failed for tool=$TOOL" >&2
    if [ -s "$TMPFILE.err" ]; then
        echo "get-findings: scanner stderr follows:" >&2
        cat "$TMPFILE.err" >&2
    fi
    exit 1
}

# ── Filter deferred findings (skip if --no-filter) ──
if [ "$NO_FILTER" = "true" ]; then
    echo "$NORMALISED"
else
    echo "$NORMALISED" | python3 "$SCRIPT_DIR/lib/filter-deferred.py" --deferred "$DEFERRED_PATH" || {
        echo "get-findings: filter-deferred failed" >&2
        exit 1
    }
fi
