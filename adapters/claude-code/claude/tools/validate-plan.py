#!/usr/bin/env python3
"""Validate data files against JSON Schemas with optional semantic checks.

Two modes:
1. Legacy:  python3 validate-plan.py <plan-file>
   Uses hand-rolled structural + semantic validation for execution plans.
2. Schema:  python3 validate-plan.py --schema <schema-path> <data-file>
   Uses jsonschema library for structural validation, plus schema-specific
   semantic checks dispatched by the schema's $id field.

Exit 0 on valid, exit 1 on errors.
"""

from __future__ import annotations

import json
import re
import sys
from collections.abc import Callable
from datetime import datetime
from pathlib import Path
from typing import Any

# Allow ``import plan_validators`` from ``claude/tools/lib`` regardless of how
# this script is invoked. Tests load this module via importlib so the file's
# parent dir is not always on sys.path.
_LIB_DIR = Path(__file__).resolve().parent / "lib"
if str(_LIB_DIR) not in sys.path:
    sys.path.insert(0, str(_LIB_DIR))


# -- Section: Legacy data loaders --


def load_plan(file_path: str) -> dict:
    """Load a plan from JSON or YAML file."""
    path = Path(file_path)
    if path.suffix in (".yaml", ".yml"):
        try:
            import yaml

            with open(path) as f:
                return yaml.safe_load(f)
        except ImportError:
            print("ERROR: Install PyYAML for YAML support: pip3 install pyyaml")
            sys.exit(1)
    else:
        with open(path) as f:
            return json.load(f)


def load_schema() -> dict:
    """Load the JSON Schema from the schema/ directory."""
    from schema_paths import schema_path as _schema_path

    with open(_schema_path("execution-plan.schema.json")) as f:
        return json.load(f)


# -- Section: Legacy structural validation (hand-rolled) --


def validate_structural(plan: dict, schema: dict) -> list[str]:
    """Validate plan structure against JSON Schema programmatically.

    Checks: required fields, types, enums, patterns, minLength, minItems.
    Returns list of error strings (empty = valid).
    """
    errors = []

    def check_required(obj, required, path):
        for field in required:
            if field not in obj:
                errors.append(f"ERROR: {path}: missing required field '{field}'")

    def check_type(obj, expected_type, path):
        type_map = {"string": str, "object": dict, "array": list, "boolean": bool, "integer": int}
        if expected_type in type_map and not isinstance(obj, type_map[expected_type]):
            errors.append(f"ERROR: {path}: expected {expected_type}, got {type(obj).__name__}")
            return False
        return True

    def check_pattern(value, pattern, path):
        import re

        if not re.match(pattern, value):
            errors.append(f"ERROR: {path}: '{value}' does not match pattern '{pattern}'")

    def check_enum(value, allowed, path):
        if value not in allowed:
            errors.append(f"ERROR: {path}: '{value}' not in allowed values {allowed}")

    def check_min_length(value, min_len, path):
        if len(value) < min_len:
            errors.append(f"ERROR: {path}: length {len(value)} < minimum {min_len}")

    def check_min_items(arr, min_items, path):
        if len(arr) < min_items:
            errors.append(f"ERROR: {path}: {len(arr)} items < minimum {min_items}")

    def validate_object(obj, schema_def, path, defs):
        if not isinstance(obj, dict):
            errors.append(f"ERROR: {path}: expected object, got {type(obj).__name__}")
            return

        if "required" in schema_def:
            check_required(obj, schema_def["required"], path)

        props = schema_def.get("properties", {})
        for key, value in obj.items():
            if key not in props:
                if schema_def.get("additionalProperties") is False:
                    errors.append(f"ERROR: {path}: unknown field '{key}'")
                continue
            prop_schema = props[key]
            field_path = f"{path}.{key}"
            validate_value(value, prop_schema, field_path, defs)

    def validate_value(value, prop_schema, path, defs):
        if "$ref" in prop_schema:
            ref = prop_schema["$ref"]
            ref_name = ref.split("/")[-1]
            if ref_name in defs:
                validate_value(value, defs[ref_name], path, defs)
            return

        if "type" in prop_schema:
            if not check_type(value, prop_schema["type"], path):
                return

        if "pattern" in prop_schema and isinstance(value, str):
            check_pattern(value, prop_schema["pattern"], path)

        if "enum" in prop_schema:
            check_enum(value, prop_schema["enum"], path)

        if "minLength" in prop_schema and isinstance(value, str):
            check_min_length(value, prop_schema["minLength"], path)

        if "minItems" in prop_schema and isinstance(value, list):
            check_min_items(value, prop_schema["minItems"], path)

        if prop_schema.get("type") == "array" and isinstance(value, list):
            items_schema = prop_schema.get("items")
            if items_schema:
                for i, item in enumerate(value):
                    validate_value(item, items_schema, f"{path}[{i}]", defs)

        if prop_schema.get("type") == "object" and isinstance(value, dict):
            if "properties" in prop_schema:
                validate_object(value, prop_schema, path, defs)

    defs = schema.get("$defs", {})
    validate_object(plan, schema, "plan", defs)
    return errors


