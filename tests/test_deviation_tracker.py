"""Tests for claude/tools/deviation-tracker.py — phase results writer (DT-1..14)."""

from __future__ import annotations

import fcntl
import json
import multiprocessing
import os
import signal
import subprocess
import sys
import threading
import time
from pathlib import Path

import pytest
import yaml
from conftest import TOOLS_DIR, import_tool

TRACKER = TOOLS_DIR / "deviation-tracker.py"


def _run_tracker(
    plan_yaml: Path, task_id: str, stdin_data: dict | str, timeout: int = 10
) -> subprocess.CompletedProcess:
    """Run deviation-tracker.py as a subprocess."""
    if isinstance(stdin_data, dict):
        stdin_str = json.dumps(stdin_data)
    else:
        stdin_str = stdin_data
    return subprocess.run(
        [sys.executable, str(TRACKER), "--plan-yaml", str(plan_yaml), "--task-id", task_id],
        input=stdin_str,
        capture_output=True,
        text=True,
        timeout=timeout,
    )


def _valid_phase_result(**overrides) -> dict:
    pr = {
        "phase": "ba",
        "timestamp": "2026-04-17T10:00:00Z",
        "conformance": "aligned",
        "acceptance_status": "met",
        "deviations": [],
    }
    pr.update(overrides)
    return pr


def _write_plan(tmp_path: Path, tasks: list[dict]) -> Path:
    plan = {
        "schema_version": "1.0.0",
        "name": "Test Plan",
        "phases": [
            {
                "id": "phase-1",
                "name": "Phase 1",
                "tasks": tasks,
            }
        ],
    }
    plan_file = tmp_path / "execution-plan.yaml"
    plan_file.write_text(yaml.dump(plan, default_flow_style=False))
    return plan_file


def _read_plan(plan_file: Path) -> dict:
    return yaml.safe_load(plan_file.read_text())


# --- DT-1: Valid phase_result appended ---


class TestValidAppend:
    """DT-1: Valid phase_result appended to existing phase_results array."""

    def test_appends_to_existing(self, tmp_path: Path):
        existing_pr = _valid_phase_result(phase="plan")
        plan_file = _write_plan(
            tmp_path,
            [
                {
                    "id": "task-1",
                    "name": "Task 1",
                    "status": "wip",
                    "phase_results": [existing_pr],
                }
            ],
        )
        new_pr = _valid_phase_result(phase="implement")
        result = _run_tracker(plan_file, "task-1", new_pr)
        assert result.returncode == 0

        plan = _read_plan(plan_file)
        task = plan["phases"][0]["tasks"][0]
        assert len(task["phase_results"]) == 2
        assert task["phase_results"][1]["phase"] == "implement"


# --- DT-2: phase_results created when absent ---


class TestCreatesArray:
    """DT-2: phase_results array created when absent."""

    def test_creates_when_absent(self, tmp_path: Path):
        plan_file = _write_plan(
            tmp_path,
            [
                {
                    "id": "task-1",
                    "name": "Task 1",
                    "status": "wip",
                }
            ],
        )
        pr = _valid_phase_result()
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 0

        plan = _read_plan(plan_file)
        task = plan["phases"][0]["tasks"][0]
        assert len(task["phase_results"]) == 1
        assert task["phase_results"][0]["phase"] == "ba"


# --- DT-3: Append-only preserves prior ---


class TestAppendOnly:
    """DT-3: Multiple appends preserve prior entries."""

    def test_multiple_appends(self, tmp_path: Path):
        plan_file = _write_plan(
            tmp_path,
            [
                {
                    "id": "task-1",
                    "name": "Task 1",
                    "status": "wip",
                }
            ],
        )
        for phase in ["ba", "plan", "implement"]:
            pr = _valid_phase_result(phase=phase)
            result = _run_tracker(plan_file, "task-1", pr)
            assert result.returncode == 0

        plan = _read_plan(plan_file)
        task = plan["phases"][0]["tasks"][0]
        phases = [pr["phase"] for pr in task["phase_results"]]
        assert phases == ["ba", "plan", "implement"]


# --- DT-4: Invalid conformance rejected ---


class TestInvalidConformance:
    """DT-4: Invalid conformance enum rejected."""

    def test_rejects(self, tmp_path: Path):
        plan_file = _write_plan(tmp_path, [{"id": "task-1", "name": "Task 1", "status": "wip"}])
        pr = _valid_phase_result(conformance="unknown")
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 1
        assert "conformance" in result.stderr.lower()


# --- DT-5: Invalid acceptance_status rejected ---


class TestInvalidAcceptanceStatus:
    """DT-5: Invalid acceptance_status enum rejected."""

    def test_rejects(self, tmp_path: Path):
        plan_file = _write_plan(tmp_path, [{"id": "task-1", "name": "Task 1", "status": "wip"}])
        pr = _valid_phase_result(acceptance_status="bad")
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 1
        assert "acceptance_status" in result.stderr.lower()


# --- DT-6: Invalid deviation type rejected ---


