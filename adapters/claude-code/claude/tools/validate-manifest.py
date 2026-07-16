#!/usr/bin/env python3
"""Validate a pipeline manifest (pipeline.yaml).

Two validation layers (matching validate-plan.py pattern):
1. validate_structural(grinder, schema) — JSON Schema checks
2. validate_semantic(grinder, toolchain) — cross-validation, at-least-one checks

Usage: python3 validate-manifest.py <pipeline.yaml path or project dir>
Exit 0 on valid (or no grinder block), exit 1 on errors.

Migrated 2026-04-29 from CLAUDE.md regex parsing — pipeline manifest
now lives in standalone pipeline.yaml at project root.
"""
import json
import sys
from pathlib import Path

import yaml

# Allow ``import schema_paths`` from ``claude/tools/lib`` regardless of how
# this script is invoked. Tests load this module via importlib so the file's
# parent dir is not always on sys.path.
_LIB_DIR = Path(__file__).resolve().parent / "lib"
if str(_LIB_DIR) not in sys.path:
    sys.path.insert(0, str(_LIB_DIR))

import schema_paths  # noqa: E402

# Tool name mapping: grinder key -> toolchain name
TOOL_NAME_MAP = {"sonarqube": "sonar-scanner"}

# Fixed keys in sub-blocks (not language commands)
COVERAGE_FIXED_KEYS = {"target_project_wide", "target_per_commit", "exclude_paths", "exclude_patterns"}
FINDINGS_NON_TOOL_KEYS = {"fix_rules_allowlist", "never_touch_files"}
DEPS_FIXED_KEYS = {"severity_gate", "suggest_only_gate", "never_auto_upgrade", "exclude_deps"}

# Toolchain categories that contain executable tools
EXECUTABLE_CATEGORIES = {"python", "node", "infra"}


def _resolve_pipeline_path(arg: str) -> Path:
    """Accept either a pipeline.yaml path or a project directory."""
    p = Path(arg)
    if p.is_dir():
        return p / "pipeline.yaml"
    return p


def _parse_pipeline_block(pipeline_yaml_path: str) -> dict:
    """Load pipeline.yaml and return the parsed dict.

    Returns empty dict if file does not exist (caller decides what to do).
    Raises ValueError on malformed YAML.
    """
    path = _resolve_pipeline_path(pipeline_yaml_path)
    if not path.is_file():
        return {}

    with open(path) as f:
        try:
            parsed = yaml.safe_load(f)
        except yaml.YAMLError as e:
            raise ValueError(f"Malformed YAML in {path}: {e}")

    if not isinstance(parsed, dict):
        return {}
    return parsed


def parse_grinder_block(pipeline_yaml_path: str) -> dict | None:
    """Extract the grinder block from pipeline.yaml.

    Returns None if no grinder block found.
    """
    pipeline = _parse_pipeline_block(pipeline_yaml_path)
    if not pipeline:
        return None

    grinder = pipeline.get("grinder")
    if grinder is None:
        return None

    if not isinstance(grinder, dict):
        return None

    return grinder


def parse_toolchain_block(pipeline_yaml_path: str) -> dict:
    """Extract the toolchain block from pipeline.yaml.

    Returns dict of {category: [tool_names]}.
    Returns empty dict if no toolchain block.
    """
    pipeline = _parse_pipeline_block(pipeline_yaml_path)
    toolchain = pipeline.get("toolchain")
    if not isinstance(toolchain, dict):
        return {}

    result = {}
    for category, tools in toolchain.items():
        if isinstance(tools, list):
            result[category] = [str(t) for t in tools]
        elif isinstance(tools, str):
            result[category] = [tools]
    return result


def validate_structural(grinder: dict, schema_path: Path) -> list[str]:
    """Validate grinder dict against JSON Schema.

    Returns list of error strings with field paths.
    """
    import jsonschema

    with open(schema_path) as f:
        schema = json.load(f)

    errors = []
    validator = jsonschema.Draft202012Validator(schema)
    for error in sorted(validator.iter_errors(grinder), key=lambda e: list(e.path)):
        path = ".".join(str(p) for p in error.absolute_path)
        field = f"grinder.{path}" if path else "grinder"
        errors.append(f"{field}: {error.message}")

    return errors