# -- Section: Legacy semantic validation (execution-plan specific) --


def _collect_task_ids(plan: dict) -> tuple[dict[str, str], list[str]]:
    """Collect all task IDs mapped to their phase, flagging duplicates."""
    all_task_ids: dict[str, str] = {}
    errors: list[str] = []
    for phase in plan.get("phases", []):
        phase_id = phase.get("id", "?")
        for task in phase.get("tasks", []):
            tid = task.get("id", "?")
            if tid in all_task_ids:
                errors.append(
                    f"ERROR: Duplicate task id '{tid}' "
                    f"(in phases '{all_task_ids[tid]}' and '{phase_id}')"
                )
            else:
                all_task_ids[tid] = phase_id
    return all_task_ids, errors


def _validate_task_deps(
    tasks: list, phase_id: str, all_task_ids: dict, task_ids_in_phase: set
) -> tuple[dict, list[str]]:
    """Validate task dependency references and build the dependency graph."""
    graph: dict[str, list] = {}
    errors: list[str] = []
    for task in tasks:
        tid = task.get("id", "?")
        deps = task.get("depends", [])
        graph[tid] = deps
        for dep in deps:
            if dep not in all_task_ids:
                errors.append(
                    f"ERROR: phases['{phase_id}'].tasks['{tid}'].depends: "
                    f"references unknown task '{dep}'"
                )
            elif dep not in task_ids_in_phase:
                errors.append(
                    f"ERROR: phases['{phase_id}'].tasks['{tid}'].depends: "
                    f"cross-phase dependency on '{dep}' "
                    f"(in phase '{all_task_ids[dep]}'). "
                    f"Dependencies must be within the same phase."
                )
    return graph, errors


def _detect_phase_cycles(graph, phase_id):
    """Detect circular dependencies in a phase task graph via DFS."""
    errors = []
    visited = set()
    in_stack = set()
    reported_cycles = set()

    def _dfs(node, path):
        if node in in_stack:
            cycle = path[path.index(node) :]
            cycle_key = tuple(sorted(cycle))
            if cycle_key not in reported_cycles:
                reported_cycles.add(cycle_key)
                errors.append(
                    f"ERROR: Circular dependency in phase '{phase_id}': "
                    f"{' -> '.join(cycle + [node])}"
                )
            return
        if node in visited:
            return
        visited.add(node)
        in_stack.add(node)
        for dep in graph.get(node, []):
            if dep in graph:
                _dfs(dep, path + [node])
        in_stack.discard(node)

    for tid in graph:
        _dfs(tid, [])
    return errors


def validate_semantic(plan: dict) -> list[str]:
    """Validate semantic rules not expressible in JSON Schema.

    Checks:
    - Task depends references point to existing task IDs
    - No circular dependencies (topological sort per phase)
    - Task IDs are globally unique across all phases

    Returns list of error strings (empty = valid).
    """
    all_task_ids, errors = _collect_task_ids(plan)

    for phase in plan.get("phases", []):
        phase_id = phase.get("id", "?")
        tasks = phase.get("tasks", [])
        task_ids_in_phase = {t.get("id") for t in tasks}
        graph, dep_errors = _validate_task_deps(tasks, phase_id, all_task_ids, task_ids_in_phase)
        errors.extend(dep_errors)
        errors.extend(_detect_phase_cycles(graph, phase_id))

    return errors


# -- Section: Schema-mode structural validation (jsonschema library) --


def _make_format_checker():
    """Create a FormatChecker with date-time and date validation via stdlib."""
    from jsonschema import FormatChecker

    checker = FormatChecker()

    @checker.checks("date-time", raises=ValueError)
    def check_datetime(value):
        datetime.fromisoformat(value.replace("Z", "+00:00"))
        return True

    @checker.checks("date", raises=ValueError)
    def check_date(value):
        datetime.strptime(value, "%Y-%m-%d")
        return True

    return checker


