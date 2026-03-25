#!/usr/bin/env python3
"""Validate an execution plan against the schema and semantic rules.

Two validation layers:
1. validate_structural(plan, schema) — required fields, types, enums
2. validate_semantic(plan) — dependency refs, cycles, unique IDs

Usage: python3 tools/validate-plan.py <plan-file>
Exit 0 on valid, exit 1 on errors.
"""
import json
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
    """Load the JSON Schema from the schema/ directory."""
    schema_path = Path(__file__).resolve().parent.parent / "schema" / "execution-plan.schema.json"
    with open(schema_path) as f:
        return json.load(f)


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


def validate_semantic(plan: dict) -> list[str]:
    """Validate semantic rules not expressible in JSON Schema.

    Checks:
    - Task depends references point to existing task IDs
    - No circular dependencies (topological sort per phase)
    - Task IDs are globally unique across all phases

    Returns list of error strings (empty = valid).
    """
    errors = []

    all_task_ids = {}
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

    for phase in plan.get("phases", []):
        phase_id = phase.get("id", "?")
        tasks = phase.get("tasks", [])
        task_ids_in_phase = {t.get("id") for t in tasks}

        graph = {}
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

        visited = set()
        in_stack = set()
        reported_cycles = set()

        def detect_cycle(node, path):
            if node in in_stack:
                cycle = path[path.index(node):]
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
                    detect_cycle(dep, path + [node])
            in_stack.discard(node)

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
