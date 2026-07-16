"""Unit tests for ``claude/tools/lib/plan_yaml_deferred.py``."""
from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
LIB_DIR = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "lib"
sys.path.insert(0, str(LIB_DIR))

import plan_yaml_deferred as pyd  # noqa: E402


def _write_2_0_plan(path: Path, deferred: list[dict] | None = None) -> Path:
    src = REPO_ROOT / "tests" / "fixtures" / "plan-2.0.0" / "minimal.yaml"
    plan = yaml.safe_load(src.read_text())
    if deferred is not None:
        plan["deferred"] = deferred
    path.write_text(yaml.safe_dump(plan, sort_keys=False))
    return path


def _write_1_x_plan(path: Path) -> Path:
    plan = {
        "schema_version": "1.4.0",
        "name": "legacy",
        "phases": [{"id": "p1", "name": "P1", "tasks": []}],
    }
    path.write_text(yaml.safe_dump(plan, sort_keys=False))
    return path


def test_detect_plan_version_2_0(tmp_path):
    p = _write_2_0_plan(tmp_path / "execution-plan.yaml")
    assert pyd.detect_plan_version(p) == "2.0"


def test_detect_plan_version_1_x(tmp_path):
    p = _write_1_x_plan(tmp_path / "execution-plan.yaml")
    assert pyd.detect_plan_version(p) == "1.x"


def test_detect_plan_version_missing(tmp_path):
    assert pyd.detect_plan_version(tmp_path / "absent.yaml") is None


def test_find_colocated_plan_walks_up(tmp_path):
    plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_x"
    plan_dir.mkdir(parents=True)
    p = _write_2_0_plan(plan_dir / "execution-plan.yaml")
    nested = plan_dir / "deep" / "nest"
    nested.mkdir(parents=True)
    assert pyd.find_colocated_plan(nested) == p


def test_read_deferred_returns_entries(tmp_path):
    entry = pyd.make_future_enhancement_entry(
        id="FE-1", date="2026-04-26", description="x"
    )
    p = _write_2_0_plan(tmp_path / "execution-plan.yaml", [entry])
    assert pyd.read_deferred(p) == [entry]


def test_read_deferred_kind_filter(tmp_path):
    a = pyd.make_future_enhancement_entry(id="FE-1", date="2026-04-26", description="x")
    b = pyd.make_scope_decision_entry(
        id="SD-1", date="2026-04-26", decided_at_task_id="t",
        decision="dismissed", rationale="ok",
    )
    p = _write_2_0_plan(tmp_path / "execution-plan.yaml", [a, b])
    assert pyd.read_deferred(p, kind_filter="scope_decision") == [b]


def test_read_deferred_legacy_raises(tmp_path):
    p = _write_1_x_plan(tmp_path / "execution-plan.yaml")
    with pytest.raises(pyd.LegacyPlanError):
        pyd.read_deferred(p)


def test_write_deferred_round_trips(tmp_path):
    p = _write_2_0_plan(tmp_path / "execution-plan.yaml", [])
    entry = pyd.make_future_enhancement_entry(
        id="FE-1", date="2026-04-26", description="x"
    )
    pyd.write_deferred(p, [entry])
    assert pyd.read_deferred(p) == [entry]
    plan = yaml.safe_load(p.read_text())
    # Other top-level fields preserved.
    assert plan["name"] == "minimal-fixture"
    assert plan["schema_version"] == "2.0.0"
    assert plan["phases"][0]["id"] == "foundation"


def test_write_deferred_rejects_short_reason(tmp_path):
    p = _write_2_0_plan(tmp_path / "execution-plan.yaml", [])
    with pytest.raises(pyd.SchemaViolation):
        pyd.write_deferred(p, [{
            "id": "x", "kind": "code_finding",
            "finding_id": "dotfiles:abcdef12",
            "rule": "ruff:E501",
            "file": "x.py", "line": 1,
            "state": "Deferred",
            "reason": "too short",
            "owner": "lead-dev",
            "reviewed_at": "2026-04-26T08:00:00Z",
            "review_trigger": "may-defer-autolog",
        }])


