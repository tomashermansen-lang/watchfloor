"""Tests for grinder-static-partition.py (Component C1b).

Covers: ST-P01..ST-P10 from TESTPLAN.md.
"""

from __future__ import annotations

from pathlib import Path

from conftest import import_tool

partition_mod = import_tool("lib/grinder-static-partition.py")


def make_finding(
    tool: str,
    rule: str,
    file: str,
    line: int = 1,
    severity: str = "warning",
    message: str | None = None,
) -> dict:
    """Create a minimal normalised finding dict.

    If ``rule`` is already namespace-prefixed (contains ``:``), ``id`` is built
    from ``rule`` alone to avoid a double-prefix that no real normaliser
    would emit. This keeps the synthetic-input fixtures (T15-T18) coherent
    while T18b uses bare-rule input that mirrors normalise-findings.py output.
    """
    rule_for_id = rule if ":" in rule else f"{tool}:{rule}"
    return {
        "id": f"{rule_for_id}-{Path(file).name}-{'a' * 8}",
        "tool": tool,
        "rule": rule,
        "file": file,
        "line": line,
        "severity": severity,
        "message": message or f"Test finding {rule}",
        "content_hash": "a" * 8,
    }


# ---------------------------------------------------------------------------
# ST-P01: Empty allowlist — all findings proposed
# ---------------------------------------------------------------------------


def test_p01_empty_allowlist_all_proposed():
    findings = [
        make_finding("bandit", "B101", "src/app.py"),
        make_finding("semgrep", "S1481", "src/util.py"),
        make_finding("mypy", "E0602", "src/main.py"),
    ]
    result = partition_mod.partition_findings(findings, allowlist=[], never_touch=[])
    assert result["fix_count"] == 0
    assert result["propose_count"] == 3
    assert result["skip_count"] == 0
    assert len(result["fix"]) == 0
    assert len(result["propose"]) == 3


# ---------------------------------------------------------------------------
# ST-P02: Full allowlist — all findings fixable
# ---------------------------------------------------------------------------


def test_p02_full_allowlist_all_fixable():
    findings = [
        make_finding("bandit", "B101", "src/app.py"),
        make_finding("semgrep", "S1481", "src/util.py"),
        make_finding("mypy", "E0602", "src/main.py"),
    ]
    result = partition_mod.partition_findings(
        findings, allowlist=["B101", "S1481", "E0602"], never_touch=[]
    )
    assert result["fix_count"] == 3
    assert result["propose_count"] == 0
    assert result["skip_count"] == 0


# ---------------------------------------------------------------------------
# ST-P03: Mixed allowlist — some fix, some propose
# ---------------------------------------------------------------------------


def test_p03_mixed_allowlist():
    findings = [
        make_finding("bandit", "B101", "src/a.py"),
        make_finding("semgrep", "S1481", "src/b.py"),
        make_finding("mypy", "E0602", "src/c.py"),
        make_finding("bandit", "B102", "src/d.py"),
    ]
    result = partition_mod.partition_findings(findings, allowlist=["B101", "E0602"], never_touch=[])
    assert result["fix_count"] == 2
    assert result["propose_count"] == 2
    fix_rules = {f["rule"] for f in result["fix"]}
    assert fix_rules == {"B101", "E0602"}
    propose_rules = {f["rule"] for f in result["propose"]}
    assert propose_rules == {"S1481", "B102"}


# ---------------------------------------------------------------------------
# ST-P04: never_touch_files wins over allowlist
# ---------------------------------------------------------------------------


def test_p04_never_touch_wins_over_allowlist():
    findings = [
        make_finding("bandit", "B101", "tests/conftest.py"),
    ]
    result = partition_mod.partition_findings(
        findings, allowlist=["B101"], never_touch=["tests/**"]
    )
    assert result["fix_count"] == 0
    assert result["propose_count"] == 0
    assert result["skip_count"] == 1


# ---------------------------------------------------------------------------
# ST-P05: never_touch_files — no proposals for skipped files
# ---------------------------------------------------------------------------


def test_p05_never_touch_no_proposals():
    findings = [
        make_finding("bandit", "B999", "scripts/vendor_lib.py"),
    ]
    result = partition_mod.partition_findings(
        findings, allowlist=[], never_touch=["scripts/vendor*"]
    )
    assert result["skip_count"] == 1
    assert result["propose_count"] == 0


# ---------------------------------------------------------------------------
# ST-P06: Finding with missing rule field
# ---------------------------------------------------------------------------


def test_p06_missing_rule_field(capsys):
    findings = [
        {
            "tool": "bandit",
            "file": "src/a.py",
            "line": 1,
            "severity": "warning",
            "message": "bad",
            "content_hash": "x" * 8,
            "id": "bandit:X-a.py-xxxxxxxx",
        },
    ]
    result = partition_mod.partition_findings(findings, allowlist=["B101"], never_touch=[])
    assert result["skip_count"] == 1
    assert result["fix_count"] == 0
    assert result["propose_count"] == 0


# ---------------------------------------------------------------------------
# ST-P07: Same rule in multiple findings
# ---------------------------------------------------------------------------


def test_p07_same_rule_multiple_findings():
    findings = [
        make_finding("bandit", "B101", "src/a.py", line=1),
        make_finding("bandit", "B101", "src/b.py", line=5),
        make_finding("bandit", "B101", "src/c.py", line=10),
    ]
    result = partition_mod.partition_findings(findings, allowlist=["B101"], never_touch=[])
    assert result["fix_count"] == 3


# ---------------------------------------------------------------------------
# ST-P08: never_touch_files glob patterns
# ---------------------------------------------------------------------------


