#!/usr/bin/env python3
"""Append a phase_results entry to a task in execution-plan.yaml.

Usage:
    echo '<json>' | python3 deviation-tracker.py --plan-yaml <path> --task-id <id>

Reads a phase_result JSON object from stdin, validates it, and atomically
appends it to the specified task's phase_results array under fcntl.flock.

NFS limitation: fcntl.flock is advisory-only on NFSv3. This repo's plans
live on local disk under $PROJECTS_ROOT, so the limitation does not apply
in practice — but operators MUST NOT relocate plan files onto NFS shares
without revisiting the locking strategy.

Exit codes — see TRACKER_EXIT_CODES below.

Lock-contention math (S-P4): the lock critical section is ~50 ms (open +
load YAML + mutate + atomic rename); with N parallel autopilots × 8 phases
each, expect ~N×50 ms wait at the worst-case phase. DEVIATION_TRACKER_TIMEOUT
(default 10 s) becomes the cap around N≈25 parallel runs, at which point the
latest phase entry is dropped and a REQ-4 WARNING fires.
"""
from __future__ import annotations

import errno
import fcntl
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any

# Allow ``import schema_paths`` from ``claude/tools/lib`` regardless of how
# this script is invoked (subprocess, importlib, deployed copy at
# ~/.claude/tools). Mirrors the convention used by validate-plan.py.
_LIB_DIR = Path(__file__).resolve().parent / "lib"
if str(_LIB_DIR) not in sys.path:
    sys.path.insert(0, str(_LIB_DIR))

# TRACKER_EXIT_CODES — single source of truth for the deviation-tracker.py
# CLI exit-code contract. The bash wrapper in claude-session-lib.sh maps
# these values into REQ-4 canonical WARNING lines. Do not introduce new
# meanings without updating the wrapper's exit-code-map comment.
TRACKER_EXIT_CODES = {
    0: "success",
    1: "task not found / validation error / write error",
    2: "transient failure (lock contention, I/O retry)",
    # 124 from coreutils timeout(1)  -> 'timeout'
    # 127 from /bin/sh                -> 'tracker script not found'
}


def _load_phase_result_validator():
    """Build a Draft202012Validator targeting the phase_result $def.

    The returned validator references ``execution-plan.schema.json`` as its
    sole source of truth: enums, required fields, ``additionalProperties:
    false``, and recursive ``deviation`` constraints all flow from the
    declared schema. Earlier versions of this file duplicated those rules as
    Python sets — which drifted and missed ``additionalProperties`` plus
    several ``deviation`` required fields. Loading the schema here keeps the
    validator and the schema in lockstep by construction.
    """
    from jsonschema import Draft202012Validator
    from schema_paths import schema_path

    full_schema = json.loads(schema_path("execution-plan.schema.json").read_text())
    sub_schema = {
        "$ref": "#/$defs/phase_result",
        "$defs": full_schema["$defs"],
    }
    return Draft202012Validator(sub_schema)


_PHASE_RESULT_VALIDATOR = _load_phase_result_validator()


def _format_validation_error(err) -> str:
    """Format a single jsonschema ValidationError for stderr.

    Default shape is ``<json-path>: <message>``. The single carve-out is
    ``deviation.evidence`` minLength failures, which are reshaped to
    ``<path>: evidence too short (<N> characters, minimum 80)`` so the
    host plan's AC-3 lands literally. The path-tuple guard
    (``deviations`` → int → ``evidence``) anchors the rewrite to the
    intended failure site and avoids accidentally matching any unrelated
    minLength site that a future schema extension might introduce.
    """
    path = err.absolute_path
    if (
        err.validator == "minLength"
        and len(path) >= 3
        and path[-3] == "deviations"
        and isinstance(path[-2], int)
        and path[-1] == "evidence"
        and isinstance(err.instance, str)
    ):
        return (
            f"{err.json_path}: evidence too short "
            f"({len(err.instance)} characters, minimum {err.validator_value})"
        )
    return f"{err.json_path}: {err.message}"