def _check_min_keys(block: dict | None, fixed_keys: set, field: str, label: str) -> str | None:
    """Check that a sub-block has at least one key beyond its fixed keys."""
    if not isinstance(block, dict):
        return None
    dynamic_keys = {k for k in block if k not in fixed_keys}
    if not dynamic_keys:
        return f"grinder.{field}: at least one {label} required"
    return None


def _collect_toolchain_tools(toolchain: dict) -> set[str]:
    """Collect all executable tool names from toolchain categories."""
    tools = set()
    for category, names in toolchain.items():
        if category in EXECUTABLE_CATEGORIES:
            tools.update(names)
    return tools


def _check_findings_cross_validation(findings: dict | None, toolchain_tools: set[str]) -> list[str]:
    """Check that all findings tools are declared in the toolchain."""
    errors = []
    if not isinstance(findings, dict):
        return errors
    for key in findings:
        if key in FINDINGS_NON_TOOL_KEYS:
            continue
        toolchain_name = TOOL_NAME_MAP.get(key, key)
        if toolchain_name not in toolchain_tools:
            errors.append(f"grinder.findings.{key}: not declared in pipeline.toolchain")
    return errors


def validate_semantic(grinder: dict, toolchain: dict) -> list[str]:
    """Validate semantic rules not expressible in JSON Schema.

    Checks:
    - Coverage: at least one language command when present
    - Findings: at least one tool when present
    - Dependencies: at least one language command when present
    - Cross-validation: all grinder tools exist in toolchain
    """
    errors = []

    err = _check_min_keys(grinder.get("coverage"), COVERAGE_FIXED_KEYS, "coverage", "language command")
    if err:
        errors.append(err)

    err = _check_min_keys(grinder.get("findings"), FINDINGS_NON_TOOL_KEYS, "findings", "tool")
    if err:
        errors.append(err)

    err = _check_min_keys(grinder.get("dependencies"), DEPS_FIXED_KEYS, "dependencies", "language command")
    if err:
        errors.append(err)

    toolchain_tools = _collect_toolchain_tools(toolchain)
    errors.extend(_check_findings_cross_validation(grinder.get("findings"), toolchain_tools))

    return errors


def main():
    import argparse

    parser = argparse.ArgumentParser(
        prog="validate-manifest.py",
        description="Validate a pipeline.yaml manifest (grinder block + structural).",
    )
    parser.add_argument(
        "pipeline_path",
        metavar="PIPELINE",
        help="Path to pipeline.yaml or project directory containing pipeline.yaml",
    )
    parser.add_argument(
        "--parse-grinder",
        action="store_true",
        dest="parse_grinder",
        help="Emit the grinder block as JSON to stdout and exit",
    )

    args = parser.parse_args()
    pipeline_path = args.pipeline_path

    resolved = _resolve_pipeline_path(pipeline_path)
    if not resolved.exists():
        print(f"ERROR: pipeline.yaml not found at {resolved}", file=sys.stderr)
        sys.exit(1)

    if args.parse_grinder:
        try:
            grinder = parse_grinder_block(pipeline_path)
        except ValueError as e:
            print(str(e), file=sys.stderr)
            sys.exit(1)
        if grinder is None:
            print("No grinder block found in pipeline.yaml", file=sys.stderr)
            sys.exit(1)
        json.dump(grinder, sys.stdout, indent=2)
        print()  # trailing newline
        sys.exit(0)

    # Schema path: resolved via lib/schema_paths.py (probes deployed
    # ``~/.claude/schema/`` first, falls back to ``<monorepo>/core/schema/``).
    schema_path = schema_paths.schema_path("manifest.schema.json")

    try:
        grinder = parse_grinder_block(pipeline_path)
    except ValueError as e:
        print(str(e))
        sys.exit(1)

    if grinder is None:
        print("No grinder block found.")
        sys.exit(0)

    toolchain = parse_toolchain_block(pipeline_path)

    structural_errors = validate_structural(grinder, schema_path)
    semantic_errors = validate_semantic(grinder, toolchain)

    all_errors = structural_errors + semantic_errors
    if all_errors:
        for err in all_errors:
            print(err)
        sys.exit(1)

    print("Valid.")
    sys.exit(0)


if __name__ == "__main__":
    main()