class TestInvalidDeviationType:
    """DT-6: Invalid deviations[].type enum rejected."""

    def test_rejects(self, tmp_path: Path):
        plan_file = _write_plan(tmp_path, [{"id": "task-1", "name": "Task 1", "status": "wip"}])
        pr = _valid_phase_result(
            deviations=[
                {
                    "type": "invalid",
                    "description": "x",
                    "reason": "y",
                    "impact": "added",
                    "criteria_affected": [],
                }
            ]
        )
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 1
        assert "type" in result.stderr.lower()


# --- DT-7: Invalid deviation impact rejected ---


class TestInvalidDeviationImpact:
    """DT-7: Invalid deviations[].impact enum rejected."""

    def test_rejects(self, tmp_path: Path):
        plan_file = _write_plan(tmp_path, [{"id": "task-1", "name": "Task 1", "status": "wip"}])
        pr = _valid_phase_result(
            deviations=[
                {
                    "type": "scope_change",
                    "description": "x",
                    "reason": "y",
                    "impact": "invalid",
                    "criteria_affected": [],
                }
            ]
        )
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 1
        assert "impact" in result.stderr.lower()


# --- DT-8: Missing required field rejected ---


class TestMissingRequiredField:
    """DT-8: Missing required field rejected."""

    def test_rejects(self, tmp_path: Path):
        plan_file = _write_plan(tmp_path, [{"id": "task-1", "name": "Task 1", "status": "wip"}])
        pr = {"phase": "ba", "timestamp": "2026-04-17T10:00:00Z"}  # missing conformance etc
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 1


# --- DT-9: Task not found ---


class TestTaskNotFound:
    """DT-9: Task ID not found exits 1 with diagnostic."""

    def test_exits_1(self, tmp_path: Path):
        plan_file = _write_plan(tmp_path, [{"id": "task-1", "name": "Task 1", "status": "wip"}])
        pr = _valid_phase_result()
        result = _run_tracker(plan_file, "nonexistent", pr)
        assert result.returncode == 1
        assert "not found" in result.stderr.lower()


# --- DT-10: Plan file not found exits 0 ---


class TestPlanNotFound:
    """DT-10: Plan file not found exits 0 with warning."""

    def test_exits_0_with_warning(self, tmp_path: Path):
        fake_path = tmp_path / "nonexistent.yaml"
        pr = _valid_phase_result()
        result = _run_tracker(fake_path, "task-1", pr)
        assert result.returncode == 0
        assert "not found" in result.stderr.lower() or "warning" in result.stderr.lower()


# --- DT-11: Empty deviations accepted ---


class TestEmptyDeviations:
    """DT-11: Empty deviations array accepted."""

    def test_accepted(self, tmp_path: Path):
        plan_file = _write_plan(tmp_path, [{"id": "task-1", "name": "Task 1", "status": "wip"}])
        pr = _valid_phase_result(deviations=[])
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 0


# --- DT-12: Atomic write ---


class TestAtomicWrite:
    """DT-12: Atomic write via temp file + os.replace."""

    def test_file_written_atomically(self, tmp_path: Path):
        plan_file = _write_plan(tmp_path, [{"id": "task-1", "name": "Task 1", "status": "wip"}])
        original_content = plan_file.read_text()
        pr = _valid_phase_result()
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 0
        # File should be updated (different from original)
        new_content = plan_file.read_text()
        assert new_content != original_content
        # And should be valid YAML
        plan = yaml.safe_load(new_content)
        assert plan["phases"][0]["tasks"][0]["phase_results"] is not None


# --- DT-13: Task without acceptance criteria ---


class TestNoAcceptanceCriteria:
    """DT-13: Phase result for task without acceptance criteria accepted."""

    def test_accepted(self, tmp_path: Path):
        plan_file = _write_plan(
            tmp_path,
            [
                {
                    "id": "task-1",
                    "name": "Task 1",
                    "status": "wip",
                    # no "acceptance" field
                }
            ],
        )
        pr = _valid_phase_result()
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 0


# --- DT-14: Write failure logged, non-blocking ---


class TestWriteFailure:
    """DT-14: Write failure logged to stderr, non-blocking."""

    def test_write_failure_logged(self, tmp_path: Path):
        plan_file = _write_plan(tmp_path, [{"id": "task-1", "name": "Task 1", "status": "wip"}])
        # Make the directory read-only to force write failure
        plan_file.parent.chmod(0o444)
        try:
            pr = _valid_phase_result()
            result = _run_tracker(plan_file, "task-1", pr)
            # EC4.3: write failure is non-blocking — must exit 0
            assert result.returncode == 0
            assert "error" in result.stderr.lower() or "warning" in result.stderr.lower()
        finally:
            plan_file.parent.chmod(0o755)


# ---------------------------------------------------------------------------
# TC-1..TC-6 — flock, SRP, exit-code contract
# ---------------------------------------------------------------------------


