#!/usr/bin/env python3
"""Validate an execution plan against the schema and semantic rules.

Two validation layers:
1. validate_structural(plan, schema) — required fields, types, enums,
   if/then/else dispatch (schema 2.0), const, oneOf with discriminators
2. validate_semantic(plan) — dependency refs, cycles, unique IDs

Usage: python3 tools/validate-plan.py <plan-file>
Exit 0 on valid, exit 1 on errors.
"""
import json
import re
import sys
from pathlib import Path


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
    """Load the JSON Schema from the monorepo's core/schema/ directory."""
    schema_path = Path(__file__).resolve().parents[2] / "core" / "schema" / "execution-plan.schema.json"
    with open(schema_path) as f:
        return json.load(f)


def is_plan_2_0(plan: dict) -> bool:
    """True when the plan declares schema_version 2.x."""
    sv = plan.get("schema_version", "")
    return isinstance(sv, str) and bool(re.match(r"^2\.", sv))


def validate_structural(plan: dict, schema: dict) -> list[str]:
    """Validate plan structure against JSON Schema programmatically.

    Supports: required, properties, types, enums, patterns, minLength,
    minItems, items, oneOf (with discriminator), $ref, const,
    if/then/else dispatch, recursive additionalProperties.

    Returns list of error strings (empty = valid).
    """
    errors: list[str] = []

    type_map = {
        "string": str,
        "object": dict,
        "array": list,
        "boolean": bool,
        "integer": int,
        "number": (int, float),
    }

    def check_required(obj, required, path):
        for field in required:
            if field not in obj:
                errors.append(f"ERROR: {path}: missing required field '{field}'")

    def check_type(obj, expected_type, path):
        py_type = type_map.get(expected_type)
        if py_type is None:
            return True
        if not isinstance(obj, py_type) or (
            expected_type in ("integer", "number") and isinstance(obj, bool)
        ):
            errors.append(f"ERROR: {path}: expected {expected_type}, got {type(obj).__name__}")
            return False
        return True

    def check_pattern(value, pattern, path):
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

    def check_minimum(value, minimum, path):
        if value < minimum:
            errors.append(f"ERROR: {path}: value {value} < minimum {minimum}")

    def matches_schema(value, candidate_schema, defs, resolving):
        """Run a candidate sub-schema and return whether it matched cleanly."""
        saved = len(errors)
        validate_value(value, candidate_schema, "_probe", defs, resolving)
        matched = len(errors) == saved
        # Roll back any errors emitted by the probe — caller decides.
        del errors[saved:]
        return matched

    def validate_object(obj, schema_def, path, defs, resolving):
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
            validate_value(value, prop_schema, field_path, defs, resolving)

    def validate_value(value, prop_schema, path, defs, resolving):
        if "$ref" in prop_schema:
            ref = prop_schema["$ref"]
            ref_name = ref.split("/")[-1]
            if ref_name in resolving:
                errors.append(f"ERROR: {path}: circular $ref to '{ref_name}'")
                return
            if ref_name in defs:
                next_resolving = resolving | {ref_name}
                validate_value(value, defs[ref_name], path, defs, next_resolving)
            return

        # if/then/else dispatch keyed on a properties.<key>.pattern check.
        if "if" in prop_schema and ("then" in prop_schema or "else" in prop_schema):
            cond = prop_schema["if"]
            if matches_schema(value, cond, defs, resolving):
                branch = prop_schema.get("then")
            else:
                branch = prop_schema.get("else")
            if branch is not None:
                validate_value(value, branch, path, defs, resolving)
            # The base schema may also declare its own properties/required,
            # which we still want to apply against the raw value below.

        if "oneOf" in prop_schema:
            candidates = prop_schema["oneOf"]
            matching: list[dict] = []
            for candidate in candidates:
                if matches_schema(value, candidate, defs, resolving):
                    matching.append(candidate)
            if len(matching) == 0:
                errors.append(
                    f"ERROR: {path}: value does not match any oneOf option"
                )
            elif len(matching) > 1:
                errors.append(
                    f"ERROR: {path}: value matches {len(matching)} oneOf options "
                    f"(must match exactly one)"
                )
            else:
                validate_value(value, matching[0], path, defs, resolving)
            return

        if "const" in prop_schema:
            if value != prop_schema["const"]:
                errors.append(
                    f"ERROR: {path}: expected const '{prop_schema['const']}', got '{value}'"
                )
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

        if "minimum" in prop_schema and isinstance(value, (int, float)) and not isinstance(value, bool):
            check_minimum(value, prop_schema["minimum"], path)

        if prop_schema.get("type") == "array" and isinstance(value, list):
            items_schema = prop_schema.get("items")
            if items_schema:
                for i, item in enumerate(value):
                    validate_value(item, items_schema, f"{path}[{i}]", defs, resolving)

        # Apply object-level constraints whenever the value is a dict and the
        # schema declares object-shape rules — even if it does not set
        # type:object explicitly (e.g., if/then/else condition fragments).
        if isinstance(value, dict):
            if "properties" in prop_schema or "additionalProperties" in prop_schema or "required" in prop_schema:
                validate_object(value, prop_schema, path, defs, resolving)

    defs = schema.get("$defs", {})
    validate_value(plan, schema, "plan", defs, frozenset())
    return errors


