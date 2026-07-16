"""Tests for grinder-cve-partition.py (Component C1).

Covers: CVE-P01..CVE-P13 from TESTPLAN.md.
"""

from __future__ import annotations

from conftest import import_tool

partition_mod = import_tool("lib/grinder-cve-partition.py")


def make_cve_finding(
    package: str,
    cve_id: str = "CVE-2024-0001",
    severity: str = "CRITICAL",
    fix_version: str | None = "1.2.4",
    current_version: str = "1.2.3",
    tool: str = "pip-audit",
) -> dict:
    """Create a minimal normalised CVE finding dict."""
    return {
        "id": f"{tool}:{cve_id}-{package}-{'a' * 8}",
        "tool": tool,
        "rule": cve_id,
        "file": package,
        "line": 1,
        "severity": severity,
        "message": f"{package} {current_version}: vulnerability",
        "content_hash": "a" * 8,
        "fix_version": fix_version,
    }


# ---------------------------------------------------------------------------
# CVE-P01: exclude_deps skipped
# ---------------------------------------------------------------------------


def test_p01_exclude_deps_skipped():
    """AS-3: excluded dependency is skipped, not fixed."""
    findings = [make_cve_finding("Z", severity="CRITICAL")]
    result = partition_mod.partition_findings(
        findings=findings,
        exclude_deps=[{"name": "Z", "reason": "pinned by upstream"}],
        never_auto_upgrade=[],
        severity_gate="HIGH",
        suggest_only_gate="MEDIUM",
    )
    assert result["skip_count"] == 1
    assert result["fix_count"] == 0
    assert result["defer_count"] == 0
    assert len(result["skip"]) == 1


# ---------------------------------------------------------------------------
# CVE-P02: never_auto_upgrade deferred
# ---------------------------------------------------------------------------


def test_p02_never_auto_upgrade_deferred():
    """AS-6: never_auto_upgrade dependency is deferred."""
    findings = [make_cve_finding("W", fix_version="2.0.1")]
    result = partition_mod.partition_findings(
        findings=findings,
        exclude_deps=[],
        never_auto_upgrade=[{"name": "W", "semver_range": ">=2.0.0"}],
        severity_gate="HIGH",
        suggest_only_gate="MEDIUM",
    )
    assert result["defer_count"] == 1
    assert result["fix_count"] == 0
    assert any("never_auto_upgrade" in d.get("reason", "") for d in result["defer"])


# ---------------------------------------------------------------------------
# CVE-P03: major bump deferred
# ---------------------------------------------------------------------------


def test_p03_major_bump_deferred():
    """AS-2: major version bump is deferred."""
    findings = [
        make_cve_finding("Y", current_version="2.0.0", fix_version="3.0.0", severity="HIGH")
    ]
    result = partition_mod.partition_findings(
        findings=findings,
        exclude_deps=[],
        never_auto_upgrade=[],
        severity_gate="HIGH",
        suggest_only_gate="MEDIUM",
    )
    assert result["defer_count"] == 1
    assert result["fix_count"] == 0
    assert any("major bump" in d.get("reason", "") for d in result["defer"])


# ---------------------------------------------------------------------------
# CVE-P04: minor/patch classified as fix
# ---------------------------------------------------------------------------


def test_p04_minor_patch_classified_as_fix():
    """AS-1: patch bump is classified as fix."""
    findings = [
        make_cve_finding("X", current_version="1.2.3", fix_version="1.2.4", severity="CRITICAL")
    ]
    result = partition_mod.partition_findings(
        findings=findings,
        exclude_deps=[],
        never_auto_upgrade=[],
        severity_gate="HIGH",
        suggest_only_gate="MEDIUM",
    )
    assert result["fix_count"] == 1
    assert len(result["fix"]) == 1


# ---------------------------------------------------------------------------
# CVE-P05: no fix version deferred
# ---------------------------------------------------------------------------


def test_p05_no_fix_version_deferred():
    """EC-2.1: no fix version available is deferred."""
    findings = [make_cve_finding("A", fix_version=None, severity="HIGH")]
    result = partition_mod.partition_findings(
        findings=findings,
        exclude_deps=[],
        never_auto_upgrade=[],
        severity_gate="HIGH",
        suggest_only_gate="MEDIUM",
    )
    assert result["defer_count"] == 1
    assert any("no fix version" in d.get("reason", "") for d in result["defer"])


# ---------------------------------------------------------------------------
# CVE-P06: pre-release deferred
# ---------------------------------------------------------------------------


def test_p06_pre_release_deferred():
    """EC-3.2: pre-release fix version is deferred."""
    findings = [make_cve_finding("B", fix_version="2.0.0-rc1", severity="CRITICAL")]
    result = partition_mod.partition_findings(
        findings=findings,
        exclude_deps=[],
        never_auto_upgrade=[],
        severity_gate="HIGH",
        suggest_only_gate="MEDIUM",
    )
    assert result["defer_count"] == 1
    assert any("pre-release" in d.get("reason", "") for d in result["defer"])


# ---------------------------------------------------------------------------
# CVE-P07: severity below suggest gate skipped
# ---------------------------------------------------------------------------


