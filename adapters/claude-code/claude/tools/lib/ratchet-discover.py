#!/usr/bin/env python3
"""Discover which scanners to invoke for the ratchet.

Checks pipeline.yaml for a grinder.findings block via
validate-manifest.py --parse-grinder. Falls back to auto-detection
via shutil.which() if no manifest or parser failure.

Usage:
    ratchet-discover.py [--project-root <path>]

stdout: JSON object {"scanners": [...], "warnings": [...]}
Exit 0 always.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys

# Scanner tool definitions: tool → (command_flags, default_paths)
_SCANNER_DEFS: dict[str, tuple[list[str], list[str]]] = {
    "shellcheck": (["-f", "json"], []),
    "ruff": (["check", "--output-format", "json"], []),
    "eslint": (["--format", "json"], []),
    "mypy": ([], []),
    "tsc": (["--noEmit"], []),
}


def _run_parse_grinder(project_root: str) -> dict | None:
    """Run validate-manifest.py --parse-grinder and return parsed JSON."""
    pipeline_yaml = os.path.join(project_root, "pipeline.yaml")
    if not os.path.exists(pipeline_yaml):
        return None

    # Find validate-manifest.py relative to this script
    script_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    parser_path = os.path.join(script_dir, "validate-manifest.py")

    if not os.path.exists(parser_path):
        return None

    result = subprocess.run(
        [sys.executable, parser_path, "--parse-grinder", pipeline_yaml],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        return None

    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        return None


def _build_scanner_spec(tool: str, paths: list[str]) -> dict:
    """Build a scanner invocation spec.

    Command format: get-findings.sh --no-filter <normaliser-key> <scanner-binary> [flags] [paths]
    The tool name appears twice: first as the normaliser key, then as the scanner binary name.
    get-findings.sh must be on $PATH at runtime.
    """
    flags, default_paths = _SCANNER_DEFS.get(tool, ([], []))
    effective_paths = paths or default_paths
    command = ["get-findings.sh", "--no-filter", tool, tool] + flags + effective_paths
    return {
        "tool": tool,
        "command": command,
        "paths": effective_paths,
    }


def _discover_from_manifest(grinder_data: dict) -> list[dict]:
    """Extract scanner specs from grinder.findings block."""
    findings = grinder_data.get("findings", {})
    scanners: list[dict] = []

    for tool_name, config in findings.items():
        # Skip non-scanner keys
        if tool_name in ("fix_rules_allowlist", "never_touch_files"):
            continue
        if tool_name not in _SCANNER_DEFS:
            continue

        paths = []
        if isinstance(config, dict):
            paths = config.get("paths", [])

        scanners.append(_build_scanner_spec(tool_name, paths))

    return scanners


def _discover_auto() -> list[dict]:
    """Auto-detect available scanners via shutil.which()."""
    scanners: list[dict] = []
    for tool in _SCANNER_DEFS:
        if shutil.which(tool):
            scanners.append(_build_scanner_spec(tool, []))
    return scanners


def discover(project_root: str) -> dict:
    """Discover scanners and return {"scanners": [...], "warnings": [...]}."""
    warnings: list[str] = []
    scanners: list[dict] = []

    # Try manifest first
    try:
        grinder_data = _run_parse_grinder(project_root)
    except Exception:
        grinder_data = None

    if grinder_data and grinder_data.get("findings"):
        scanners = _discover_from_manifest(grinder_data)

    # Fall back to auto-detect if no manifest or no findings
    if not scanners:
        scanners = _discover_auto()

    if not scanners:
        warnings.append("no scanners discovered")
        print(
            "warning: no scanners discovered — ratchet will produce empty results",
            file=sys.stderr,
        )

    return {"scanners": scanners, "warnings": warnings}


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Discover scanners for the ratchet.",
    )
    parser.add_argument(
        "--project-root",
        default=".",
        help="Path to project root (default: current directory)",
    )
    args = parser.parse_args()

    result = discover(args.project_root)
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
