"""Tests for the per-pass turn-budget formulas and the
mid-tool-use exhaustion WARN diagnostic.

Covers requirements R1, R2, R3, R4, R5, R6, R7 and acceptance
scenarios AS-1..AS-11 plus edge cases EC-1..EC-7 from
docs/INPROGRESS_Feature_grinder-turn-budget/REQUIREMENTS.md.

AS-12 (zero error_max_turns events on the regression fixture, R9)
is the manual Phase 3 gate documented in TESTPLAN.md § M-01.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
from pathlib import Path

import pytest
import yaml
from conftest import TOOLS_DIR, import_tool

# Reuse the existing helpers from test_grinder_discover.py — cross-test
# imports are an established pattern in the suite (see
# tests/test_consumer_2_0_routing.py).
from test_grinder_discover import default_args, make_finding, run_discover_py

LIB_DIR = TOOLS_DIR / "lib"
DISCOVER_PATH = LIB_DIR / "grinder-discover.py"
MECHANICAL_PATH = LIB_DIR / "grinder-mechanical.sh"
STATIC_PATH = LIB_DIR / "grinder-static.sh"


# ---------------------------------------------------------------------------
# In-process module loader — handles the hyphenated module name.
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def discover_module():
    """Import grinder-discover.py via importlib.

    The repo's ``conftest.import_tool`` resolves names relative to
    ``adapters/claude-code/claude/tools/`` — but the discover script
    lives one level deeper at ``lib/grinder-discover.py``. Use
    ``import_tool`` with the relative name so the helper does the
    spec_from_file_location dance for us.
    """
    return import_tool("lib/grinder-discover.py")


# ===========================================================================
# C1 — compute_estimated_turns (pure arithmetic)
# ===========================================================================


class TestComputeEstimatedTurns:
    """Direct unit tests on compute_estimated_turns(kind, total_findings).

    Covers T-01..T-16 from TESTPLAN.md § Coverage Matrix.
    """

    # --- mechanical formula: max(8, min(40, N+5)) ---
    # Ceiling raised 25→40 and headroom 3→5 on 2026-05-12 after pass-mechanical
    # batches 3, 4, 5, 7 saturated the prior ceiling (claude needs ~1.5-2 turns
    # per finding + 5-7 turns overhead; 25 was too tight for batches with 12+
    # findings). Floor unchanged.

    def test_mechanical_n0_returns_floor_8(self, discover_module):
        # T-01: EC-1 — empty batch pins to floor.
        assert discover_module.compute_estimated_turns("mechanical", 0) == 8

    def test_mechanical_n5_mid_range(self, discover_module):
        # T-02: AS-1 — 5+5=10 (just above floor with new headroom).
        assert discover_module.compute_estimated_turns("mechanical", 5) == 10

    def test_mechanical_n12_mid_range(self, discover_module):
        # T-03: AS-2 — 12+5=17.
        assert discover_module.compute_estimated_turns("mechanical", 12) == 17

    def test_mechanical_n22_mid_range(self, discover_module):
        # T-04: 22+5=27 (room above the old 25 ceiling).
        assert discover_module.compute_estimated_turns("mechanical", 22) == 27

    def test_mechanical_n35_just_below_ceiling(self, discover_module):
        # T-05a: 35+5=40 hits the new ceiling exactly.
        assert discover_module.compute_estimated_turns("mechanical", 35) == 40

    def test_mechanical_n50_ceiling_clamp(self, discover_module):
        # T-05: AS-3 — 50+5=55 clamps to 40.
        assert discover_module.compute_estimated_turns("mechanical", 50) == 40

    def test_mechanical_n100_ceiling_clamp(self, discover_module):
        # T-06: EC-3 — far past the ceiling break-even.
        assert discover_module.compute_estimated_turns("mechanical", 100) == 40

    # --- static formula: max(10, min(50, 2N+6)) ---
    # Ceiling raised 30→50 and headroom 4→6 on 2026-05-12 paralleling the
    # mechanical bump. Floor and multiplier unchanged.

    def test_static_n0_returns_floor_10(self, discover_module):
        # T-07: EC-1.
        assert discover_module.compute_estimated_turns("static_analysis", 0) == 10

    def test_static_n1_floor_pin(self, discover_module):
        # T-08: AS-4 — 2*1+6=8 floors to 10.
        assert discover_module.compute_estimated_turns("static_analysis", 1) == 10

    def test_static_n2_floor_still(self, discover_module):
        # T-09: 2*2+6=10 just hits the floor.
        assert discover_module.compute_estimated_turns("static_analysis", 2) == 10

    def test_static_n10_mid_range(self, discover_module):
        # T-10: AS-5 — 2*10+6=26.
        assert discover_module.compute_estimated_turns("static_analysis", 10) == 26

    def test_static_n13_mid_range(self, discover_module):
        # T-11: 2*13+6=32 (room above the old 30 ceiling).
        assert discover_module.compute_estimated_turns("static_analysis", 13) == 32

    def test_static_n22_just_below_ceiling(self, discover_module):
        # T-11a: 2*22+6=50 hits the new ceiling exactly.
        assert discover_module.compute_estimated_turns("static_analysis", 22) == 50

    def test_static_n30_ceiling_clamp(self, discover_module):
        # T-12: AS-6 — 2*30+6=66 clamps to 50.
        assert discover_module.compute_estimated_turns("static_analysis", 30) == 50

    def test_static_n50_ceiling_clamp(self, discover_module):
        # T-13: EC-3 — far past the ceiling break-even.
        assert discover_module.compute_estimated_turns("static_analysis", 50) == 50

    # --- coverage: fixed at COVERAGE_ESTIMATED_TURNS = 15 ---

    def test_coverage_n0_returns_15(self, discover_module):
        # T-14: AS-7.
        assert discover_module.compute_estimated_turns("coverage", 0) == 15

    def test_coverage_n_irrelevant(self, discover_module):
        # T-15: per R3, coverage budget is fixed irrespective of N.
        assert discover_module.compute_estimated_turns("coverage", 999) == 15

    # --- cve: fixed at CVE_ESTIMATED_TURNS = 15 (R3 — pre-task behaviour) ---

    def test_cve_n0_returns_15(self, discover_module):
        # R3 guard: cve passes retain the existing fixed budget. Without
        # this branch a future caller would crash on ValueError, breaking
        # the implicit contract the dispatch satisfies today.
        assert discover_module.compute_estimated_turns("cve", 0) == 15

    def test_cve_n_irrelevant(self, discover_module):
        # cve.sh ignores the passed-in budget; the value here is purely
        # the YAML-side number. N is not consulted.
        assert discover_module.compute_estimated_turns("cve", 50) == 15

    # --- defensive: unknown kind ---

    def test_unknown_kind_raises_valueerror(self, discover_module):
        # T-16: defensive raise — message contract preserved.
        with pytest.raises(ValueError, match="unknown pass kind"):
            discover_module.compute_estimated_turns("nonsense_kind", 5)


# ===========================================================================
# C2 — Module-level constants (R4)
# ===========================================================================


class TestNamedConstants:
    """Asserts the seven new constants exist with the documented values.

    Covers T-17..T-26 from TESTPLAN.md.
    """

    def test_mechanical_floor(self, discover_module):
        # T-17.
        assert discover_module.MECHANICAL_TURNS_FLOOR == 8

    def test_mechanical_ceiling(self, discover_module):
        # T-18: raised 25→40 on 2026-05-12 (pass-mechanical batch saturation).
        assert discover_module.MECHANICAL_TURNS_CEILING == 40

    def test_mechanical_headroom(self, discover_module):
        # T-19: raised 3→5 on 2026-05-12 (more cushion for read→fix→test→commit).
        assert discover_module.MECHANICAL_TURNS_HEADROOM == 5

    def test_static_floor(self, discover_module):
        # T-20.
        assert discover_module.STATIC_TURNS_FLOOR == 10

    def test_static_ceiling(self, discover_module):
        # T-21: raised 30→50 on 2026-05-12 (parallels mechanical bump).
        assert discover_module.STATIC_TURNS_CEILING == 50

    def test_static_multiplier(self, discover_module):
        # T-22.
        assert discover_module.STATIC_TURNS_MULTIPLIER == 2

    def test_static_headroom(self, discover_module):
        # T-23: raised 4→6 on 2026-05-12.
        assert discover_module.STATIC_TURNS_HEADROOM == 6

    def test_legacy_constants_removed(self, discover_module):
        # T-24: MIN_TURNS / MAX_TURNS no longer exist on the module.
        assert not hasattr(discover_module, "MIN_TURNS")
        assert not hasattr(discover_module, "MAX_TURNS")

    def test_coverage_constant_retained(self, discover_module):
        # T-25.
        assert discover_module.COVERAGE_ESTIMATED_TURNS == 15

    def test_cve_constant_present(self, discover_module):
        # R3 guard: a named CVE_ESTIMATED_TURNS preserves the
        # pre-task fixed budget for cve batches. Asserted explicitly so
        # a silent rename or removal trips the test.
        assert discover_module.CVE_ESTIMATED_TURNS == 15

    def test_staleness_buffer_retained(self, discover_module):
        # T-26 — guards against unintended collateral damage.
        assert discover_module.STALENESS_BUFFER == 5

    def test_grep_gate_replicated(self):
        # T-27: same regex the Phase 1 gate uses; ≥7 matches expected.
        result = subprocess.run(
            [
                "grep",
                "-cE",
                "^(MECHANICAL_TURNS|STATIC_TURNS)",
                str(DISCOVER_PATH),
            ],
            capture_output=True,
            text=True,
        )
        # `grep -c` exits 0 with a count when matches found.
        assert result.returncode == 0, f"grep stderr: {result.stderr}"
        assert int(result.stdout.strip()) >= 7


# ===========================================================================
# C3 + C4 — discover round-trip: build_batches_for_files + build_coverage_pass
# ===========================================================================


def _single_pass_batch(plan: dict, kind: str) -> dict:
    """Return the single batch of the named pass — fails loud if not found."""
    pass_obj = next(p for p in plan["passes"] if p["kind"] == kind)
    assert len(pass_obj["batches"]) == 1, (
        f"expected exactly one batch in {kind}, got {len(pass_obj['batches'])}"
    )
    batch: dict = pass_obj["batches"][0]
    return batch


class TestDiscoverIntegration:
    """End-to-end: synthetic findings JSON → grinder-plan.yaml → assert.

    Covers T-28..T-36.
    """

    def test_mechanical_floor_round_trip(self, tmp_path):
        # T-28: AS-1 — 5 ruff findings on 5 files (one per file → 1 batch
        # at the default batch_size=5) → 5+5=10.
        findings = [make_finding("ruff", f"R{i:03d}", f"f{i}.py") for i in range(5)]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        assert _single_pass_batch(plan, "mechanical")["estimated_turns"] == 10

    def test_mechanical_mid_round_trip(self, tmp_path):
        # T-29: AS-2 — 12 ruff findings on a single file → 12+5=17.
        findings = [make_finding("ruff", f"R{i:03d}", "single.py") for i in range(12)]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        assert _single_pass_batch(plan, "mechanical")["estimated_turns"] == 17

    def test_mechanical_ceiling_round_trip(self, tmp_path):
        # T-30: AS-3 — 50 ruff findings on a single file → 55 clamped to 40.
        findings = [make_finding("ruff", f"R{i:03d}", "single.py") for i in range(50)]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        assert _single_pass_batch(plan, "mechanical")["estimated_turns"] == 40

    def test_static_floor_round_trip(self, tmp_path):
        # T-31: AS-4 — 1 mypy finding → 2*1+6=8 floors to 10.
        findings = [make_finding("mypy", "E001", "src/x.py")]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        assert _single_pass_batch(plan, "static_analysis")["estimated_turns"] == 10

    def test_static_mid_round_trip(self, tmp_path):
        # T-32: AS-5 — 10 mypy findings on a single file → 2*10+6=26.
        findings = [make_finding("mypy", f"E{i:03d}", "src/x.py") for i in range(10)]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        assert _single_pass_batch(plan, "static_analysis")["estimated_turns"] == 26

    def test_static_ceiling_round_trip(self, tmp_path):
        # T-33: AS-6 — 30 mypy findings on a single file → 66 clamped to 50.
        findings = [make_finding("mypy", f"E{i:03d}", "src/x.py") for i in range(30)]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        assert _single_pass_batch(plan, "static_analysis")["estimated_turns"] == 50

    def test_unknown_tool_falls_through_to_static(self, tmp_path):
        # T-34: EC-4 — unknown tool → static_analysis kind (existing
        # SCANNER_TO_KIND fallback) → uses the new R2 formula.
        findings = [make_finding("future-unknown-tool", f"E{i:03d}", "src/x.py") for i in range(10)]
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        batch = _single_pass_batch(plan, "static_analysis")
        # 2*10+6=26 — proves the fallback inherits the static formula.
        assert batch["estimated_turns"] == 26

    def test_coverage_round_trip_unchanged(self, tmp_path):
        # T-35: AS-7 — coverage batches still report 15.
        findings = [make_finding("ruff", "R001", "f.py")]  # required for non-empty
        coverage_files = json.dumps({"src/a.ts": 0.3, "src/b.ts": 0.7})
        result = run_discover_py(
            *default_args(tmp_path),
            "--coverage-files",
            coverage_files,
            findings_data=findings,
            tmp_path=tmp_path,
        )
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        cov_pass = next(p for p in plan["passes"] if p["kind"] == "coverage")
        for batch in cov_pass["batches"]:
            assert batch["estimated_turns"] == 15

    def test_regenerate_produces_in_range_budgets(self, tmp_path):
        # T-36: AS-11 / R7 — mechanical batches in [8, 40], static in [10, 50].
        findings = []
        # mix of mechanical (ruff) and static (mypy) findings, varied counts
        for i in range(7):
            findings.append(make_finding("ruff", f"R{i}", f"m{i}.py"))
        for i in range(15):
            findings.append(make_finding("mypy", f"E{i}", f"s{i}.py"))
        result = run_discover_py(*default_args(tmp_path), findings_data=findings, tmp_path=tmp_path)
        assert result.exit_code == 0, f"stderr: {result.stderr}"
        plan = yaml.safe_load((tmp_path / "grinder" / "grinder-plan.yaml").read_text())
        mech = next(p for p in plan["passes"] if p["kind"] == "mechanical")
        static = next(p for p in plan["passes"] if p["kind"] == "static_analysis")
        for batch in mech["batches"]:
            assert 8 <= batch["estimated_turns"] <= 40, batch
        for batch in static["batches"]:
            assert 10 <= batch["estimated_turns"] <= 50, batch


# ===========================================================================
# C5 — _grinder_warn_on_turns_exhaustion (bash helper)
# ===========================================================================


def _bash_call_warn(
    stream_path: Path, batch_id: str, *, env_overrides: dict | None = None
) -> subprocess.CompletedProcess:
    """Source grinder-mechanical.sh and call _grinder_warn_on_turns_exhaustion.

    Returns the CompletedProcess so callers can assert on stderr.
    """
    env = os.environ.copy()
    env["STREAM_FILE"] = str(stream_path)
    env["TOOLS_DIR"] = str(TOOLS_DIR)
    env["LIB_DIR"] = str(LIB_DIR)
    env["PROJECT_DIR"] = str(stream_path.parent)
    if env_overrides:
        env.update(env_overrides)
        if env_overrides.get("STREAM_FILE") == "":
            env.pop("STREAM_FILE", None)

    script = (
        "set -uo pipefail\n"
        f"source '{MECHANICAL_PATH}'\n"
        f"_grinder_warn_on_turns_exhaustion '{batch_id}'\n"
    )
    return subprocess.run(
        ["bash", "-c", script],
        capture_output=True,
        text=True,
        env=env,
    )


def _exhaustion_pair(batch_id: str = "batch-001") -> str:
    """A minimal stream slice that should trigger the WARN.

    Most-recent assistant has stop_reason=tool_use; most-recent result
    has subtype=error_max_turns.
    """
    return (
        "\n".join(
            [
                json.dumps({"type": "system", "subtype": "init", "session_id": "s1"}),
                json.dumps(
                    {
                        "type": "assistant",
                        "message": {"stop_reason": "tool_use", "content": []},
                    }
                ),
                json.dumps(
                    {
                        "type": "result",
                        "subtype": "error_max_turns",
                        "is_error": True,
                        "session_id": "s1",
                        "num_turns": 25,
                    }
                ),
            ]
        )
        + "\n"
    )


def _success_pair() -> str:
    """A normal-completion stream slice — no WARN expected."""
    return (
        "\n".join(
            [
                json.dumps({"type": "system", "subtype": "init", "session_id": "s1"}),
                json.dumps(
                    {
                        "type": "assistant",
                        "message": {"stop_reason": "end_turn", "content": []},
                    }
                ),
                json.dumps(
                    {
                        "type": "result",
                        "subtype": "success",
                        "is_error": False,
                        "session_id": "s1",
                        "num_turns": 5,
                    }
                ),
            ]
        )
        + "\n"
    )


def _split_pair_a() -> str:
    """error_max_turns but preceding assistant ended with end_turn — no WARN."""
    return (
        "\n".join(
            [
                json.dumps({"type": "system", "subtype": "init", "session_id": "s1"}),
                json.dumps(
                    {
                        "type": "assistant",
                        "message": {"stop_reason": "end_turn", "content": []},
                    }
                ),
                json.dumps(
                    {
                        "type": "result",
                        "subtype": "error_max_turns",
                        "is_error": True,
                        "session_id": "s1",
                        "num_turns": 30,
                    }
                ),
            ]
        )
        + "\n"
    )


def _split_pair_b() -> str:
    """assistant tool_use but result subtype=success — no WARN."""
    return (
        "\n".join(
            [
                json.dumps({"type": "system", "subtype": "init", "session_id": "s1"}),
                json.dumps(
                    {
                        "type": "assistant",
                        "message": {"stop_reason": "tool_use", "content": []},
                    }
                ),
                json.dumps(
                    {
                        "type": "result",
                        "subtype": "success",
                        "is_error": False,
                        "session_id": "s1",
                        "num_turns": 10,
                    }
                ),
            ]
        )
        + "\n"
    )


def _read_warn_lines(stream_path: Path) -> list[dict]:
    out = []
    for raw in stream_path.read_text().splitlines():
        raw = raw.strip()
        if not raw:
            continue
        try:
            evt = json.loads(raw)
        except json.JSONDecodeError:
            continue
        if evt.get("type") == "warning":
            out.append(evt)
    return out


class TestWarnEmit:
    """Bash-from-Python tests for the WARN diagnostic helper.

    Covers T-37..T-46 from TESTPLAN.md.
    """

    def test_warn_emitted_on_exhaustion_pair(self, tmp_path):
        # T-37: AS-9 — positive case.
        stream = tmp_path / "stream.ndjson"
        stream.write_text(_exhaustion_pair("batch-001"))
        proc = _bash_call_warn(stream, "batch-001")
        assert proc.returncode == 0, proc.stderr
        warns = _read_warn_lines(stream)
        assert len(warns) == 1, stream.read_text()
        warn = warns[0]
        assert warn["batch"] == "batch-001"
        assert "ended mid-tool-use" in warn["message"]
        assert "MAX_TURNS_PHASE" in warn["message"]
        # ts must be RFC3339-ish — strict: parseable by fromisoformat after
        # normalising trailing Z.
        from datetime import datetime

        ts = warn["ts"].replace("Z", "+00:00")
        datetime.fromisoformat(ts)
        # Validate the appended line via jq (T-37 strict shape check).
        if shutil.which("jq"):
            jq_proc = subprocess.run(
                ["jq", "empty", str(stream)],
                capture_output=True,
                text=True,
            )
            assert jq_proc.returncode == 0, jq_proc.stderr

    def test_no_warn_on_success(self, tmp_path):
        # T-38: AS-10 — success completion, no WARN.
        stream = tmp_path / "stream.ndjson"
        stream.write_text(_success_pair())
        proc = _bash_call_warn(stream, "batch-002")
        assert proc.returncode == 0, proc.stderr
        assert _read_warn_lines(stream) == []

    def test_no_warn_on_split_case_endturn(self, tmp_path):
        # T-39: EC-5 — error_max_turns but no preceding tool_use.
        stream = tmp_path / "stream.ndjson"
        stream.write_text(_split_pair_a())
        proc = _bash_call_warn(stream, "batch-003")
        assert proc.returncode == 0, proc.stderr
        assert _read_warn_lines(stream) == []

    def test_no_warn_on_split_case_success_with_tool_use(self, tmp_path):
        # T-40: EC-5 — tool_use but result subtype=success.
        stream = tmp_path / "stream.ndjson"
        stream.write_text(_split_pair_b())
        proc = _bash_call_warn(stream, "batch-004")
        assert proc.returncode == 0, proc.stderr
        assert _read_warn_lines(stream) == []

    def test_unset_stream_file_fail_soft(self, tmp_path):
        # T-41: EC-6 — STREAM_FILE unset → exit 0, stderr message.
        stream = tmp_path / "stream.ndjson"  # not created; not used.
        proc = _bash_call_warn(stream, "batch-005", env_overrides={"STREAM_FILE": ""})
        assert proc.returncode == 0, f"stderr: {proc.stderr}"
        assert "stream file unavailable" in proc.stderr

    def test_unwritable_stream_file_fail_soft(self, tmp_path):
        # T-42: EC-6 — STREAM_FILE itself is read-only; the helper's
        # ``[[ ! -w "$STREAM_FILE" ]]`` guard must fire and the helper
        # must NOT append a WARN line. Making the parent directory
        # read-only is insufficient because POSIX permits appends to an
        # existing file regardless of dir mode.
        stream = tmp_path / "stream.ndjson"
        stream.write_text(_exhaustion_pair("batch-006"))
        try:
            os.chmod(stream, 0o400)
            proc = _bash_call_warn(stream, "batch-006")
            assert proc.returncode == 0, proc.stderr
            # The fail-soft guard MUST fire — empty stderr is wrong here.
            assert "stream file unavailable" in proc.stderr, (
                f"expected fail-soft message, got stderr={proc.stderr!r}"
            )
        finally:
            os.chmod(stream, 0o600)
        # And the file must not have been mutated (no WARN appended).
        os.chmod(stream, 0o600)
        assert _read_warn_lines(stream) == []

    def test_empty_stream_file(self, tmp_path):
        # T-43: empty file → no WARN, exit 0.
        stream = tmp_path / "stream.ndjson"
        stream.write_text("")
        proc = _bash_call_warn(stream, "batch-007")
        assert proc.returncode == 0, proc.stderr
        assert _read_warn_lines(stream) == []

    def test_tail_window_handles_long_stream(self, tmp_path):
        # T-44: RSK-3 — 90 lines of preamble before the trigger pair.
        preamble = []
        for _ in range(30):
            preamble.append(
                json.dumps(
                    {
                        "type": "assistant",
                        "message": {"stop_reason": "tool_use", "content": []},
                    }
                )
            )
            preamble.append(
                json.dumps(
                    {
                        "type": "user",
                        "message": {"content": [{"type": "tool_result", "content": "ok"}]},
                    }
                )
            )
            preamble.append(json.dumps({"type": "system", "subtype": "tick"}))
        stream = tmp_path / "stream.ndjson"
        stream.write_text("\n".join(preamble) + "\n" + _exhaustion_pair("batch-008"))
        proc = _bash_call_warn(stream, "batch-008")
        assert proc.returncode == 0, proc.stderr
        warns = _read_warn_lines(stream)
        assert len(warns) == 1
        assert warns[0]["batch"] == "batch-008"

    def test_malformed_line_tolerance(self, tmp_path):
        # T-45: RSK-5 — truncated NDJSON line in tail.
        stream = tmp_path / "stream.ndjson"
        stream.write_text('{"type":"resul' + "\n" + _exhaustion_pair("batch-009"))
        proc = _bash_call_warn(stream, "batch-009")
        assert proc.returncode == 0, proc.stderr
        warns = _read_warn_lines(stream)
        assert len(warns) == 1, stream.read_text()
        assert warns[0]["batch"] == "batch-009"

    def test_jq_quote_safety_in_batch_id(self, tmp_path):
        # T-46: RSK-9 — batch_id with embedded quote stays valid JSON.
        stream = tmp_path / "stream.ndjson"
        stream.write_text(_exhaustion_pair('batch-evil"'))
        proc = _bash_call_warn(stream, 'batch-evil"')
        assert proc.returncode == 0, proc.stderr
        if shutil.which("jq"):
            jq_proc = subprocess.run(
                ["jq", "empty", str(stream)],
                capture_output=True,
                text=True,
            )
            assert jq_proc.returncode == 0, jq_proc.stderr
        warns = _read_warn_lines(stream)
        assert len(warns) == 1
        assert warns[0]["batch"] == 'batch-evil"'


# ===========================================================================
# C6 + C7 — wiring grep regression guards
# ===========================================================================


class TestWireUp:
    """Structural greps that verify the helper is wired into both
    execute_*_batch sites and that no shell magic numbers remain.

    Covers T-47..T-49.
    """

    def test_wired_into_mechanical(self):
        # T-47: AS-9 / RSK-6.
        result = subprocess.run(
            [
                "grep",
                "-cF",
                '_grinder_warn_on_turns_exhaustion "$batch_id"',
                str(MECHANICAL_PATH),
            ],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, result.stderr
        assert int(result.stdout.strip()) >= 1

    def test_wired_into_static(self):
        # T-48: AS-9 / RSK-6.
        result = subprocess.run(
            [
                "grep",
                "-cF",
                '_grinder_warn_on_turns_exhaustion "$batch_id"',
                str(STATIC_PATH),
            ],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0, result.stderr
        assert int(result.stdout.strip()) >= 1

    def test_no_legacy_constant_references_in_shell(self):
        # T-49: R5 — narrow check. Asserts the two removed constant
        # names (MIN_TURNS, MAX_TURNS) do not appear in either shell
        # file. This does NOT enforce a general "no numeric turn-budget
        # literals" rule — that broader check belongs in code review.
        # The test name reflects the literal coverage: legacy constants
        # only.
        result = subprocess.run(
            [
                "grep",
                "-nE",
                r"\b(MIN_TURNS|MAX_TURNS)\b",
                str(MECHANICAL_PATH),
                str(STATIC_PATH),
            ],
            capture_output=True,
            text=True,
        )
        # `grep -nE` returns 1 when no matches found — that's the desired state.
        assert result.returncode == 1, (
            f"unexpected shell references to legacy turn-budget constants:\n{result.stdout}"
        )