def test_p07_severity_below_suggest_gate_skip():
    """REQ-1 rule 7: severity below suggest_only_gate is skipped."""
    findings = [make_cve_finding("C", severity="LOW")]
    result = partition_mod.partition_findings(
        findings=findings,
        exclude_deps=[],
        never_auto_upgrade=[],
        severity_gate="HIGH",
        suggest_only_gate="MEDIUM",
    )
    assert result["skip_count"] == 1
    assert result["fix_count"] == 0
    assert result["suggest_count"] == 0


# ---------------------------------------------------------------------------
# CVE-P08: severity between gates suggest
# ---------------------------------------------------------------------------


def test_p08_severity_between_gates_suggest():
    """REQ-1 rule 6: severity between gates is suggested."""
    findings = [make_cve_finding("D", severity="MEDIUM")]
    result = partition_mod.partition_findings(
        findings=findings,
        exclude_deps=[],
        never_auto_upgrade=[],
        severity_gate="HIGH",
        suggest_only_gate="MEDIUM",
    )
    assert result["suggest_count"] == 1
    assert result["fix_count"] == 0


# ---------------------------------------------------------------------------
# CVE-P09: zero vulnerabilities
# ---------------------------------------------------------------------------


def test_p09_zero_vulnerabilities():
    """AS-4: empty findings array returns all-zero counts."""
    result = partition_mod.partition_findings(
        findings=[],
        exclude_deps=[],
        never_auto_upgrade=[],
        severity_gate="HIGH",
        suggest_only_gate="MEDIUM",
    )
    assert result["fix_count"] == 0
    assert result["defer_count"] == 0
    assert result["skip_count"] == 0
    assert result["suggest_count"] == 0


# ---------------------------------------------------------------------------
# CVE-P10: conflicting fix versions deferred
# ---------------------------------------------------------------------------


def test_p10_conflicting_fix_versions_deferred():
    """EC-2.2: when one CVE needs a major bump and another a minor bump for the
    same package, the major-bump CVE is deferred individually (step 7). The
    minor-bump CVE remains fixable. True cross-finding conflicts cannot arise
    when each finding is classified independently."""
    findings = [
        make_cve_finding(
            "P",
            cve_id="CVE-2024-0001",
            fix_version="1.3.0",
            severity="CRITICAL",
            current_version="1.2.0",
        ),
        make_cve_finding(
            "P",
            cve_id="CVE-2024-0002",
            fix_version="2.0.0",
            severity="CRITICAL",
            current_version="1.2.0",
        ),
    ]
    result = partition_mod.partition_findings(
        findings=findings,
        exclude_deps=[],
        never_auto_upgrade=[],
        severity_gate="HIGH",
        suggest_only_gate="MEDIUM",
    )
    # 2.0.0 is major bump → deferred at step 7
    # 1.3.0 is minor bump → fixable
    assert result["defer_count"] == 1
    assert result["fix_count"] == 1


# ---------------------------------------------------------------------------
# CVE-P11: exclude_deps precedence
# ---------------------------------------------------------------------------


def test_p11_exclude_deps_precedence():
    """REQ-4 > REQ-1: exclude_deps wins over all other classifications."""
    findings = [make_cve_finding("Q", severity="CRITICAL")]
    result = partition_mod.partition_findings(
        findings=findings,
        exclude_deps=[{"name": "Q", "reason": "pinned"}],
        never_auto_upgrade=[{"name": "Q", "semver_range": ">=1.0.0"}],
        severity_gate="HIGH",
        suggest_only_gate="MEDIUM",
    )
    assert result["skip_count"] == 1
    assert result["defer_count"] == 0


# ---------------------------------------------------------------------------
# CVE-P12: multiple CVEs same package — highest fix version used
# ---------------------------------------------------------------------------


def test_p12_multiple_cves_same_pkg_highest():
    """EC-2.2: multiple compatible CVEs for same package use highest fix version."""
    findings = [
        make_cve_finding(
            "R",
            cve_id="CVE-2024-0001",
            fix_version="1.3.0",
            severity="CRITICAL",
            current_version="1.2.0",
        ),
        make_cve_finding(
            "R",
            cve_id="CVE-2024-0002",
            fix_version="1.4.0",
            severity="CRITICAL",
            current_version="1.2.0",
        ),
    ]
    result = partition_mod.partition_findings(
        findings=findings,
        exclude_deps=[],
        never_auto_upgrade=[],
        severity_gate="HIGH",
        suggest_only_gate="MEDIUM",
    )
    assert result["fix_count"] == 2
    # All findings for R should be marked with the highest fix version
    for f in result["fix"]:
        assert f.get("resolved_version") == "1.4.0"


# ---------------------------------------------------------------------------
# CVE-P13: severity ordering
# ---------------------------------------------------------------------------


def test_p13_severity_ordering():
    """REQ-1: CRITICAL and HIGH are fix candidates, MEDIUM is suggest, LOW is skip."""
    findings = [
        make_cve_finding("A", severity="CRITICAL"),
        make_cve_finding("B", severity="HIGH"),
        make_cve_finding("C", severity="MEDIUM"),
        make_cve_finding("D", severity="LOW"),
    ]
    result = partition_mod.partition_findings(
        findings=findings,
        exclude_deps=[],
        never_auto_upgrade=[],
        severity_gate="HIGH",
        suggest_only_gate="MEDIUM",
    )
    assert result["fix_count"] == 2
    assert result["suggest_count"] == 1
    assert result["skip_count"] == 1