def validate_phase_result(pr: dict) -> list[str]:
    """Validate a phase_result entry against execution-plan.schema.json.

    Returns a list of error strings (empty = valid). Each error is formatted
    as ``<json-path>: <message>`` so existing callers that grep stderr for
    field names ("conformance", "acceptance_status", "type", "impact",
    "reason") still match.
    """
    errors = []
    for err in _PHASE_RESULT_VALIDATOR.iter_errors(pr):
        errors.append(_format_validation_error(err))
    return errors


def find_task(plan: dict, task_id: str) -> dict | None:
    """Find a task by ID across all phases."""
    for phase in plan.get("phases", []):
        for task in phase.get("tasks", []):
            if task.get("id") == task_id:
                return task
    return None


def _load_and_append(plan_path: Path, task_id: str, phase_result: dict) -> tuple[Any, bool]:
    """Pure-data helper: load YAML, append phase_result to the task.

    Returns (plan, use_ruamel). Raises KeyError(task_id) when the task
    is absent. No file-IO side effects beyond the read.
    """
    try:
        from ruamel.yaml import YAML
        yaml_handler = YAML()
        yaml_handler.preserve_quotes = True
        with open(plan_path) as f:
            plan = yaml_handler.load(f)
        use_ruamel = True
    except ImportError:
        import yaml
        with open(plan_path) as f:
            plan = yaml.safe_load(f)
        use_ruamel = False

    task = find_task(plan, task_id)
    if task is None:
        raise KeyError(task_id)

    if "phase_results" not in task:
        task["phase_results"] = []
    task["phase_results"].append(phase_result)

    return plan, use_ruamel


def _write_atomic(plan_path: Path, plan: Any, use_ruamel: bool) -> None:
    """File-IO helper: atomic write via mkstemp + os.replace.

    Cleans up the tempfile if the write fails, then re-raises so the
    caller can decide on user-facing handling.
    """
    fd, tmp_file = tempfile.mkstemp(dir=plan_path.parent, suffix=".yaml.tmp")
    try:
        with os.fdopen(fd, "w") as f:
            if use_ruamel:
                from ruamel.yaml import YAML
                yaml_handler = YAML()
                yaml_handler.preserve_quotes = True
                yaml_handler.dump(plan, f)
            else:
                import yaml
                # sort_keys=False preserves the original key order (- id:
                # first, status: in its authored slot) so the regex-based
                # post-merge finalizers in commit-finalize.sh and
                # autopilot-chain.sh can still locate task and gate blocks.
                # Without this, yaml.dump alphabetizes keys, which makes
                # the entry start with `- depends:` instead of `- id:` —
                # the regex anchor fails and `status: done` never gets
                # written. Observed in deviation-tracker-full-monty
                # Phase 2: post-merge finalize missed all five tasks
                # because each pipeline phase's tracker write reordered
                # keys.
                yaml.dump(plan, f, default_flow_style=False, sort_keys=False)
        os.replace(tmp_file, str(plan_path))
    except Exception:
        try:
            os.unlink(tmp_file)
        except OSError:
            pass
        raise


