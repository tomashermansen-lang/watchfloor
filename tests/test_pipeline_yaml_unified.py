"""Covers: REQ-1..REQ-12 from REQUIREMENTS.md (C1..C5 from PLAN.md).

Asserts the root pipeline.yaml content invariants and the
validate-manifest.py exit-code contract. Each test re-invokes
_load_manifest() for a fresh dict to avoid cross-test state.

Also covers REQ-1..REQ-10 / AS-1..AS-8 from grinder-scanner-enable
REQUIREMENTS.md (`docs/INPROGRESS_Feature_grinder-scanner-enable/`).
"""

from __future__ import annotations

import json
import subprocess
from pathlib import Path

import jsonschema
import yaml
from conftest import REPO_ROOT, run_tool

REQ4_ALLOWLIST = {
    "python:S1481",
    "python:S1763",
    "typescript:S1172",
    "typescript:S1854",
    "shellcheck:SC2086",
    "eslint:no-unused-vars",
    "bandit:B404",
}

EXPECTED_NEVER_TOUCH = [
    "**/node_modules/**",
    "**/.venv/**",
    "**/dist/**",
    "docs/DONE_*/**",
    "docs/grinder/scanner-output/**",
    "tests/fixtures/**",
    "dashboard/tests/fixtures/**",
]


PIPELINE_YAML = REPO_ROOT / "pipeline.yaml"
SCHEMA_FILE = REPO_ROOT / "core" / "schema" / "pipeline.schema.json"
VALIDATOR = "validate-manifest.py"

SMOKE_FORBIDDEN_SUBSTRINGS = [
    "~/.claude/tools/",
    "claude/schema/",
    "cd ",
]

HEADER_REQUIRED = [
    "core/schema/pipeline.schema.json",
    "adapters/claude-code/claude/tools/validate-manifest.py",
]
HEADER_FORBIDDEN = [
    "claude/schema/",
    "claude-agent-dashboard",
    "~/.claude/tools/",
    "Migrated 2026-04-29 from CLAUDE.md",
]

NEW_TOOLS_PREFIX = "adapters/claude-code/claude/tools/"
LEGACY_TOOLS_FRAGMENT = "claude/tools/"


def _has_bare_legacy_tools(text: str) -> bool:
    """True when `claude/tools/` appears outside `adapters/claude-code/claude/tools/`.

    The new and legacy paths share the `claude/tools/` substring, so a plain
    `in` check would always flag the new prefix. Counts compare instead:
    every legitimate occurrence of the legacy fragment is part of the new
    prefix, so the counts must match.
    """
    return text.count(LEGACY_TOOLS_FRAGMENT) != text.count(NEW_TOOLS_PREFIX)


EXPECTED_SMOKE = [
    "python3 adapters/claude-code/claude/tools/validate-plan.py docs/DONE_Plan_zero-tech-debt-pipeline/execution-plan.yaml",
    'GRINDER_CHECK_PROJECTS="dotfiles-monorepo|$(pwd)" bash adapters/claude-code/claude/tools/grinder-check.sh',
    "python3 adapters/claude-code/claude/tools/validate-manifest.py pipeline.yaml",
    "pnpm --dir dashboard/app run test",
]

EXCLUDE_PREFIXES = (
    ".git/",
    "node_modules/",
    "docs/INPROGRESS_",
    "docs/DONE_",
    ".venv/",
    "__pycache__/",
)


def _load_manifest() -> dict:
    data = yaml.safe_load(PIPELINE_YAML.read_text())
    assert isinstance(data, dict)
    return data


def test_canonical_uniqueness_at_root() -> None:
    """REQ-11 — exactly one pipeline.yaml at the repo root."""
    matches = []
    for p in REPO_ROOT.rglob("pipeline.yaml"):
        rel = p.relative_to(REPO_ROOT)
        rel_str = str(rel)
        if any(rel_str.startswith(pref) for pref in EXCLUDE_PREFIXES):
            continue
        matches.append(rel)
    assert len(matches) == 1, f"Expected exactly one pipeline.yaml, found: {matches}"
    assert matches[0] == Path("pipeline.yaml"), f"Unexpected location: {matches[0]}"