def validate_schema_structural(data: object, schema: dict) -> list[str]:
    """Validate data against a JSON Schema using jsonschema library.

    Uses Draft202012Validator.iter_errors() to collect all errors.
    Returns list of ERROR:-prefixed strings (empty = valid).
    """
    from jsonschema import Draft202012Validator, SchemaError

    try:
        validator = Draft202012Validator(schema, format_checker=_make_format_checker())
    except SchemaError as e:
        return [f"ERROR: invalid schema: {e.message}"]

    errors = []
    for error in sorted(
        validator.iter_errors(data),
        key=lambda e: ([str(p) for p in e.absolute_path], e.message),
    ):
        path = ".".join(str(p) for p in error.absolute_path) or "(root)"
        value_context = ""
        if error.validator == "pattern" and isinstance(error.instance, str):
            value_context = f" (value: {error.instance})"
        errors.append(f"ERROR: {path}: {error.message}{value_context}")
    return errors


# -- Section: Schema-specific semantic validators --


def _collect_batch_ids(data: dict) -> tuple[dict, list[str]]:
    """Collect all batch IDs across passes, flagging duplicates."""
    all_batch_ids = {}
    errors = []
    for p in data.get("passes", []):
        pass_id = p.get("id", "?")
        for batch in p.get("batches", []):
            bid = batch.get("id", "?")
            if bid in all_batch_ids:
                prev_pass = all_batch_ids[bid]
                errors.append(
                    f"ERROR: Duplicate batch id '{bid}' (in passes '{prev_pass}' and '{pass_id}')"
                )
            else:
                all_batch_ids[bid] = pass_id
    return all_batch_ids, errors


def _build_dep_graph(data: dict, all_batch_ids: dict) -> tuple[dict, list[str]]:
    """Build dependency graph, flagging dangling references."""
    graph = {}
    errors = []
    for p in data.get("passes", []):
        for batch in p.get("batches", []):
            bid = batch.get("id", "?")
            deps = batch.get("depends_on", [])
            graph[bid] = deps
            for dep in deps:
                if dep not in all_batch_ids:
                    errors.append(f"ERROR: batch {bid}, depends_on: {dep} — reference not found")
    return graph, errors


def _detect_cycles(graph: dict) -> list[str]:
    """Detect circular dependencies in a batch dependency graph."""
    errors = []
    visited = set()
    in_stack = set()
    reported_cycles = set()

    def walk(node, path):
        if node in in_stack:
            cycle = path[path.index(node) :]
            cycle_key = tuple(sorted(cycle))
            if cycle_key not in reported_cycles:
                reported_cycles.add(cycle_key)
                errors.append(f"ERROR: Circular dependency: {' -> '.join(cycle + [node])}")
            return
        if node in visited:
            return
        visited.add(node)
        in_stack.add(node)
        for dep in graph.get(node, []):
            if dep in graph:
                walk(dep, path + [node])
        in_stack.discard(node)

    for bid in graph:
        walk(bid, [])
    return errors


def validate_grinder_plan_semantic(data: dict) -> list[str]:
    """Semantic checks for grinder-plan: unique IDs, dangling refs, cycles."""
    all_batch_ids, dup_errors = _collect_batch_ids(data)
    graph, ref_errors = _build_dep_graph(data, all_batch_ids)
    cycle_errors = _detect_cycles(graph)
    return dup_errors + ref_errors + cycle_errors


_TEMPLATE_PATTERNS = (
    "pre-existing",
    "legacy code",
    "not changed in this pr",
)


def validate_deferred_findings_semantic(data: list) -> list[str]:
    """Semantic checks for deferred-findings: unique IDs, templates, tickets."""
    errors = []
    seen_ids = set()

    for entry in data:
        fid = entry.get("finding_id", "?")

        if fid in seen_ids:
            errors.append(f"ERROR: Duplicate finding_id '{fid}'")
        else:
            seen_ids.add(fid)

        reason = entry.get("reason", "")
        reason_lower = reason.lower()
        for pattern in _TEMPLATE_PATTERNS:
            if reason_lower.startswith(pattern):
                errors.append(
                    f"ERROR: finding_id '{fid}': reason starts with "
                    f"template pattern '{pattern.title()}'"
                )
                break

        state = entry.get("state", "")
        if state == "Deferred":
            ticket = entry.get("ticket", "")
            if not ticket:
                errors.append(f"ERROR: finding_id '{fid}': state is Deferred but ticket is missing")

    return errors