def _append_under_lock(plan_path: Path, task_id: str, phase_result: dict) -> None:
    """Orchestrator: open lockfile, acquire LOCK_EX, load+append, write, release.

    Raises KeyError(task_id) when the task is absent (caller maps to exit 1).
    Exits 2 if the lockfile cannot be opened or LOCK_EX fails (transient).
    """
    lock_path = plan_path.with_suffix(plan_path.suffix + ".lock")
    real_lock = os.path.realpath(lock_path)
    real_parent = os.path.realpath(plan_path.parent)
    # F4: refuse if the plan's parent resolves to the filesystem root —
    # any absolute lockfile path would pass the startswith check below.
    # Treat as a misconfiguration / symlink-to-/ attack and skip silently.
    if real_parent in (os.sep, ""):
        print(f"WARNING: refusing to write — plan parent resolves to {real_parent!r}", file=sys.stderr)
        sys.exit(0)
    if not real_lock.startswith(real_parent + os.sep):
        print(f"WARNING: lock_path escapes plan parent: {lock_path}", file=sys.stderr)
        sys.exit(0)

    # F3: O_NOFOLLOW closes the symlink TOCTOU window between the realpath
    # check above and the open() below. The kernel rejects the open() if
    # lock_path is a symlink, regardless of when the link was planted. We
    # keep the realpath check as defence-in-depth (it catches symlinks
    # planted on the *parent directory* path, which O_NOFOLLOW does not).
    # Mode "a" semantics (append, create-if-absent, no truncation) are
    # preserved by O_RDWR | O_CREAT — we never truncate the lockfile
    # because that would race with any concurrent holder inspecting it.
    # F13: add O_APPEND so kernel-enforces append-on-write. macOS
    # `fdopen(fd, "a")` does NOT set O_APPEND on the existing fd — it
    # falls back to libc seek-to-end which is non-atomic under concurrent
    # writers. The lockfile has no writers today (only flock holders) but
    # add O_APPEND so any future appender is race-free by construction.
    try:
        fd = os.open(
            lock_path,
            os.O_RDWR | os.O_CREAT | os.O_APPEND | os.O_NOFOLLOW,
            0o600,
        )
    except OSError as e:
        if e.errno == errno.ELOOP:
            print(f"lock acquisition failed: symlink rejected ({lock_path})", file=sys.stderr)
            sys.exit(2)
        print(f"lock acquisition failed: {e}", file=sys.stderr)
        sys.exit(2)
    try:
        lock_fd = os.fdopen(fd, "a")
    except OSError as e:
        try:
            os.close(fd)
        except OSError:
            pass
        print(f"lock acquisition failed: {e}", file=sys.stderr)
        sys.exit(2)

    try:
        try:
            fcntl.flock(lock_fd.fileno(), fcntl.LOCK_EX)
        except OSError as e:
            print(f"lock acquisition failed: {e}", file=sys.stderr)
            sys.exit(2)

        try:
            plan, use_ruamel = _load_and_append(plan_path, task_id, phase_result)
            _write_atomic(plan_path, plan, use_ruamel)
        finally:
            try:
                fcntl.flock(lock_fd.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
    finally:
        try:
            lock_fd.close()
        except OSError:
            pass


def main() -> None:
    import argparse

    parser = argparse.ArgumentParser(description="Append phase_result to execution-plan.yaml")
    parser.add_argument("--plan-yaml", required=True, help="Path to execution-plan.yaml")
    parser.add_argument("--task-id", required=True, help="Task ID to append to")
    args = parser.parse_args()

    plan_path = Path(args.plan_yaml)

    try:
        exists = plan_path.exists()
    except PermissionError:
        print(f"WARNING: cannot access {plan_path}: permission denied", file=sys.stderr)
        sys.exit(0)

    if not exists:
        print(f"WARNING: plan file not found: {plan_path} (standalone mode)", file=sys.stderr)
        sys.exit(0)

    if not plan_path.is_file():
        print(f"WARNING: plan path is not a file: {plan_path}", file=sys.stderr)
        sys.exit(0)

    # F7: cap stdin at 1 MiB to defang DoS via unbounded stdin payloads.
    # Legitimate phase_result JSON is < 2 KiB; the cap is conservative.
    _STDIN_CAP_BYTES = 1 << 20  # 1 MiB — conservative cap; legitimate phase_result JSON is < 2 KiB
    stdin_raw = sys.stdin.read(_STDIN_CAP_BYTES + 1)
    if len(stdin_raw) > _STDIN_CAP_BYTES:
        print("ERROR: stdin payload exceeds 1 MiB", file=sys.stderr)
        sys.exit(1)
    stdin_data = stdin_raw.strip()
    if not stdin_data:
        print("ERROR: no JSON input on stdin", file=sys.stderr)
        sys.exit(1)

    try:
        phase_result = json.loads(stdin_data)
    except json.JSONDecodeError as e:
        print(f"ERROR: invalid JSON on stdin: {e}", file=sys.stderr)
        sys.exit(1)

    errors = validate_phase_result(phase_result)
    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        sys.exit(1)

    try:
        _append_under_lock(plan_path, args.task_id, phase_result)
    except KeyError:
        print(f"ERROR: task '{args.task_id}' not found in {plan_path}", file=sys.stderr)
        sys.exit(1)
    except SystemExit:
        raise
    except Exception as e:
        print(f"WARNING: failed to write {plan_path}: {e}", file=sys.stderr)
        sys.exit(0)


if __name__ == "__main__":
    main()