def test_header_paths() -> None:
    """REQ-1, REQ-12 — header references post-restructure paths only."""
    head = PIPELINE_YAML.read_text().splitlines()[:10]

    for s in HEADER_REQUIRED:
        assert any(s in line for line in head), f"Header missing required substring: {s!r}"

    for s in HEADER_FORBIDDEN:
        assert not any(s in line for line in head), f"Header contains forbidden substring: {s!r}"

    head_text = "\n".join(head)
    assert not _has_bare_legacy_tools(head_text), (
        f"Header contains bare legacy 'claude/tools/' reference outside "
        f"the {NEW_TOOLS_PREFIX!r} prefix; head:\n{head_text}"
    )

    comment_lines = []
    for line in head:
        stripped = line.strip()
        if stripped.startswith("#"):
            comment_lines.append(line)
        else:
            break
    assert 3 <= len(comment_lines) <= 6, (
        f"Header comment block must be 3-6 lines, got {len(comment_lines)}"
    )


def test_toolchain_block() -> None:
    """REQ-3, EC-4, EC-5 — toolchain unifies Python + Node + dedup infra."""
    toolchain = _load_manifest()["toolchain"]

    assert set(toolchain["imports"]) == {"yaml", "jsonschema", "pytest"}, (
        f"toolchain.imports mismatch: {toolchain['imports']}"
    )

    assert {"eslint", "tsc"}.issubset(set(toolchain["node"])), (
        f"toolchain.node must contain eslint and tsc; got {toolchain['node']}"
    )

    assert set(toolchain["infra"]) == {"bash", "jq", "shellcheck", "sonar-scanner"}, (
        f"toolchain.infra mismatch (shellcheck must remain in infra because "
        f"grinder.findings.shellcheck cross-references it — EC-4): "
        f"{toolchain['infra']}"
    )


def test_smoke_entries() -> None:
    """REQ-5, REQ-6 — smoke array has the four mandated entries, no forbidden substrings."""
    smoke = _load_manifest()["smoke_test"]

    assert len(smoke) == 4, f"smoke_test must have exactly 4 entries; got {len(smoke)}: {smoke}"

    for expected in EXPECTED_SMOKE:
        assert expected in smoke, f"smoke_test missing entry: {expected!r}"

    for i, entry in enumerate(smoke):
        for sub in SMOKE_FORBIDDEN_SUBSTRINGS:
            assert sub not in entry, (
                f"Smoke entry {i}: forbidden substring {sub!r} found in {entry!r}"
            )
        assert not _has_bare_legacy_tools(entry), (
            f"Smoke entry {i}: bare legacy 'claude/tools/' reference outside "
            f"the {NEW_TOOLS_PREFIX!r} prefix in {entry!r}"
        )


def test_preconditions_block() -> None:
    """REQ-7, REQ-8, REQ-9, EC-1 — preconditions has the three REQ-mandated entries, schema-valid."""
    manifest = _load_manifest()
    preconds = manifest["preconditions"]

    assert len(preconds) == 3, (
        f"preconditions must have exactly 3 entries; got {len(preconds)}: {preconds}"
    )

    assert any(e["kind"] == "python_import" and e["value"] == "jsonschema" for e in preconds), (
        f"Missing python_import jsonschema entry: {preconds}"
    )

    assert any(
        e["kind"] == "file_exists" and e["path"] == "core/schema/execution-plan.schema.json"
        for e in preconds
    ), f"Missing file_exists core/schema/execution-plan.schema.json entry: {preconds}"

    assert any(
        e["kind"] == "file_exists" and e["path"] == "dashboard/app/package.json" for e in preconds
    ), f"Missing file_exists dashboard/app/package.json entry: {preconds}"

    assert not any(e.get("path") == "claude/schema/execution-plan.schema.json" for e in preconds), (
        "Legacy claude/schema/execution-plan.schema.json path must not reappear (EC-1)."
    )

    for e in preconds:
        assert len(e["reason"]) >= 10, (
            f"Precondition {e!r}: reason too short ({len(e['reason'])} chars, need 10+)"
        )

    schema = json.loads(SCHEMA_FILE.read_text())
    items_schema = schema["properties"]["preconditions"]["items"]
    items_schema = dict(items_schema)
    items_schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
    validator = jsonschema.Draft202012Validator(items_schema)

    for e in preconds:
        errors = list(validator.iter_errors(e))
        assert errors == [], (
            f"Precondition {e!r} failed schema oneOf: {[err.message for err in errors]}"
        )


