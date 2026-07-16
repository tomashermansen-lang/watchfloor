"""Tests for finalise-deferred.py (Component C4b).

Covers: DF-01..DF-08 from TESTPLAN.md.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

import jsonschema
from conftest import SCHEMA_DIR, import_tool

deferred_mod = import_tool("lib/finalise-deferred.py")


def _load_schema(name: str) -> dict:
    return json.loads((SCHEMA_DIR / name).read_text())


def _setup_grinder(
    tmp_path: Path,
    proposals_md: str | None = None,
    cve_review_md: str | None = None,
    existing_deferred: list[dict] | None = None,
) -> tuple[Path, Path]:
    """Set up mock grinder directory."""
    grinder_dir = tmp_path / "docs" / "grinder"
    grinder_dir.mkdir(parents=True)

    if proposals_md is not None:
        (grinder_dir / "proposals.md").write_text(proposals_md)

    if cve_review_md is not None:
        (grinder_dir / "cve-review.md").write_text(cve_review_md)

    if existing_deferred is None:
        existing_deferred = []
    (grinder_dir / "deferred-findings.json").write_text(json.dumps(existing_deferred))

    return grinder_dir, SCHEMA_DIR


SAMPLE_PROPOSALS = """# Grinder Proposals

### SC2086 — claude/tools/grinder.sh:45
- **Tool:** shellcheck
- **Severity:** warning
- **Message:** Double quote to prevent globbing and word splitting
- **Batch:** batch-001
- **Date:** 2026-04-18T10:00:00Z

### SC2155 — claude/tools/lib/grinder-static.sh:12
- **Tool:** shellcheck
- **Severity:** warning
- **Message:** Declare and assign separately to avoid masking return values
- **Batch:** batch-002
- **Date:** 2026-04-18T10:05:00Z

"""

SAMPLE_CVE_REVIEW = """# CVE Review

### CVE-2024-1234 — requests (2.25.0 → 3.0.0)
- **Severity:** CRITICAL
- **Scanner:** pip-audit
- **Impact:** SSRF via crafted URL
- **Reason deferred:** Major version bump required
- **Date:** 2026-04-18T10:00:00Z

