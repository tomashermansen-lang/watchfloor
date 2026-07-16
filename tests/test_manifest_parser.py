"""Tests for claude/tools/lib/manifest_parser.py."""
from __future__ import annotations

import subprocess
import sys
import textwrap
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parent.parent
LIB_DIR = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "lib"

sys.path.insert(0, str(LIB_DIR))

from manifest_parser import (  # noqa: E402
    parse_manifest,
    parse_records,
    resolve_pipeline_path,
)


def _yaml(text: str) -> dict:
    return yaml.safe_load(textwrap.dedent(text))


class TestResolvePipelinePath:
    def test_returns_input_when_file(self, tmp_path: Path) -> None:
        f = tmp_path / "pipeline.yaml"
        f.write_text("toolchain: {}\n")
        assert resolve_pipeline_path(f) == f

    def test_appends_pipeline_yaml_when_directory(self, tmp_path: Path) -> None:
        assert resolve_pipeline_path(tmp_path) == tmp_path / "pipeline.yaml"


class TestParseRecords:
    def test_toolchain_single_item(self) -> None:
        manifest = _yaml(
            """
            toolchain:
              python: [ruff]
            """
        )
        assert list(parse_records(manifest)) == ["TOOLCHAIN|python|ruff"]

    def test_toolchain_multi_item(self) -> None:
        manifest = _yaml(
            """
            toolchain:
              python: [ruff, mypy, pytest]
            """
        )
        assert list(parse_records(manifest)) == [
            "TOOLCHAIN|python|ruff",
            "TOOLCHAIN|python|mypy",
            "TOOLCHAIN|python|pytest",
        ]

    def test_toolchain_infra(self) -> None:
        manifest = _yaml(
            """
            toolchain:
              infra: [bash, jq]
            """
        )
        assert list(parse_records(manifest)) == [
            "TOOLCHAIN|infra|bash",
            "TOOLCHAIN|infra|jq",
        ]

    def test_smoke_test_entries(self) -> None:
        manifest = _yaml(
            """
            smoke_test:
              - bash test.sh
              - python3 -m foo
            """
        )
        assert list(parse_records(manifest)) == [
            "SMOKE|bash test.sh",
            "SMOKE|python3 -m foo",
        ]

    def test_integration_test_entries(self) -> None:
        manifest = _yaml(
            """
            integration_test:
              - bash dashboard/tests/run-all.sh
            """
        )
        assert list(parse_records(manifest)) == [
            "INTEGRATION|bash dashboard/tests/run-all.sh",
        ]

    def test_smoke_and_integration_order(self) -> None:
        # smoke_test records precede integration_test records.
        manifest = _yaml(
            """
            smoke_test:
              - bash smoke.sh
            integration_test:
              - bash integ.sh
            """
        )
        assert list(parse_records(manifest)) == [
            "SMOKE|bash smoke.sh",
            "INTEGRATION|bash integ.sh",
        ]

    # --- integration_test object form (real integration gates §4.1) ---
    # The object form declares the project's integration *surface*: the
    # commands, the path globs that trigger the gate (§5), and the services
    # the ephemeral execution env must bring up (§6a Guard #4). Backward
    # compatible with the legacy flat-array form above.

    def test_integration_object_commands(self) -> None:
        manifest = _yaml(
            """
            integration_test:
              commands:
                - bash dashboard/tests/run-all.sh --only-integration
            """
        )
        assert list(parse_records(manifest)) == [
            "INTEGRATION|bash dashboard/tests/run-all.sh --only-integration",
        ]

    def test_integration_object_trigger_globs(self) -> None:
        manifest = _yaml(
            """
            integration_test:
              commands: [bash integ.sh]
              trigger:
                - dashboard/**
                - core/schema/**
            """
        )
        assert list(parse_records(manifest)) == [
            "INTEGRATION|bash integ.sh",
            "INTEGRATION_TRIGGER|dashboard/**",
            "INTEGRATION_TRIGGER|core/schema/**",
        ]

    def test_integration_object_services(self) -> None:
        manifest = _yaml(
            """
            integration_test:
              commands: [bash integ.sh]
              services:
                - name: postgres-test-db
                  start_cmd: docker compose up -d db-test
                  health_cmd: pg_isready -h localhost
            """
        )
        assert list(parse_records(manifest)) == [
            "INTEGRATION|bash integ.sh",
            "INTEGRATION_SERVICE|postgres-test-db|docker compose up -d db-test|pg_isready -h localhost",
        ]

    def test_integration_service_name_only(self) -> None:
        # start_cmd / health_cmd are optional; absent → empty fields so the
        # record arity stays fixed (4 pipe-fields) for the bash consumer.
        manifest = _yaml(
            """
            integration_test:
              commands: [bash integ.sh]
              services:
                - name: redis
            """
        )
        assert list(parse_records(manifest)) == [
            "INTEGRATION|bash integ.sh",
            "INTEGRATION_SERVICE|redis||",
        ]

    def test_integration_service_missing_name_skipped(self) -> None:
        # A nameless service is unactionable; the parser drops it (the schema
        # rejects it too — defence in depth).
        manifest = _yaml(
            """
            integration_test:
              commands: [bash integ.sh]
              services:
                - start_cmd: docker up
            """
        )
        assert list(parse_records(manifest)) == ["INTEGRATION|bash integ.sh"]

    def test_integration_object_commands_only_no_extra_records(self) -> None:
        manifest = _yaml(
            """
            integration_test:
              commands: [bash integ.sh]
            """
        )
        assert list(parse_records(manifest)) == ["INTEGRATION|bash integ.sh"]

    def test_integration_object_oracle_globs(self) -> None:
        # oracle_globs → INTEGRATION_ORACLE| records (Guard #2 WORM-lock source).
        manifest = _yaml(
            """
            integration_test:
              commands: [bash integ.sh]
              oracle_globs:
                - dashboard/tests/**
                - dashboard/tests/_lib/**
            """
        )
        assert list(parse_records(manifest)) == [
            "INTEGRATION|bash integ.sh",
            "INTEGRATION_ORACLE|dashboard/tests/**",
            "INTEGRATION_ORACLE|dashboard/tests/_lib/**",
        ]

    def test_contract_test(self) -> None:
        manifest = _yaml(
            """
            contracts:
              - test: tests/contracts.py
            """
        )
        assert list(parse_records(manifest)) == ["CONTRACT_TEST|tests/contracts.py"]

    def test_contract_grep(self) -> None:
        manifest = _yaml(
            """
            contracts:
              - grep: TODO
                source: src/**/*.py
                max_value: 0
            """
        )
        assert list(parse_records(manifest)) == [
            "CONTRACT_GREP|TODO",
            "CONTRACT_SOURCE|src/**/*.py",
            "CONTRACT_MAX|0",
        ]

    def test_precondition(self) -> None:
        manifest = _yaml(
            """
            preconditions:
              - kind: file_exists
                path: README.md
            """
        )
        assert list(parse_records(manifest)) == [
            "PRECONDITION|file_exists|path=README.md",
        ]

    def test_empty_manifest_yields_nothing(self) -> None:
        assert list(parse_records({})) == []

    def test_non_list_toolchain_value_skipped(self) -> None:
        manifest = {"toolchain": {"python": "ruff"}}
        assert list(parse_records(manifest)) == []