def test_grinder_block() -> None:
    """grinder block matches the live contract.

    Updated for grinder-scanner-enable (T23 + the pre-existing line-205/220
    drift documented in TESTPLAN.md):
    - languages: [bash, python, typescript] (was [bash])
    - shellcheck.paths: three roots (adapters/, dashboard/tests/, scripts/)
    - fix_rules_allowlist: seven REQ-4 entries (was [])
    - never_touch_files: seven KC-C globs (was [])
    """
    grinder = _load_manifest()["grinder"]

    assert grinder["languages"] == ["bash", "python", "typescript"], (
        f"grinder.languages mismatch; got {grinder['languages']}"
    )

    assert grinder["findings"]["shellcheck"]["paths"] == [
        "adapters/claude-code/claude/tools/",
        "dashboard/tests/",
        "scripts/",
    ], f"grinder.findings.shellcheck.paths mismatch: {grinder['findings']['shellcheck']['paths']}"

    assert set(grinder["findings"]["fix_rules_allowlist"]) == REQ4_ALLOWLIST, (
        f"grinder.findings.fix_rules_allowlist mismatch (REQ-4); got "
        f"{grinder['findings']['fix_rules_allowlist']}"
    )
    assert len(grinder["findings"]["fix_rules_allowlist"]) == 7, (
        f"grinder.findings.fix_rules_allowlist must have exactly 7 entries; got "
        f"{len(grinder['findings']['fix_rules_allowlist'])}"
    )

    assert grinder["findings"]["never_touch_files"] == EXPECTED_NEVER_TOUCH, (
        f"grinder.findings.never_touch_files mismatch (KC-C contract); got "
        f"{grinder['findings']['never_touch_files']}"
    )

    for forbidden_finding in ("sonarqube", "eslint"):
        assert forbidden_finding not in grinder["findings"], (
            f"Q-3 lift is out of scope: {forbidden_finding!r} must not appear in grinder.findings."
        )


def test_validate_manifest_exits_zero() -> None:
    """REQ-2, Scenario A — validate-manifest.py exits 0 on the real root manifest."""
    result = run_tool(VALIDATOR, str(PIPELINE_YAML))
    assert result.exit_code == 0, (
        f"validate-manifest.py exit_code={result.exit_code}; stderr: {result.stderr}"
    )
    assert "Valid." in result.stdout, f"Expected 'Valid.' in stdout; got: {result.stdout!r}"


def test_parse_grinder_emits_valid_json() -> None:
    """REQ-4, Scenario B — --parse-grinder exits 0 and emits valid JSON."""
    result = run_tool(VALIDATOR, str(PIPELINE_YAML), "--parse-grinder")
    assert result.exit_code == 0, (
        f"--parse-grinder exit_code={result.exit_code}; stderr: {result.stderr}"
    )
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError as e:
        raise AssertionError(
            f"--parse-grinder stdout is not valid JSON: {result.stdout!r}; error: {e}"
        ) from e
    assert data["languages"] == ["bash", "python", "typescript"], (
        f"--parse-grinder languages mismatch: {data.get('languages')}"
    )
    assert data["findings"]["shellcheck"]["paths"] == [
        "adapters/claude-code/claude/tools/",
        "dashboard/tests/",
        "scripts/",
    ], (
        f"--parse-grinder findings.shellcheck.paths mismatch: "
        f"{data['findings']['shellcheck'].get('paths')}"
    )


def test_contracts_block_preserved() -> None:
    """C2.5 — top-level contracts: [] preserved (regression guard)."""
    manifest = _load_manifest()
    assert "contracts" in manifest, (
        "Top-level 'contracts' key was dropped during merge — consumers "
        "(autopilot.sh, manifest_parser.py) expect it to exist as []."
    )
    assert manifest["contracts"] == [], f"contracts must be []; got {manifest['contracts']}"


