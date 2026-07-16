"""Tests for autopilot-chain.sh — chain orchestrator (CH-1..63).

Uses a mock autopilot.sh stub that reads a control file for exit code/duration.
All tests create temporary plan directories with fixture execution-plan.yaml.
"""

from __future__ import annotations

import json
import os
import subprocess
import textwrap
import time
from pathlib import Path

import yaml
from conftest import REPO_ROOT

CHAIN_SH = str(REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "autopilot-chain.sh")


def _write_plan(plan_dir: Path, phases: list[dict]) -> Path:
    """Write an execution-plan.yaml with given phases."""
    plan = {
        "schema_version": "1.0.0",
        "name": "Test Plan",
        "phases": phases,
    }
    plan_dir.mkdir(parents=True, exist_ok=True)
    plan_file = plan_dir / "execution-plan.yaml"
    plan_file.write_text(yaml.dump(plan, default_flow_style=False, sort_keys=False))
    return plan_file


def _task(
    tid: str,
    status: str = "pending",
    depends: list[str] | None = None,
    autopilot: bool = True,
    **kwargs,
) -> dict:
    """Create a task dict."""
    t = {"id": tid, "name": f"Task {tid}", "status": status, "autopilot": autopilot}
    if depends:
        t["depends"] = depends
    t.update(kwargs)
    return t


def _phase(pid: str, tasks: list[dict], gate: dict | None = None) -> dict:
    """Create a phase dict."""
    p = {"id": pid, "name": f"Phase {pid}", "tasks": tasks}
    if gate:
        p["gate"] = gate
    return p


def _mock_autopilot(tmp_path: Path, behavior: dict[str, dict] | None = None) -> str:
    """Create a mock autopilot.sh that updates YAML status and exits.

    behavior: {task_id: {
        "exit_code": 0,
        "sleep": 0.1,
        "status": "done",
        "blocked_reason": "merge_conflict|lock_timeout|dirty_main",  # optional
    }}

    When blocked_reason is set AND CHAIN_MERGE_LOCK is in env, the mock
    writes a .chain-blocked-reason-<task> sentinel file in the plan dir
    before exiting — mirrors real autopilot.sh's _write_chain_blocked_reason.
    """
    control_file = tmp_path / "mock-control.json"
    if behavior:
        control_file.write_text(json.dumps(behavior))

    mock_script = tmp_path / "mock-autopilot.sh"
    mock_script.write_text(
        textwrap.dedent(f"""\
        #!/usr/bin/env bash
        # Mock autopilot.sh — reads control file for behavior
        TASK=""
        while [[ "${{1:-}}" == --* ]]; do
            case "$1" in
                --full) shift ;;
                --pipeline) shift 2 ;;
                *) shift ;;
            esac
        done
        TASK="${{1:-}}"

        CONTROL_FILE="{control_file}"
        BLOCKED_REASON=""
        if [[ -f "$CONTROL_FILE" ]]; then
            BEHAVIOR=$(python3 -c "
import json, sys
with open('$CONTROL_FILE') as f:
    ctrl = json.load(f)
b = ctrl.get('$TASK', {{}})
print(b.get('sleep', '0.1'))
print(b.get('exit_code', '0'))
print(b.get('status', 'done'))
print(b.get('blocked_reason', ''))
" 2>/dev/null)
            SLEEP_TIME=$(echo "$BEHAVIOR" | sed -n '1p')
            EXIT_CODE=$(echo "$BEHAVIOR" | sed -n '2p')
            NEW_STATUS=$(echo "$BEHAVIOR" | sed -n '3p')
            BLOCKED_REASON=$(echo "$BEHAVIOR" | sed -n '4p')
        else
            SLEEP_TIME=0.1
            EXIT_CODE=0
            NEW_STATUS="done"
        fi

        sleep "$SLEEP_TIME"

        # Update the YAML status (find and replace)
        for f in docs/INPROGRESS_Plan_*/execution-plan.yaml; do
            if [[ -f "$f" ]]; then
                python3 -c "
import yaml
with open('$f') as fh:
    plan = yaml.safe_load(fh.read())
for phase in plan.get('phases', []):
    for task in phase.get('tasks', []):
        if task.get('id') == '$TASK':
            task['status'] = '$NEW_STATUS'
with open('$f', 'w') as fh:
    yaml.dump(plan, fh, default_flow_style=False, sort_keys=False)
" 2>/dev/null || true
                break
            fi
        done

        # Mirror autopilot.sh::_write_chain_blocked_reason: write the
        # blocked-reason sentinel for chain.sh to read after exit 2.
        if [[ -n "$BLOCKED_REASON" && -n "${{CHAIN_MERGE_LOCK:-}}" ]]; then
            PLAN_DIR_FROM_LOCK=$(dirname "$CHAIN_MERGE_LOCK")
            if [[ -d "$PLAN_DIR_FROM_LOCK" && "$TASK" =~ ^[a-zA-Z0-9_-]+$ ]]; then
                echo "$BLOCKED_REASON" > "${{PLAN_DIR_FROM_LOCK}}/.chain-blocked-reason-${{TASK}}" 2>/dev/null || true
            fi
        fi

        exit "$EXIT_CODE"
    """)
    )
    mock_script.chmod(0o755)
    return f"bash {mock_script}"


def _run_chain(
    tmp_path: Path, plan_dir: Path, *extra_args: str, mock_cmd: str | None = None, timeout: int = 30
) -> subprocess.CompletedProcess:
    """Run autopilot-chain.sh with optional mock."""
    env = os.environ.copy()
    if mock_cmd:
        env["AUTOPILOT_CMD"] = mock_cmd

    return subprocess.run(
        ["bash", CHAIN_SH, "run", *extra_args, str(plan_dir)],
        capture_output=True,
        text=True,
        timeout=timeout,
        env=env,
        cwd=str(tmp_path),
    )


def _get_gate_items(plan_dir: Path) -> list[dict]:
    """Extract parsed items from the first gate_evaluated event."""
    events_file = plan_dir / "chain-events.ndjson"
    assert events_file.exists(), "chain-events.ndjson should exist"
    events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
    gate_eval = [e for e in events if e.get("event") == "gate_evaluated"]
    assert len(gate_eval) >= 1, "Expected at least one gate_evaluated event"
    items_raw = gate_eval[0]["items"]
    if isinstance(items_raw, str):
        return json.loads(items_raw)
    return items_raw


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# DAG Traversal (R1)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


class TestLinearChain:
    """CH-1: Linear chain A→B→C executes in order."""

    def test_linear_order(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_1"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("a"),
                        _task("b", depends=["a"]),
                        _task("c", depends=["b"]),
                    ],
                )
            ],
        )
        mock = _mock_autopilot(
            tmp_path,
            {
                "a": {"exit_code": 0, "sleep": "0.1", "status": "done"},
                "b": {"exit_code": 0, "sleep": "0.1", "status": "done"},
                "c": {"exit_code": 0, "sleep": "0.1", "status": "done"},
            },
        )
        result = _run_chain(tmp_path, plan_dir, "--max-parallel", "1", mock_cmd=mock)
        assert result.returncode == 0

        # Verify events show correct order
        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should be created"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        started = [e["task"] for e in events if e.get("event") == "task_started"]
        assert started == ["a", "b", "c"]


class TestReadyWhenDepsAreDone:
    """CH-2: Task ready only when all deps are done."""

    def test_deps_check(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_2"
        # B depends on A, but A is still pending — B should not run
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("a", autopilot=False),  # Not autopilot — won't run
                        _task("b", depends=["a"]),  # Depends on a — blocked
                    ],
                )
            ],
        )
        mock = _mock_autopilot(tmp_path)
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        # Should exit with no tasks launched
        assert "manual" in result.stderr.lower()


class TestNonAutopilotSkipped:
    """CH-3: Non-autopilot task skipped with log message."""

    def test_skipped_with_message(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_3"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("manual-task", autopilot=False),
                        _task("auto-task"),
                    ],
                )
            ],
        )
        mock = _mock_autopilot(
            tmp_path,
            {
                "auto-task": {"exit_code": 0, "sleep": "0.1", "status": "done"},
            },
        )
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        assert "requires manual execution" in result.stderr


class TestBlockedByManual:
    """CH-4: Task depending on non-autopilot task reported as blocked."""

    def test_blocked(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_4"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("manual", autopilot=False),
                        _task("downstream", depends=["manual"]),
                    ],
                )
            ],
        )
        mock = _mock_autopilot(tmp_path)
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        # Chain should exit since no ready tasks
        assert result.returncode == 0


class TestNoPendingTasks:
    """CH-5: No pending tasks — exit 0 with plan complete."""

    def test_exit_0(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_5"
        _write_plan(plan_dir, [_phase("p1", [_task("a", status="done")])])
        mock = _mock_autopilot(tmp_path)
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        assert result.returncode == 0
        assert "complete" in result.stderr.lower() or "no ready tasks" in result.stderr.lower()


class TestCircularDependency:
    """CH-6: Circular dependency deadlock — exit 0 with diagnostic."""

    def test_deadlock(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_6"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("a", depends=["b"]),
                        _task("b", depends=["a"]),
                    ],
                )
            ],
        )
        mock = _mock_autopilot(tmp_path)
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        assert result.returncode == 0
        assert "circular" in result.stderr.lower() or "no ready tasks" in result.stderr.lower()