def _worker_append(plan_path: str, task_id: str, barrier_release_at: float) -> int:
    """multiprocessing worker: wait until shared timestamp, then run tracker."""
    # Coarse-grained "barrier": all workers spin until the wall-clock
    # passes barrier_release_at, so they reach the lock acquisition step
    # within microseconds of each other.
    while time.time() < barrier_release_at:
        time.sleep(0.001)
    pr = {
        "phase": "ba",
        "timestamp": "2026-04-30T00:00:00Z",
        "conformance": "aligned",
        "acceptance_status": "met",
        "deviations": [],
    }
    res = subprocess.run(
        [sys.executable, str(TRACKER), "--plan-yaml", plan_path, "--task-id", task_id],
        input=json.dumps(pr),
        capture_output=True,
        text=True,
        timeout=15,
    )
    return res.returncode


def _write_concurrent_plan(tmp_path: Path) -> Path:
    tmp_path.mkdir(parents=True, exist_ok=True)
    plan = {
        "schema_version": "1.0.0",
        "name": "concurrent",
        "phases": [
            {
                "id": "phase-1",
                "name": "Phase 1",
                "tasks": [
                    {"id": "task-a", "name": "Task A", "status": "wip"},
                    {"id": "task-b", "name": "Task B", "status": "wip"},
                ],
            }
        ],
    }
    plan_file = tmp_path / "execution-plan.yaml"
    plan_file.write_text(yaml.dump(plan, default_flow_style=False))
    return plan_file


# --- TC-1: Concurrent writes both land (REQ-6) ---


class TestConcurrentWrites:
    """TC-1: Two workers append concurrently → both phase_results entries land.

    The pre-flock implementation lost ≥1 entry across multiple iterations
    because the read → modify → atomic-replace window races: process A and
    B both read the unmodified plan, A writes its update, B overwrites
    A. With `fcntl.flock(LOCK_EX)` on a sibling lockfile the read-modify-
    write region is serialized and both updates land every time.
    """

    def test_no_lost_updates_across_iterations(self, tmp_path: Path):
        iterations = 5
        for _ in range(iterations):
            plan_file = _write_concurrent_plan(tmp_path / f"iter-{_}")
            release_at = time.time() + 0.5
            ctx = multiprocessing.get_context("fork")
            with ctx.Pool(processes=2) as pool:
                results = pool.starmap(
                    _worker_append,
                    [
                        (str(plan_file), "task-a", release_at),
                        (str(plan_file), "task-b", release_at),
                    ],
                )
            assert all(r == 0 for r in results), f"workers failed: {results}"
            data = yaml.safe_load(plan_file.read_text())
            tasks = {t["id"]: t for t in data["phases"][0]["tasks"]}
            assert len(tasks["task-a"].get("phase_results", [])) == 1, (
                f"task-a missing entry on iter {_}: {tasks['task-a']}"
            )
            assert len(tasks["task-b"].get("phase_results", [])) == 1, (
                f"task-b missing entry on iter {_}: {tasks['task-b']}"
            )


# --- TC-2: Lock release on process exit (REQ-6 EC#1) ---


def _hold_lock_then_kill(lock_path: str, ready_event_name: str) -> None:
    """Subprocess target: open lock, acquire LOCK_EX, signal parent, SIGKILL self."""
    fd = open(lock_path, "a")
    fcntl.flock(fd.fileno(), fcntl.LOCK_EX)
    # Touch a sentinel file so the parent knows the lock is held.
    Path(ready_event_name).touch()
    os.kill(os.getpid(), signal.SIGKILL)


class TestLockAcquisition:
    """TC-2: Stale lock from crashed prior run is released by the kernel."""

    def test_kernel_releases_lock_on_process_death(self, tmp_path: Path):
        plan_file = _write_plan(tmp_path, [{"id": "task-1", "name": "Task 1", "status": "wip"}])
        lock_path = str(plan_file) + ".lock"
        ready = tmp_path / "ready"

        ctx = multiprocessing.get_context("fork")
        proc = ctx.Process(target=_hold_lock_then_kill, args=(lock_path, str(ready)))
        proc.start()
        # Wait for the child to signal lock ownership (max 3 s).
        deadline = time.time() + 3
        while time.time() < deadline and not ready.exists():
            time.sleep(0.01)
        assert ready.exists(), "child never acquired the lock"
        proc.join(timeout=2)
        # Now the child is dead; the kernel should have released the lock.
        # Acquire LOCK_EX with a 1 s budget.
        fd = open(lock_path, "a")
        try:
            t0 = time.time()
            fcntl.flock(fd.fileno(), fcntl.LOCK_EX)
            elapsed = time.time() - t0
            assert elapsed < 1.0, f"acquisition took {elapsed:.2f}s — kernel should release on exit"
        finally:
            try:
                fcntl.flock(fd.fileno(), fcntl.LOCK_UN)
            except OSError:
                pass
            fd.close()


# --- TC-3: SRP helpers (load_and_append, write_atomic, append_under_lock) ---


