"""Unit tests for dashboard/server/validation.py.

Covers TESTPLAN rows V1-V11 (REQUIREMENTS.md R4, R22, EC-D1, EC-M2).
"""

from __future__ import annotations

import ast
import inspect
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
if str(REPO_ROOT) not in sys.path:
    sys.path.insert(0, str(REPO_ROOT))

from dashboard.server import validation  # noqa: E402
from dashboard.server.validation import (  # noqa: E402
    SAFE_ID_PATTERN,
    SAFE_ID_REGEX,
    validate_safe_id,
)


class TestValidation:
    @pytest.mark.parametrize("value", ["task-01", "feature_one", "ABC", "a", "0"])
    def test_v1_pattern_accepts_valid_ids(self, value: str) -> None:
        assert SAFE_ID_PATTERN.match(value)

    def test_v2_upper_boundary_accepted(self) -> None:
        assert SAFE_ID_PATTERN.match("a" * 64)

    def test_v3_pattern_rejects_65_chars(self) -> None:
        assert SAFE_ID_PATTERN.match("a" * 65) is None

    def test_v4_pattern_rejects_empty(self) -> None:
        assert SAFE_ID_PATTERN.match("") is None

    @pytest.mark.parametrize(
        "value",
        [
            "task; rm -rf /",
            "task/sub",
            "feat.x",
            "feat x",
            "task\nnewline",
            "$home",
        ],
    )
    def test_v5_pattern_rejects_metacharacters(self, value: str) -> None:
        assert SAFE_ID_PATTERN.match(value) is None

    def test_v6_validate_safe_id_returns_none_on_valid(self) -> None:
        # Returns None implicitly — must not raise.
        validate_safe_id("good")

    def test_v7_validate_safe_id_raises_with_offender_quoted(self) -> None:
        with pytest.raises(ValueError) as exc:
            validate_safe_id("bad value")
        assert "'bad value'" in str(exc.value)

    def test_v8_validate_safe_id_field_kwarg_appears_in_message(self) -> None:
        with pytest.raises(ValueError) as exc:
            validate_safe_id("bad value", field="target_id")
        assert "'bad value'" in str(exc.value)
        assert "target_id" in str(exc.value)

    def test_v9_safe_id_regex_string_value(self) -> None:
        assert SAFE_ID_REGEX == r"^[a-zA-Z0-9_-]{1,64}$"

    def test_v10_pattern_and_regex_in_sync(self) -> None:
        assert SAFE_ID_PATTERN.pattern == SAFE_ID_REGEX

    def test_v11_no_dashboard_server_imports(self) -> None:
        source = inspect.getsource(validation)
        tree = ast.parse(source)
        modules: set[str] = set()
        for node in ast.walk(tree):
            if isinstance(node, ast.Import):
                for alias in node.names:
                    modules.add(alias.name)
            elif isinstance(node, ast.ImportFrom) and node.module:
                modules.add(node.module)
        for m in modules:
            assert not m.startswith("dashboard.server"), (
                f"validation.py must not import from dashboard.server.* (got {m})"
            )
