"""Unit tests for claude/tools/lib/drift_coverage.py — E.T2 (R40).

TC-DC01: 100% coverage → pass
TC-DC02: exactly 80% coverage → pass (boundary)
TC-DC03: 79.99% (4/5 files) → fail with explicit message
TC-DC04: empty inputs → no zero-division, vacuous pass
"""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
LIB_DIR = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "lib"
sys.path.insert(0, str(LIB_DIR))

from drift_coverage import compute_drift_coverage, DRIFT_COVERAGE_THRESHOLD  # noqa: E402


class TestDriftCoverage:
    def test_tc_dc01_full_coverage_passes(self):
        """TC-DC01: all declared paths touched → 100%, pass."""
        declared = ["src/a.py", "src/b.py", "tests/test_a.py"]
        touched = ["src/a.py", "src/b.py", "tests/test_a.py", "README.md"]
        pct, passed = compute_drift_coverage(declared, touched)
        assert pct == pytest.approx(100.0)
        assert passed is True

    def test_tc_dc02_exactly_80_percent_passes(self):
        """TC-DC02: boundary — 80% coverage (4 of 5 declared) passes."""
        declared = ["a.py", "b.py", "c.py", "d.py", "e.py"]
        touched = ["a.py", "b.py", "c.py", "d.py"]  # 4/5 = 80.0%
        pct, passed = compute_drift_coverage(declared, touched)
        assert pct == pytest.approx(80.0)
        assert passed is True

    def test_tc_dc03_below_80_fails_with_message(self):
        """TC-DC03: 4/5 files covered but declared has 5+1=6, giving 4/6=66.7% → fail."""
        # Use 5 declared, 3 touched → 60% < 80% threshold.
        declared = ["a.py", "b.py", "c.py", "d.py", "e.py"]
        touched = ["a.py", "b.py", "c.py"]  # 3/5 = 60.0%
        pct, passed = compute_drift_coverage(declared, touched)
        assert pct < DRIFT_COVERAGE_THRESHOLD
        assert passed is False
        # The caller is expected to use pct to format the error message;
        # validate the helper gives enough info for the message.
        msg = f"Drift-coverage {pct:.1f}% below {DRIFT_COVERAGE_THRESHOLD:.0f}% threshold"
        assert "60.0%" in msg
        assert "80%" in msg

    def test_tc_dc03_boundary_79_point_99_fails(self):
        """TC-DC03: 79.99% edge — just below threshold fails."""
        # 79 of 100 declared paths → 79% < 80%
        declared = [f"file_{i}.py" for i in range(100)]
        touched = [f"file_{i}.py" for i in range(79)]
        pct, passed = compute_drift_coverage(declared, touched)
        assert pct == pytest.approx(79.0)
        assert passed is False

    def test_tc_dc04_empty_inputs_no_zero_division(self):
        """TC-DC04: both declared and touched are empty → vacuous 100%, pass."""
        pct, passed = compute_drift_coverage([], [])
        assert pct == pytest.approx(100.0)
        assert passed is True

    def test_tc_dc04_empty_declared_with_touched(self):
        """TC-DC04: no declared paths but files were touched → still vacuous pass."""
        pct, passed = compute_drift_coverage([], ["src/something.py"])
        assert pct == pytest.approx(100.0)
        assert passed is True

    def test_path_normalisation_strips_leading_dot_slash(self):
        """Leading ./ is stripped before comparison."""
        declared = ["./src/a.py"]
        touched = ["src/a.py"]
        pct, passed = compute_drift_coverage(declared, touched)
        assert pct == pytest.approx(100.0)
        assert passed is True