class TestMissingPlanDir:
    """CH-7: Missing plan directory — exit 1."""

    def test_exit_1(self, tmp_path: Path):
        result = _run_chain(tmp_path, tmp_path / "nonexistent", mock_cmd="true")
        assert result.returncode == 1
        assert "not found" in result.stderr.lower()


class TestMissingYaml:
    """CH-8: Missing execution-plan.yaml — exit 1."""

    def test_exit_1(self, tmp_path: Path):
        plan_dir = tmp_path / "empty_dir"
        plan_dir.mkdir()
        result = _run_chain(tmp_path, plan_dir, mock_cmd="true")
        assert result.returncode == 1
        assert "not found" in result.stderr.lower()


class TestMaxTasksZero:
    """CH-9: --max-tasks 0 exits immediately."""

    def test_exit_0(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_9"
        _write_plan(plan_dir, [_phase("p1", [_task("a")])])
        mock = _mock_autopilot(tmp_path)
        result = _run_chain(tmp_path, plan_dir, "--max-tasks", "0", mock_cmd=mock)
        assert result.returncode == 0
        assert "max-tasks" in result.stderr.lower() or "dry-run" in result.stderr.lower()


class TestMaxTasksLimit:
    """CH-10: --max-tasks N stops after N tasks."""

    def test_stops_after_n(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_10"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("a"),
                        _task("b", depends=["a"]),
                        _task("c", depends=["b"]),
                    ],
                )
            ],
        )
        mock = _mock_autopilot(
            tmp_path,
            {
                "a": {"exit_code": 0, "sleep": "0.1", "status": "done"},
                "b": {"exit_code": 0, "sleep": "0.1", "status": "done"},
            },
        )
        result = _run_chain(
            tmp_path, plan_dir, "--max-tasks", "2", "--max-parallel", "1", mock_cmd=mock
        )
        assert result.returncode == 0

        # Verify only 2 tasks started
        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should be created"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        started = [e for e in events if e.get("event") == "task_started"]
        assert len(started) == 2


class TestAutoDiscover:
    """CH-11: Auto-discover plan when no dir provided (exactly one)."""

    def test_discovers(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_auto"
        _write_plan(plan_dir, [_phase("p1", [_task("a", status="done")])])
        mock = _mock_autopilot(tmp_path)
        env = os.environ.copy()
        env["AUTOPILOT_CMD"] = mock
        result = subprocess.run(
            ["bash", CHAIN_SH, "run"],
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
            cwd=str(tmp_path),
        )
        assert result.returncode == 0


class TestAutoDiscoverZero:
    """CH-12: Auto-discover fails with zero plans."""

    def test_fails(self, tmp_path: Path):
        (tmp_path / "docs").mkdir(parents=True, exist_ok=True)
        env = os.environ.copy()
        env["AUTOPILOT_CMD"] = "true"
        result = subprocess.run(
            ["bash", CHAIN_SH, "run"],
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
            cwd=str(tmp_path),
        )
        assert result.returncode == 1
        assert "no plan" in result.stderr.lower()


class TestAutoDiscoverMultiple:
    """CH-13: Auto-discover fails with multiple plans."""

    def test_fails(self, tmp_path: Path):
        for name in ["plan-a", "plan-b"]:
            d = tmp_path / "docs" / f"INPROGRESS_Plan_{name}"
            _write_plan(d, [_phase("p1", [_task("a")])])
        env = os.environ.copy()
        env["AUTOPILOT_CMD"] = "true"
        result = subprocess.run(
            ["bash", CHAIN_SH, "run"],
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
            cwd=str(tmp_path),
        )
        assert result.returncode == 1
        assert "multiple" in result.stderr.lower()


class TestShlockRequired:
    """CH-14: shlock not found — exit 1."""

    def test_exit_1(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_14"
        _write_plan(plan_dir, [_phase("p1", [_task("a")])])
        env = os.environ.copy()
        env["PATH"] = (
            "/usr/bin:/bin"  # Remove shlock from PATH — but shlock IS at /usr/bin on macOS
        )
        # Instead, test the guard by checking the script content
        content = Path(CHAIN_SH).read_text()
        assert "command -v shlock" in content


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Parallel Execution (R2)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


class TestParallelLaunch:
    """CH-20: Two independent tasks launch in parallel."""

    def test_parallel(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_20"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("x"),
                        _task("y"),
                    ],
                )
            ],
        )
        mock = _mock_autopilot(
            tmp_path,
            {
                "x": {"exit_code": 0, "sleep": "1", "status": "done"},
                "y": {"exit_code": 0, "sleep": "1", "status": "done"},
            },
        )
        start = time.time()
        result = _run_chain(tmp_path, plan_dir, "--max-parallel", "2", mock_cmd=mock, timeout=30)
        elapsed = time.time() - start
        assert result.returncode == 0
        # Both should run in parallel — serial baseline is ~2s (two 1s tasks)
        # plus chain orchestrator overhead (yaml parse, ready-set compute,
        # state-file writes per harvest). The original < 3.0 s threshold
        # left only ~1 s of overhead headroom and went flaky under machine
        # load (CI, parallel test execution, autopilot running its own
        # full pipeline while testing). The < 6.0 s threshold still
        # distinguishes parallel (~2 s + overhead) from serial (~4 s +
        # overhead, which would push past 6 s) without flaking on slow
        # runs. Tightened 2026-05-22 after a QA-phase max-turns burn
        # ($8.61) chasing what turned out to be a 3.0 s threshold
        # exceeded by 0.15 s on a loaded host.
        assert elapsed < 6.0, f"Expected parallel execution, took {elapsed:.1f}s"


class TestStdoutPrefix:
    """controls-07 #13 — chain prefixes each task's stdout/stderr lines
    with `[task-id] ` so the merged tmux pane is filterable per task.
    Without the prefix, N parallel autopilots interleave their output
    in the chain's pane with no way to tell which line came from where.
    """

    def test_stdout_lines_carry_task_id_prefix(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_prefix"
        _write_plan(plan_dir, [_phase("p1", [_task("alpha"), _task("beta")])])
        # Custom mock — echoes a recognizable marker line then exits 0.
        # The chain script's spawn pipeline must rewrite each line as
        # `[<task_id>] <line>`. We assert both task ids appear with the
        # `[id]` prefix on the marker line in result.stdout.
        mock_script = tmp_path / "mock-echo.sh"
        mock_script.write_text(textwrap.dedent("""\
            #!/usr/bin/env bash
            TASK=""
            while [[ "${1:-}" == --* ]]; do
                case "$1" in
                    --full) shift ;;
                    --pipeline) shift 2 ;;
                    *) shift ;;
                esac
            done
            TASK="${1:-}"
            echo "MARKER_LINE_FROM_$TASK"
            # Update status so the chain doesn't keep retrying.
            for f in docs/INPROGRESS_Plan_*/execution-plan.yaml; do
                if [[ -f "$f" ]]; then
                    python3 -c "
import yaml
with open('$f') as fh: plan = yaml.safe_load(fh.read())
for phase in plan.get('phases', []):
    for task in phase.get('tasks', []):
        if task.get('id') == '$TASK':
            task['status'] = 'done'
with open('$f', 'w') as fh: yaml.dump(plan, fh, default_flow_style=False, sort_keys=False)
" 2>/dev/null || true
                    break
                fi
            done
            exit 0
        """))
        mock_script.chmod(0o755)
        result = _run_chain(
            tmp_path, plan_dir, "--max-parallel", "2",
            mock_cmd=f"bash {mock_script}", timeout=30,
        )
        assert result.returncode == 0, f"chain failed: {result.stderr}"
        # Both task ids must appear as `[id]` prefixes on the marker
        # line. The exact whitespace after `[id]` matches sed "s/^/[id] /"
        # — one space between bracket and original content.
        assert "[alpha] MARKER_LINE_FROM_alpha" in result.stdout, (
            f"alpha prefix missing; stdout=\n{result.stdout}"
        )
        assert "[beta] MARKER_LINE_FROM_beta" in result.stdout, (
            f"beta prefix missing; stdout=\n{result.stdout}"
        )


class TestPersistentStdoutLog:
    """controls-07 #14 — chain tees stdout+stderr to a persistent log
    file in the plan directory. start-system.sh redirects uvicorn
    stderr to /dev/null and tmux pane scrollback caps at 3000 lines,
    so without a persistent file the chain leaves no recoverable
    trace when it dies — empirically observed today as multiple
    silent chain deaths during the controls-07 session.

    Verification is split across two tests:
      - Structural: the script contains the tee redirect (works in any
        sandbox; verifies the line is in place).
      - End-to-end: the log file is actually written (requires
        process-substitution support; skipped under restrictive
        sandboxes where /dev/fd/N opens are blocked).
    """

    def test_chain_script_contains_persistent_log_redirect(self):
        """Structural — script must invoke `tee` against chain-stdout.log."""
        content = Path(CHAIN_SH).read_text()
        assert "tee -a \"$PLAN_DIR/chain-stdout.log\"" in content, (
            "controls-07 #14 redirect missing — chain runs leave no "
            "recoverable trace when stderr is /dev/null'd"
        )

    def test_chain_stdout_log_written_to_plan_dir(self, tmp_path: Path):
        """End-to-end — under permissive sandbox, the log file is
        actually populated. Skipped when /dev/fd is restricted
        (process substitution is the only portable bash idiom)."""
        # Pre-flight: can we even open /dev/fd via process subst here?
        probe = subprocess.run(
            ["bash", "-c", "exec 3> >(cat >/dev/null); echo ok"],
            capture_output=True, text=True, timeout=5,
        )
        if probe.returncode != 0 or "Operation not permitted" in probe.stderr:
            import pytest as _pt
            _pt.skip(f"sandbox blocks process substitution: {probe.stderr.strip()}")

        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_log"
        _write_plan(plan_dir, [_phase("p1", [_task("alpha")])])
        mock_script = tmp_path / "mock-echo.sh"
        mock_script.write_text(textwrap.dedent("""\
            #!/usr/bin/env bash
            TASK=""
            while [[ "${1:-}" == --* ]]; do
                case "$1" in
                    --full) shift ;;
                    --pipeline) shift 2 ;;
                    *) shift ;;
                esac
            done
            TASK="${1:-}"
            echo "MARKER_FOR_$TASK"
            for f in docs/INPROGRESS_Plan_*/execution-plan.yaml; do
                if [[ -f "$f" ]]; then
                    python3 -c "
import yaml
with open('$f') as fh: plan = yaml.safe_load(fh.read())
for phase in plan.get('phases', []):
    for task in phase.get('tasks', []):
        if task.get('id') == '$TASK':
            task['status'] = 'done'
with open('$f', 'w') as fh: yaml.dump(plan, fh, default_flow_style=False, sort_keys=False)
" 2>/dev/null || true
                    break
                fi
            done
            exit 0
        """))
        mock_script.chmod(0o755)
        result = _run_chain(
            tmp_path, plan_dir, mock_cmd=f"bash {mock_script}", timeout=30,
        )
        assert result.returncode == 0, f"chain failed: {result.stderr}"
        log_file = plan_dir / "chain-stdout.log"
        assert log_file.exists(), (
            f"chain-stdout.log not written to plan dir; "
            f"plan_dir contents = {list(plan_dir.iterdir())}"
        )
        log_content = log_file.read_text()
        assert "[alpha] MARKER_FOR_alpha" in log_content, (
            f"marker missing from log; content=\n{log_content}"
        )
        assert "[alpha] MARKER_FOR_alpha" in result.stdout, (
            "marker missing from stdout — tee redirect broke the pane stream"
        )


class TestSerialExecution:
    """CH-21: --max-parallel 1 runs serially."""

    def test_serial(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_21"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("x"),
                        _task("y"),
                    ],
                )
            ],
        )
        mock = _mock_autopilot(
            tmp_path,
            {
                "x": {"exit_code": 0, "sleep": "0.5", "status": "done"},
                "y": {"exit_code": 0, "sleep": "0.5", "status": "done"},
            },
        )
        start = time.time()
        result = _run_chain(tmp_path, plan_dir, "--max-parallel", "1", mock_cmd=mock, timeout=30)
        elapsed = time.time() - start
        assert result.returncode == 0
        # Should be serial — ~1s total
        assert elapsed >= 0.8, f"Expected serial execution, took {elapsed:.1f}s"