# ---------------------------------------------------------------------------
# grinder-scanner-enable — manifest-shape tests (T3-T12, T21, T22)
# ---------------------------------------------------------------------------


def test_toolchain_includes_bandit_and_semgrep() -> None:
    """T12 / REQ-5 / AS-6 — toolchain.python declares the new scanners.

    Preserves the existing entries (mypy, ruff, coverage) so the cross-toolchain
    semantic check (`validate-manifest._check_findings_cross_validation`) passes
    when `grinder.findings.bandit` and `grinder.findings.semgrep` are declared.
    """
    python_tools = set(_load_manifest()["toolchain"]["python"])
    assert {"mypy", "ruff", "coverage"}.issubset(python_tools), (
        f"toolchain.python must still contain mypy/ruff/coverage; got {python_tools}"
    )
    assert {"bandit", "semgrep"}.issubset(python_tools), (
        f"toolchain.python must include bandit and semgrep (REQ-5); got {python_tools}"
    )


def test_bandit_block_well_formed() -> None:
    """T4 / REQ-2 / AS-1 — grinder.findings.bandit declared correctly."""
    grinder = _load_manifest()["grinder"]
    bandit = grinder["findings"].get("bandit")
    assert isinstance(bandit, dict), (
        f"grinder.findings.bandit must be a mapping; got {type(bandit).__name__}"
    )
    assert bandit.get("enabled") is True, (
        f"grinder.findings.bandit.enabled must be true; got {bandit.get('enabled')!r}"
    )
    paths = bandit.get("paths")
    assert isinstance(paths, list) and paths, (
        f"grinder.findings.bandit.paths must be a non-empty list; got {paths!r}"
    )
    assert "adapters/claude-code/claude/tools/" in paths, (
        f"REQ-2 requires adapters/claude-code/claude/tools/ in paths; got {paths!r}"
    )


def test_semgrep_block_well_formed() -> None:
    """T6 / REQ-3 / AS-1 — grinder.findings.semgrep declared correctly."""
    grinder = _load_manifest()["grinder"]
    semgrep = grinder["findings"].get("semgrep")
    assert isinstance(semgrep, dict), (
        f"grinder.findings.semgrep must be a mapping; got {type(semgrep).__name__}"
    )
    assert semgrep.get("enabled") is True, (
        f"grinder.findings.semgrep.enabled must be true; got {semgrep.get('enabled')!r}"
    )
    assert semgrep.get("config") == "auto", (
        f"grinder.findings.semgrep.config must be 'auto' (REQ-3); got {semgrep.get('config')!r}"
    )
    paths = semgrep.get("paths")
    assert isinstance(paths, list) and paths, (
        f"grinder.findings.semgrep.paths must be a non-empty list; got {paths!r}"
    )


def test_scanner_paths_exist_on_disk() -> None:
    """T5, T7 / REQ-2, REQ-3 (EC-A1 guard) — declared scanner paths exist."""
    findings = _load_manifest()["grinder"]["findings"]
    for scanner in ("bandit", "semgrep"):
        block = findings.get(scanner) or {}
        for entry in block.get("paths", []) or []:
            target = REPO_ROOT / entry
            assert target.is_dir(), (
                f"grinder.findings.{scanner}.paths entry {entry!r} does not resolve "
                f"to a directory on branch HEAD ({target}); EC-A1 guard."
            )


def test_fix_rules_allowlist_seven_entries() -> None:
    """T8, T9, T10 / REQ-4 / AS-2 — exactly the seven REQ-4 strings, no duplicates."""
    allowlist = _load_manifest()["grinder"]["findings"]["fix_rules_allowlist"]
    assert isinstance(allowlist, list), (
        f"fix_rules_allowlist must be a sequence; got {type(allowlist).__name__}"
    )
    assert len(allowlist) == 7, (
        f"fix_rules_allowlist must have exactly 7 entries (REQ-4); got {len(allowlist)}: {allowlist}"
    )
    assert len(allowlist) == len(set(allowlist)), (
        f"fix_rules_allowlist must contain no duplicates (EC-A3); got {allowlist}"
    )
    assert set(allowlist) == REQ4_ALLOWLIST, (
        f"fix_rules_allowlist set mismatch (REQ-4 verbatim contract); "
        f"missing={REQ4_ALLOWLIST - set(allowlist)}, "
        f"extra={set(allowlist) - REQ4_ALLOWLIST}"
    )