class TestLoadAndAppend:
    """TC-3a: Pure-data helper appends to the right task; unrelated tasks unchanged."""

    def test_appends_to_target_task(self, tmp_path: Path):
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-a", "name": "A", "status": "wip"},
                {
                    "id": "task-b",
                    "name": "B",
                    "status": "wip",
                    "phase_results": [
                        {
                            "phase": "old",
                            "timestamp": "2020-01-01T00:00:00Z",
                            "conformance": "aligned",
                            "acceptance_status": "met",
                            "deviations": [],
                        }
                    ],
                },
            ],
        )
        mod = import_tool("deviation-tracker.py")
        pr = {
            "phase": "ba",
            "timestamp": "2026-05-01T00:00:00Z",
            "conformance": "aligned",
            "acceptance_status": "met",
            "deviations": [],
        }
        plan, use_ruamel = mod._load_and_append(plan_file, "task-a", pr)
        # task-a should have one entry; task-b should still have its original.
        tasks = {t["id"]: t for t in plan["phases"][0]["tasks"]}
        assert len(tasks["task-a"]["phase_results"]) == 1
        assert tasks["task-a"]["phase_results"][0]["phase"] == "ba"
        assert len(tasks["task-b"]["phase_results"]) == 1
        assert tasks["task-b"]["phase_results"][0]["phase"] == "old"

    def test_raises_keyerror_on_missing_task(self, tmp_path: Path):
        plan_file = _write_plan(tmp_path, [{"id": "task-a", "name": "A", "status": "wip"}])
        mod = import_tool("deviation-tracker.py")
        pr = {
            "phase": "ba",
            "timestamp": "2026-05-01T00:00:00Z",
            "conformance": "aligned",
            "acceptance_status": "met",
            "deviations": [],
        }
        with pytest.raises(KeyError):
            mod._load_and_append(plan_file, "nope", pr)


class TestWriteAtomic:
    """TC-3b: File-IO helper writes atomically and cleans up tempfiles."""

    def test_atomic_replace(self, tmp_path: Path):
        plan_file = tmp_path / "execution-plan.yaml"
        plan_file.write_text("placeholder: yes\n")
        mod = import_tool("deviation-tracker.py")
        data = {"foo": "bar", "list": [1, 2, 3]}
        mod._write_atomic(plan_file, data, use_ruamel=False)
        # File replaced; YAML round-trip works.
        loaded = yaml.safe_load(plan_file.read_text())
        assert loaded == data
        # No leftover tempfiles in the same dir.
        leftover = list(plan_file.parent.glob("tmp*"))
        assert leftover == [], f"tempfiles left behind: {leftover}"


class TestAppendUnderLock:
    """TC-3c: Orchestrator opens lockfile, calls helpers, releases lock, closes fd."""

    def test_orchestrates_helpers(self, tmp_path: Path):
        plan_file = _write_plan(tmp_path, [{"id": "task-1", "name": "Task 1", "status": "wip"}])
        mod = import_tool("deviation-tracker.py")
        pr = {
            "phase": "ba",
            "timestamp": "2026-05-01T00:00:00Z",
            "conformance": "aligned",
            "acceptance_status": "met",
            "deviations": [],
        }
        mod._append_under_lock(plan_file, "task-1", pr)
        data = yaml.safe_load(plan_file.read_text())
        assert len(data["phases"][0]["tasks"][0]["phase_results"]) == 1
        # Lockfile exists alongside the plan.
        assert (tmp_path / "execution-plan.yaml.lock").exists()


# --- TC-4: Lock timeout boundary (REQ-6 EC#2) ---


class TestLockTimeoutBoundary:
    """TC-4: External holder past timeout → wrapper logs WARNING and exits 0.

    The bash wrapper enforces the timeout (REQ-5); the Python tracker
    delegates by relying on `coreutils timeout(1)`. This test holds the
    lockfile from a sibling thread and proves the bash wrapper times the
    tracker out cleanly.
    """

    def test_timeout_logs_warning(self, tmp_path: Path):
        if not (
            subprocess.run(["which", "timeout"], capture_output=True).returncode == 0
            or subprocess.run(["which", "gtimeout"], capture_output=True).returncode == 0
        ):
            pytest.skip("no timeout binary on PATH")
        plan_file = _write_plan(tmp_path, [{"id": "task-1", "name": "Task 1", "status": "wip"}])
        lock_path = str(plan_file) + ".lock"

        # Hold the lock from a daemon thread for the full test window.
        hold_seconds = 4
        stop_event = threading.Event()

        def holder() -> None:
            fd = open(lock_path, "a")
            try:
                fcntl.flock(fd.fileno(), fcntl.LOCK_EX)
                t0 = time.time()
                while not stop_event.is_set() and (time.time() - t0) < hold_seconds:
                    time.sleep(0.05)
            finally:
                try:
                    fcntl.flock(fd.fileno(), fcntl.LOCK_UN)
                except OSError:
                    pass
                fd.close()

        t = threading.Thread(target=holder)
        t.start()
        try:
            time.sleep(0.2)  # let the holder grab the lock
            # Run the tracker via the bash wrapper layer (timeout 1s)
            timeout_bin = (
                "timeout"
                if subprocess.run(["which", "timeout"], capture_output=True).returncode == 0
                else "gtimeout"
            )
            pr = {
                "phase": "ba",
                "timestamp": "2026-05-01T00:00:00Z",
                "conformance": "aligned",
                "acceptance_status": "met",
                "deviations": [],
            }
            res = subprocess.run(
                [
                    timeout_bin,
                    "--kill-after=2",
                    "1",
                    sys.executable,
                    str(TRACKER),
                    "--plan-yaml",
                    str(plan_file),
                    "--task-id",
                    "task-1",
                ],
                input=json.dumps(pr),
                capture_output=True,
                text=True,
                timeout=10,
            )
            # Exit 124 is coreutils timeout(1)'s SIGTERM-on-deadline marker.
            assert res.returncode == 124, f"expected 124, got {res.returncode}"
        finally:
            stop_event.set()
            t.join(timeout=hold_seconds + 1)


