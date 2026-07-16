"""Tests for validate-manifest.py.

Covers: C2-8, C4-1..C4-4 from TESTPLAN.md.
"""

from __future__ import annotations

from pathlib import Path

import yaml
from conftest import import_tool


def _write_pipeline(tmp_path: Path, content: str) -> Path:
    p = tmp_path / "pipeline.yaml"
    p.write_text(content)
    return p


# ---------------------------------------------------------------------------
# C4: validate-manifest.py smoke tests
# ---------------------------------------------------------------------------


class TestValidateManifestSmoke:
    """C4-1..C4-4: smoke tests for validate-manifest.py."""

    def test_import_has_parse_grinder_block(self) -> None:
        mod = import_tool("validate-manifest.py")
        assert hasattr(mod, "parse_grinder_block")

    def test_import_has_validate_structural(self) -> None:
        mod = import_tool("validate-manifest.py")
        assert hasattr(mod, "validate_structural")

    def test_parse_grinder_block_with_grinder_returns_dict(self, tmp_path: Path) -> None:
        content = (
            "toolchain:\n"
            "  infra: [bash]\n"
            "\n"
            "grinder:\n"
            "  languages: [python]\n"
            "  findings:\n"
            "    ruff:\n"
            "      paths: [src/]\n"
            "    fix_rules_allowlist: []\n"
            "    never_touch_files: []\n"
        )
        p = _write_pipeline(tmp_path, content)
        mod = import_tool("validate-manifest.py")
        result = mod.parse_grinder_block(str(p))
        assert isinstance(result, dict)

    def test_parse_grinder_block_without_grinder_returns_none(self, tmp_path: Path) -> None:
        content = "toolchain:\n  infra: [bash]\n"
        p = _write_pipeline(tmp_path, content)
        mod = import_tool("validate-manifest.py")
        result = mod.parse_grinder_block(str(p))
        assert result is None


# ---------------------------------------------------------------------------
# T25 — eval-scanner-enable-manifest-cross-tool-missing (REQ-1, REQ-5)
# ---------------------------------------------------------------------------


class TestValidateManifestCrossToolchain:
    """grinder-scanner-enable REQ-1 / REQ-5 / AS-1 cross-toolchain semantic check."""

    def test_findings_without_toolchain_declaration_fails(self, tmp_path: Path) -> None:
        """T25 — enabling bandit in findings without declaring it in toolchain.python
        must surface as a semantic-validation error.

        Locks the contract in `_check_findings_cross_validation`:
        every tool key in `grinder.findings` (outside FINDINGS_NON_TOOL_KEYS)
        must appear in one of the EXECUTABLE_CATEGORIES.
        """
        content = (
            "toolchain:\n"
            "  python: [mypy, ruff]\n"
            "  infra: [bash]\n"
            "\n"
            "grinder:\n"
            "  languages: [python]\n"
            "  findings:\n"
            "    bandit:\n"
            "      enabled: true\n"
            "      paths: [src/]\n"
            "    fix_rules_allowlist: []\n"
            "    never_touch_files: []\n"
        )
        p = _write_pipeline(tmp_path, content)
        mod = import_tool("validate-manifest.py")
        grinder = mod.parse_grinder_block(str(p))
        toolchain = yaml.safe_load(p.read_text())["toolchain"]
        errors = mod.validate_semantic(grinder, toolchain)
        assert any("bandit" in e and "not declared" in e for e in errors), (
            f"Expected cross-toolchain error mentioning bandit; got: {errors}"
        )

    def test_findings_with_toolchain_declaration_passes(self, tmp_path: Path) -> None:
        """Positive companion to T25 — declaring scanners in toolchain.python clears the error."""
        content = (
            "toolchain:\n"
            "  python: [mypy, ruff, bandit, semgrep]\n"
            "  infra: [bash]\n"
            "\n"
            "grinder:\n"
            "  languages: [python]\n"
            "  findings:\n"
            "    bandit:\n"
            "      enabled: true\n"
            "      paths: [src/]\n"
            "    semgrep:\n"
            "      enabled: true\n"
            "      config: auto\n"
            "      paths: [src/]\n"
            "    fix_rules_allowlist: []\n"
            "    never_touch_files: []\n"
        )
        p = _write_pipeline(tmp_path, content)
        mod = import_tool("validate-manifest.py")
        grinder = mod.parse_grinder_block(str(p))
        toolchain = yaml.safe_load(p.read_text())["toolchain"]
        errors = mod.validate_semantic(grinder, toolchain)
        cross_errors = [e for e in errors if "not declared" in e]
        assert not cross_errors, (
            f"Expected no cross-toolchain errors when scanners are declared; got: {cross_errors}"
        )