"""


# ---------------------------------------------------------------------------
# DF-01: Deferred from proposals
# ---------------------------------------------------------------------------


def test_df01_deferred_from_proposals(tmp_path: Path):
    """AS-8: static-analysis proposals become deferred entries."""
    grinder_dir, schema_dir = _setup_grinder(tmp_path, proposals_md=SAMPLE_PROPOSALS)
    result = deferred_mod.finalise_deferred(
        grinder_dir=str(grinder_dir),
        schema_dir=str(schema_dir),
    )
    assert len(result) == 2
    assert all(e["state"] == "Deferred" for e in result)
    # Each reason should reference rule and file
    reasons = [e["reason"] for e in result]
    assert any("SC2086" in r for r in reasons)
    assert any("SC2155" in r for r in reasons)


# ---------------------------------------------------------------------------
# DF-02: Deferred from cve-review
# ---------------------------------------------------------------------------


def test_df02_deferred_from_cve_review(tmp_path: Path):
    """AS-8: CVE review entries become deferred entries."""
    grinder_dir, schema_dir = _setup_grinder(tmp_path, cve_review_md=SAMPLE_CVE_REVIEW)
    result = deferred_mod.finalise_deferred(
        grinder_dir=str(grinder_dir),
        schema_dir=str(schema_dir),
    )
    assert len(result) == 1
    assert result[0]["state"] == "Deferred"
    assert "CVE-2024-1234" in result[0]["reason"]
    assert "requests" in result[0]["reason"]


# ---------------------------------------------------------------------------
# DF-03: No duplicates
# ---------------------------------------------------------------------------


def test_df03_no_duplicates(tmp_path: Path):
    """EC-8.2: existing finding_id is updated, not duplicated."""
    # First generate to get the actual finding_id
    grinder_dir, schema_dir = _setup_grinder(tmp_path, proposals_md=SAMPLE_PROPOSALS)
    first_result = deferred_mod.finalise_deferred(
        grinder_dir=str(grinder_dir),
        schema_dir=str(schema_dir),
    )
    assert len(first_result) == 2
    # Use the actual finding_id from first generation as existing
    existing_entry = dict(first_result[0])
    existing_entry["reviewed_at"] = "2026-04-17"
    existing_entry["owner"] = "previous-run"

    # Re-setup with the existing entry pre-populated
    grinder_dir2, _ = _setup_grinder(
        tmp_path / "run2",
        proposals_md=SAMPLE_PROPOSALS,
        existing_deferred=[existing_entry],
    )
    result = deferred_mod.finalise_deferred(
        grinder_dir=str(grinder_dir2),
        schema_dir=str(schema_dir),
    )
    # Should still have exactly 2 entries, not 3
    assert len(result) == 2
    # The matched entry should have updated reviewed_at
    matched = [e for e in result if e["finding_id"] == existing_entry["finding_id"]]
    assert len(matched) == 1
    assert matched[0]["owner"] == "previous-run"  # preserved from existing


# ---------------------------------------------------------------------------
# DF-04: Reason length minimum
# ---------------------------------------------------------------------------


def test_df04_reason_length_minimum(tmp_path: Path):
    """EC-8.3: every reason is at least 40 characters."""
    grinder_dir, schema_dir = _setup_grinder(
        tmp_path,
        proposals_md=SAMPLE_PROPOSALS,
        cve_review_md=SAMPLE_CVE_REVIEW,
    )
    result = deferred_mod.finalise_deferred(
        grinder_dir=str(grinder_dir),
        schema_dir=str(schema_dir),
    )
    for entry in result:
        assert len(entry["reason"]) >= 40, f"Reason too short: {entry['reason']!r}"


# ---------------------------------------------------------------------------
# DF-05: No template patterns
# ---------------------------------------------------------------------------


def test_df05_no_template_patterns(tmp_path: Path):
    """REQ-8.3: no reason starts with template patterns."""
    grinder_dir, schema_dir = _setup_grinder(
        tmp_path,
        proposals_md=SAMPLE_PROPOSALS,
        cve_review_md=SAMPLE_CVE_REVIEW,
    )
    result = deferred_mod.finalise_deferred(
        grinder_dir=str(grinder_dir),
        schema_dir=str(schema_dir),
    )
    templates = ["Pre-existing", "Legacy code", "Not changed in this PR"]
    for entry in result:
        for t in templates:
            assert not entry["reason"].startswith(t), f"Template pattern found: {entry['reason']}"


# ---------------------------------------------------------------------------
# DF-06: Empty passes
# ---------------------------------------------------------------------------


def test_df06_empty_passes(tmp_path: Path):
    """EC-8.1: no proposals, no cve-review → empty list."""
    grinder_dir, schema_dir = _setup_grinder(tmp_path)
    result = deferred_mod.finalise_deferred(
        grinder_dir=str(grinder_dir),
        schema_dir=str(schema_dir),
    )
    assert result == []


# ---------------------------------------------------------------------------
# DF-07: Finding ID format
# ---------------------------------------------------------------------------


def test_df07_finding_id_format(tmp_path: Path):
    """REQ-8: every finding_id matches the schema pattern."""
    grinder_dir, schema_dir = _setup_grinder(
        tmp_path,
        proposals_md=SAMPLE_PROPOSALS,
        cve_review_md=SAMPLE_CVE_REVIEW,
    )
    result = deferred_mod.finalise_deferred(
        grinder_dir=str(grinder_dir),
        schema_dir=str(schema_dir),
    )
    pattern = re.compile(r"^[a-z0-9-]+:[A-Z0-9]+-[^-]+-[a-f0-9]{8}$")
    for entry in result:
        assert pattern.match(entry["finding_id"]), f"Invalid finding_id: {entry['finding_id']}"


# ---------------------------------------------------------------------------
# DF-08: Schema valid
# ---------------------------------------------------------------------------


def test_df08_schema_valid(tmp_path: Path):
    """REQ-8: deferred-findings.json validates against schema."""
    grinder_dir, schema_dir = _setup_grinder(
        tmp_path,
        proposals_md=SAMPLE_PROPOSALS,
        cve_review_md=SAMPLE_CVE_REVIEW,
    )
    result = deferred_mod.finalise_deferred(
        grinder_dir=str(grinder_dir),
        schema_dir=str(schema_dir),
    )
    schema = _load_schema("deferred-findings.schema.json")
    jsonschema.validate(result, schema, format_checker=jsonschema.FormatChecker())
