"""TC-VP30: regression guard — validate-plan.py must not emit duplicate error strings.

Runs validate-plan.py against the missing-what.yaml negative fixture and asserts
each error string in the output appears exactly once. This guards against overlap
between the jsonschema structural validator and validate_2_0_completeness().
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from conftest import REPO_ROOT, run_tool

FIXTURE = REPO_ROOT / "tests" / "fixtures" / "plan-2.0.0" / "missing-what.yaml"


def test_no_duplicate_error_strings():
    """TC-VP30: each error line in validate-plan.py output appears exactly once."""
    assert FIXTURE.exists(), f"Fixture not found: {FIXTURE}"

    result = run_tool("validate-plan.py", str(FIXTURE))

    # The fixture has an empty `what` — the validator should exit non-zero.
    assert result.exit_code != 0, (
        f"Expected non-zero exit for missing-what fixture, got 0.\n"
        f"stdout: {result.stdout}\nstderr: {result.stderr}"
    )

    # Collect all non-blank output lines (errors appear on stdout or stderr).
    output_lines = [
        line.strip() for line in (result.stdout + result.stderr).splitlines() if line.strip()
    ]

    # Group by line content and find duplicates.
    seen: dict[str, int] = {}
    for line in output_lines:
        seen[line] = seen.get(line, 0) + 1

    duplicates = {line: count for line, count in seen.items() if count > 1}
    assert not duplicates, (
        "Duplicate error strings found (jsonschema vs completeness overlap):\n"
        + "\n".join(f"  [{count}x] {line}" for line, count in duplicates.items())
    )