# --- TC-5: Path defences (is_file, lockfile mode "a", symlink escape) ---


class TestPathDefences:
    """TC-5: REQ-3 EC#2 + lockfile-mode-"a" + symlink-escape protection."""

    def test_is_file_check_for_directory_plan_yaml(self, tmp_path: Path):
        # Pass a directory, not a file.
        result = subprocess.run(
            [sys.executable, str(TRACKER), "--plan-yaml", str(tmp_path), "--task-id", "task-1"],
            input=json.dumps(_valid_phase_result()),
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0
        assert "WARNING: plan path is not a file" in result.stderr

    def test_lockfile_opened_with_mode_a(self):
        # Read the source and assert the lockfile is opened append-only
        # (no truncation). This is a regression test for the AR-1
        # truncation hole — mode "w" / O_TRUNC would race with any
        # concurrent holder inspecting the file. F3 (symlink TOCTOU)
        # switched to os.open(..., O_RDWR | O_CREAT | O_NOFOLLOW) +
        # os.fdopen(fd, "a"); this preserves append-only semantics
        # (no O_TRUNC) and adds kernel-level symlink rejection.
        src = TRACKER.read_text()
        assert 'os.fdopen(fd, "a")' in src, "lockfile must be opened with mode 'a' (append-only)"
        assert "O_NOFOLLOW" in src, "lockfile open must use O_NOFOLLOW to defang symlink TOCTOU"
        # F13: O_APPEND must be set kernel-side. macOS fdopen(fd, "a")
        # does not flip O_APPEND on an existing fd — without this flag,
        # any future appender would race under concurrent writes.
        assert "O_APPEND" in src, (
            "lockfile open must set O_APPEND for kernel-enforced atomic appends"
        )
        assert "O_TRUNC" not in src, "lockfile must NOT be truncated on open"
        assert 'open(lock_path, "w")' not in src, "lockfile must NOT be opened with mode 'w'"

    def test_symlink_escape_refused(self, tmp_path: Path):
        # TC-5(c): F3 (O_NOFOLLOW) — symlink planted at <plan>.lock is rejected
        # at the kernel-level open(), eliminating the TOCTOU race window.
        #
        # Two sub-cases:
        #
        # (a) Symlink pointing OUTSIDE the plan directory — caught by the
        #     realpath prefix check (belt), exits 0 with "lock_path escapes".
        # (b) Symlink pointing INSIDE the plan directory — realpath prefix
        #     check passes (target is within parent), but O_NOFOLLOW rejects
        #     the open() because the lock_path itself is a symlink (suspenders).
        #     The kernel returns ELOOP → exits 2 with "symlink rejected".
        #
        # Case (a): outside target — realpath guard fires.
        inside = tmp_path / "inside"
        inside.mkdir()
        plan_file = _write_plan(
            inside,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        outside = tmp_path / "outside"
        outside.mkdir()
        lock_path = Path(str(plan_file) + ".lock")
        lock_path.symlink_to(outside / "external.lock")

        result = subprocess.run(
            [sys.executable, str(TRACKER), "--plan-yaml", str(plan_file), "--task-id", "task-1"],
            input=json.dumps(_valid_phase_result()),
            capture_output=True,
            text=True,
            timeout=10,
        )
        assert result.returncode == 0
        assert "lock_path escapes plan parent" in result.stderr

        # Case (b): inside target — O_NOFOLLOW fires.
        lock_path.unlink()
        inside_target = inside / "innocent.lock"
        lock_path.symlink_to(inside_target)  # target stays inside parent

        result2 = subprocess.run(
            [sys.executable, str(TRACKER), "--plan-yaml", str(plan_file), "--task-id", "task-1"],
            input=json.dumps(_valid_phase_result()),
            capture_output=True,
            text=True,
            timeout=10,
        )
        # O_NOFOLLOW → ELOOP → exit 2 with greppable "symlink rejected" phrase.
        assert result2.returncode == 2, (
            f"expected exit 2 from O_NOFOLLOW, got {result2.returncode}; stderr: {result2.stderr!r}"
        )
        assert "symlink rejected" in result2.stderr, (
            f"expected 'symlink rejected' in stderr; got: {result2.stderr!r}"
        )

    def test_refuses_root_parent_directory(self, tmp_path: Path):
        # TC-5(d): F4 — when `os.path.realpath(plan_path.parent)` returns "/"
        # (the case where the plan dir is a symlink to /) the guard must fire
        # before any lock acquisition (exit 0, stderr "plan parent resolves to").
        #
        # Full filesystem simulation of "/"-parent is not sandbox-safe, so we
        # test at the unit level by monkey-patching os.path.realpath inside the
        # imported tracker module to return "/" for the parent and a normal path
        # for the lock path (so the prefix check does NOT fire first).
        import io
        from unittest.mock import patch

        mod = import_tool("deviation-tracker.py")
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        pr = _valid_phase_result()

        # Intercept os.path.realpath: parent → "/", lock path → itself (inside "/").
        original_realpath = os.path.realpath

        def fake_realpath(p: str) -> str:
            resolved = original_realpath(p)
            if resolved == original_realpath(str(plan_file.parent)):
                return "/"
            return resolved

        captured_stderr = io.StringIO()
        with patch.object(mod.os.path, "realpath", side_effect=fake_realpath):
            with patch("sys.stderr", captured_stderr):
                with pytest.raises(SystemExit) as exc_info:
                    mod._append_under_lock(plan_file, "task-1", pr)

        assert exc_info.value.code == 0, (
            f"expected sys.exit(0), got {exc_info.value.code}; "
            f"stderr: {captured_stderr.getvalue()!r}"
        )
        assert "plan parent resolves to" in captured_stderr.getvalue(), (
            f"expected 'plan parent resolves to' in stderr; got: {captured_stderr.getvalue()!r}"
        )


# --- TC-6: TRACKER_EXIT_CODES contract ---


class TestExitCodesContract:
    """TC-6: TRACKER_EXIT_CODES dict is the single source of truth for exit codes."""

    def test_constant_present_with_expected_keys(self):
        mod = import_tool("deviation-tracker.py")
        assert hasattr(mod, "TRACKER_EXIT_CODES"), "TRACKER_EXIT_CODES missing from module"
        codes = mod.TRACKER_EXIT_CODES
        assert isinstance(codes, dict)
        assert 0 in codes and "success" in codes[0]
        assert 1 in codes and "task" in codes[1].lower()
        assert 2 in codes and "transient" in codes[2].lower()

    def test_124_and_127_documented_in_source(self):
        src = TRACKER.read_text()
        # 124 (timeout) + 127 (command not found) are documented in comments.
        assert "124" in src and "timeout" in src
        assert "127" in src


# --- DT-15: Schema is the single source of truth ---


class TestSchemaIsSourceOfTruth:
    """DT-15: validate_phase_result delegates to execution-plan.schema.json.

    Two behaviours that the prior hardcoded Python validator did NOT enforce
    but the schema does — proving the validator now reads the schema:

    1. ``additionalProperties: false`` on phase_result — unknown fields are
       rejected.
    2. ``required: [type, description, reason, impact, criteria_affected]``
       on the deviation $def — missing ``reason`` is rejected (the old
       validator only inspected ``type`` and ``impact``).
    """

    def test_rejects_unknown_field_per_schema(self, tmp_path: Path):
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        pr = _valid_phase_result()
        pr["rogue_field"] = "should be rejected by additionalProperties:false"
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 1, (
            f"expected exit 1 for unknown field, got {result.returncode}; stderr: {result.stderr!r}"
        )
        # Schema reports either the field name or "additional properties".
        stderr_lower = result.stderr.lower()
        assert "rogue_field" in stderr_lower or "additional" in stderr_lower, (
            f"expected unknown-field diagnostic; got: {result.stderr!r}"
        )

    def test_rejects_deviation_missing_required_per_schema(self, tmp_path: Path):
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        # Missing "reason" — required by schema's deviation $def, ignored
        # by the prior hardcoded Python validator.
        pr = _valid_phase_result(
            deviations=[
                {
                    "type": "scope_change",
                    "description": "x",
                    "impact": "added",
                    "criteria_affected": [],
                }
            ]
        )
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 1, (
            f"expected exit 1 for missing 'reason', got {result.returncode}; "
            f"stderr: {result.stderr!r}"
        )
        assert "reason" in result.stderr.lower(), (
            f"expected 'reason' in stderr; got: {result.stderr!r}"
        )


# --- TC-7: Stdin size cap (F7 / DoS guard) ---


class TestStdinSizeCap:
    """TC-7: Stdin capped at 1 MiB — oversized payloads exit 1 with diagnostic.

    Legitimate phase_result JSON is < 2 KiB; the cap is conservative enough
    that no real payload should ever hit it.
    """

    def test_oversized_stdin_exits_1(self, tmp_path: Path):
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        # 2 MiB of garbage — well above the 1 MiB cap.
        oversized = b"x" * (2 << 20)
        result = subprocess.run(
            [sys.executable, str(TRACKER), "--plan-yaml", str(plan_file), "--task-id", "task-1"],
            input=oversized,
            capture_output=True,
            timeout=15,
        )
        assert result.returncode == 1, (
            f"expected exit 1 for oversized stdin, got {result.returncode}; "
            f"stderr: {result.stderr!r}"
        )
        assert b"exceeds 1 MiB" in result.stderr, (
            f"expected 'exceeds 1 MiB' in stderr; got: {result.stderr!r}"
        )

    def test_exactly_cap_boundary_rejected(self, tmp_path: Path):
        # One byte over the cap must also be rejected.
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        cap = 1 << 20  # 1 MiB
        over_cap = b"x" * (cap + 1)
        result = subprocess.run(
            [sys.executable, str(TRACKER), "--plan-yaml", str(plan_file), "--task-id", "task-1"],
            input=over_cap,
            capture_output=True,
            timeout=15,
        )
        assert result.returncode == 1
        assert b"exceeds 1 MiB" in result.stderr


# --- DT-16..DT-23: deviation schema extension (8 new types + confidence + evidence) ---

_CASES = json.loads(
    (Path(__file__).parent / "fixtures" / "deviation_full_monty" / "cases.json").read_text()
)
_POSITIVE = {c["case"]: c for c in _CASES["positive"]}
_NEGATIVE = {c["case"]: c for c in _CASES["negative"]}


def _deviation_from(case: dict) -> dict:
    return {k: v for k, v in case.items() if k != "case"}


def _deviated_pr(deviations: list[dict]) -> dict:
    return _valid_phase_result(
        conformance="deviated",
        acceptance_status="partial",
        deviations=deviations,
    )


_NEW_TYPE_CASES = [
    "type:integration_gap",
    "type:gate_logic_drift",
    "type:error_reporting_tautology",
    "type:factual_error",
    "type:test_tautology",
    "type:sycophancy",
    "type:acceptance_reinterpretation",
    "type:architectural_change_without_anchor",
]


# --- DT-16: Eight new deviation types accepted (R1 / AS-1 / host-plan AC #1) ---


class TestNewTypesAccepted:
    """DT-16: Each of the 8 new deviation type values accepted end-to-end."""

    @pytest.mark.parametrize("case_id", _NEW_TYPE_CASES, ids=_NEW_TYPE_CASES)
    def test_accepts(self, tmp_path: Path, case_id: str):
        deviation = _deviation_from(_POSITIVE[case_id])
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        pr = _deviated_pr([deviation])
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 0, (
            f"expected exit 0 for {case_id}, got {result.returncode}; stderr: {result.stderr!r}"
        )
        plan = _read_plan(plan_file)
        persisted = plan["phases"][0]["tasks"][0]["phase_results"][0]["deviations"][0]
        assert persisted["type"] == deviation["type"]


# --- DT-17: Assessor-shape deviation (new type + confidence + evidence) accepted ---
#     R2 + R3 + AS-2 + EC-9 + host-plan AC #2


class TestAssessorShapeAccepted:
    """DT-17: Single assessor-shape entry, plus mixed heuristic+assessor array."""

    def test_single_assessor_shape_round_trips(self, tmp_path: Path):
        case = _POSITIVE["assessor-shape"]
        deviation = _deviation_from(case)
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        pr = _deviated_pr([deviation])
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 0, f"stderr: {result.stderr!r}"
        assert result.stderr == "", f"expected no warnings; got: {result.stderr!r}"

        plan = _read_plan(plan_file)
        persisted = plan["phases"][0]["tasks"][0]["phase_results"][0]["deviations"][0]
        assert persisted["type"] == deviation["type"]
        assert persisted["confidence"] == deviation["confidence"]
        assert persisted["evidence"] == deviation["evidence"]

    def test_mixed_shape_array_atomic(self, tmp_path: Path):
        heuristic = {
            "type": "scope_change",
            "description": "Heuristic-shape entry without optional fields.",
            "reason": "Mixed-array fixture.",
            "impact": "added",
            "criteria_affected": ["AC-1"],
        }
        assessor = _deviation_from(_POSITIVE["assessor-shape"])
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        pr = _deviated_pr([heuristic, assessor])
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 0, f"stderr: {result.stderr!r}"

        plan = _read_plan(plan_file)
        persisted = plan["phases"][0]["tasks"][0]["phase_results"]
        assert len(persisted) == 1, "atomic single phase_result append"
        deviations = persisted[0]["deviations"]
        assert len(deviations) == 2
        assert deviations[0]["type"] == "scope_change"
        assert deviations[1]["type"] == assessor["type"]
        assert deviations[1]["confidence"] == assessor["confidence"]


# --- DT-18: Evidence below 80-char floor rejected with literal phrase + count ---
#     R3 + AS-3 + EC-7 + host-plan AC #3 (strict)


class TestEvidenceTooShortRejected:
    """DT-18: Stderr contains 'evidence too short (<N> characters, minimum 80)'."""

    @pytest.mark.parametrize(
        "case_id, length",
        [
            ("evidence:length-0", 0),
            ("evidence:length-1", 1),
            ("evidence:length-79", 79),
        ],
        ids=["length-0", "length-1", "length-79"],
    )
    def test_rejects_with_literal_phrase_and_count(self, tmp_path: Path, case_id: str, length: int):
        deviation = _deviation_from(_NEGATIVE[case_id])
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        pr = _deviated_pr([deviation])
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 1, f"stderr: {result.stderr!r}"
        assert "evidence too short" in result.stderr, (
            f"expected literal phrase 'evidence too short'; got: {result.stderr!r}"
        )
        expected_count = f"({length} characters, minimum 80)"
        assert expected_count in result.stderr, (
            f"expected '{expected_count}' in stderr; got: {result.stderr!r}"
        )


# --- DT-19: Confidence out of range / wrong type rejected (R2 + AS-4 + EC-4) ---


class TestConfidenceOutOfRangeRejected:
    """DT-19: confidence < 0.0, > 1.0, or non-number rejected."""

    @pytest.mark.parametrize(
        "case_id",
        ["confidence:-0.1", "confidence:1.1", "confidence:2.0", "confidence:string"],
        ids=["minus-0.1", "1.1", "2.0", "string-0.5"],
    )
    def test_rejects(self, tmp_path: Path, case_id: str):
        deviation = _deviation_from(_NEGATIVE[case_id])
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        pr = _deviated_pr([deviation])
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 1, f"stderr: {result.stderr!r}"
        assert "confidence" in result.stderr.lower(), (
            f"expected 'confidence' in stderr; got: {result.stderr!r}"
        )


# --- DT-20: Unknown deviation type rejected (AS-5 + host-plan AC #5) ---


class TestUnknownTypeRejected:
    """DT-20: type outside the union of original 4 + new 8 rejected."""

    def test_rejects_made_up_category(self, tmp_path: Path):
        deviation = _deviation_from(_NEGATIVE["type:made_up_category"])
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        pr = _deviated_pr([deviation])
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 1, f"stderr: {result.stderr!r}"
        assert "made_up_category" in result.stderr, (
            f"expected offending value 'made_up_category' in stderr; got: {result.stderr!r}"
        )
        assert "type" in result.stderr.lower(), f"expected 'type' in stderr; got: {result.stderr!r}"


# --- DT-21: Confidence boundary inclusive (EC-2 + EC-8) ---


class TestConfidenceBoundaryInclusive:
    """DT-21: confidence ∈ {0.0, 1.0, integer 1, 0.5} all validate."""

    @pytest.mark.parametrize(
        "case_id",
        ["confidence:0.0", "confidence:1.0", "confidence:int-1", "confidence:0.5"],
        ids=["0.0", "1.0", "integer-1", "0.5"],
    )
    def test_accepts(self, tmp_path: Path, case_id: str):
        case = _POSITIVE[case_id]
        deviation = _deviation_from(case)
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        pr = _deviated_pr([deviation])
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 0, f"stderr: {result.stderr!r}"
        plan = _read_plan(plan_file)
        persisted = plan["phases"][0]["tasks"][0]["phase_results"][0]["deviations"][0]
        assert persisted["confidence"] == case["confidence"]


# --- DT-22: Evidence boundary inclusive + type strictness (EC-3 + EC-5) ---


class TestEvidenceBoundaryInclusive:
    """DT-22: evidence of exactly 80 chars validates; non-string evidence rejected."""

    def test_accepts_exactly_80(self, tmp_path: Path):
        case = _POSITIVE["evidence:80-char-boundary"]
        deviation = _deviation_from(case)
        assert isinstance(deviation["evidence"], str)
        assert len(deviation["evidence"]) == 80
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        pr = _deviated_pr([deviation])
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 0, f"stderr: {result.stderr!r}"
        plan = _read_plan(plan_file)
        persisted = plan["phases"][0]["tasks"][0]["phase_results"][0]["deviations"][0]
        assert persisted["evidence"] == case["evidence"]

    def test_rejects_number_evidence(self, tmp_path: Path):
        deviation = _deviation_from(_NEGATIVE["evidence:number"])
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        pr = _deviated_pr([deviation])
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 1, f"stderr: {result.stderr!r}"
        assert "evidence" in result.stderr.lower(), (
            f"expected 'evidence' in stderr; got: {result.stderr!r}"
        )


# --- DT-23: Unknown additional field on deviation rejected (R4 + EC-6) ---


class TestUnknownDeviationFieldRejected:
    """DT-23: additionalProperties:false enforced at the deviation level."""

    def test_rejects_unknown_field(self, tmp_path: Path):
        deviation = _deviation_from(_NEGATIVE["additional:severity"])
        assert "severity" in deviation, "fixture must include the unknown field"
        plan_file = _write_plan(
            tmp_path,
            [
                {"id": "task-1", "name": "Task 1", "status": "wip"},
            ],
        )
        pr = _deviated_pr([deviation])
        result = _run_tracker(plan_file, "task-1", pr)
        assert result.returncode == 1, f"stderr: {result.stderr!r}"
        stderr_lower = result.stderr.lower()
        assert "severity" in stderr_lower or "additional" in stderr_lower, (
            f"expected unknown-field diagnostic; got: {result.stderr!r}"
        )