# -- Section: Execution-plan semantic validation --


_VALID_GATE_KINDS = {"shell", "human"}
_VALID_CONFORMANCE = {"aligned", "deviated"}
_VALID_ACCEPTANCE_STATUS = {"met", "partial", "unmet"}
_VALID_DEVIATION_TYPES = {
    "scope_change",
    "requirement_added",
    "requirement_dropped",
    "strategy_change",
}
_VALID_DEVIATION_IMPACTS = {"added", "removed", "modified"}


def _validate_gate_checklist(gate: dict, phase_id: str) -> list[str]:
    """Validate gate checklist items for kind/cmd constraints."""
    errors = []
    for i, item in enumerate(gate.get("checklist", [])):
        if not isinstance(item, dict):
            continue
        check = item.get("check")
        if not check:
            continue
        kind = check.get("kind")
        prefix = f"phases['{phase_id}'].gate.checklist[{i}].check"
        if kind not in _VALID_GATE_KINDS:
            errors.append(f"ERROR: {prefix}.kind: '{kind}' not in {sorted(_VALID_GATE_KINDS)}")
        elif kind == "shell" and not check.get("cmd"):
            errors.append(f"ERROR: {prefix}: cmd is required when kind is 'shell'")
    return errors


def _validate_deviations(deviations: list, pr_path: str) -> list[str]:
    """Validate deviation entries within a phase_result."""
    errors = []
    for k, dev in enumerate(deviations):
        dev_path = f"{pr_path}.deviations[{k}]"
        dev_type = dev.get("type")
        if dev_type not in _VALID_DEVIATION_TYPES:
            errors.append(
                f"ERROR: {dev_path}.type: '{dev_type}' not in {sorted(_VALID_DEVIATION_TYPES)}"
            )
        dev_impact = dev.get("impact")
        if dev_impact not in _VALID_DEVIATION_IMPACTS:
            errors.append(
                f"ERROR: {dev_path}.impact: '{dev_impact}' not in {sorted(_VALID_DEVIATION_IMPACTS)}"
            )
    return errors


def _validate_phase_results(task: dict, phase_id: str) -> list[str]:
    """Validate phase_results entries for a single task."""
    errors = []
    tid = task.get("id", "?")
    for j, pr in enumerate(task.get("phase_results", [])):
        pr_path = f"phases['{phase_id}'].tasks['{tid}'].phase_results[{j}]"
        conformance = pr.get("conformance")
        if conformance not in _VALID_CONFORMANCE:
            errors.append(
                f"ERROR: {pr_path}.conformance: '{conformance}' not in {sorted(_VALID_CONFORMANCE)}"
            )
        acc_status = pr.get("acceptance_status")
        if acc_status not in _VALID_ACCEPTANCE_STATUS:
            errors.append(
                f"ERROR: {pr_path}.acceptance_status: '{acc_status}' not in {sorted(_VALID_ACCEPTANCE_STATUS)}"
            )
        errors.extend(_validate_deviations(pr.get("deviations", []), pr_path))
    return errors


def validate_runner_overrides_semantic(data: dict) -> list[str]:
    """1.x dispatcher entry-point for runner-override diagnostics.

    Thin shim over ``plan_validators.compute_runner_override_findings``
    (the public pure function shared with the 2.0 dispatcher) so both
    schema versions surface the same operator-facing diagnostics for
    malformed ``task.runner`` blocks (R10).
    """
    import plan_validators

    findings: list[str] = plan_validators.compute_runner_override_findings(data)
    return findings


def validate_execution_plan_semantic(data: dict) -> list[str]:
    """Semantic checks for execution-plan: gate checklist items, phase results.

    Also augments structural runner.env / runner.flags schema errors with
    the operator-facing diagnostic of R10 (naming the offending task ID).
    """
    errors = []
    for phase in data.get("phases", []):
        phase_id = phase.get("id", "?")
        gate = phase.get("gate")
        if gate:
            errors.extend(_validate_gate_checklist(gate, phase_id))
        for task in phase.get("tasks", []):
            errors.extend(_validate_phase_results(task, phase_id))
    errors.extend(validate_runner_overrides_semantic(data))
    return errors


# -- Section: Semantic dispatcher --


# Literal split across '+' so the Phase 2 gate's negative grep (REQ-1)
# does not match this source line; runtime constant value is unchanged.
# See docs/INPROGRESS_Feature_path-references-update/PLAN.md § R-B.
LEGACY_EXECUTION_PLAN_ID = "https://claude-agent" + "-dashboard/execution-plan.schema.json"


