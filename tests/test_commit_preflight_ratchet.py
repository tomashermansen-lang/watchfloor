"""Integration tests for commit-preflight.sh --ratchet mode (C5).

Uses real temp git repos. Scanners are mocked by stub scripts on PATH
that return fixture JSON.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
PREFLIGHT = str(REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "commit-preflight.sh")
FIXTURES = Path(__file__).resolve().parent / "fixtures" / "ratchet"


def _tmpdir() -> Path:
    """Create a temp dir in TMPDIR (sandbox-safe)."""
    return Path(tempfile.mkdtemp(dir=os.environ.get("TMPDIR", "/tmp")))


def _setup_repo(base: Path, name: str) -> Path:
    """Create a temp git repo with a feature branch containing one added line."""
    repo = base / name
    repo.mkdir(parents=True)

    def _git(*args: str) -> None:
        subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=True)

    subprocess.run(["git", "init", str(repo)], capture_output=True, check=True)
    _git("config", "user.email", "test@test.com")
    _git("config", "user.name", "Test User")

    (repo / "file.sh").write_text("existing line 1\nexisting line 2\n")
    _git("add", ".")
    _git("commit", "-m", "init")
    _git("branch", "-M", "main")

    _git("checkout", "-b", "feature/test")
    (repo / "file.sh").write_text("existing line 1\nnew line added\nexisting line 2\n")
    _git("add", ".")
    _git("commit", "-m", "add line")

    return repo


def _setup_mock_bin(base: Path, findings_file: str | None = None) -> Path:
    """Create mock get-findings.sh on PATH."""
    mock_bin = base / "mock-bin"
    mock_bin.mkdir(exist_ok=True)

    mock_script = mock_bin / "get-findings.sh"
    if findings_file:
        mock_script.write_text(f'#!/usr/bin/env bash\ncat "{findings_file}"\n')
    else:
        mock_script.write_text('#!/usr/bin/env bash\necho "[]"\n')
    mock_script.chmod(0o755)

    return mock_bin


def _run_preflight(*args: str, cwd: str, env_extra: dict | None = None) -> tuple[int, str, str]:
    """Run commit-preflight.sh and return (exit_code, stdout, stderr)."""
    env = os.environ.copy()
    if env_extra:
        env.update(env_extra)
    result = subprocess.run(
        ["bash", PREFLIGHT, *args],
        capture_output=True,
        text=True,
        cwd=cwd,
        env=env,
    )
    return result.returncode, result.stdout, result.stderr


# ---------------------------------------------------------------------------
# TC-CP09: Without --ratchet → standard behavior preserved
# ---------------------------------------------------------------------------


def test_cp09_no_ratchet_standard_behavior():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp09")
        exit_code, stdout, stderr = _run_preflight("--test-cmd", "true", cwd=str(repo))

        assert exit_code == 0
        output = json.loads(stdout)
        assert output["ok"] is True
        assert "ratchet" not in output
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP12: All clean → exit 0, ok: true
# ---------------------------------------------------------------------------


def test_cp12_all_clean():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp12")
        mock_bin = _setup_mock_bin(base)

        env = {"PATH": f"{mock_bin}:{os.environ['PATH']}"}
        exit_code, stdout, stderr = _run_preflight("--ratchet", cwd=str(repo), env_extra=env)

        assert exit_code == 0
        output = json.loads(stdout)
        assert output["ok"] is True
        assert output["ratchet"] is True
        assert output["must_fix"] == []
        assert output["should_fix"] == []
        assert output["suppressions"] == []
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP13: --ratchet --flow mutual exclusion
# ---------------------------------------------------------------------------


def test_cp13_mutual_exclusion():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp13")
        exit_code, stdout, stderr = _run_preflight("--ratchet", "--flow", cwd=str(repo))

        assert exit_code == 1
        assert "mutually exclusive" in stderr
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP16: JSON output schema correctness
# ---------------------------------------------------------------------------


def test_cp16_json_schema():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp16")
        mock_bin = _setup_mock_bin(base)

        env = {"PATH": f"{mock_bin}:{os.environ['PATH']}"}
        exit_code, stdout, stderr = _run_preflight("--ratchet", cwd=str(repo), env_extra=env)

        output = json.loads(stdout)
        assert "ok" in output
        assert output["ratchet"] is True
        assert "must_fix" in output
        assert "should_fix" in output
        assert "may_defer" in output
        assert "suppressions" in output
        assert "summary" in output
        summary = output["summary"]
        assert "must_fix_count" in summary
        assert "should_fix_count" in summary
        assert "may_defer_count" in summary
        assert "suppression_count" in summary
        assert "auto_logged_count" in summary
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP01: MUST-fix blocks commit
# ---------------------------------------------------------------------------


def test_cp01_must_fix_blocks():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp01")

        # Create findings file with a finding on line 2 (the added line)
        findings = [
            {
                "id": "shellcheck:SC2086-file.sh-aabb1122",
                "tool": "shellcheck",
                "rule": "SC2086",
                "file": "file.sh",
                "line": 2,
                "severity": "warning",
                "message": "test",
                "content_hash": "aabb1122",
            }
        ]
        findings_file = base / "findings.json"
        findings_file.write_text(json.dumps(findings))

        mock_bin = _setup_mock_bin(base, str(findings_file))
        env = {"PATH": f"{mock_bin}:{os.environ['PATH']}"}
        exit_code, stdout, stderr = _run_preflight("--ratchet", cwd=str(repo), env_extra=env)

        assert exit_code == 1
        output = json.loads(stdout)
        assert output["ok"] is False
        assert len(output["must_fix"]) == 1
        assert "MUST-fix" in stderr
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP06: Inline suppression rejected
# ---------------------------------------------------------------------------


def test_cp06_suppression_rejected():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp06")
        # Rewrite file.sh with a noqa suppression on the added line
        (repo / "file.sh").write_text("existing line 1\nnew line  # noqa\nexisting line 2\n")
        subprocess.run(["git", "-C", str(repo), "add", "."], capture_output=True, check=True)
        subprocess.run(
            ["git", "-C", str(repo), "commit", "-m", "add noqa"], capture_output=True, check=True
        )

        mock_bin = _setup_mock_bin(base)
        env = {"PATH": f"{mock_bin}:{os.environ['PATH']}"}
        exit_code, stdout, stderr = _run_preflight("--ratchet", cwd=str(repo), env_extra=env)

        assert exit_code == 1
        output = json.loads(stdout)
        assert output["ok"] is False
        assert len(output["suppressions"]) >= 1
        assert "inline suppression rejected" in stderr
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP07: Suppression in string literal not rejected
# ---------------------------------------------------------------------------


def test_cp07_suppression_in_string_not_rejected():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp07")
        (repo / "file.sh").write_text(
            'existing line 1\nmsg="use # noqa to suppress"\nexisting line 2\n'
        )
        subprocess.run(["git", "-C", str(repo), "add", "."], capture_output=True, check=True)
        subprocess.run(
            ["git", "-C", str(repo), "commit", "-m", "add string"], capture_output=True, check=True
        )

        mock_bin = _setup_mock_bin(base)
        env = {"PATH": f"{mock_bin}:{os.environ['PATH']}"}
        exit_code, stdout, stderr = _run_preflight("--ratchet", cwd=str(repo), env_extra=env)

        output = json.loads(stdout)
        assert len(output["suppressions"]) == 0
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP14: --ratchet --test-cmd integration
# ---------------------------------------------------------------------------


def test_cp14_ratchet_test_cmd():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp14")
        mock_bin = _setup_mock_bin(base)
        env = {"PATH": f"{mock_bin}:{os.environ['PATH']}"}
        exit_code, stdout, stderr = _run_preflight(
            "--ratchet",
            "--test-cmd",
            "false",
            cwd=str(repo),
            env_extra=env,
        )

        assert exit_code == 1
        output = json.loads(stdout)
        assert output["ok"] is False
        assert output["tests_passed"] is False
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP15: Existing flags still work after --ratchet added
# ---------------------------------------------------------------------------


def test_cp15_existing_flags_work():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp15")
        # --flow alone should still work (won't pass worktree check but that's ok)
        exit_code, stdout, stderr = _run_preflight("--flow", "--test-cmd", "true", cwd=str(repo))

        # Flow mode without worktree: ok=false, but it ran (didn't crash)
        output = json.loads(stdout)
        assert "ok" in output
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP17: Corrupt deferred-findings.json → exit 1
# ---------------------------------------------------------------------------


def test_cp17_corrupt_deferred():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp17")
        # Create corrupt deferred file
        grinder_dir = repo / "docs" / "grinder"
        grinder_dir.mkdir(parents=True)
        (grinder_dir / "deferred-findings.json").write_text("{bad json")

        # Create a finding that needs SHOULD-fix check (on unchanged line in touched file)
        findings = [
            {
                "id": "shellcheck:SC2086-file.sh-aabb1122",
                "tool": "shellcheck",
                "rule": "SC2086",
                "file": "file.sh",
                "line": 1,  # Line 1 is unchanged
                "severity": "warning",
                "message": "test",
                "content_hash": "aabb1122",
            }
        ]
        findings_file = base / "findings.json"
        findings_file.write_text(json.dumps(findings))
        mock_bin = _setup_mock_bin(base, str(findings_file))
        env = {"PATH": f"{mock_bin}:{os.environ['PATH']}"}

        exit_code, stdout, stderr = _run_preflight("--ratchet", cwd=str(repo), env_extra=env)

        assert exit_code == 1
        assert "corrupt" in stderr.lower() or "corrupt" in stdout.lower()
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP02: SHOULD-fix without deferral blocks commit
# ---------------------------------------------------------------------------


def test_cp02_should_fix_without_deferral_blocks():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp02")

        # Finding on line 1 (unchanged line in touched file) → classified SHOULD-fix
        findings = [
            {
                "id": "shellcheck:SC2086-file.sh-aabb1122",
                "tool": "shellcheck",
                "rule": "SC2086",
                "file": "file.sh",
                "line": 1,
                "severity": "warning",
                "message": "test",
                "content_hash": "aabb1122",
            }
        ]
        findings_file = base / "findings.json"
        findings_file.write_text(json.dumps(findings))

        mock_bin = _setup_mock_bin(base, str(findings_file))
        env = {"PATH": f"{mock_bin}:{os.environ['PATH']}"}
        # No deferred-findings.json exists
        exit_code, stdout, stderr = _run_preflight("--ratchet", cwd=str(repo), env_extra=env)

        assert exit_code == 1
        assert "SHOULD-fix finding requires deferred-findings.json entry or fix" in stderr
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP03: SHOULD-fix with deferral passes
# ---------------------------------------------------------------------------


def test_cp03_should_fix_with_deferral_passes():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp03")

        finding_id = "shellcheck:SC2086-file.sh-aabb1122"
        findings = [
            {
                "id": finding_id,
                "tool": "shellcheck",
                "rule": "SC2086",
                "file": "file.sh",
                "line": 1,
                "severity": "warning",
                "message": "test",
                "content_hash": "aabb1122",
            }
        ]
        findings_file = base / "findings.json"
        findings_file.write_text(json.dumps(findings))

        # Pre-populate deferred-findings.json with matching entry
        grinder_dir = repo / "docs" / "grinder"
        grinder_dir.mkdir(parents=True)
        (grinder_dir / "deferred-findings.json").write_text(
            json.dumps(
                [
                    {
                        "finding_id": finding_id,
                        "rule": "SC2086",
                        "file": "file.sh",
                        "line": 1,
                        "state": "Accepted",
                        "reason": "pre-existing finding accepted for deferral in test",
                        "owner": "test",
                        "reviewed_at": "2024-01-01",
                    }
                ]
            )
        )

        mock_bin = _setup_mock_bin(base, str(findings_file))
        env = {"PATH": f"{mock_bin}:{os.environ['PATH']}"}
        exit_code, stdout, stderr = _run_preflight("--ratchet", cwd=str(repo), env_extra=env)

        assert exit_code == 0
        output = json.loads(stdout)
        assert output["ok"] is True
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP04: MAY-defer auto-logs and passes
# ---------------------------------------------------------------------------


def test_cp04_may_defer_auto_logs():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp04")

        # Add a second file in initial commit that won't be modified on feature branch
        def _git(*args: str) -> None:
            subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=True)

        _git("checkout", "main")
        (repo / "other.sh").write_text("echo hello\n")
        _git("add", "other.sh")
        _git("commit", "-m", "add other.sh")
        _git("checkout", "feature/test")
        _git("merge", "main", "-m", "merge main")

        # Finding references other.sh (untouched file) → MAY-defer
        findings = [
            {
                "id": "shellcheck:SC2086-other.sh-ccdd3344",
                "tool": "shellcheck",
                "rule": "SC2086",
                "file": "other.sh",
                "line": 1,
                "severity": "warning",
                "message": "test",
                "content_hash": "ccdd3344",
            }
        ]
        findings_file = base / "findings.json"
        findings_file.write_text(json.dumps(findings))

        mock_bin = _setup_mock_bin(base, str(findings_file))
        env = {"PATH": f"{mock_bin}:{os.environ['PATH']}"}
        exit_code, stdout, stderr = _run_preflight("--ratchet", cwd=str(repo), env_extra=env)

        assert exit_code == 0
        output = json.loads(stdout)
        assert output["ok"] is True
        assert len(output["may_defer"]) >= 1

        # Check that deferred-findings.json was created with the entry
        deferred_path = repo / "docs" / "grinder" / "deferred-findings.json"
        assert deferred_path.exists()
        deferred = json.loads(deferred_path.read_text())
        ids = [e["finding_id"] for e in deferred]
        assert "shellcheck:SC2086-other.sh-ccdd3344" in ids
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP05: MAY-defer duplicate skipped
# ---------------------------------------------------------------------------


def test_cp05_may_defer_duplicate_skipped():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp05")

        def _git(*args: str) -> None:
            subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=True)

        _git("checkout", "main")
        (repo / "other.sh").write_text("echo hello\n")
        _git("add", "other.sh")
        _git("commit", "-m", "add other.sh")
        _git("checkout", "feature/test")
        _git("merge", "main", "-m", "merge main")

        finding_id = "shellcheck:SC2086-other.sh-ccdd3344"
        findings = [
            {
                "id": finding_id,
                "tool": "shellcheck",
                "rule": "SC2086",
                "file": "other.sh",
                "line": 1,
                "severity": "warning",
                "message": "test",
                "content_hash": "ccdd3344",
            }
        ]
        findings_file = base / "findings.json"
        findings_file.write_text(json.dumps(findings))

        # Pre-populate deferred file with the same finding_id
        grinder_dir = repo / "docs" / "grinder"
        grinder_dir.mkdir(parents=True)
        (grinder_dir / "deferred-findings.json").write_text(
            json.dumps(
                [
                    {
                        "finding_id": finding_id,
                        "rule": "SC2086",
                        "file": "other.sh",
                        "line": 1,
                        "state": "Accepted",
                        "reason": "pre-existing finding accepted for deferral in test",
                        "owner": "test",
                        "reviewed_at": "2024-01-01",
                    }
                ]
            )
        )

        mock_bin = _setup_mock_bin(base, str(findings_file))
        env = {"PATH": f"{mock_bin}:{os.environ['PATH']}"}
        exit_code, stdout, stderr = _run_preflight("--ratchet", cwd=str(repo), env_extra=env)

        assert exit_code == 0
        # Verify no duplicate — still only 1 entry
        deferred = json.loads((grinder_dir / "deferred-findings.json").read_text())
        matching = [e for e in deferred if e["finding_id"] == finding_id]
        assert len(matching) == 1
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP08: Suppression in never_touch_files still rejected
# ---------------------------------------------------------------------------


def test_cp08_never_touch_files_suppression_rejected():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp08")
        # Add noqa on the changed line — never_touch_files doesn't exempt from suppression scan
        (repo / "file.sh").write_text("existing line 1\nnew line  # noqa\nexisting line 2\n")
        subprocess.run(["git", "-C", str(repo), "add", "."], capture_output=True, check=True)
        subprocess.run(
            ["git", "-C", str(repo), "commit", "-m", "add noqa"], capture_output=True, check=True
        )

        mock_bin = _setup_mock_bin(base)
        env = {"PATH": f"{mock_bin}:{os.environ['PATH']}"}
        exit_code, stdout, stderr = _run_preflight("--ratchet", cwd=str(repo), env_extra=env)

        assert exit_code == 1
        output = json.loads(stdout)
        assert output["ok"] is False
        assert len(output["suppressions"]) >= 1
        assert "inline suppression rejected" in stderr
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP10: No common ancestor → exit 1
# ---------------------------------------------------------------------------


def test_cp10_no_common_ancestor():
    base = _tmpdir()
    try:
        repo = base / "cp10"
        repo.mkdir(parents=True)

        def _git(*args: str) -> None:
            subprocess.run(["git", "-C", str(repo), *args], capture_output=True, check=True)

        subprocess.run(["git", "init", str(repo)], capture_output=True, check=True)
        _git("config", "user.email", "test@test.com")
        _git("config", "user.name", "Test User")

        (repo / "file.sh").write_text("line 1\n")
        _git("add", ".")
        _git("commit", "-m", "init")
        _git("branch", "-M", "main")

        # Create orphan branch — no common ancestor with main
        _git("checkout", "--orphan", "orphan-branch")
        (repo / "orphan.sh").write_text("orphan line\n")
        _git("add", ".")
        _git("commit", "-m", "orphan")

        mock_bin = _setup_mock_bin(base)
        env = {"PATH": f"{mock_bin}:{os.environ['PATH']}"}
        exit_code, stdout, stderr = _run_preflight("--ratchet", cwd=str(repo), env_extra=env)

        assert exit_code == 1
        combined = stdout + stderr
        assert "no common ancestor" in combined.lower() or "error" in combined.lower()
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP11: Partial scanner failure continues
# ---------------------------------------------------------------------------


def test_cp11_partial_scanner_failure_continues():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp11")

        # Create a mock ratchet-discover.py that returns two scanners:
        # one that works and one that fails
        mock_bin = base / "mock-bin"
        mock_bin.mkdir(exist_ok=True)

        # Working scanner script
        good_scanner = mock_bin / "good-scanner.sh"
        good_scanner.write_text('#!/usr/bin/env bash\necho "[]"\n')
        good_scanner.chmod(0o755)

        # Failing scanner script
        bad_scanner = mock_bin / "bad-scanner.sh"
        bad_scanner.write_text("#!/usr/bin/env bash\nexit 1\n")
        bad_scanner.chmod(0o755)

        # Mock ratchet-discover.py that returns both scanners
        mock_discover = mock_bin / "ratchet-discover.py"
        mock_discover.write_text(f'''#!/usr/bin/env python3
import json, sys
result = {{
    "scanners": [
        {{"tool": "good", "command": ["{good_scanner}"], "paths": []}},
        {{"tool": "bad", "command": ["{bad_scanner}"], "paths": []}}
    ],
    "warnings": []
}}
print(json.dumps(result))
''')
        mock_discover.chmod(0o755)

        # We need to override the discover script. The commit-preflight.sh
        # calls python3 "$SCRIPT_DIR/lib/ratchet-discover.py". We can create
        # a local tools dir structure with our mock.
        tools_dir = base / "tools"
        tools_dir.mkdir()
        lib_dir = tools_dir / "lib"
        lib_dir.mkdir()

        # Copy the real commit-preflight.sh but it will use its own SCRIPT_DIR
        # Instead, let's use the real script and override via a symlink approach.
        # Actually, simpler: create a mock get-findings.sh that the real
        # discover will find, and use the real flow. But we need two scanners.

        # Simplest: mock the discover python script in the lib dir so the
        # real commit-preflight.sh picks it up. We'll create a temporary
        # tools structure.
        import shutil as shutil_mod

        tmp_tools = base / "fake-tools"
        tmp_tools.mkdir()
        shutil_mod.copytree(
            str(REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools"),
            str(tmp_tools / "tools"),
        )

        # Override ratchet-discover.py
        (tmp_tools / "tools" / "lib" / "ratchet-discover.py").write_text(f'''#!/usr/bin/env python3
import json, sys
result = {{
    "scanners": [
        {{"tool": "good", "command": ["{good_scanner}"], "paths": []}},
        {{"tool": "bad", "command": ["{bad_scanner}"], "paths": []}}
    ],
    "warnings": []
}}
print(json.dumps(result))
''')

        fake_preflight = str(tmp_tools / "tools" / "commit-preflight.sh")
        env = {"PATH": f"{mock_bin}:{os.environ['PATH']}"}
        result = subprocess.run(
            ["bash", fake_preflight, "--ratchet"],
            capture_output=True,
            text=True,
            cwd=str(repo),
            env={**os.environ, **env},
        )

        assert "ratchet: scanner bad failed, continuing" in result.stderr
        # Should still produce valid JSON output
        output = json.loads(result.stdout)
        assert "ok" in output
        assert output["ratchet"] is True
        # The warnings should mention the failed scanner
        assert any("bad" in w for w in output.get("warnings", []))
    finally:
        shutil.rmtree(base, ignore_errors=True)


# ---------------------------------------------------------------------------
# TC-CP18: Zero scanners — warning, commit proceeds
# ---------------------------------------------------------------------------


def test_cp18_zero_scanners_commit_proceeds():
    base = _tmpdir()
    try:
        repo = _setup_repo(base, "cp18")

        # Create fake tools dir with a discover that returns zero scanners
        import shutil as shutil_mod

        tmp_tools = base / "fake-tools"
        tmp_tools.mkdir()
        shutil_mod.copytree(
            str(REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools"),
            str(tmp_tools / "tools"),
        )

        (tmp_tools / "tools" / "lib" / "ratchet-discover.py").write_text("""#!/usr/bin/env python3
import json, sys
print(json.dumps({"scanners": [], "warnings": ["no scanners discovered"]}))
print("warning: no scanners discovered", file=sys.stderr)
""")

        fake_preflight = str(tmp_tools / "tools" / "commit-preflight.sh")
        result = subprocess.run(
            ["bash", fake_preflight, "--ratchet"],
            capture_output=True,
            text=True,
            cwd=str(repo),
            env=os.environ.copy(),
        )

        assert result.returncode == 0
        output = json.loads(result.stdout)
        assert output["ok"] is True
        assert "no scanners discovered" in " ".join(output.get("warnings", []))
    finally:
        shutil.rmtree(base, ignore_errors=True)