class TestParseManifest:
    def test_missing_file_returns_empty(self, tmp_path: Path) -> None:
        assert parse_manifest(tmp_path / "nonexistent.yaml") == []

    def test_directory_arg_resolves_to_pipeline_yaml(self, tmp_path: Path) -> None:
        (tmp_path / "pipeline.yaml").write_text(
            "toolchain:\n  python: [ruff]\n"
        )
        assert parse_manifest(tmp_path) == ["TOOLCHAIN|python|ruff"]

    def test_full_manifest(self, tmp_path: Path) -> None:
        pipeline = tmp_path / "pipeline.yaml"
        pipeline.write_text(
            textwrap.dedent(
                """
                toolchain:
                  imports: [yaml, jsonschema]
                  infra: [bash, jq]
                smoke_test:
                  - python3 validate.py
                  - bash check.sh
                contracts: []
                """
            ).lstrip()
        )
        records = parse_manifest(pipeline)
        assert "TOOLCHAIN|imports|yaml" in records
        assert "TOOLCHAIN|imports|jsonschema" in records
        assert "TOOLCHAIN|infra|bash" in records
        assert "SMOKE|python3 validate.py" in records
        assert "SMOKE|bash check.sh" in records

    def test_malformed_yaml_raises(self, tmp_path: Path) -> None:
        pipeline = tmp_path / "pipeline.yaml"
        pipeline.write_text("toolchain:\n  python: [ruff,\n")
        with pytest.raises(yaml.YAMLError):
            parse_manifest(pipeline)


class TestCLIInterface:
    def test_invocation_with_pipeline_yaml(self, tmp_path: Path) -> None:
        pipeline = tmp_path / "pipeline.yaml"
        pipeline.write_text("toolchain:\n  python: [ruff]\n")
        result = subprocess.run(
            [sys.executable, str(LIB_DIR / "manifest_parser.py"), str(pipeline)],
            capture_output=True,
            text=True,
        )
        assert result.returncode == 0
        assert "TOOLCHAIN|python|ruff" in result.stdout

    def test_missing_arg_exits_nonzero(self) -> None:
        result = subprocess.run(
            [sys.executable, str(LIB_DIR / "manifest_parser.py")],
            capture_output=True,
            text=True,
        )
        assert result.returncode != 0
