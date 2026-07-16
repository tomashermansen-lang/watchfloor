"""Parse a project's `pipeline.yaml` manifest.

Replaces the previous regex-based extraction from CLAUDE.md (an embedded YAML
block that was self-described as 'parser is regex-based — keep indentation
strict'). As of 2026-04-29 each project owns a `pipeline.yaml` at its root.
No fallback to CLAUDE.md — full migration. See dotfiles BACKLOG and the
migration commit for rationale.

Emits pipe-delimited records that bash callers consume line-by-line:

    TOOLCHAIN|<category>|<tool>      # one per declared tool
    SMOKE|<command>                  # one per smoke_test entry
    INTEGRATION|<command>            # one per integration_test command
    INTEGRATION_TRIGGER|<glob>       # one per integration_test.trigger glob (object form)
    INTEGRATION_SERVICE|<name>|<start_cmd>|<health_cmd>
                                     # one per integration_test.services entry (object form);
                                     # start_cmd / health_cmd empty when omitted (fixed 4-field arity)
    INTEGRATION_ORACLE|<glob>        # one per integration_test.oracle_globs entry (object form);
                                     # the test/oracle files WORM-locked during remediation (Guard #2)
    CONTRACT_TEST|<path>             # contracts: test paths
    CONTRACT_GREP|<pattern>          # contracts: grep + source + max_value
    CONTRACT_SOURCE|<glob>
    CONTRACT_MAX|<value>
    PRECONDITION|<kind>|<param1>=<value1>;<param2>=<value2>;...

Usage:
    python3 -m lib.manifest_parser <path-to-pipeline.yaml-or-project-dir>

If a directory is supplied, the parser appends `/pipeline.yaml`.

Exit codes:
    0 — file parsed successfully
    0 — pipeline.yaml not found (silent no-op, mirrors prior behaviour for
        projects that have no pipeline manifest yet)
    1 — pipeline.yaml exists but is malformed YAML
"""
from __future__ import annotations

import sys
from collections.abc import Iterable
from pathlib import Path

import yaml


def resolve_pipeline_path(arg: Path) -> Path:
    """Accept either a pipeline.yaml path or a project directory."""
    if arg.is_dir():
        return arg / "pipeline.yaml"
    return arg


def _integration_records(integration_test: object) -> Iterable[str]:
    """Yield INTEGRATION|/INTEGRATION_TRIGGER|/INTEGRATION_SERVICE| records.

    Accepts both manifest forms (real integration gates §4.1):
      - legacy flat list of command strings, OR
      - object {commands: [...], trigger: [...], services: [{name, start_cmd?,
        health_cmd?}]}.
    The flat list is treated as the object form with no trigger and no
    services, so the legacy detection-half shape is byte-identical.
    """
    if isinstance(integration_test, dict):
        commands = integration_test.get("commands") or []
        triggers = integration_test.get("trigger") or []
        services = integration_test.get("services") or []
        oracle_globs = integration_test.get("oracle_globs") or []
    else:
        commands = integration_test or []
        triggers = []
        services = []
        oracle_globs = []

    for cmd in commands:
        if isinstance(cmd, str) and cmd.strip():
            yield f"INTEGRATION|{cmd.strip()}"
    for glob in triggers:
        if isinstance(glob, str) and glob.strip():
            yield f"INTEGRATION_TRIGGER|{glob.strip()}"
    for glob in oracle_globs:
        if isinstance(glob, str) and glob.strip():
            yield f"INTEGRATION_ORACLE|{glob.strip()}"
    for svc in services:
        if not isinstance(svc, dict):
            continue
        name = svc.get("name")
        if not (isinstance(name, str) and name.strip()):
            continue  # nameless service is unactionable (schema rejects it too)
        start = (svc.get("start_cmd") or "").strip()
        health = (svc.get("health_cmd") or "").strip()
        yield f"INTEGRATION_SERVICE|{name.strip()}|{start}|{health}"


def parse_records(manifest: dict) -> Iterable[str]:
    """Yield pipe-delimited records from a parsed pipeline.yaml dict."""
    # Toolchain
    toolchain = manifest.get("toolchain", {}) or {}
    for category, tools in toolchain.items():
        if not isinstance(tools, list):
            continue
        for tool in tools:
            if isinstance(tool, str) and tool:
                yield f"TOOLCHAIN|{category}|{tool}"

    # Smoke test commands
    for cmd in manifest.get("smoke_test", []) or []:
        if isinstance(cmd, str) and cmd.strip():
            yield f"SMOKE|{cmd.strip()}"

    # Integration surface — run UNSANDBOXED by the orchestrator integration
    # gate. Hosts suites that can't run inside the agent sandbox (e.g.
    # git-fixture / server-bound dashboard suites). See run_integration_gate
    # in claude-session-lib.sh. Two manifest forms (real integration gates
    # §4.1): a legacy flat array of commands, or an object declaring
    # commands + trigger globs (§5) + services (§6a Guard #4). Backward
    # compatible — the flat array is the object form with no trigger/services.
    yield from _integration_records(manifest.get("integration_test"))

    # Contracts (mixed: test entries OR grep/source/max_value entries)
    for entry in manifest.get("contracts", []) or []:
        if not isinstance(entry, dict):
            continue
        if "test" in entry:
            yield f"CONTRACT_TEST|{entry['test']}"
        if "grep" in entry:
            yield f"CONTRACT_GREP|{entry['grep']}"
        if "source" in entry:
            yield f"CONTRACT_SOURCE|{entry['source']}"
        if "max_value" in entry:
            yield f"CONTRACT_MAX|{entry['max_value']}"

    # Preconditions
    for entry in manifest.get("preconditions", []) or []:
        if not isinstance(entry, dict):
            continue
        kind = entry.get("kind")
        if not kind:
            continue
        params = sorted((k, v) for k, v in entry.items() if k != "kind")
        param_str = ";".join(f"{k}={v}" for k, v in params)
        yield f"PRECONDITION|{kind}|{param_str}"


def parse_manifest(path: Path) -> list[str]:
    """Load pipeline.yaml and return the list of records.

    Accepts either a pipeline.yaml path or a project directory (in which case
    pipeline.yaml is appended). Missing file is a silent no-op (returns empty
    list); malformed YAML raises (caller decides to fail or continue).
    """
    resolved = resolve_pipeline_path(path)
    if not resolved.is_file():
        return []
    content = resolved.read_text()
    manifest = yaml.safe_load(content)
    if not isinstance(manifest, dict):
        return []
    return list(parse_records(manifest))


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(
            "usage: manifest_parser.py <path-to-pipeline.yaml-or-project-dir>",
            file=sys.stderr,
        )
        return 2
    try:
        records = parse_manifest(Path(argv[1]))
    except yaml.YAMLError as exc:
        print(f"manifest_parser: YAML parse error: {exc}", file=sys.stderr)
        return 1
    for record in records:
        print(record)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