def test_fix_rules_allowlist_no_whitespace() -> None:
    """T11 / REQ-4 (EC-B1 guard) — entries have no leading/trailing whitespace."""
    allowlist = _load_manifest()["grinder"]["findings"]["fix_rules_allowlist"]
    for entry in allowlist:
        assert isinstance(entry, str), f"Allowlist entry not a string: {entry!r}"
        assert entry == entry.strip(), f"Allowlist entry {entry!r} has whitespace drift (EC-B1)."


def test_never_touch_files_byte_identical() -> None:
    """T21 / REQ-9 / AS-7 (KC-C guard) — never_touch_files unchanged.

    REQ-9 mandates the seven existing patterns in the same order. This is a
    static-content guard that runs without git, so it works on a fresh
    checkout too — complements an end-of-branch diff regex check.
    """
    never_touch = _load_manifest()["grinder"]["findings"]["never_touch_files"]
    assert never_touch == EXPECTED_NEVER_TOUCH, (
        f"never_touch_files diverged from KC-C contract.\n"
        f"  expected: {EXPECTED_NEVER_TOUCH}\n"
        f"  got:      {never_touch}"
    )


def test_parse_grinder_emits_bandit_and_semgrep() -> None:
    """T3 / REQ-2, REQ-3 / AS-1 — --parse-grinder JSON exposes the new keys."""
    result = run_tool(VALIDATOR, str(PIPELINE_YAML), "--parse-grinder")
    assert result.exit_code == 0, (
        f"--parse-grinder exit_code={result.exit_code}; stderr: {result.stderr}"
    )
    data = json.loads(result.stdout)
    findings_keys = set(data["findings"].keys())
    assert {"bandit", "semgrep"}.issubset(findings_keys), (
        f"--parse-grinder must expose bandit and semgrep alongside existing scanners; "
        f"got keys: {findings_keys}"
    )
    assert {"shellcheck", "ruff", "mypy", "tsc"}.issubset(findings_keys), (
        f"--parse-grinder must preserve existing scanner keys; got: {findings_keys}"
    )


