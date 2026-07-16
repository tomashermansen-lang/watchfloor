"""Cover 2.0-plan colocation routing for the seven legacy consumers.

These tests assert that when a sibling 2.0 ``execution-plan.yaml`` is
present, each consumer reads from / writes to ``project.deferred[]``
instead of the legacy ``deferred-findings.json``.
"""
from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
LIB_DIR = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "lib"
TOOLS_DIR = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools"
sys.path.insert(0, str(LIB_DIR))

import plan_yaml_deferred as pyd  # noqa: E402


def _write_2_0_plan(plan_dir: Path, deferred: list[dict] | None = None) -> Path:
    src = REPO_ROOT / "tests" / "fixtures" / "plan-2.0.0" / "minimal.yaml"
    plan = yaml.safe_load(src.read_text())
    if deferred is not None:
        plan["deferred"] = deferred
    plan_dir.mkdir(parents=True, exist_ok=True)
    plan_path = plan_dir / "execution-plan.yaml"
    plan_path.write_text(yaml.safe_dump(plan, sort_keys=False))
    return plan_path


def test_filter_deferred_routes_through_2_0_plan(tmp_path):
    plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_x"
    entry = pyd.make_code_finding_entry(
        id="DF-1",
        finding_id="dotfiles:abcdef12",
        rule="ruff:E501",
        file="src/x.py",
        line=10,
        state="Deferred",
        reason="forty plus character reason content for the deferred entry coverage line",
        owner="lead-dev",
        reviewed_at="2026-04-26",
        review_trigger="may-defer-autolog",
    )
    _write_2_0_plan(plan_dir, [entry])

    findings = [
        {"id": "dotfiles:abcdef12", "rule": "ruff:E501"},
        {"id": "dotfiles:other-fid", "rule": "ruff:F401"},
    ]
    fake_deferred_arg = plan_dir / "deferred-findings.json"  # need not exist
    proc = subprocess.run(
        [
            sys.executable,
            str(LIB_DIR / "filter-deferred.py"),
            "--deferred",
            str(fake_deferred_arg),
        ],
        input=json.dumps(findings),
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stderr
    out = json.loads(proc.stdout)
    # Only the non-deferred finding remains.
    assert len(out) == 1
    assert out[0]["id"] == "dotfiles:other-fid"


def test_ratchet_autolog_routes_to_yaml(tmp_path):
    plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_y"
    plan_path = _write_2_0_plan(plan_dir, [])
    findings = [
        {
            "id": "dotfiles:01234567",
            "rule": "ruff:E501",
            "file": "src/y.py",
            "line": 5,
        }
    ]
    fake_deferred_arg = plan_dir / "deferred-findings.json"
    proc = subprocess.run(
        [
            sys.executable,
            str(LIB_DIR / "ratchet-autolog.py"),
            "--deferred",
            str(fake_deferred_arg),
        ],
        input=json.dumps(findings),
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stderr
    # Entry landed in YAML, not JSON.
    assert not fake_deferred_arg.exists()
    plan = yaml.safe_load(plan_path.read_text())
    assert plan.get("deferred"), "expected deferred entry in 2.0 plan"
    assert plan["deferred"][0]["kind"] == "code_finding"
    assert plan["deferred"][0]["finding_id"] == "dotfiles:01234567"


def test_grinder_audit_routes_via_subprocess(tmp_path):
    plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_z"
    entry = pyd.make_code_finding_entry(
        id="DF-1",
        finding_id="dotfiles:abcdef12",
        rule="ruff:E501",
        file="src/x.py",
        line=10,
        state="Deferred",
        reason="forty plus character reason content for the deferred entry coverage line",
        owner="lead-dev",
        reviewed_at="2026-04-26",
        review_trigger="may-defer-autolog",
    )
    _write_2_0_plan(plan_dir, [entry])
    proc = subprocess.run(
        [sys.executable, str(TOOLS_DIR / "grinder-audit.py"), str(plan_dir)],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stderr
    assert "Deferred Findings Audit" in proc.stdout


def test_finalise_deferred_routes_to_yaml(tmp_path):
    """When a 2.0 plan is colocated, finalise-deferred writes into the YAML
    graph and never creates the legacy ``deferred-findings.json`` next to
    the grinder dir. With empty inputs the routing path runs as a no-op,
    which is the regression guard.
    """
    plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_w"
    plan_path = _write_2_0_plan(plan_dir, [])
    grinder_dir = plan_dir / "grinder"
    grinder_dir.mkdir()
    schema_dir = REPO_ROOT / "core" / "schema"
    proc = subprocess.run(
        [
            sys.executable,
            str(LIB_DIR / "finalise-deferred.py"),
            "--grinder-dir",
            str(grinder_dir),
            "--schema-dir",
            str(schema_dir),
        ],
        capture_output=True,
        text=True,
    )
    assert proc.returncode == 0, proc.stderr + proc.stdout
    legacy_json = grinder_dir / "deferred-findings.json"
    assert not legacy_json.exists(), "2.0 plan colocation must NOT write legacy JSON"
    plan = yaml.safe_load(plan_path.read_text())
    assert plan["schema_version"] == "2.0.0"