def test_write_deferred_rejects_symlink(tmp_path):
    p = _write_2_0_plan(tmp_path / "execution-plan.yaml", [])
    link = tmp_path / "link.yaml"
    link.symlink_to(p)
    with pytest.raises(pyd.SecurityError):
        pyd.write_deferred(link, [])


def test_append_deferred_dedupes_by_id(tmp_path):
    p = _write_2_0_plan(tmp_path / "execution-plan.yaml", [])
    entry = pyd.make_future_enhancement_entry(id="X", date="2026-04-26", description="x")
    assert pyd.append_deferred(p, entry) is True
    assert pyd.append_deferred(p, entry) is False


def test_make_factories_set_kind():
    cf = pyd.make_code_finding_entry(
        id="x", finding_id="dotfiles:abcdef12", rule="r", file="f", line=1,
        state="Deferred",
        reason="forty plus character reason content for the deferred entry coverage",
        owner="lead-dev", reviewed_at="2026-04-26T08:00:00Z",
        review_trigger="may-defer-autolog",
    )
    assert cf["kind"] == "code_finding"
    rs = pyd.make_review_suggestion_entry(
        id="r", date="2026-04-26", feature_or_task_id="f", phase_id="p",
        reviewer="architect", category="SOLID", description="d",
        reason_deferred="forty plus character reason content for the deferred entry coverage",
    )
    assert rs["kind"] == "review_suggestion"
    sd = pyd.make_scope_decision_entry(
        id="s", date="2026-04-26", decided_at_task_id="t",
        decision="dismissed", rationale="r",
    )
    assert sd["kind"] == "scope_decision"
    fe = pyd.make_future_enhancement_entry(id="f", date="2026-04-26", description="d")
    assert fe["kind"] == "future_enhancement"


def test_cli_dump_yaml_plan(tmp_path, capsys):
    entry = pyd.make_future_enhancement_entry(id="FE", date="2026-04-26", description="x")
    p = _write_2_0_plan(tmp_path / "execution-plan.yaml", [entry])
    rc = pyd.main(["dump", "--", str(p)])
    captured = capsys.readouterr()
    assert rc == 0
    assert json.loads(captured.out) == [entry]


def test_cli_dump_rejects_metacharacters(capsys):
    rc = pyd.main(["dump", "--", "$(echo PWNED)"])
    captured = capsys.readouterr()
    assert rc == 2
    assert "shell metacharacters" in captured.err


def test_cli_dump_rejects_out_of_boundary(tmp_path, capsys):
    rc = pyd.main(["dump", "--", "/etc"])
    captured = capsys.readouterr()
    assert rc == 2
    assert "trust boundary" in captured.err


def test_dump_rejects_large_json_file(tmp_path, capsys):
    """Size-limit test for fix #12: .json file > 10 MB is rejected with exit 2."""
    big_json = tmp_path / "deferred-findings.json"
    # Write 12 MB of data (exceeds MAX_JSON_SIZE = 10 MB)
    big_json.write_bytes(b"x" * (12 * 1024 * 1024))
    rc = pyd.main(["dump", "--", str(big_json)])
    captured = capsys.readouterr()
    assert rc == 2, f"expected exit 2 for oversized file, got {rc}"
    assert "size limit" in captured.err or "exceeds" in captured.err


def test_validate_plan_rejects_metachar_argv(tmp_path):
    """Covers fix #11: validate-plan.py rejects metachar in argv path, exits non-zero."""
    import subprocess
    validate_plan = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "validate-plan.py"
    proc = subprocess.run(
        ["python3", str(validate_plan), "$(evil)"],
        capture_output=True,
        text=True,
    )
    assert proc.returncode != 0, "validate-plan.py must exit non-zero for metachar path"
    assert "metachar" in proc.stderr or "shell" in proc.stderr or "control" in proc.stderr