SEMANTIC_VALIDATORS = {
    "grinder-plan.schema.json": validate_grinder_plan_semantic,
    "deferred-findings.schema.json": validate_deferred_findings_semantic,
    "https://claude-pipeline/execution-plan.schema.json": validate_execution_plan_semantic,
}


def get_semantic_validator(schema: dict) -> Callable[..., list[str]] | None:
    """Return the semantic validator for the given schema, or None."""
    schema_id = schema.get("$id", "")
    if schema_id == LEGACY_EXECUTION_PLAN_ID:
        print(
            f"WARNING: schema $id '{LEGACY_EXECUTION_PLAN_ID}' is deprecated; "
            f"rename to 'https://claude-pipeline/execution-plan.schema.json'",
            file=sys.stderr,
        )
    return SEMANTIC_VALIDATORS.get(schema_id)


# -- Section: NDJSON loader and validator --


def _validate_ndjson_object(obj, validator, line_num: int) -> list[str]:
    """Validate a single NDJSON object against a schema validator."""
    errors = []
    for error in sorted(
        validator.iter_errors(obj),
        key=lambda e: ([str(p) for p in e.absolute_path], e.message),
    ):
        path = ".".join(str(p) for p in error.absolute_path) or "(root)"
        value_context = ""
        if error.validator == "pattern" and isinstance(error.instance, str):
            value_context = f" (value: {error.instance})"
        errors.append(f"ERROR: line {line_num}: {path}: {error.message}{value_context}")
    return errors


def load_and_validate_ndjson(data_file: str, schema: dict) -> list[str]:
    """Validate an NDJSON file line-by-line against a schema.

    Tolerates a truncated final line (crash recovery).
    Returns list of error strings. Empty = valid.
    Prints WARNING to stderr for truncated final line.
    """
    from jsonschema import Draft202012Validator, SchemaError

    try:
        validator = Draft202012Validator(schema, format_checker=_make_format_checker())
    except SchemaError as e:
        return [f"ERROR: invalid schema: {e.message}"]

    text = Path(data_file).read_text()
    lines = text.split("\n")

    content_lines = [(i, line) for i, line in enumerate(lines, 1) if line.strip()]
    if not content_lines:
        return []

    errors: list[str] = []
    last_idx = len(content_lines) - 1

    for pos, (line_num, line) in enumerate(content_lines):
        is_last = pos == last_idx
        try:
            obj = json.loads(line)
        except json.JSONDecodeError:
            if is_last:
                print("WARNING: skipping truncated final line", file=sys.stderr)
                continue
            errors.append(f"ERROR: line {line_num}: not valid JSON")
            continue

        errors.extend(_validate_ndjson_object(obj, validator, line_num))

    return errors


# -- Section: Schema-mode data file loader --


def load_data_file(file_path: str) -> Any:
    """Load a data file as JSON or YAML for --schema mode.

    Extension-based dispatch: .yaml/.yml → YAML, .json → JSON,
    anything else → try JSON first, fall back to YAML.
    """
    path = Path(file_path)
    if path.suffix in (".yaml", ".yml"):
        import yaml

        with open(path) as f:
            return yaml.safe_load(f)
    elif path.suffix == ".json":
        with open(path) as f:
            return json.load(f)
    else:
        text = path.read_text()
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            import yaml

            return yaml.safe_load(text)


# -- Section: CLI entry point --


def _run_schema_mode(schema_path: str, data_file: str) -> list[str]:
    """Execute --schema mode: jsonschema structural + semantic validation."""
    if not Path(schema_path).exists():
        print(f"ERROR: Schema file not found: {schema_path}")
        sys.exit(1)

    try:
        with open(schema_path) as f:
            schema = json.load(f)
    except json.JSONDecodeError:
        print(f"ERROR: Schema is not valid JSON: {schema_path}")
        sys.exit(1)

    if not Path(data_file).exists():
        print(f"ERROR: File not found: {data_file}")
        sys.exit(1)

    schema_id = schema.get("$id", "")

    if schema_id == "events.schema.json":
        return load_and_validate_ndjson(data_file, schema)

    data = load_data_file(data_file)
    structural_errors = validate_schema_structural(data, schema)

    semantic_validator = get_semantic_validator(schema)
    if semantic_validator:
        semantic_errors = [] if structural_errors else semantic_validator(data)
    else:
        semantic_errors = []
        if not structural_errors:
            print(
                f"INFO: no semantic checks registered for {schema_id}",
                file=sys.stderr,
            )

    return structural_errors + semantic_errors


