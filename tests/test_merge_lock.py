"""Tests for claude/tools/lib/merge-lock.sh — shared lock library (ML-1..7)."""

from __future__ import annotations

import subprocess
import time
from pathlib import Path

from conftest import REPO_ROOT

LOCK_LIB = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "lib" / "merge-lock.sh"


def _run_lock_script(script: str, timeout: int = 30) -> subprocess.CompletedProcess:
    """Run a bash script that sources merge-lock.sh."""
    full_script = f'source "{LOCK_LIB}"\n{script}'
    return subprocess.run(
        ["bash", "-c", full_script],
        capture_output=True,
        text=True,
        timeout=timeout,
    )


class TestAcquireLock:
    """ML-1: acquire_merge_lock creates lock file with PID."""

    def test_creates_lock_file_with_pid(self, tmp_path: Path):
        lock_file = tmp_path / "test.lock"
        # acquire lock, check file exists and contains our PID, then release
        result = _run_lock_script(
            f'acquire_merge_lock "{lock_file}" && '
            f'cat "{lock_file}" && '
            f'release_merge_lock "{lock_file}"'
        )
        assert result.returncode == 0
        # shlock writes the PID as the file content
        pid_str = result.stdout.strip()
        assert pid_str.isdigit(), f"Expected PID in lock file, got: {pid_str}"


class TestReleaseLock:
    """ML-2: release_merge_lock removes lock file."""

    def test_removes_lock_file(self, tmp_path: Path):
        lock_file = tmp_path / "test.lock"
        result = _run_lock_script(
            f'acquire_merge_lock "{lock_file}" && '
            f'release_merge_lock "{lock_file}" && '
            f'[[ ! -f "{lock_file}" ]] && echo "removed"'
        )
        assert result.returncode == 0
        assert "removed" in result.stdout


class TestBlockingBehavior:
    """ML-3: Second acquire blocks while first holds lock."""

    def test_second_acquire_blocks(self, tmp_path: Path):
        lock_file = tmp_path / "test.lock"
        # First process acquires lock and holds it for 3 seconds
        # Second process tries to acquire — should block
        script = f"""
        source "{LOCK_LIB}"
        acquire_merge_lock "{lock_file}"
        sleep 3
        release_merge_lock "{lock_file}"
        """
        proc1 = subprocess.Popen(
            ["bash", "-c", script],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        time.sleep(0.5)  # Let proc1 acquire the lock

        # proc2 tries to acquire — should not succeed immediately
        start = time.time()
        result2 = _run_lock_script(
            f'acquire_merge_lock "{lock_file}" && '
            f'echo "acquired" && '
            f'release_merge_lock "{lock_file}"',
            timeout=15,
        )
        elapsed = time.time() - start

        proc1.wait(timeout=10)
        assert result2.returncode == 0
        assert "acquired" in result2.stdout
        # Should have waited at least 2 seconds (proc1 holds for 3s)
        assert elapsed >= 1.5, f"Expected blocking wait, but only waited {elapsed:.1f}s"


class TestStaleLockDetection:
    """ML-4: Stale lock (dead PID) is detected and removed."""

    def test_stale_lock_removed(self, tmp_path: Path):
        lock_file = tmp_path / "test.lock"
        # Write a lock file with a dead PID
        lock_file.write_text("99999999")  # PID that doesn't exist
        result = _run_lock_script(
            f'acquire_merge_lock "{lock_file}" && '
            f'echo "acquired" && '
            f'release_merge_lock "{lock_file}"'
        )
        assert result.returncode == 0
        assert "acquired" in result.stdout


class TestStaleLockNoDelay:
    """ML-5: Lock acquired after stale removal without sleep delay."""

    def test_no_unnecessary_delay_after_stale(self, tmp_path: Path):
        lock_file = tmp_path / "test.lock"
        lock_file.write_text("99999999")
        start = time.time()
        result = _run_lock_script(
            f'acquire_merge_lock "{lock_file}" && release_merge_lock "{lock_file}"'
        )
        elapsed = time.time() - start
        assert result.returncode == 0
        # Should complete quickly (under 2 seconds) — no unnecessary sleep
        assert elapsed < 2.0, f"Stale lock removal took {elapsed:.1f}s (expected <2s)"


class TestLockTimeout:
    """ML-6: Timeout exits non-zero after max_wait."""

    def test_timeout_exits_nonzero(self, tmp_path: Path):
        lock_file = tmp_path / "test.lock"
        # First process holds lock indefinitely
        holder = subprocess.Popen(
            ["bash", "-c", f'source "{LOCK_LIB}" && acquire_merge_lock "{lock_file}" && sleep 60'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        time.sleep(0.5)

        # Second process tries with short max_wait (override via env)
        result = subprocess.run(
            [
                "bash",
                "-c",
                f'source "{LOCK_LIB}"\nMERGE_LOCK_MAX_WAIT=3 acquire_merge_lock "{lock_file}"',
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        holder.terminate()
        holder.wait(timeout=5)
        assert result.returncode != 0
        assert "timeout" in result.stderr.lower()

    def test_timeout_returns_exit_code_2(self, tmp_path: Path):
        """Lock timeout returns exit code 2 specifically (not 1) so the
        caller (autopilot.sh) can distinguish "blocked / operator-resolvable"
        from real errors. Chain orchestrator routes exit 2 to blocked_tasks
        instead of failed_tasks — symmetry with merge-conflict handling.
        """
        lock_file = tmp_path / "test.lock"
        holder = subprocess.Popen(
            ["bash", "-c", f'source "{LOCK_LIB}" && acquire_merge_lock "{lock_file}" && sleep 60'],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        time.sleep(0.5)

        result = subprocess.run(
            [
                "bash",
                "-c",
                f'source "{LOCK_LIB}"\nMERGE_LOCK_MAX_WAIT=3 acquire_merge_lock "{lock_file}"',
            ],
            capture_output=True,
            text=True,
            timeout=15,
        )
        holder.terminate()
        holder.wait(timeout=5)
        assert result.returncode == 2, (
            f"Expected exit code 2 (blocked); got {result.returncode}. stderr: {result.stderr}"
        )


class TestConcurrentSerialization:
    """ML-7: Two concurrent processes serialize via lock."""

    def test_concurrent_serialization(self, tmp_path: Path):
        lock_file = tmp_path / "test.lock"
        output_file = tmp_path / "output.txt"
        output_file.write_text("")

        # Two processes each acquire lock, write a marker, release
        script_template = """
        source "{lib}"
        acquire_merge_lock "{lock}"
        echo "{marker}" >> "{output}"
        sleep 0.5
        echo "{marker}_done" >> "{output}"
        release_merge_lock "{lock}"
        """

        procs = []
        for marker in ["A", "B"]:
            script = script_template.format(
                lib=LOCK_LIB,
                lock=lock_file,
                output=output_file,
                marker=marker,
            )
            p = subprocess.Popen(
                ["bash", "-c", script],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            procs.append(p)

        for p in procs:
            p.wait(timeout=30)
            assert p.returncode == 0

        lines = output_file.read_text().strip().split("\n")
        # Should be serialized: A, A_done, B, B_done (or B, B_done, A, A_done)
        # NOT interleaved like A, B, A_done, B_done
        assert len(lines) == 4
        # Check that each start/done pair is adjacent
        if lines[0] == "A":
            assert lines[1] == "A_done"
            assert lines[2] == "B"
            assert lines[3] == "B_done"
        else:
            assert lines[0] == "B"
            assert lines[1] == "B_done"
            assert lines[2] == "A"
            assert lines[3] == "A_done"
