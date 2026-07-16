#!/usr/bin/env python3
"""Normalise native scanner output into a unified JSON schema.

Reads scanner output from stdin, translates through a tool-specific adapter,
and emits a unified JSON array to stdout.

Usage:
    normalise-findings.py --tool <tool_name> [--project-root <path>]

Supported tools: ruff, shellcheck, eslint, mypy, tsc, bandit, semgrep,
pip-audit, npm-audit.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
from collections.abc import Callable
from pathlib import Path
from typing import TypedDict

# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------


class RawFinding(TypedDict):
    """Adapter output: partial finding before enrichment."""

    file: str | None
    line: int
    rule: str
    message: str
    severity: str


class Finding(TypedDict):
    """Enriched finding with all unified schema fields."""

    id: str
    tool: str
    rule: str
    file: str
    line: int
    severity: str
    message: str
    content_hash: str


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------


class ParseError(Exception):
    """Raised when adapter cannot parse scanner output."""


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_ERR_EXPECTED_JSON_ARRAY = "expected JSON array"
_DEFAULT_PIP_MANIFEST = "requirements.txt"
_DEFAULT_NPM_MANIFEST = "package.json"


# ---------------------------------------------------------------------------
# C13: Path Normalisation
# ---------------------------------------------------------------------------


def normalise_path(file_path: str, project_root: str) -> str:
    """Convert absolute or ./-prefixed path to project-root-relative."""
    if file_path.startswith("./"):
        file_path = file_path[2:]
    resolved_root = os.path.realpath(project_root)
    if os.path.isabs(file_path):
        resolved_file = os.path.realpath(file_path)
        if resolved_file.startswith(resolved_root + os.sep):
            return resolved_file[len(resolved_root) + 1 :]
        if resolved_file == resolved_root:
            return "."
    return file_path


def normalise_path_with_check(file_path: str, project_root: str) -> tuple[str, bool]:
    """Normalise path and check containment. Returns (path, escaped)."""
    normalised = normalise_path(file_path, project_root)
    resolved_root = os.path.realpath(project_root)
    resolved_file = os.path.realpath(os.path.join(project_root, normalised))
    escaped = (
        not resolved_file.startswith(resolved_root + os.sep) and resolved_file != resolved_root
    )
    return normalised, escaped


# ---------------------------------------------------------------------------
# C12: Content-Hash
# ---------------------------------------------------------------------------


def compute_content_hash(
    file_path: str,
    line: int,
    project_root: str,
    tool: str,
    rule: str,
) -> str:
    """Compute 8-char hex SHA-256 of a 5-line window centered on line."""
    fallback_input = f"{tool}:{rule}:{file_path}:{line}"

    resolved_root = os.path.realpath(project_root)
    abs_path = os.path.realpath(os.path.join(project_root, file_path))

    # Path containment check
    if not abs_path.startswith(resolved_root + os.sep) and abs_path != resolved_root:
        print(
            f"WARNING: path {file_path} escapes project root — using fallback",
            file=sys.stderr,
        )
        return hashlib.sha256(fallback_input.encode("utf-8")).hexdigest()[:8]

    try:
        content = Path(abs_path).read_text(encoding="utf-8", errors="replace")
    except OSError:
        print(
            f"WARNING: cannot read {file_path} for content-hash — using fallback",
            file=sys.stderr,
        )
        return hashlib.sha256(fallback_input.encode("utf-8")).hexdigest()[:8]

    lines = content.splitlines()

    if not lines:
        return hashlib.sha256(b"").hexdigest()[:8]

    # Clamp line to file length
    if line > len(lines):
        print(
            f"WARNING: {file_path}:{line} exceeds file length ({len(lines)}) — clamping to last line",
            file=sys.stderr,
        )
        line = len(lines)

    # 0-indexed center
    center = line - 1
    start = max(0, center - 2)
    end = min(len(lines), center + 3)
    window = "\n".join(lines[start:end])

    return hashlib.sha256(window.encode("utf-8")).hexdigest()[:8]


# ---------------------------------------------------------------------------
# C3: Ruff Adapter
# ---------------------------------------------------------------------------


def parse_ruff(raw: str) -> list[RawFinding]:
    """Parse ruff JSON output (bare array of violations)."""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ParseError(str(e)) from e

    if not isinstance(data, list):
        raise ParseError(_ERR_EXPECTED_JSON_ARRAY)

    findings: list[RawFinding] = []
    for v in data:
        findings.append(
            RawFinding(
                file=v["filename"],
                line=v["location"]["row"],
                rule=v["code"],
                message=v["message"],
                severity="error",
            )
        )
    return findings


# ---------------------------------------------------------------------------
# C4: Shellcheck Adapter
# ---------------------------------------------------------------------------

_SHELLCHECK_SEVERITY = {
    "error": "error",
    "warning": "warning",
    "info": "info",
    "style": "info",
}


def parse_shellcheck(raw: str) -> list[RawFinding]:
    """Parse shellcheck JSON output (bare array of comment objects)."""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ParseError(str(e)) from e

    if not isinstance(data, list):
        raise ParseError(_ERR_EXPECTED_JSON_ARRAY)

    findings: list[RawFinding] = []
    for c in data:
        findings.append(
            RawFinding(
                file=c["file"],
                line=c["line"],
                rule=f"SC{c['code']}",
                message=c["message"],
                severity=_SHELLCHECK_SEVERITY.get(c["level"], "info"),
            )
        )
    return findings


# ---------------------------------------------------------------------------
# C5: ESLint Adapter
# ---------------------------------------------------------------------------

_ESLINT_SEVERITY = {2: "error", 1: "warning"}


def parse_eslint(raw: str) -> list[RawFinding]:
    """Parse eslint JSON output (array of file objects with messages[])."""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ParseError(str(e)) from e

    if not isinstance(data, list):
        raise ParseError(_ERR_EXPECTED_JSON_ARRAY)

    findings: list[RawFinding] = []
    for file_obj in data:
        file_path = file_obj["filePath"]
        for msg in file_obj.get("messages", []):
            line = msg.get("line", 0)
            if line == 0:
                line = 1
            findings.append(
                RawFinding(
                    file=file_path,
                    line=line,
                    rule=msg.get("ruleId") or "PARSE-ERROR",
                    message=msg["message"],
                    severity=_ESLINT_SEVERITY.get(msg["severity"], "warning"),
                )
            )
    return findings


# ---------------------------------------------------------------------------
# C6: Mypy Adapter
# ---------------------------------------------------------------------------

_MYPY_RE = re.compile(r"^(.+):(\d+): (error|warning|note): (.+?)(?:\s{2}\[([A-Za-z0-9_-]+)\])?$")
_MYPY_SEVERITY = {"error": "error", "warning": "warning", "note": "info"}


def parse_mypy(raw: str) -> list[RawFinding]:
    """Parse mypy plain text output line by line."""
    findings: list[RawFinding] = []
    for line in raw.splitlines():
        m = _MYPY_RE.match(line)
        if not m:
            continue
        findings.append(
            RawFinding(
                file=m.group(1),
                line=int(m.group(2)),
                rule=m.group(5) or "UNKNOWN",
                message=m.group(4),
                severity=_MYPY_SEVERITY.get(m.group(3), "info"),
            )
        )
    return findings


# ---------------------------------------------------------------------------
# C7: TSC Adapter
# ---------------------------------------------------------------------------

_TSC_RE = re.compile(r"^(.+)\((\d+),(\d+)\): (error|warning) (TS\d+): (.+)$")
_TSC_SEVERITY = {"error": "error", "warning": "warning"}


def parse_tsc(raw: str) -> list[RawFinding]:
    """Parse tsc plain text output line by line."""
    findings: list[RawFinding] = []
    for line in raw.splitlines():
        m = _TSC_RE.match(line)
        if not m:
            continue
        findings.append(
            RawFinding(
                file=m.group(1),
                line=int(m.group(2)),
                rule=m.group(5),
                message=m.group(6),
                severity=_TSC_SEVERITY.get(m.group(4), "error"),
            )
        )
    return findings


# ---------------------------------------------------------------------------
# C8: Bandit Adapter
# ---------------------------------------------------------------------------

_BANDIT_SEVERITY = {"HIGH": "error", "MEDIUM": "warning", "LOW": "info"}


def parse_bandit(raw: str) -> list[RawFinding]:
    """Parse bandit JSON output (object with results[] array)."""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ParseError(str(e)) from e

    findings: list[RawFinding] = []
    for r in data.get("results", []):
        findings.append(
            RawFinding(
                file=r["filename"],
                line=r["line_number"],
                rule=r["test_id"],
                message=r["issue_text"],
                severity=_BANDIT_SEVERITY.get(r["issue_severity"], "info"),
            )
        )
    return findings


# ---------------------------------------------------------------------------
# C9: Semgrep Adapter
# ---------------------------------------------------------------------------

_SEMGREP_SEVERITY = {"ERROR": "error", "WARNING": "warning", "INFO": "info"}


def parse_semgrep(raw: str) -> list[RawFinding]:
    """Parse semgrep JSON output (object with results[] array)."""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ParseError(str(e)) from e

    findings: list[RawFinding] = []
    for r in data.get("results", []):
        findings.append(
            RawFinding(
                file=r["path"],
                line=r["start"]["line"],
                rule=r["check_id"],
                message=r["extra"]["message"],
                severity=_SEMGREP_SEVERITY.get(r["extra"]["severity"], "info"),
            )
        )
    return findings


# ---------------------------------------------------------------------------
# C10: pip-audit Adapter
# ---------------------------------------------------------------------------


def _pick_highest_version(versions: list[str]) -> str | None:
    """Pick the highest semver version from a list, or None if empty."""
    if not versions:
        return None
    if len(versions) == 1:
        return versions[0]

    # Sort by semver-like numeric parts (best effort)
    def _version_key(v: str) -> tuple[int, ...]:
        parts = []
        for p in v.split("."):
            digits = ""
            for c in p:
                if c.isdigit():
                    digits += c
                else:
                    break
            parts.append(int(digits) if digits else 0)
        return tuple(parts)

    return max(versions, key=_version_key)


def parse_pip_audit(raw: str) -> list[RawFinding]:
    """Parse pip-audit JSON output (object with dependencies[] array)."""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ParseError(str(e)) from e

    findings: list[RawFinding] = []
    for dep in data.get("dependencies", []):
        name = dep["name"]
        version = dep["version"]
        for vuln in dep.get("vulns", []):
            fix_versions = vuln.get("fix_versions", [])
            finding: dict = dict(
                RawFinding(
                    file=None,
                    line=1,
                    rule=vuln["id"],
                    message=f"{name} {version}: {vuln['description']}",
                    severity="critical",
                )
            )
            finding["fix_version"] = _pick_highest_version(fix_versions)
            findings.append(finding)  # type: ignore[arg-type]
    return findings


# ---------------------------------------------------------------------------
# C11: npm audit Adapter
# ---------------------------------------------------------------------------

_NPM_SEVERITY = {
    "critical": "critical",
    "high": "error",
    "moderate": "warning",
    "low": "info",
}


def parse_npm_audit(raw: str) -> list[RawFinding]:
    """Parse npm audit JSON output (object with vulnerabilities map)."""
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as e:
        raise ParseError(str(e)) from e

    findings: list[RawFinding] = []
    for pkg_name, vuln in data.get("vulnerabilities", {}).items():
        # Extract rule from via[]
        via = vuln.get("via", [])
        if via:
            first_via = via[0]
            if isinstance(first_via, dict):
                rule = first_via.get("url") or first_via.get("name", pkg_name)
            else:
                rule = str(first_via)
        else:
            rule = pkg_name

        # Extract message
        if via and isinstance(via[0], dict):
            title = via[0].get("title", "Unknown vulnerability")
        else:
            title = f"Vulnerability in {pkg_name}"
        message = f"{pkg_name}: {title}"

        # Extract fix_version from fixAvailable
        fix_available = vuln.get("fixAvailable")
        if isinstance(fix_available, dict):
            fix_version: str | None = fix_available.get("version")
        else:
            fix_version = None

        finding: dict = dict(
            RawFinding(
                file=None,
                line=1,
                rule=rule,
                message=message,
                severity=_NPM_SEVERITY.get(vuln.get("severity", "low"), "info"),
            )
        )
        finding["fix_version"] = fix_version
        findings.append(finding)  # type: ignore[arg-type]
    return findings


# ---------------------------------------------------------------------------
# C2: Adapter Registry
# ---------------------------------------------------------------------------

ADAPTER_REGISTRY: dict[str, Callable[[str], list[RawFinding]]] = {
    "ruff": parse_ruff,
    "shellcheck": parse_shellcheck,
    "eslint": parse_eslint,
    "mypy": parse_mypy,
    "tsc": parse_tsc,
    "bandit": parse_bandit,
    "semgrep": parse_semgrep,
    "pip-audit": parse_pip_audit,
    "npm-audit": parse_npm_audit,
}


# ---------------------------------------------------------------------------
# C14: Finding Enrichment
# ---------------------------------------------------------------------------


def compose_finding_id(tool: str, rule: str, basename: str, content_hash: str) -> str:
    """Compose finding_id: <tool>:<RULE_UPPER>-<basename>-<hash8>."""
    return f"{tool}:{rule.upper()}-{basename}-{content_hash}"


def _resolve_manifest(tool: str, project_root: str) -> str:
    """Resolve manifest file path for dependency-audit tools."""
    root = Path(project_root)
    if tool == "pip-audit":
        if (root / _DEFAULT_PIP_MANIFEST).exists():
            return _DEFAULT_PIP_MANIFEST
        if (root / "pyproject.toml").exists():
            return "pyproject.toml"
        print(
            f"WARNING: no pip manifest found — using {_DEFAULT_PIP_MANIFEST} as default",
            file=sys.stderr,
        )
        return _DEFAULT_PIP_MANIFEST
    if tool == "npm-audit":
        if (root / _DEFAULT_NPM_MANIFEST).exists():
            return _DEFAULT_NPM_MANIFEST
        print(
            f"WARNING: no npm manifest found — using {_DEFAULT_NPM_MANIFEST} as default",
            file=sys.stderr,
        )
        return _DEFAULT_NPM_MANIFEST
    return ""


def enrich_findings(
    raw_findings: list[RawFinding],
    tool: str,
    project_root: str,
) -> list[Finding]:
    """Add tool, content_hash, and id fields to raw findings."""
    enriched: list[Finding] = []
    manifest_cache: str | None = None

    for rf in raw_findings:
        file_path = rf["file"]

        # Resolve manifest for dependency-audit tools
        if file_path is None:
            if manifest_cache is None:
                manifest_cache = _resolve_manifest(tool, project_root)
            file_path = manifest_cache

        # Normalise path with containment check
        file_path, escaped = normalise_path_with_check(file_path, project_root)
        if escaped:
            print(
                f"WARNING: {file_path} escapes project root — path is untrusted",
                file=sys.stderr,
            )
            # Strip leading ../ sequences so output never references parent dirs
            while file_path.startswith("../"):
                file_path = file_path[3:]
            if not file_path:
                file_path = "UNTRUSTED_PATH"

        # Compute content hash
        content_hash = compute_content_hash(file_path, rf["line"], project_root, tool, rf["rule"])

        basename = os.path.basename(file_path)
        finding_id = compose_finding_id(tool, rf["rule"], basename, content_hash)

        enriched.append(
            Finding(
                id=finding_id,
                tool=tool,
                rule=rf["rule"],
                file=file_path,
                line=rf["line"],
                severity=rf["severity"],
                message=rf["message"],
                content_hash=content_hash,
            )
        )

    return enriched


# ---------------------------------------------------------------------------
# C1: CLI Entry Point
# ---------------------------------------------------------------------------

# Text-based adapters that treat empty input as zero findings (not malformed)
_TEXT_ADAPTERS = {"mypy", "tsc"}


def main() -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(description="Normalise scanner output to unified JSON schema.")
    parser.add_argument(
        "--tool",
        required=True,
        help="Scanner tool name",
    )
    parser.add_argument(
        "--project-root",
        default=".",
        help="Project root for path normalisation and content-hash (default: .)",
    )
    args = parser.parse_args()

    if args.tool not in ADAPTER_REGISTRY:
        print(
            f"normalise: unknown tool: {args.tool}",
            file=sys.stderr,
        )
        return 1

    raw_input = sys.stdin.read()

    # Empty stdin handling
    if not raw_input.strip():
        if args.tool in _TEXT_ADAPTERS:
            print("[]")
            return 0
        print(
            f"normalise: failed to parse {args.tool} output",
            file=sys.stderr,
        )
        return 1

    adapter = ADAPTER_REGISTRY[args.tool]

    try:
        raw_findings = adapter(raw_input)
    except (ParseError, KeyError, TypeError, AttributeError):
        print(
            f"normalise: failed to parse {args.tool} output",
            file=sys.stderr,
        )
        return 1

    enriched = enrich_findings(raw_findings, args.tool, args.project_root)
    print(json.dumps(enriched, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