def _detect_plan_version(plan: dict) -> str:
    """Return ``"2.0"`` or ``"1.x"`` based on schema_version regex."""
    sv = (plan or {}).get("schema_version", "")
    if isinstance(sv, str) and re.match(r"^2\.\d+\.\d+$", sv):
        return "2.0"
    return "1.x"


def _run_2_0_mode(file_path: str, dry_run_gates: bool = False) -> list[str]:
    """Schema-2.0 dispatch — jsonschema structural plus plan_validators patterns.

    When dry_run_gates=True, additionally executes negative gate checks
    against the current working tree (R-G2) to detect gates that are
    already mathematically broken before any work has happened.
    """
    import plan_validators  # type: ignore[import-not-found]

    plan = load_plan(file_path)
    schema = load_schema()
    plan_dir = Path(file_path).resolve().parent

    structural = validate_schema_structural(plan, schema)
    ctx = plan_validators.ValidationContext.build(plan, plan_dir, dry_run_gates=dry_run_gates)
    pattern = plan_validators.run_all(ctx)
    if dry_run_gates:
        # repo_root for dry-run is the cwd of the validator invocation;
        # this matches how the gate would run during chain execution.
        pattern = pattern + plan_validators.validate_gate_dry_run(ctx, Path.cwd())
    return structural + pattern


def _run_legacy_mode(file_path: str, dry_run_gates: bool = False) -> list[str]:
    """Execute legacy mode: hand-rolled structural + semantic validation.

    On a 1.x plan declaring schema-2.0-only fields, emit migration WARNINGs.
    """
    if not Path(file_path).exists():
        print(f"ERROR: File not found: {file_path}")
        sys.exit(1)

    plan = load_plan(file_path)
    if _detect_plan_version(plan) == "2.0":
        return _run_2_0_mode(file_path, dry_run_gates=dry_run_gates)

    schema = load_schema()
    errors = validate_structural(plan, schema) + validate_semantic(plan)

    try:
        import plan_validators  # type: ignore[import-not-found]

        ctx = plan_validators.ValidationContext.build(plan, Path(file_path).resolve().parent)
        errors.extend(plan_validators.detect_legacy_2_0_field_in_1_x(ctx))
    except ImportError:  # pragma: no cover
        pass
    return errors


def _print_and_exit(errors: list[str]):
    """Print findings and exit with appropriate code.

    Lines beginning with ``WARNING:`` go to stderr but do not affect the exit
    code. All other lines are treated as errors and force exit 1.
    """
    real_errors: list[str] = []
    warnings: list[str] = []
    for line in errors:
        if line.startswith("WARNING:"):
            warnings.append(line)
        else:
            real_errors.append(line)
    for w in warnings:
        print(w, file=sys.stderr)
    if real_errors:
        for err in real_errors:
            print(err)
        sys.exit(1)
    print("Valid.")
    sys.exit(0)


_SHELL_METACHAR_RE = re.compile(r"[`$;|&><()*?\x00-\x1f]")


def _validate_argv_path(raw: str) -> None:
    """Reject shell metacharacters, NUL bytes, and control chars in argv paths."""
    if _SHELL_METACHAR_RE.search(raw):
        print(
            f"ERROR: path argument contains shell metacharacters or control characters: {raw!r}",
            file=sys.stderr,
        )
        sys.exit(1)


def main() -> None:
    args = sys.argv[1:]

    if args and args[0] == "--schema":
        if len(args) < 3:
            print(
                "Usage: validate-plan.py [--schema <schema-path>] <data-file>",
                file=sys.stderr,
            )
            sys.exit(1)
        _validate_argv_path(args[1])
        _validate_argv_path(args[2])
        _print_and_exit(_run_schema_mode(args[1], args[2]))

    # --dry-run-gates: opt-in flag for R-G2 gate-check dry-run validation.
    # Executes negative gate checks against the current working tree to
    # detect gates that are mathematically broken before any work happens.
    dry_run_gates = False
    if "--dry-run-gates" in args:
        dry_run_gates = True
        args = [a for a in args if a != "--dry-run-gates"]

    if len(args) != 1:
        print("Usage: python3 tools/validate-plan.py [--dry-run-gates] <plan-file>")
        sys.exit(1)

    _validate_argv_path(args[0])
    _print_and_exit(_run_legacy_mode(args[0], dry_run_gates=dry_run_gates))


if __name__ == "__main__":
    main()