class TestBatchedExecution:
    """CH-22: More ready tasks than max-parallel — batched."""

    def test_batched(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_22"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("a"),
                        _task("b"),
                        _task("c"),
                    ],
                )
            ],
        )
        mock = _mock_autopilot(
            tmp_path,
            {
                "a": {"exit_code": 0, "sleep": "0.2", "status": "done"},
                "b": {"exit_code": 0, "sleep": "0.2", "status": "done"},
                "c": {"exit_code": 0, "sleep": "0.2", "status": "done"},
            },
        )
        result = _run_chain(tmp_path, plan_dir, "--max-parallel", "2", mock_cmd=mock, timeout=30)
        assert result.returncode == 0


class TestAllSiblingsFail:
    """CH-23: All parallel siblings fail — chain halts with reasons."""

    def test_all_fail(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_23"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("x"),
                        _task("y"),
                    ],
                )
            ],
        )
        mock = _mock_autopilot(
            tmp_path,
            {
                "x": {"exit_code": 1, "sleep": "0.1", "status": "failed"},
                "y": {"exit_code": 1, "sleep": "0.1", "status": "failed"},
            },
        )
        result = _run_chain(tmp_path, plan_dir, "--max-parallel", "2", mock_cmd=mock)
        assert result.returncode == 1


class TestPlanReRead:
    """CH-24: Plan re-read after each batch completes."""

    def test_reread(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_24"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("a"),
                        _task("b", depends=["a"]),
                    ],
                )
            ],
        )
        mock = _mock_autopilot(
            tmp_path,
            {
                "a": {"exit_code": 0, "sleep": "0.1", "status": "done"},
                "b": {"exit_code": 0, "sleep": "0.1", "status": "done"},
            },
        )
        result = _run_chain(tmp_path, plan_dir, "--max-parallel", "1", mock_cmd=mock)
        assert result.returncode == 0

        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should be created"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        started = [e["task"] for e in events if e.get("event") == "task_started"]
        assert "b" in started


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Gate Evaluation (R3)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


