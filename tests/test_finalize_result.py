"""Tests for claude/tools/lib/finalize_result.py."""
from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
LIB_DIR = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "lib"

sys.path.insert(0, str(LIB_DIR))

from finalize_result import (  # noqa: E402
    extract_json_line,
    parse_merge_failed,
    parse_ok,
)


class TestExtractJsonLine:
    def test_finds_trailing_json(self) -> None:
        stream = "log line one\nlog line two\n{\"ok\":true}\n"
        assert extract_json_line(stream) == '{"ok":true}'

    def test_returns_last_json_when_multiple(self) -> None:
        stream = "{\"ok\":false}\nlog noise\n{\"ok\":true,\"task\":\"final\"}\n"
        assert extract_json_line(stream) == '{"ok":true,"task":"final"}'

    def test_ignores_nested_braces_in_middle_of_line(self) -> None:
        # Regression: previous `rfind('{')` grabbed the innermost brace inside
        # a nested JSON array and produced invalid JSON.
        stream = '{"ok":true,"steps":[{"step":"a"},{"step":"b"}]}\n'
        line = extract_json_line(stream)
        assert line == '{"ok":true,"steps":[{"step":"a"},{"step":"b"}]}'
        # Must round-trip through json.loads without error
        assert json.loads(line)["ok"] is True

    def test_returns_none_when_no_json(self) -> None:
        assert extract_json_line("plain log text\nmore text\n") is None

    def test_handles_leading_whitespace(self) -> None:
        stream = "  {\"ok\":true}\n"
        assert extract_json_line(stream) == '{"ok":true}'


class TestParseOk:
    def test_ok_true(self) -> None:
        assert parse_ok({"ok": True}) is True

    def test_ok_false(self) -> None:
        assert parse_ok({"ok": False}) is False

    def test_ok_missing_defaults_false(self) -> None:
        assert parse_ok({}) is False

    def test_ok_as_string_truthy(self) -> None:
        # bool("true") is True; documenting the (probably surprising) behavior.
        assert parse_ok({"ok": "true"}) is True


class TestParseMergeFailed:
    def test_merge_failure_detected(self) -> None:
        payload = {"steps": [{"step": "merge", "status": "fail"}]}
        assert parse_merge_failed(payload) is True

    def test_merge_success_not_detected(self) -> None:
        payload = {"steps": [{"step": "merge", "status": "ok"}]}
        assert parse_merge_failed(payload) is False

    def test_unrelated_failure_not_detected(self) -> None:
        payload = {"steps": [{"step": "cleanup", "status": "fail"}]}
        assert parse_merge_failed(payload) is False

    def test_no_steps_returns_false(self) -> None:
        assert parse_merge_failed({}) is False


class TestCLIInterface:
    def test_ok_flag_on_successful_finalize(self) -> None:
        stream = '{"ok":true,"task":"x","steps":[{"step":"merge","status":"ok"}]}\n'
        result = subprocess.run(
            [sys.executable, str(LIB_DIR / "finalize_result.py"), "--ok"],
            input=stream,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert result.stdout.strip() == "True"

    def test_ok_flag_on_failed_finalize(self) -> None:
        stream = '{"ok":false,"task":"x"}\n'
        result = subprocess.run(
            [sys.executable, str(LIB_DIR / "finalize_result.py"), "--ok"],
            input=stream,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert result.stdout.strip() == "False"

    def test_merge_failed_flag(self) -> None:
        stream = (
            '{"ok":false,"steps":[{"step":"docs_rename","status":"ok"},'
            '{"step":"merge","status":"fail"}]}\n'
        )
        result = subprocess.run(
            [sys.executable, str(LIB_DIR / "finalize_result.py"), "--merge-failed"],
            input=stream,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert result.stdout.strip() == "True"

    def test_invalid_json_exits_one(self) -> None:
        result = subprocess.run(
            [sys.executable, str(LIB_DIR / "finalize_result.py"), "--ok"],
            input="not-json-at-all\n",
            capture_output=True,
            text=True,
        )
        assert result.returncode == 1

    def test_real_world_regression_case(self) -> None:
        """This is the exact JSON shape that broke autopilot and sent False
        even though ok:true (9 nested step objects)."""
        stream = (
            '{"ok":true,"task":"manifest-block-spec","steps":['
            '{"step":"docs_rename","status":"ok"},'
            '{"step":"plan_yaml","status":"ok"},'
            '{"step":"exec_guide","status":"skip"},'
            '{"step":"finalize_commit","status":"ok"},'
            '{"step":"merge","status":"ok"},'
            '{"step":"push","status":"ok"},'
            '{"step":"cleanup","status":"ok"},'
            '{"step":"docs_verify","status":"ok"},'
            '{"step":"git_clean","status":"ok"}]}\n'
        )
        result = subprocess.run(
            [sys.executable, str(LIB_DIR / "finalize_result.py"), "--ok"],
            input=stream,
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert result.stdout.strip() == "True", "regression: rfind bug must not return"
