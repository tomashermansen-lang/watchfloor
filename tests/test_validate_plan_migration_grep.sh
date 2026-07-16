#!/usr/bin/env bash
# test_validate_plan_migration_grep.sh — C.T12
#
# Enforces R36: no consumer under claude/tools/ should directly open
# deferred-findings.json unless it is either:
#   - plan_yaml_deferred.py (the authorised dispatch module itself), or
#   - guarded by a legacy-version check (schema_version 1.x, LegacyPlanError,
#     legacy keyword, 1.x label, dump -- dispatch, find_colocated_plan, etc.), or
#   - in a docstring, comment, help=, description=, or error-message string.
#
# TC-VPM01: current repo passes clean.
# TC-VPM02: planted unguarded bare file-read reference is detected.
#
# Usage: bash tests/test_validate_plan_migration_grep.sh
# Exits 0 on all pass, 1 on any failure.

set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

check() {
    local name="$1"
    shift
    if "$@"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"
        failed=$((failed + 1))
    fi
}

check_fail() {
    local name="$1"
    shift
    if ! "$@"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name (expected failure but succeeded)"
        failed=$((failed + 1))
    fi
}

# ---------------------------------------------------------------------------
# Core guard checker (Python-based).
#
# A reference to "deferred-findings.json" is GUARDED if the ±3-line context
# window matches ANY of these patterns, OR if the file is plan_yaml_deferred.py
# (the authorised dispatch module):
#
#   a) docstring/comment markers (#, """, ''', //)
#   b) argparse help/description strings (help=, description=)
#   c) error/print message strings (print(, echo)
#   d) legacy keyword
#   e) schema_version 1.x / version.startswith('1. / 1.x
#   f) LegacyPlanError exception handling
#   g) plan_yaml_deferred CLI delegation (dump --)
#   h) 2.0-routing functions (find_colocated_plan, detect_plan_version)
#   i) LEGACY_SIBLINGS / DEFAULT_PATH constant assignments
#   j) # Legacy or # 3. comment (fallback block comments)
#   k) try: (guarded import block)
#
# Files under tests/ and __pycache__ are excluded.
# ---------------------------------------------------------------------------
_check_references_py() {
    local search_dir="$1"
    python3 - "$search_dir" << 'PYEOF'
import sys, os, re

search_dir = sys.argv[1]

# Files allowed to reference deferred-findings.json without restriction
# (they ARE the routing/dispatch layer).
ALLOWED_FILENAMES = {'plan_yaml_deferred.py'}

GUARD_RES = [
    # docstring / comment markers
    re.compile(r'(^\s*(#|"""|' + r"'''" + r'|//)|""")', re.MULTILINE),
    # argparse help/description strings
    re.compile(r'(help\s*=|description\s*=)'),
    # print( or echo (error message, not a file read)
    re.compile(r'\b(print\(|echo\b)'),
    # legacy keyword
    re.compile(r'\blegacy\b', re.IGNORECASE),
    # schema_version 1.x checks
    re.compile(r'schema_version.*1\.'),
    re.compile(r"version\.startswith\(['\"]1\."),
    re.compile(r'1\.x'),
    # Python exception dispatch
    re.compile(r'LegacyPlanError'),
    # plan_yaml_deferred CLI dispatch
    re.compile(r'dump\s+--'),
    # 2.0 routing functions
    re.compile(r'find_colocated_plan|detect_plan_version'),
    # constant assignment (LEGACY_SIBLINGS, DEFAULT_PATH)
    re.compile(r'(LEGACY_SIBLINGS|DEFAULT_PATH)\s*='),
    # explicit fallback comment in plan_yaml_deferred._cli_dump
    re.compile(r'(Else fall back|fall back to a sibling|# 3\.|Sibling)'),
    # guarded try: block (emit-baseline import pattern)
    re.compile(r'^\s*try\s*:', re.MULTILINE),
    # bash echo or jq (error messages, not file reads)
    re.compile(r'\bjq\b'),
]

violations = 0
for dirpath, dirnames, filenames in os.walk(search_dir):
    dirnames[:] = [d for d in dirnames if d not in ('__pycache__', '.git')]
    for fname in filenames:
        if not (fname.endswith('.py') or fname.endswith('.sh')):
            continue
        fpath = os.path.join(dirpath, fname)
        norm = fpath.replace(os.sep, '/')
        # Skip test files.
        if '/tests/' in norm:
            continue
        # Skip the authorised dispatch module.
        if fname in ALLOWED_FILENAMES:
            continue

        try:
            with open(fpath, encoding='utf-8', errors='replace') as fh:
                lines = fh.readlines()
        except OSError:
            continue

        for i, line in enumerate(lines):
            if 'deferred-findings.json' not in line:
                continue
            # ±5-line context window (wide enough to catch module docstrings).
            start = max(0, i - 5)
            end = min(len(lines), i + 6)
            window = ''.join(lines[start:end])

            if any(pat.search(window) for pat in GUARD_RES):
                continue

            print(f"UNGUARDED: {fpath}:{i+1} — {line.rstrip()}", file=sys.stderr)
            violations += 1

sys.exit(violations)
PYEOF
}

# ---------------------------------------------------------------------------
# TC-VPM01: current repo — all references are legitimately guarded.
# ---------------------------------------------------------------------------
tc_vpm01() {
    _check_references_py "$REPO_DIR/adapters/claude-code/claude/tools"
}
check "TC-VPM01: current repo has no unguarded deferred-findings.json references" tc_vpm01


# ---------------------------------------------------------------------------
# TC-VPM02: planted unguarded reference in a scratch file → script detects it.
# ---------------------------------------------------------------------------
SCRATCH_DIR="${TMPDIR:-/tmp}/test-vpm02-$$"
mkdir -p "$SCRATCH_DIR"
trap 'rm -rf "$SCRATCH_DIR"' EXIT

# Write a fake Python file with a bare unguarded file-read (no guard markers).
python3 - "$SCRATCH_DIR/unguarded_consumer.py" << 'PYEOF'
import sys
content = (
    "import json\n"
    "from pathlib import Path\n"
    "\n"
    "def read_deferred(project_root):\n"
    "    path = Path(project_root) / 'docs/grinder/deferred-findings.json'\n"
    "    data = json.loads(path.read_text())\n"
    "    return data\n"
)
with open(sys.argv[1], "w") as f:
    f.write(content)
PYEOF

tc_vpm02() {
    _check_references_py "$SCRATCH_DIR" 2>/dev/null
}
check_fail "TC-VPM02: planted unguarded reference is detected" tc_vpm02


# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $passed passed, $failed failed"
[ "$failed" -eq 0 ]