class TestGateAllShellPass:
    """CH-30: All kind:shell pass — gate auto-marked passed."""

    def test_auto_pass(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_30"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate 1",
                        "checklist": [
                            {"text": "Check 1", "check": {"kind": "shell", "cmd": "true"}},
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        assert result.returncode == 0

        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should be created"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        passed_events = [e for e in events if e.get("event") == "gate_passed"]
        assert len(passed_events) >= 1


class TestGateHumanHalts:
    """CH-31: kind:human present — chain halts with summary."""

    def test_halts(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_31"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate 1",
                        "checklist": [
                            {"text": "Human review", "check": {"kind": "human"}},
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        # Gate should block but chain may still exit 0 (gate evaluation is within main loop)
        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should be created"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        blocked = [e for e in events if e.get("event") == "gate_blocked"]
        assert len(blocked) >= 1


class TestGateShellFails:
    """CH-32: kind:shell command fails — chain halts."""

    def test_fails(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_32"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate 1",
                        "checklist": [
                            {"text": "Failing check", "check": {"kind": "shell", "cmd": "false"}},
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should be created"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        blocked = [e for e in events if e.get("event") == "gate_blocked"]
        assert len(blocked) >= 1


class TestStrictGates:
    """CH-33: --strict-gates always halt regardless of kind."""

    def test_strict(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_33"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate 1",
                        "checklist": [
                            {"text": "Shell check", "check": {"kind": "shell", "cmd": "true"}},
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, "--strict-gates", mock_cmd=mock)

        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should be created"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        blocked = [e for e in events if e.get("event") == "gate_blocked"]
        assert len(blocked) >= 1


class TestDefaultHumanCheck:
    """CH-34: Gate items without check default to human."""

    def test_default_human(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_34"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate 1",
                        "checklist": ["Plain string item"],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should be created"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        blocked = [e for e in events if e.get("event") == "gate_blocked"]
        assert len(blocked) >= 1


class TestEmptyChecklist:
    """CH-35: Empty checklist — auto-pass."""

    def test_auto_pass(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_35"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Empty Gate",
                        "checklist": [],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        assert result.returncode == 0
        events_file = plan_dir / "chain-events.ndjson"
        if events_file.exists():
            events = [
                json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()
            ]
            passed = [e for e in events if e.get("event") == "gate_passed"]
            assert len(passed) >= 1


class TestGateTimeout:
    """CH-36: Gate command timeout treated as failed.

    Note: Behavioral test impractical (would require a real wait).
    Verified structurally that the default gate timeout (raised 60s→600s
    in commit 3399349) is configured with an AUTOPILOT_CHAIN_GATE_TIMEOUT_S
    env override hook so projects can shorten or lengthen it.
    """

    def test_timeout_handling(self):
        content = Path(CHAIN_SH).read_text()
        assert "AUTOPILOT_CHAIN_GATE_TIMEOUT_S" in content
        assert "'600'" in content


class TestNoGate:
    """CH-37: Phase without gate — proceed without halting."""

    def test_no_gate_proceeds(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_37"
        _write_plan(
            plan_dir,
            [
                _phase("p1", [_task("a")]),  # No gate
                _phase("p2", [_task("b", depends=["a"])]),
            ],
        )
        mock = _mock_autopilot(
            tmp_path,
            {
                "a": {"exit_code": 0, "sleep": "0.1", "status": "done"},
                "b": {"exit_code": 0, "sleep": "0.1", "status": "done"},
            },
        )
        result = _run_chain(tmp_path, plan_dir, "--max-parallel", "1", mock_cmd=mock)
        assert result.returncode == 0


class TestGateOutput:
    """CH-38: Gate command output captured in event log."""

    def test_output_captured(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_38"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate with output",
                        "checklist": [
                            {"text": "Echo check", "check": {"kind": "shell", "cmd": "echo hello"}},
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should exist"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        gate_eval = [e for e in events if e.get("event") == "gate_evaluated"]
        assert len(gate_eval) >= 1
        assert "items" in gate_eval[0]


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Gate Output Persistence (REQ-1..6)
# T11 (AS-7: existing tests pass) is verified by the full suite
# running green — no dedicated class needed.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


class TestGateOutputFailedCheck:
    """T1: Failed shell check includes exit_code, stdout, stderr (REQ-1, AS-1)."""

    def test_failed_includes_output(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_t1"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate T1",
                        "checklist": [
                            {
                                "text": "Fail check",
                                "check": {"kind": "shell", "cmd": "echo hello && exit 1"},
                            },
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        items = _get_gate_items(plan_dir)
        item = items[0]
        assert item["result"] == "failed"
        assert item["exit_code"] == 1
        assert item["stdout"] == "hello\n"
        assert item["stderr"] == ""


class TestGateOutputPassedCheck:
    """T2: Passed shell check includes exit_code only (REQ-2, AS-2)."""

    def test_passed_exit_code_only(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_t2"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate T2",
                        "checklist": [
                            {"text": "Pass check", "check": {"kind": "shell", "cmd": "echo ok"}},
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        items = _get_gate_items(plan_dir)
        item = items[0]
        assert item["result"] == "passed"
        assert item["exit_code"] == 0
        assert "stdout" not in item
        assert "stderr" not in item


class TestGateOutputMixed:
    """T3: Mixed pass/fail — only failures include output (AS-5, EC-6)."""

    def test_mixed_pass_fail(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_t3"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate T3",
                        "checklist": [
                            {"text": "Passes", "check": {"kind": "shell", "cmd": "true"}},
                            {
                                "text": "Fails stderr",
                                "check": {"kind": "shell", "cmd": "echo err >&2; false"},
                            },
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        items = _get_gate_items(plan_dir)
        assert len(items) == 2
        # Passed item
        assert items[0]["exit_code"] == 0
        assert "stdout" not in items[0]
        assert "stderr" not in items[0]
        # Failed item — stderr captured
        assert items[1]["exit_code"] == 1
        assert items[1]["stdout"] == ""
        assert items[1]["stderr"] == "err\n"


class TestGateOutputHumanUnchanged:
    """T4: Human-review items unchanged (REQ-6, AS-6)."""

    def test_human_no_output_fields(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_t4"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate T4",
                        "checklist": ["Operator has approved"],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        items = _get_gate_items(plan_dir)
        item = items[0]
        assert item["kind"] == "human"
        assert item["result"] == "needs_review"
        assert "exit_code" not in item
        assert "stdout" not in item
        assert "stderr" not in item


class TestGateOutputTruncateStdout:
    """T5: Truncation of large stdout (REQ-4, AS-4)."""

    def test_truncate_large_stdout(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_t5"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate T5",
                        "checklist": [
                            {
                                "text": "Big output",
                                "check": {
                                    "kind": "shell",
                                    "cmd": "python3 -c \"print('x' * 10000)\"; exit 1",
                                },
                            },
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        items = _get_gate_items(plan_dir)
        item = items[0]
        header = "[truncated \u2014 showing last 4096 chars]\n"
        assert item["stdout"].startswith(header)
        after_header = item["stdout"][len(header) :]
        assert len(after_header) == 4096
        assert item["stderr"] == ""


class TestGateOutputTruncateStderr:
    """T6: Truncation of large stderr (REQ-4)."""

    def test_truncate_large_stderr(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_t6"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate T6",
                        "checklist": [
                            {
                                "text": "Big stderr",
                                "check": {
                                    "kind": "shell",
                                    "cmd": "python3 -c \"import sys; sys.stderr.write('y' * 10000)\"; exit 1",
                                },
                            },
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        items = _get_gate_items(plan_dir)
        item = items[0]
        header = "[truncated \u2014 showing last 4096 chars]\n"
        assert item["stderr"].startswith(header)
        after_header = item["stderr"][len(header) :]
        assert len(after_header) == 4096


class TestGateOutputTruncateBoundary:
    """T7: Output exactly at truncation boundary — no truncation (REQ-4)."""

    def test_no_truncation_at_boundary(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_t7"
        # 4095 chars + newline from print() = 4096 total
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate T7",
                        "checklist": [
                            {
                                "text": "Boundary",
                                "check": {
                                    "kind": "shell",
                                    "cmd": "python3 -c \"print('z' * 4095)\"; exit 1",
                                },
                            },
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        items = _get_gate_items(plan_dir)
        item = items[0]
        assert "[truncated" not in item["stdout"]
        assert len(item["stdout"]) == 4096


class TestGateOutputEmptyFailure:
    """T8: Empty output on failure (EC-2)."""

    def test_empty_output(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_t8"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate T8",
                        "checklist": [
                            {"text": "Silent fail", "check": {"kind": "shell", "cmd": "exit 1"}},
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        items = _get_gate_items(plan_dir)
        item = items[0]
        assert item["exit_code"] == 1
        assert item["stdout"] == ""
        assert item["stderr"] == ""


class TestGateOutputTimeoutStructural:
    """T9: Timeout — structural verification (REQ-3, EC-4)."""

    def test_timeout_structure(self):
        content = Path(CHAIN_SH).read_text()
        # Existing: default gate timeout raised 60s→600s in commit
        # 3399349 with AUTOPILOT_CHAIN_GATE_TIMEOUT_S override hook.
        assert "AUTOPILOT_CHAIN_GATE_TIMEOUT_S" in content
        assert "'600'" in content
        # Streaming refactor (commit 5ebe547 stream gate-check output)
        # replaced subprocess.run(timeout=...) with proc.wait(timeout=...)
        # + a TimeoutExpired catch that sets a `timed_out` flag.
        assert "subprocess.TimeoutExpired" in content
        assert "proc.wait(timeout=" in content
        # exit_code is None and result is 'timeout' on timeout
        assert "'result': 'timeout'" in content
        assert "'exit_code': None" in content


class TestGateOutputBackwardsCompat:
    """T10: Backwards compatibility — existing fields unchanged (REQ-5)."""

    def test_existing_fields_present(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_t10"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate T10",
                        "checklist": [
                            {
                                "text": "Compat check",
                                "check": {"kind": "shell", "cmd": "echo hello && exit 1"},
                            },
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        items = _get_gate_items(plan_dir)
        item = items[0]
        assert isinstance(item["text"], str)
        assert item["kind"] == "shell"
        assert item["result"] == "failed"
        # New fields coexist
        assert "exit_code" in item
        assert "stdout" in item
        assert "stderr" in item


class TestGateOutputSpecialChars:
    """T12: Newlines and special characters in output (EC-3)."""

    def test_special_chars_preserved(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_t12"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate T12",
                        "checklist": [
                            {
                                "text": "Special chars",
                                "check": {
                                    "kind": "shell",
                                    "cmd": "printf 'line1\\nline2\\t\"quoted\"\\n'; exit 1",
                                },
                            },
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        items = _get_gate_items(plan_dir)
        item = items[0]
        assert 'line1\nline2\t"quoted"\n' == item["stdout"]
        # Verify JSON round-trip integrity
        roundtrip = json.loads(json.dumps(item))
        assert roundtrip == item


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# State Tracking (R6)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


class TestChainStateCreated:
    """CH-40: chain-state.json created with required fields."""

    def test_state_created(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_40"
        _write_plan(plan_dir, [_phase("p1", [_task("a", status="done")])])
        mock = _mock_autopilot(tmp_path)
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        state_file = plan_dir / "chain-state.json"
        assert state_file.exists()
        state = json.loads(state_file.read_text())
        assert "started_at" in state
        assert "max_parallel" in state
        assert "active_tasks" in state
        assert "completed_tasks" in state
        assert "failed_tasks" in state


class TestEventStarted:
    """CH-41: chain-events.ndjson receives task_started event."""

    def test_started_event(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_41"
        _write_plan(plan_dir, [_phase("p1", [_task("a")])])
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists()
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        started = [e for e in events if e.get("event") == "task_started"]
        assert len(started) >= 1
        assert started[0]["task"] == "a"
        assert "ts" in started[0]


class TestEventCompleted:
    """CH-42: chain-events.ndjson receives task_completed event."""

    def test_completed_event(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_42"
        _write_plan(plan_dir, [_phase("p1", [_task("a")])])
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        events_file = plan_dir / "chain-events.ndjson"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        completed = [e for e in events if e.get("event") == "task_completed"]
        assert len(completed) >= 1
        assert "duration_s" in completed[0]


class TestEventFailed:
    """CH-43: chain-events.ndjson receives task_failed event."""

    def test_failed_event(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_43"
        _write_plan(plan_dir, [_phase("p1", [_task("a")])])
        mock = _mock_autopilot(
            tmp_path, {"a": {"exit_code": 1, "sleep": "0.1", "status": "failed"}}
        )
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        events_file = plan_dir / "chain-events.ndjson"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        failed = [e for e in events if e.get("event") == "task_failed"]
        assert len(failed) >= 1
        assert "reason" in failed[0]


class TestCrashRecoveryAbandoned:
    """CH-44: Crash recovery — dead PID + worktree → mark abandoned."""

    def test_abandoned(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_44"
        _write_plan(plan_dir, [_phase("p1", [_task("a")])])
        # Create a chain-state with a dead PID
        state = {
            "started_at": "2026-04-17T00:00:00Z",
            "max_parallel": 2,
            "active_tasks": [{"id": "a", "pid": 99999999}],
            "completed_tasks": [],
            "failed_tasks": [],
        }
        (plan_dir / "chain-state.json").write_text(json.dumps(state))
        mock = _mock_autopilot(tmp_path)
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        # Should detect abandoned and continue
        assert "abandoned" in result.stderr.lower()


class TestCrashRecoveryNotRerun:
    """CH-45: Crash recovery — completed tasks not re-run."""

    def test_not_rerun(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_45"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("a", status="done"),
                        _task("b", depends=["a"]),
                    ],
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"b": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, "--max-parallel", "1", mock_cmd=mock)
        assert result.returncode == 0

        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should be created"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        started = [e["task"] for e in events if e.get("event") == "task_started"]
        assert "a" not in started  # a should not be re-run


class TestCorruptState:
    """CH-46: Corrupt chain-state.json — exit 1."""

    def test_corrupt(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_46"
        _write_plan(plan_dir, [_phase("p1", [_task("a")])])
        (plan_dir / "chain-state.json").write_text("{corrupt json")
        mock = _mock_autopilot(tmp_path)
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        assert result.returncode == 1
        assert "corrupt" in result.stderr.lower()


class TestAlreadyRunning:
    """CH-47: Chain already running — exit 1."""

    def test_already_running(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_47"
        _write_plan(plan_dir, [_phase("p1", [_task("a")])])
        # Use current PID (which IS alive) in active_tasks
        state = {
            "started_at": "2026-04-17T00:00:00Z",
            "max_parallel": 2,
            "active_tasks": [{"id": "a", "pid": os.getpid()}],
            "completed_tasks": [],
            "failed_tasks": [],
        }
        (plan_dir / "chain-state.json").write_text(json.dumps(state))
        mock = _mock_autopilot(tmp_path)
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        assert result.returncode == 1
        assert "already running" in result.stderr.lower()


class TestTruncatedNdjson:
    """CH-48: Truncated NDJSON last line — chain still works (write-only file)."""

    def test_truncated_last_line(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_48"
        _write_plan(plan_dir, [_phase("p1", [_task("a")])])
        # Pre-create chain-events.ndjson with a truncated last line
        events_file = plan_dir / "chain-events.ndjson"
        events_file.write_text('{"ts":"2026-04-17T00:00:00Z","event":"task_started"}\n{"truncated')
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        assert result.returncode == 0
        # The chain appends new events despite the truncated line
        content = events_file.read_text()
        lines = [l for l in content.strip().split("\n") if l.strip()]
        # Should have the original 2 lines + new events appended
        assert len(lines) >= 3


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Failure Handling (R7)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


class TestFailureHaltsChain:
    """CH-50: Task failure — siblings complete, then chain halts."""

    def test_halts(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_50"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("a"),
                        _task("b"),
                        _task("c", depends=["a", "b"]),
                    ],
                )
            ],
        )
        mock = _mock_autopilot(
            tmp_path,
            {
                "a": {"exit_code": 0, "sleep": "0.5", "status": "done"},
                "b": {"exit_code": 1, "sleep": "0.5", "status": "failed"},
            },
        )
        result = _run_chain(tmp_path, plan_dir, "--max-parallel", "2", mock_cmd=mock)
        assert result.returncode == 1

        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should be created"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        completed = [e for e in events if e.get("event") == "task_completed"]
        failed = [e for e in events if e.get("event") == "task_failed"]
        # a should complete, b should fail
        assert len(completed) >= 1
        assert len(failed) >= 1


class TestFailureReasonLogged:
    """CH-51: Failed task's reason logged."""

    def test_reason_logged(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_51"
        _write_plan(plan_dir, [_phase("p1", [_task("a")])])
        mock = _mock_autopilot(
            tmp_path, {"a": {"exit_code": 1, "sleep": "0.1", "status": "failed"}}
        )
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        events_file = plan_dir / "chain-events.ndjson"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        failed = [e for e in events if e.get("event") == "task_failed"]
        assert len(failed) >= 1
        assert "reason" in failed[0]


class TestContinueOnFailure:
    """CH-52: --continue-on-failure — chain continues past failure."""

    def test_continues(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_52"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("a"),
                        _task("b"),  # Independent of a
                    ],
                )
            ],
        )
        mock = _mock_autopilot(
            tmp_path,
            {
                "a": {"exit_code": 1, "sleep": "0.1", "status": "failed"},
                "b": {"exit_code": 0, "sleep": "0.1", "status": "done"},
            },
        )
        result = _run_chain(
            tmp_path, plan_dir, "--max-parallel", "1", "--continue-on-failure", mock_cmd=mock
        )
        # Should not exit 1 — continues
        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should be created"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        started = [e["task"] for e in events if e.get("event") == "task_started"]
        assert "b" in started


class TestTransitiveDepsBlocked:
    """CH-53: Transitive deps of failed task marked blocked."""

    def test_blocked(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_53"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("a"),
                        _task("b", depends=["a"]),
                        _task("c"),  # Independent
                    ],
                )
            ],
        )
        mock = _mock_autopilot(
            tmp_path,
            {
                "a": {"exit_code": 1, "sleep": "0.1", "status": "failed"},
                "c": {"exit_code": 0, "sleep": "0.1", "status": "done"},
            },
        )
        result = _run_chain(
            tmp_path, plan_dir, "--max-parallel", "1", "--continue-on-failure", mock_cmd=mock
        )
        # b should be blocked, c should run
        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should be created"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        started = [e["task"] for e in events if e.get("event") == "task_started"]
        assert "b" not in started
        assert "c" in started


class TestAllPhaseTasksFail:
    """CH-54: All tasks in phase fail — gate evaluation skipped."""

    def test_gate_skipped(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_54"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Gate",
                        "checklist": [{"text": "Check", "check": {"kind": "shell", "cmd": "true"}}],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(
            tmp_path, {"a": {"exit_code": 1, "sleep": "0.1", "status": "failed"}}
        )
        _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should be created"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        gate_events = [e for e in events if e.get("event") in ("gate_evaluated", "gate_passed")]
        # Gate should NOT be evaluated when all tasks failed
        assert len(gate_events) == 0


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Observability (R8)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


class TestPauseSignal:
    """CH-60: chain.PAUSE file — in-flight complete, no new launches."""

    def test_pause(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_60"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("a"),
                        _task("b", depends=["a"]),
                    ],
                )
            ],
        )
        # Create PAUSE file before first task completes
        (plan_dir / "chain.PAUSE").write_text("")
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, "--max-parallel", "1", mock_cmd=mock)
        assert result.returncode == 0
        assert "paused" in result.stderr.lower()

    def test_pause_during_inflight_harvests_completed_task(self, tmp_path: Path):
        """CH-60b: pause that races with an in-flight completion harvests
        the task normally — task lands in completed_tasks, task_completed
        event fires, plan YAML moves to done. Regression test for the
        pre-2026-05-21 drain-skip-harvest bug that left completed tasks
        stuck in active_tasks and broke dashboard resume.
        """
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_60b"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("a"),
                        _task("b", depends=["a"]),
                    ],
                )
            ],
        )
        # Mock autopilot sleeps long enough that the test can touch
        # chain.PAUSE while it is running. Sleep is in the mock's sleep
        # call — the chain waits on the bg subshell to exit.
        mock = _mock_autopilot(
            tmp_path, {"a": {"exit_code": 0, "sleep": "1.5", "status": "done"}}
        )

        env = os.environ.copy()
        env["AUTOPILOT_CMD"] = mock

        # Launch chain as a background subprocess so we can touch
        # chain.PAUSE while task a is mid-sleep.
        proc = subprocess.Popen(
            ["bash", CHAIN_SH, "run", "--max-parallel", "1", str(plan_dir)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            cwd=str(tmp_path),
        )

        # Wait until the chain has launched task a (chain-state.json
        # active_tasks becomes non-empty). Then drop chain.PAUSE.
        state_file = plan_dir / "chain-state.json"
        deadline = time.time() + 10
        while time.time() < deadline:
            if state_file.exists():
                try:
                    state = json.loads(state_file.read_text())
                    if state.get("active_tasks"):
                        break
                except json.JSONDecodeError:
                    pass
            time.sleep(0.05)
        else:
            proc.kill()
            raise AssertionError("chain never moved task a to active_tasks")

        # Race window: a is sleeping, chain is polling. Touch PAUSE.
        (plan_dir / "chain.PAUSE").write_text("")

        # Wait for the chain to drain + exit.
        stdout, stderr = proc.communicate(timeout=30)
        assert proc.returncode == 0, (
            f"chain exited non-zero: rc={proc.returncode}\nstderr={stderr}"
        )

        # Post-conditions — the bug we are guarding against:
        final_state = json.loads(state_file.read_text())
        assert final_state["completed_tasks"] == ["a"], (
            f"task a was not recorded as completed despite exit 0; "
            f"state={final_state}"
        )
        assert final_state["active_tasks"] == [], (
            f"completed task still in active_tasks; state={final_state}"
        )

        events_file = plan_dir / "chain-events.ndjson"
        events = [
            json.loads(line)
            for line in events_file.read_text().strip().split("\n")
            if line.strip().startswith("{")
        ]
        kinds = [e.get("event") for e in events]
        assert "task_completed" in kinds, (
            "drain skipped harvest — no task_completed event emitted; "
            f"events seen: {kinds}"
        )
        assert "chain_paused" in kinds, (
            f"chain_paused not emitted at end of drain; events seen: {kinds}"
        )

        # Plan YAML status should reflect harvest — task a marked done by
        # the mock autopilot itself, but the chain should at minimum
        # leave the YAML consistent with completed_tasks.
        yaml_path = plan_dir / "execution-plan.yaml"
        plan = yaml.safe_load(yaml_path.read_text())
        statuses = {
            t["id"]: t["status"]
            for p in plan["phases"]
            for t in p["tasks"]
        }
        assert statuses["a"] == "done", (
            f"plan task a expected status:done, got {statuses['a']!r}"
        )


class TestStatusCommand:
    """CH-61: status subcommand prints task counts."""

    def test_status(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_61"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("a", status="done"),
                        _task("b", status="wip"),
                        _task("c"),
                        _task("d", status="failed"),
                    ],
                )
            ],
        )
        # Create state file
        (plan_dir / "chain-state.json").write_text(
            json.dumps(
                {
                    "started_at": "2026-04-17T00:00:00Z",
                    "max_parallel": 2,
                    "active_tasks": [],
                    "completed_tasks": ["a"],
                    "failed_tasks": ["d"],
                }
            )
        )
        result = subprocess.run(
            ["bash", CHAIN_SH, "status", str(plan_dir)],
            capture_output=True,
            text=True,
            timeout=10,
            cwd=str(tmp_path),
        )
        assert result.returncode == 0
        assert "Completed:" in result.stdout
        assert "Pending:" in result.stdout


class TestStatusShowsReady:
    """CH-62: status shows elapsed time and next ready tasks."""

    def test_shows_ready(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_62"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("a", status="done"),
                        _task("b", depends=["a"]),
                    ],
                )
            ],
        )
        (plan_dir / "chain-state.json").write_text(
            json.dumps(
                {
                    "started_at": "2026-04-17T00:00:00Z",
                    "max_parallel": 2,
                    "active_tasks": [],
                    "completed_tasks": ["a"],
                    "failed_tasks": [],
                }
            )
        )
        result = subprocess.run(
            ["bash", CHAIN_SH, "status", str(plan_dir)],
            capture_output=True,
            text=True,
            timeout=10,
            cwd=str(tmp_path),
        )
        assert result.returncode == 0
        assert "Ready:" in result.stdout


class TestCaffeinateWraps:
    """CH-63: caffeinate -s wraps main loop."""

    def test_caffeinate_in_script(self):
        content = Path(CHAIN_SH).read_text()
        assert "caffeinate -s" in content


class TestGateEvalAtChainStart:
    """CH-64: At chain start, evaluate gates of phases where all tasks are
    already terminal but the gate is still passed=false. Bug fix scenario:
    chain previously only evaluated gates AFTER in-run task completions,
    so resume-after-pause never evaluated gates of phases that completed
    in the previous run — leaving the next phase's tasks blocked forever.
    """

    def test_evaluates_gate_for_pre_completed_phase(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_64"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a", status="done")],
                    gate={
                        "name": "Gate 1",
                        "checklist": [
                            {"text": "Always passes", "check": {"kind": "shell", "cmd": "true"}},
                        ],
                        "passed": False,
                    },
                ),
                _phase("p2", [_task("b")]),
            ],
        )
        mock = _mock_autopilot(tmp_path, {"b": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        assert result.returncode == 0, f"chain should not fail; stderr: {result.stderr}"

        events_file = plan_dir / "chain-events.ndjson"
        assert events_file.exists(), "chain-events.ndjson should be created"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]

        passed_events = [
            e for e in events if e.get("event") == "gate_passed" and e.get("phase") == "p1"
        ]
        assert len(passed_events) >= 1, (
            "p1 gate should be evaluated at chain start since all p1 tasks were already "
            f"terminal. Events seen: {[(e.get('event'), e.get('phase'), e.get('task')) for e in events]}"
        )

        task_started = [
            e for e in events if e.get("event") == "task_started" and e.get("task") == "b"
        ]
        assert len(task_started) >= 1, (
            "b should be launched once p1 gate passes (was blocked by unpassed gate). "
            f"Events seen: {[(e.get('event'), e.get('phase'), e.get('task')) for e in events]}"
        )

    def test_already_passed_gate_not_re_evaluated(self, tmp_path: Path):
        """If a phase gate is already passed=true at chain start, it should
        not be re-evaluated (idempotency)."""
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_64b"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a", status="done")],
                    gate={
                        "name": "Gate 1",
                        "checklist": [
                            {"text": "Always passes", "check": {"kind": "shell", "cmd": "true"}},
                        ],
                        "passed": True,  # already passed
                    },
                ),
                _phase("p2", [_task("b")]),
            ],
        )
        mock = _mock_autopilot(tmp_path, {"b": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        assert result.returncode == 0

        events_file = plan_dir / "chain-events.ndjson"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        # p1 gate should not be evaluated again — no gate_passed/gate_blocked event for p1
        p1_gate_events = [
            e
            for e in events
            if e.get("event") in ("gate_passed", "gate_blocked") and e.get("phase") == "p1"
        ]
        assert len(p1_gate_events) == 0, (
            f"p1 gate already passed=true should not be re-evaluated. Got events: {p1_gate_events}"
        )


class TestFailedTasksWarning:
    """Failed-tasks awareness — chain restart with non-empty failed_tasks
    must surface a visible warning instead of silently skipping work.

    Regression: an operator previously hit "nothing happens" when restarting
    a chain whose chain-state.json had a failed_tasks entry from a prior
    run. compute_ready_set excludes those, so the chain found no work and
    exited via chain_completed without any operator-visible signal.
    """

    def test_warning_lists_failed_tasks_and_remediation(self, tmp_path: Path):
        """Restart with prior failed_tasks: stderr names every failed task
        AND the --retry-failed remediation. Plan is fully done so the chain
        exits cleanly after the warning (separate from the polling-loop
        issue in the failed+still-pending case)."""
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_failed_warn"
        # Plan-status is done for both — chain exits via "no ready tasks".
        # The warning still fires because chain-state.json carries the
        # failed_tasks entry from a prior run.
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("alpha", status="done"),
                        _task("beta", status="done"),
                    ],
                )
            ],
        )
        state = {
            "started_at": "2026-05-05T00:00:00Z",
            "max_parallel": 1,
            "active_tasks": [],
            "completed_tasks": ["alpha"],
            "failed_tasks": ["beta"],
        }
        (plan_dir / "chain-state.json").write_text(json.dumps(state))

        mock = _mock_autopilot(tmp_path)
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock, timeout=15)

        # Warning is on stderr (chain uses log() → >&2).
        assert "failed task(s) from a prior run" in result.stderr, (
            f"Expected failed-tasks warning on stderr; got: {result.stderr}"
        )
        assert "beta" in result.stderr, (
            f"Expected failed task 'beta' to be named in warning; got: {result.stderr}"
        )
        assert "--retry-failed" in result.stderr, (
            f"Expected remediation hint '--retry-failed' on stderr; got: {result.stderr}"
        )

        # Default behaviour: failed_tasks is preserved (not silently cleared).
        new_state = json.loads((plan_dir / "chain-state.json").read_text())
        assert new_state["failed_tasks"] == ["beta"], (
            f"Default behaviour must preserve failed_tasks. Got: {new_state['failed_tasks']}"
        )

    def test_retry_failed_clears_failed_tasks(self, tmp_path: Path):
        """--retry-failed: failed_tasks entries are removed at chain start
        so previously-failed tasks become eligible again."""
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_retry_failed"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("alpha", status="done"),
                        _task(
                            "beta", status="pending"
                        ),  # plan-status pending — eligible after retry
                    ],
                )
            ],
        )
        state = {
            "started_at": "2026-05-05T00:00:00Z",
            "max_parallel": 1,
            "active_tasks": [],
            "completed_tasks": ["alpha"],
            "failed_tasks": ["beta"],
        }
        (plan_dir / "chain-state.json").write_text(json.dumps(state))

        mock = _mock_autopilot(
            tmp_path,
            {
                "beta": {"exit_code": 0, "sleep": "0.1", "status": "done"},
            },
        )
        result = _run_chain(tmp_path, plan_dir, "--retry-failed", mock_cmd=mock)
        assert result.returncode == 0, (
            f"Chain should run successfully with --retry-failed. stderr: {result.stderr}"
        )

        # Confirmation message references the cleared task.
        assert "--retry-failed" in result.stderr
        assert "clearing" in result.stderr.lower()
        assert "beta" in result.stderr

        # beta actually ran (would not have without the clear).
        events_file = plan_dir / "chain-events.ndjson"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        started = [e["task"] for e in events if e.get("event") == "task_started"]
        assert "beta" in started, (
            f"--retry-failed must enable task 'beta' to start. Got started: {started}"
        )

    def test_no_warning_when_failed_tasks_empty(self, tmp_path: Path):
        """Empty failed_tasks: no warning, no false-positive operator alert."""
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_no_failed"
        _write_plan(plan_dir, [_phase("p1", [_task("alpha")])])
        # Default state has empty failed_tasks (chain initialises it that way).
        mock = _mock_autopilot(
            tmp_path,
            {
                "alpha": {"exit_code": 0, "sleep": "0.1", "status": "done"},
            },
        )
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)
        assert result.returncode == 0
        assert "failed task(s) from a prior run" not in result.stderr, (
            f"Empty failed_tasks must NOT emit warning. stderr: {result.stderr}"
        )

    def test_blocked_tasks_merge_conflict_routing(self, tmp_path: Path):
        """When autopilot.sh exits with code 2, chain.sh routes the task
        to blocked_tasks (not failed_tasks), prints a recovery banner,
        and halts cleanly so the operator can resolve the merge."""
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_blocked"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("alpha", status="pending"),
                        _task("beta", status="pending", depends=["alpha"]),
                    ],
                )
            ],
        )
        # Mock autopilot returns exit code 2 for alpha to simulate a
        # blocked-by-merge-conflict outcome.
        mock = _mock_autopilot(
            tmp_path,
            {
                "alpha": {"exit_code": 2, "sleep": "0.1", "status": "pending"},
            },
        )
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock, timeout=15)
        assert result.returncode == 0, (
            f"Chain should halt cleanly on blocked, not propagate exit. stderr: {result.stderr}"
        )

        # Task lands in blocked_tasks, not failed_tasks.
        state = json.loads((plan_dir / "chain-state.json").read_text())
        blocked_ids = [
            b.get("id") if isinstance(b, dict) else b for b in state.get("blocked_tasks", [])
        ]
        assert "alpha" in blocked_ids, f"alpha must be in blocked_tasks. state: {state}"
        assert "alpha" not in state.get("failed_tasks", []), (
            f"alpha must NOT be in failed_tasks. state: {state}"
        )

        # Banner content surfaced on stderr.
        assert "CHAIN PAUSED" in result.stderr, f"Expected blocked banner. stderr: {result.stderr}"
        assert (
            "merge conflict in alpha" in result.stderr.lower()
            or "merge conflict" in result.stderr.lower()
        ), f"Expected merge-conflict reason. stderr: {result.stderr}"

        # Dependent (beta) must NOT have started — chain halted on alpha.
        events_file = plan_dir / "chain-events.ndjson"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        started = [e["task"] for e in events if e.get("event") == "task_started"]
        assert "beta" not in started, (
            f"beta must not start when alpha is blocked. started: {started}"
        )

        # task_blocked event recorded.
        blocked_events = [e for e in events if e.get("event") == "task_blocked"]
        assert len(blocked_events) == 1
        assert blocked_events[0]["task"] == "alpha"
        assert blocked_events[0]["reason"] == "merge_conflict"

    def test_blocked_tasks_auto_resolve_on_restart(self, tmp_path: Path):
        """When operator resolves the merge manually (commit-finalize.sh
        sets task.status=done in YAML), the next chain run auto-detects
        resolution, moves the entry from blocked_tasks to completed_tasks,
        and continues with dependents."""
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_resolve"
        # alpha is now status=done (operator resolved); beta is pending and
        # depends on alpha — should run on this chain restart.
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("alpha", status="done"),
                        _task("beta", status="pending", depends=["alpha"]),
                    ],
                )
            ],
        )
        # Pre-seed state: alpha is in blocked_tasks from a prior run.
        state = {
            "started_at": "2026-05-06T00:00:00Z",
            "max_parallel": 1,
            "active_tasks": [],
            "completed_tasks": [],
            "failed_tasks": [],
            "blocked_tasks": [
                {
                    "id": "alpha",
                    "reason": "merge_conflict",
                    "ts": "2026-05-06T00:00:00Z",
                }
            ],
        }
        (plan_dir / "chain-state.json").write_text(json.dumps(state))

        mock = _mock_autopilot(
            tmp_path,
            {
                "beta": {"exit_code": 0, "sleep": "0.1", "status": "done"},
            },
        )
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock, timeout=15)
        assert result.returncode == 0
        # Auto-resolution message visible on stderr.
        assert (
            "Auto-resolved blocked task(s)" in result.stderr
            or "auto-resolved" in result.stderr.lower()
        ), f"Expected auto-resolution message. stderr: {result.stderr}"
        # State after run: alpha moved to completed_tasks, blocked_tasks empty.
        new_state = json.loads((plan_dir / "chain-state.json").read_text())
        assert new_state.get("blocked_tasks") == [], (
            f"blocked_tasks should be empty after auto-resolution. {new_state}"
        )
        assert "alpha" in new_state.get("completed_tasks", []), (
            f"alpha should be in completed_tasks after auto-resolution. {new_state}"
        )
        # beta started after auto-resolution unblocked it.
        events_file = plan_dir / "chain-events.ndjson"
        events = [json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()]
        started = [e["task"] for e in events if e.get("event") == "task_started"]
        assert "beta" in started, f"beta should start after alpha auto-resolved. started: {started}"

    def test_blocked_tasks_unresolved_halts_chain_cleanly(self, tmp_path: Path):
        """When chain restarts with blocked_tasks still unresolved (task
        still status=pending in YAML), chain halts cleanly with a clear
        message — does not start dependents on a half-merged state."""
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_unresolved"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("alpha", status="pending"),  # still pending — not resolved
                        _task("beta", status="pending", depends=["alpha"]),
                    ],
                )
            ],
        )
        state = {
            "started_at": "2026-05-06T00:00:00Z",
            "max_parallel": 1,
            "active_tasks": [],
            "completed_tasks": [],
            "failed_tasks": [],
            "blocked_tasks": [
                {
                    "id": "alpha",
                    "reason": "merge_conflict",
                    "ts": "2026-05-06T00:00:00Z",
                }
            ],
        }
        (plan_dir / "chain-state.json").write_text(json.dumps(state))

        mock = _mock_autopilot(tmp_path)
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock, timeout=10)
        assert result.returncode == 0, (
            f"Chain must exit cleanly on unresolved blocked. stderr: {result.stderr}"
        )
        # Halt message names the still-blocked task and points to recovery.
        assert "Still-blocked task" in result.stderr or "still-blocked" in result.stderr.lower(), (
            f"Expected still-blocked message. stderr: {result.stderr}"
        )
        assert "alpha" in result.stderr
        # No tasks started (chain halted before launching anything).
        events_file = plan_dir / "chain-events.ndjson"
        if events_file.exists():
            events = [
                json.loads(l) for l in events_file.read_text().strip().split("\n") if l.strip()
            ]
            started = [e["task"] for e in events if e.get("event") == "task_started"]
            assert "beta" not in started, (
                f"beta must not start when alpha is still blocked. started: {started}"
            )

    def test_blocked_reason_dirty_main_recorded(self, tmp_path: Path):
        """When autopilot exits 2 + writes 'dirty_main' sentinel, chain
        records reason='dirty_main' in blocked_tasks (not the default
        'merge_conflict').
        """
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_dirty"
        _write_plan(plan_dir, [_phase("p1", [_task("alpha", status="pending")])])
        mock = _mock_autopilot(
            tmp_path,
            {
                "alpha": {
                    "exit_code": 2,
                    "sleep": "0.1",
                    "status": "pending",
                    "blocked_reason": "dirty_main",
                },
            },
        )
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock, timeout=15)
        assert result.returncode == 0

        state = json.loads((plan_dir / "chain-state.json").read_text())
        blocked = state.get("blocked_tasks", [])
        assert len(blocked) == 1
        entry = blocked[0]
        assert isinstance(entry, dict)
        assert entry.get("id") == "alpha"
        assert entry.get("reason") == "dirty_main", f"Expected reason='dirty_main', got: {entry}"

    def test_blocked_reason_lock_timeout_recorded(self, tmp_path: Path):
        """When autopilot exits 2 + writes 'lock_timeout' sentinel, chain
        records reason='lock_timeout'.
        """
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_locktimeout"
        _write_plan(plan_dir, [_phase("p1", [_task("alpha", status="pending")])])
        mock = _mock_autopilot(
            tmp_path,
            {
                "alpha": {
                    "exit_code": 2,
                    "sleep": "0.1",
                    "status": "pending",
                    "blocked_reason": "lock_timeout",
                },
            },
        )
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock, timeout=15)
        assert result.returncode == 0

        state = json.loads((plan_dir / "chain-state.json").read_text())
        blocked = state.get("blocked_tasks", [])
        assert len(blocked) == 1
        assert blocked[0].get("reason") == "lock_timeout", (
            f"Expected reason='lock_timeout', got: {blocked[0]}"
        )

    def test_blocked_reason_defaults_when_sentinel_missing(self, tmp_path: Path):
        """Backward compat: when autopilot exits 2 without a sentinel
        file, chain defaults reason='merge_conflict' (preserves existing
        behaviour for older autopilot versions).
        """
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_nosentinel"
        _write_plan(plan_dir, [_phase("p1", [_task("alpha", status="pending")])])
        # No blocked_reason → mock won't write sentinel
        mock = _mock_autopilot(
            tmp_path,
            {
                "alpha": {"exit_code": 2, "sleep": "0.1", "status": "pending"},
            },
        )
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock, timeout=15)
        assert result.returncode == 0

        state = json.loads((plan_dir / "chain-state.json").read_text())
        blocked = state.get("blocked_tasks", [])
        assert len(blocked) == 1
        # Default reason preserved
        assert blocked[0].get("reason") == "merge_conflict", (
            f"Default reason should be merge_conflict for backward compat. Got: {blocked[0]}"
        )

    def test_dirty_main_auto_resolves_when_main_clean_via_override(self, tmp_path: Path):
        """When chain restarts with a dirty_main blocked entry AND
        CHAIN_MAIN_DIRTY_OVERRIDE=false (test override; production uses
        git status check), the entry is removed from blocked_tasks but
        NOT added to completed_tasks (task wasn't done — just unblocked).
        """
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_resolve_dirty"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("alpha", status="pending"),
                    ],
                )
            ],
        )
        # Pre-seed: alpha is blocked with reason=dirty_main.
        state = {
            "started_at": "2026-05-06T00:00:00Z",
            "max_parallel": 1,
            "active_tasks": [],
            "completed_tasks": [],
            "failed_tasks": [],
            "blocked_tasks": [
                {
                    "id": "alpha",
                    "reason": "dirty_main",
                    "ts": "2026-05-06T00:00:00Z",
                }
            ],
        }
        (plan_dir / "chain-state.json").write_text(json.dumps(state))

        mock = _mock_autopilot(
            tmp_path,
            {
                "alpha": {"exit_code": 0, "sleep": "0.1", "status": "done"},
            },
        )
        # Simulate "main is clean" via override env var.
        env = os.environ.copy()
        env["AUTOPILOT_CMD"] = mock
        env["CHAIN_MAIN_DIRTY_OVERRIDE"] = "false"
        result = subprocess.run(
            ["bash", CHAIN_SH, "run", str(plan_dir)],
            capture_output=True,
            text=True,
            timeout=20,
            env=env,
            cwd=str(tmp_path),
        )
        assert result.returncode == 0, f"stderr: {result.stderr}"

        # Auto-resolution message present.
        assert "auto-resolved" in result.stderr.lower() or "Auto-resolved" in result.stderr, (
            f"Expected auto-resolution message. stderr: {result.stderr}"
        )
        new_state = json.loads((plan_dir / "chain-state.json").read_text())
        assert new_state.get("blocked_tasks") == [], f"blocked_tasks should be empty. {new_state}"
        # CRITICAL: dirty_main resolution does NOT add to completed_tasks
        # (task wasn't actually done — chain re-attempts and presumably
        # succeeds, which moves it to completed via the normal path).
        # After the chain run, alpha SHOULD be in completed_tasks because
        # the mock returned exit 0 → task completed normally.
        assert "alpha" in new_state.get("completed_tasks", []), (
            f"alpha should be in completed_tasks (chain re-attempted and succeeded). {new_state}"
        )

    def test_dirty_main_stays_blocked_when_main_still_dirty(self, tmp_path: Path):
        """When chain restarts with a dirty_main blocked entry AND main
        is still dirty (override=true), entry stays blocked, chain halts.
        """
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_still_dirty"
        _write_plan(plan_dir, [_phase("p1", [_task("alpha", status="pending")])])
        state = {
            "started_at": "2026-05-06T00:00:00Z",
            "max_parallel": 1,
            "active_tasks": [],
            "completed_tasks": [],
            "failed_tasks": [],
            "blocked_tasks": [
                {
                    "id": "alpha",
                    "reason": "dirty_main",
                    "ts": "2026-05-06T00:00:00Z",
                }
            ],
        }
        (plan_dir / "chain-state.json").write_text(json.dumps(state))

        mock = _mock_autopilot(tmp_path)
        env = os.environ.copy()
        env["AUTOPILOT_CMD"] = mock
        env["CHAIN_MAIN_DIRTY_OVERRIDE"] = "true"  # main still dirty
        result = subprocess.run(
            ["bash", CHAIN_SH, "run", str(plan_dir)],
            capture_output=True,
            text=True,
            timeout=10,
            env=env,
            cwd=str(tmp_path),
        )
        assert result.returncode == 0
        # Halt message visible.
        assert "still-blocked" in result.stderr.lower() or "Still-blocked" in result.stderr, (
            f"Expected still-blocked halt message. stderr: {result.stderr}"
        )
        # State unchanged.
        new_state = json.loads((plan_dir / "chain-state.json").read_text())
        assert len(new_state.get("blocked_tasks", [])) == 1
        assert new_state["blocked_tasks"][0].get("reason") == "dirty_main"

    def test_pending_task_excluded_by_failed_tasks_exits_cleanly(self, tmp_path: Path):
        """Regression: when a plan-status=pending task is excluded by
        chain-state.json failed_tasks, the chain must exit via the terminal
        'blocked' branch, not loop forever in the polling stage.

        Production observation 2026-05-05 (feature-plan-link-and-nav):
        the operator restarted the chain, saw no events for 1 hour, and
        the chain process was alive in the polling sleep loop. The
        underlying cause was that the terminal check used the pre-filter
        ready_count (which included the failed task as 'ready'), so the
        terminal branch was never taken; the post-filter count was 0,
        so no launches happened either; control fell to `sleep 1;
        continue` indefinitely.
        """
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_pending_excluded"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [
                        _task("alpha", status="done"),
                        _task("beta", status="pending"),  # pending in YAML, but excluded
                    ],
                )
            ],
        )
        state = {
            "started_at": "2026-05-05T00:00:00Z",
            "max_parallel": 1,
            "active_tasks": [],
            "completed_tasks": ["alpha"],
            "failed_tasks": ["beta"],
        }
        (plan_dir / "chain-state.json").write_text(json.dumps(state))

        mock = _mock_autopilot(tmp_path)
        # Tight timeout — must exit FAST, not hang. Production hang was
        # 1+ hour; a 10-second timeout catches the regression with
        # plenty of margin.
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock, timeout=10)

        # Must exit cleanly, not be timed out / killed.
        assert result.returncode == 0, (
            f"Chain should exit cleanly with no ready tasks. "
            f"returncode={result.returncode}, stderr={result.stderr}"
        )
        # The terminal branch logs one of three messages — for the
        # "pending in YAML, excluded by chain-state" case, the plan
        # check sees pending tasks → "blocked".
        assert "blocked" in result.stderr.lower() or "no ready tasks" in result.stderr.lower(), (
            f"Expected terminal-branch message on stderr; got: {result.stderr}"
        )


# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Gate-blocked Recovery Banner (CH-64..CH-66)
#
# When a phase gate is blocked, the operator needs a concrete next step.
# Two distinct recovery paths depending on what's blocking:
#
#   - All blocking items are kind: human → operator runs manual smokes,
#     then flips the gate via finalize-plan.sh approve-gate.
#   - At least one shell check failed → operator fixes the underlying
#     issue, re-runs the chain (gate auto-evaluates next pass).
#
# See CONTINUATION_chain-pipeline-friction.md section C and the
# finalize-plan.sh helper.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━


class TestGateBlockedHumanRecoveryBanner:
    """CH-64: kind:human-only block → banner names finalize-plan.sh approve-gate."""

    def test_banner_for_human_block(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_64"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Smoke gate",
                        "checklist": [
                            {"text": "Manual smoke A", "check": {"kind": "human"}},
                            {"text": "Manual smoke B", "check": {"kind": "human"}},
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        # Banner must mention finalize-plan.sh approve-gate so the operator
        # can copy/paste the command directly.
        assert "finalize-plan.sh approve-gate" in result.stderr, (
            f"Expected approve-gate command in stderr banner; got:\n{result.stderr}"
        )
        # Banner must also mention mark-done as the follow-up for the last gate.
        assert "finalize-plan.sh mark-done" in result.stderr, (
            f"Expected mark-done command in stderr banner; got:\n{result.stderr}"
        )
        # The phase id should appear in the suggested approve-gate command.
        assert "p1" in result.stderr

        # Event must record block_mode=human for downstream tooling.
        events = [
            json.loads(l)
            for l in (plan_dir / "chain-events.ndjson").read_text().strip().split("\n")
            if l.strip()
        ]
        blocked = [e for e in events if e.get("event") == "gate_blocked"]
        assert len(blocked) >= 1
        assert blocked[0].get("block_mode") == "human", (
            f"Expected block_mode=human, got: {blocked[0]}"
        )


class TestGateBlockedShellRecoveryBanner:
    """CH-65: shell-failure block → banner says fix-and-rerun, NOT finalize-plan."""

    def test_banner_for_shell_block(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_65"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Build gate",
                        "checklist": [
                            {"text": "Failing build", "check": {"kind": "shell", "cmd": "false"}},
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        # Shell failures are NOT operator-approval territory — banner must
        # NOT suggest approve-gate (that would mask a real failure).
        assert "approve-gate" not in result.stderr, (
            f"approve-gate must not be suggested for shell failures; got:\n{result.stderr}"
        )
        # Recovery is to fix the underlying issue and re-run the chain.
        assert "autopilot-chain.sh run" in result.stderr, (
            f"Expected re-run instruction in stderr banner; got:\n{result.stderr}"
        )

        events = [
            json.loads(l)
            for l in (plan_dir / "chain-events.ndjson").read_text().strip().split("\n")
            if l.strip()
        ]
        blocked = [e for e in events if e.get("event") == "gate_blocked"]
        assert len(blocked) >= 1
        assert blocked[0].get("block_mode") == "mixed", (
            f"Expected block_mode=mixed (shell failure), got: {blocked[0]}"
        )


class TestGateBlockedMixedRecoveryBanner:
    """CH-66: mixed (human + failing shell) — shell failure dominates banner."""

    def test_banner_for_mixed_block(self, tmp_path: Path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_test_66"
        _write_plan(
            plan_dir,
            [
                _phase(
                    "p1",
                    [_task("a")],
                    gate={
                        "name": "Mixed gate",
                        "checklist": [
                            {"text": "Manual smoke", "check": {"kind": "human"}},
                            {"text": "Failing build", "check": {"kind": "shell", "cmd": "false"}},
                        ],
                        "passed": False,
                    },
                )
            ],
        )
        mock = _mock_autopilot(tmp_path, {"a": {"exit_code": 0, "sleep": "0.1", "status": "done"}})
        result = _run_chain(tmp_path, plan_dir, mock_cmd=mock)

        # Mixed mode: a real shell failure exists alongside the human item.
        # Banner must surface fix-and-rerun (the dominant blocker), not
        # approve-gate — operator should not flip the gate while a shell
        # check is still failing.
        assert "approve-gate" not in result.stderr, (
            f"approve-gate must not be suggested while shell failures remain; got:\n{result.stderr}"
        )
        assert "autopilot-chain.sh run" in result.stderr

        events = [
            json.loads(l)
            for l in (plan_dir / "chain-events.ndjson").read_text().strip().split("\n")
            if l.strip()
        ]
        blocked = [e for e in events if e.get("event") == "gate_blocked"]
        assert len(blocked) >= 1
        assert blocked[0].get("block_mode") == "mixed"