def test_diff_touches_only_allowed_paths() -> None:
    """T22 / REQ-10 / AS-8 (relaxed per PLAN reconciliation) — diff scope.

    PLAN.md's "REQ-10 + Test-suite update reconciliation" allows the
    contract-migration commit to touch tests/* in addition to `pipeline.yaml`.
    `core/schema/manifest.schema.json` is also permitted because PLAN.md
    referenced `pipeline.schema.json` (permissive `additionalProperties`)
    but `validate-manifest.py` actually validates against
    `manifest.schema.json` which explicitly typed bandit/semgrep without a
    `paths` key — a plan-error deviation surfaced during /implement.

    Reference frame: `main...HEAD` (three-dot, merge-base symmetric diff),
    NOT `main..HEAD` (two-dot, branch-tip diff). The two-dot form lists
    every file that differs between branch tips — which under parallel
    autopilot includes any sibling task that merged to main after this
    branch forked, producing spurious "forbidden touches" that this
    branch never modified. The three-dot form pins the comparison to the
    merge-base (the fork commit), so the diff returns only files this
    branch actually changed since fork. See
    `claude/tools/lib/pre-merge-rebase.sh` for the parallel-task context.

    Skips when there's no diff against the merge-base.
    """
    try:
        result = subprocess.run(
            ["git", "diff", "--name-only", "main...HEAD"],
            cwd=REPO_ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        import pytest as _pytest

        _pytest.skip("git not available")
        return
    if result.returncode != 0:
        import pytest as _pytest

        _pytest.skip(f"git diff failed: {result.stderr}")
        return
    changed = [line for line in result.stdout.splitlines() if line.strip()]
    if not changed:
        import pytest as _pytest

        _pytest.skip("no diff against main")
        return

    allowed_prefixes = (
        "docs/INPROGRESS_Feature_grinder-scanner-enable/",
        "docs/INPROGRESS_Plan_grinder-full-stack/",
        # docs/grinder/ holds regenerated grinder-plan.yaml and
        # scanner-output/* artifacts. These are NOT source-of-truth files in
        # AS-8's sense ("the only listed source-of-truth file shall be
        # pipeline.yaml"); they are continuously regenerated by the grinder
        # discovery service, which runs independently of this feature
        # pipeline. Enabling bandit + semgrep triggers a fresh discovery
        # pass on the next grinder run, producing the commit visible here.
        "docs/grinder/",
    )
    allowed_exact = {
        "pipeline.yaml",
        "tests/test_pipeline_yaml_unified.py",
        "tests/test_grinder_static.py",
        "tests/test_validate_manifest.py",
        "core/schema/manifest.schema.json",
    }
    violations = [
        path
        for path in changed
        if path not in allowed_exact and not path.startswith(allowed_prefixes)
    ]
    assert not violations, (
        f"REQ-10 (relaxed): diff touches forbidden paths: {violations}.\n"
        f"Only {sorted(allowed_exact)} and docs/INPROGRESS_*/grinder-* / "
        f"docs/grinder/ are allowed."
    )


# ---------------------------------------------------------------------------
# integration_test schema contract — real integration gates (§4.1)
#
# integration_test gains an object form declaring the project's integration
# *surface*: commands + trigger globs (§5) + services the ephemeral exec env
# brings up (§6a Guard #4). The legacy flat-array form stays valid (the
# detection half, SESSION_2026-06-02) — backward compatible via oneOf.
# ---------------------------------------------------------------------------


def _manifest_validator() -> jsonschema.Draft202012Validator:
    schema = json.loads(SCHEMA_FILE.read_text())
    return jsonschema.Draft202012Validator(schema)


class TestIntegrationTestSchema:
    def test_legacy_array_form_valid(self) -> None:
        v = _manifest_validator()
        assert v.is_valid({"integration_test": ["bash dashboard/tests/run-all.sh"]})

    def test_object_form_full_valid(self) -> None:
        v = _manifest_validator()
        manifest = {
            "integration_test": {
                "commands": ["bash dashboard/tests/run-all.sh --only-integration"],
                "trigger": ["dashboard/**", "core/schema/**"],
                "services": [
                    {
                        "name": "postgres-test-db",
                        "start_cmd": "docker compose up -d db-test",
                        "health_cmd": "pg_isready -h localhost",
                    }
                ],
            }
        }
        assert v.is_valid(manifest), list(v.iter_errors(manifest))

    def test_object_commands_only_valid(self) -> None:
        v = _manifest_validator()
        assert v.is_valid({"integration_test": {"commands": ["bash integ.sh"]}})

    def test_object_missing_commands_rejected(self) -> None:
        v = _manifest_validator()
        assert not v.is_valid({"integration_test": {"trigger": ["dashboard/**"]}})

    def test_object_empty_commands_rejected(self) -> None:
        v = _manifest_validator()
        assert not v.is_valid({"integration_test": {"commands": []}})

    def test_service_missing_name_rejected(self) -> None:
        v = _manifest_validator()
        manifest = {
            "integration_test": {
                "commands": ["bash integ.sh"],
                "services": [{"start_cmd": "docker up"}],
            }
        }
        assert not v.is_valid(manifest)

    def test_service_unknown_field_rejected(self) -> None:
        v = _manifest_validator()
        manifest = {
            "integration_test": {
                "commands": ["bash integ.sh"],
                "services": [{"name": "pg", "bogus": True}],
            }
        }
        assert not v.is_valid(manifest)

    def test_object_unknown_field_rejected(self) -> None:
        v = _manifest_validator()
        manifest = {"integration_test": {"commands": ["x"], "bogus": True}}
        assert not v.is_valid(manifest)

    def test_root_pipeline_yaml_integration_block_valid(self) -> None:
        """The real pipeline.yaml integration_test block validates (whichever
        form it currently uses)."""
        v = _manifest_validator()
        manifest = yaml.safe_load(PIPELINE_YAML.read_text())
        assert v.is_valid(manifest), list(v.iter_errors(manifest))