def test_p08_never_touch_glob_patterns():
    findings = [
        make_finding("bandit", "B101", "tests/test_a.py"),
        make_finding("mypy", "E0602", "src/conftest.py"),
        make_finding("bandit", "B102", "scripts/vendor_x.sh"),
    ]
    result = partition_mod.partition_findings(
        findings,
        allowlist=["B101", "E0602", "B102"],
        never_touch=["tests/**", "**/conftest.py", "scripts/vendor*"],
    )
    assert result["skip_count"] == 3
    assert result["fix_count"] == 0


# ---------------------------------------------------------------------------
# ST-P09: Empty never_touch — nothing skipped
# ---------------------------------------------------------------------------


def test_p09_empty_never_touch():
    findings = [
        make_finding("bandit", "B101", "src/a.py"),
        make_finding("mypy", "E0602", "src/b.py"),
        make_finding("bandit", "B102", "src/c.py"),
    ]
    result = partition_mod.partition_findings(findings, allowlist=["B101"], never_touch=[])
    assert result["skip_count"] == 0


# ---------------------------------------------------------------------------
# ST-P10: Allowlist contains unreferenced rule
# ---------------------------------------------------------------------------


def test_p10_unreferenced_allowlist_rule():
    findings = [
        make_finding("bandit", "B101", "src/a.py"),
    ]
    result = partition_mod.partition_findings(
        findings, allowlist=["B101", "NEVER_SEEN"], never_touch=[]
    )
    assert result["fix_count"] == 1


# ---------------------------------------------------------------------------
# grinder-scanner-enable: T15-T18 (synthetic-input contract for REQ-7 / AS-4)
# T18b (production-shape regression guard — PLAN.md sub-block 1.4)
# ---------------------------------------------------------------------------

REQ4_PREFIXED_ALLOWLIST = [
    "python:S1481",
    "python:S1763",
    "typescript:S1172",
    "typescript:S1854",
    "shellcheck:SC2086",
    "eslint:no-unused-vars",
    "bandit:B404",
]


def test_t15_prefixed_bandit_b404_routes_to_fix_batch():
    """T15 / REQ-7 / AS-4 — synthetic prefixed bandit:B404 routes to fix-batch.

    Synthetic-input contract: the fixture's ``rule`` field is namespace-prefixed
    so it matches the prefixed REQ-4 allowlist entry under ``grep -qxF``.
    """
    findings = [make_finding("bandit", "bandit:B404", "src/x.py")]
    result = partition_mod.partition_findings(
        findings, allowlist=REQ4_PREFIXED_ALLOWLIST, never_touch=[]
    )
    assert result["fix_count"] == 1, f"Expected fix-batch routing; got {result}"
    assert result["propose_count"] == 0


def test_t16_prefixed_bandit_b603_routes_to_proposals():
    """T16 / REQ-7 / AS-4 (EC-B3) — non-allowlisted prefixed rule routes to proposals."""
    findings = [make_finding("bandit", "bandit:B603", "src/x.py")]
    result = partition_mod.partition_findings(
        findings, allowlist=REQ4_PREFIXED_ALLOWLIST, never_touch=[]
    )
    assert result["propose_count"] == 1, f"Expected proposals routing; got {result}"
    assert result["fix_count"] == 0


def test_t17_prefixed_python_s1481_routes_to_fix_batch():
    """T17 / REQ-7 / AS-4 — prefixed python:S1481 routes to fix-batch (case-sensitive)."""
    findings = [make_finding("ruff", "python:S1481", "src/x.py")]
    result = partition_mod.partition_findings(
        findings, allowlist=REQ4_PREFIXED_ALLOWLIST, never_touch=[]
    )
    assert result["fix_count"] == 1, f"Expected fix-batch routing; got {result}"


def test_t18_case_mismatch_routes_to_proposals():
    """T18 / REQ-7 / AS-4 (EC-B1) — wrong-case prefixed rule routes to proposals.

    `_static_match_allowlist` uses `grep -qxF` (fixed-string, exact line match),
    so capitalised `Python:S1481` does NOT match the lowercase allowlist entry.
    """
    findings = [make_finding("ruff", "Python:S1481", "src/x.py")]
    result = partition_mod.partition_findings(
        findings, allowlist=REQ4_PREFIXED_ALLOWLIST, never_touch=[]
    )
    assert result["propose_count"] == 1, f"Expected proposals routing; got {result}"
    assert result["fix_count"] == 0


def test_t18b_bare_rule_id_routes_to_proposals():
    """T18b — production-shape regression guard for PLAN.md sub-block 1.4 disclosure.

    `normalise-findings.py` emits BARE rule IDs in the `rule` field
    (verified at `normalise-findings.py:325` for bandit, `:211` for shellcheck,
    `:177` for ruff, `:351` for semgrep). The prefixed allowlist entries
    therefore cannot match production findings under `grep -qxF`, so a bare
    `B404` finding routes to proposals.md even though the allowlist names
    `bandit:B404`.

    Locks the documented prefix-mismatch as a regression contract until
    upstream resolution. See `docs/INPROGRESS_Feature_grinder-scanner-enable/PLAN.md`
    sub-block 1.4 "Production-routing prefix mismatch".
    """
    findings = [make_finding("bandit", "B404", "src/x.py")]
    result = partition_mod.partition_findings(
        findings, allowlist=REQ4_PREFIXED_ALLOWLIST, never_touch=[]
    )
    assert result["propose_count"] == 1, (
        f"Production-shape regression: bare bandit B404 should route to proposals "
        f"(not fix-batch) because the prefixed allowlist entry 'bandit:B404' does "
        f"not exact-line-match. Got {result}."
    )
    assert result["fix_count"] == 0