def validate_semantic(plan: dict) -> list[str]:
    """Validate semantic rules not expressible in JSON Schema.

    Checks:
    - Task depends references point to existing task IDs
    - No circular dependencies (topological sort per phase)
    - Task IDs are globally unique across all phases
    - For 1.x plans: depends are intra-phase only.
      For 2.0 plans: cross-phase depends are allowed (graph-as-index).

    Returns list of error strings (empty = valid).
    """
    errors = []
    plan_is_2_0 = is_plan_2_0(plan)

    all_task_ids: dict[str, str] = {}
    for phase in plan.get("phases", []):
        phase_id = phase.get("id", "?")
        for task in phase.get("tasks", []):
            tid = task.get("id", "?")
            if tid in all_task_ids:
                prev_phase = all_task_ids[tid]
                errors.append(
                    f"ERROR: Duplicate task id '{tid}' "
                    f"(in phases '{prev_phase}' and '{phase_id}')"
                )
            else:
                all_task_ids[tid] = phase_id

    # Build a global task graph for 2.0 cycle detection.
    global_graph: dict[str, list[str]] = {}
    for phase in plan.get("phases", []):
        phase_id = phase.get("id", "?")
        tasks = phase.get("tasks", [])
        task_ids_in_phase = {t.get("id") for t in tasks}

        for task in tasks:
            tid = task.get("id", "?")
            deps = task.get("depends", []) or []
            global_graph[tid] = list(deps)
            for dep in deps:
                if dep not in all_task_ids:
                    errors.append(
                        f"ERROR: phases['{phase_id}'].tasks['{tid}'].depends: "
                        f"references unknown task '{dep}'"
                    )
                elif (not plan_is_2_0) and dep not in task_ids_in_phase:
                    errors.append(
                        f"ERROR: phases['{phase_id}'].tasks['{tid}'].depends: "
                        f"cross-phase dependency on '{dep}' "
                        f"(in phase '{all_task_ids[dep]}'). "
                        f"Dependencies must be within the same phase."
                    )

    if plan_is_2_0:
        visited: set[str] = set()
        in_stack: set[str] = set()
        reported_cycles: set[tuple] = set()

        def detect_cycle_global(node, path):
            if node in in_stack:
                cycle = path[path.index(node):]
                cycle_key = tuple(sorted(cycle))
                if cycle_key not in reported_cycles:
                    reported_cycles.add(cycle_key)
                    errors.append(
                        f"ERROR: Circular dependency: "
                        f"{' -> '.join(cycle + [node])}"
                    )
                return
            if node in visited:
                return
            visited.add(node)
            in_stack.add(node)
            for dep in global_graph.get(node, []):
                if dep in global_graph:
                    detect_cycle_global(dep, path + [node])
            in_stack.discard(node)

        for tid in global_graph:
            detect_cycle_global(tid, [])
    else:
        for phase in plan.get("phases", []):
            phase_id = phase.get("id", "?")
            tasks = phase.get("tasks", [])
            task_ids_in_phase = {t.get("id") for t in tasks}

            graph: dict[str, list[str]] = {}
            for task in tasks:
                tid = task.get("id", "?")
                deps = task.get("depends", []) or []
                graph[tid] = list(deps)

            visited_p: set[str] = set()
            in_stack_p: set[str] = set()
            reported_cycles_p: set[tuple] = set()

            def detect_cycle(node, path, _graph=graph, _v=visited_p, _s=in_stack_p, _r=reported_cycles_p, _phase=phase_id):
                if node in _s:
                    cycle = path[path.index(node):]
                    cycle_key = tuple(sorted(cycle))
                    if cycle_key not in _r:
                        _r.add(cycle_key)
                        errors.append(
                            f"ERROR: Circular dependency in phase '{_phase}': "
                            f"{' -> '.join(cycle + [node])}"
                        )
                    return
                if node in _v:
                    return
                _v.add(node)
                _s.add(node)
                for dep in _graph.get(node, []):
                    if dep in _graph:
                        detect_cycle(dep, path + [node])
                _s.discard(node)

            for tid in graph:
                detect_cycle(tid, [])

    return errors


def main():
    if len(sys.argv) != 2:
        print("Usage: python3 tools/validate-plan.py <plan-file>")
        sys.exit(1)

    file_path = sys.argv[1]
    if not Path(file_path).exists():
        print(f"ERROR: File not found: {file_path}")
        sys.exit(1)

    plan = load_plan(file_path)
    schema = load_schema()

    structural_errors = validate_structural(plan, schema)
    semantic_errors = validate_semantic(plan)

    all_errors = structural_errors + semantic_errors
    if all_errors:
        for err in all_errors:
            print(err)
        sys.exit(1)

    print("Valid.")
    sys.exit(0)


if __name__ == "__main__":
    main()
