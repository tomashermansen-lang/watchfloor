"""Unit tests for plan_helpers.py extensions.

Tests find_plans, find_task, _match_task_to_dir, evaluate_gate,
enhanced merge_file_status with R6a matching, and gate enrichment
(_normalize_checklist, _apply_evaluations, enrich_gates).
"""
import json
import sys
from pathlib import Path

# Add project root to path so we can import server.plan_helpers
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dashboard.server.plan_helpers import (
    PLAN_ARTIFACT_ESCAPE_MARKER,
    PLAN_ARTIFACT_OUTSIDE_ROOT_MARKER,
    _apply_evaluations,
    _load_plan_file,
    _match_task_to_dir,
    _normalize_checklist,
    discover_all_plans_v2,
    enrich_gates,
    evaluate_gate,
    find_plans,
    find_task,
    get_plan_artifact,
    merge_file_status,
)

# ─── Fixtures ─────────────────────────────────────────────────────────


def _make_plan(phases):
    """Create a minimal valid plan dict."""
    return {"schema_version": "1.0.0", "name": "Test Plan", "phases": phases}


def _make_phase(phase_id, tasks, gate=None):
    """Create a phase dict."""
    phase = {"id": phase_id, "name": f"Phase: {phase_id}", "tasks": tasks}
    if gate:
        phase["gate"] = gate
    return phase


def _make_task(task_id, status="pending", depends=None):
    """Create a task dict."""
    task = {"id": task_id, "name": f"Task {task_id}", "status": status}
    if depends:
        task["depends"] = depends
    return task


def _write_yaml_plan(path, plan_dict):
    """Write a plan as YAML (or JSON if PyYAML unavailable)."""
    try:
        import yaml

        path.write_text(yaml.dump(plan_dict, default_flow_style=False))
    except ImportError:
        # Fall back to JSON with .yaml extension — find_plans handles this
        path.write_text(json.dumps(plan_dict))


# ─── _match_task_to_dir tests ─────────────────────────────────────────


class TestMatchTaskToDir:
    def test_exact_match(self):
        result, tier = _match_task_to_dir("vector-store", ["vector-store", "ui-search"])
        assert result == "vector-store"
        assert tier == "exact"

    def test_normalized_hyphens_underscores(self):
        result, tier = _match_task_to_dir("vector_store", ["vector-store", "ui-search"])
        assert result == "vector-store"
        assert tier == "normalized"

    def test_normalized_case_insensitive(self):
        result, tier = _match_task_to_dir("Vector-Store", ["vector-store", "ui-search"])
        assert result == "vector-store"
        assert tier == "normalized"

    def test_fuzzy_needle_substring_of_candidate(self):
        # "dark-mode" (9 chars) is substring of "dark-mode-ui" (12 chars) → 75% coverage
        result, tier = _match_task_to_dir("dark-mode", ["dark-mode-ui"])
        assert result == "dark-mode-ui"
        assert tier == "fuzzy"

    def test_fuzzy_candidate_substring_of_needle(self):
        # "auth-module" (11 chars) is substring of "api-auth-module" (15 chars) → 73% coverage
        result, tier = _match_task_to_dir("api-auth-module", ["auth-module"])
        assert result == "auth-module"
        assert tier == "fuzzy"

    def test_fuzzy_rejects_short_substring(self):
        # "capacity" (8 chars) in "absence-aware-capacity" (22 chars) → 36% coverage → NO match
        result, tier = _match_task_to_dir("absence-aware-capacity", ["capacity"])
        assert result is None
        assert tier == "none"

    def test_fuzzy_rejects_very_short_candidate(self):
        # "api" (3 chars) in "authentication-api" (18 chars) → 17% coverage → NO match
        result, tier = _match_task_to_dir("authentication-api", ["api"])
        assert result is None
        assert tier == "none"

    def test_fuzzy_rejects_dashboard_vs_eval_dashboard(self):
        # "dashboard" (9 chars) in "eval-dashboard" (14 chars) → 64% coverage → NO match
        result, tier = _match_task_to_dir("eval-dashboard", ["dashboard"])
        assert result is None
        assert tier == "none"

    def test_no_match(self):
        result, tier = _match_task_to_dir("vector-store", ["ui-search", "api-auth"])
        assert result is None
        assert tier == "none"

    def test_empty_candidates(self):
        result, tier = _match_task_to_dir("anything", [])
        assert result is None
        assert tier == "none"


# ─── find_plans tests ─────────────────────────────────────────────────


class TestFindPlans:
    def test_find_plans_inprogress(self, tmp_path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_my-feature"
        plan_dir.mkdir(parents=True)
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        _write_yaml_plan(plan_dir / "execution-plan.yaml", plan)

        results = find_plans(str(tmp_path))
        assert len(results) == 1
        assert results[0]["name"] == "my-feature"
        assert results[0]["lifecycle"] == "inprogress"
        assert results[0]["type"] == "plan"

    def test_find_plans_done(self, tmp_path):
        plan_dir = tmp_path / "docs" / "DONE_Plan_old-feature"
        plan_dir.mkdir(parents=True)
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        _write_yaml_plan(plan_dir / "execution-plan.yaml", plan)

        results = find_plans(str(tmp_path))
        assert len(results) == 1
        assert results[0]["name"] == "old-feature"
        assert results[0]["lifecycle"] == "done"
        assert results[0]["type"] == "plan"

    def test_find_plans_inprogress_feature(self, tmp_path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Feature_my-feat"
        plan_dir.mkdir(parents=True)
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        _write_yaml_plan(plan_dir / "execution-plan.yaml", plan)

        results = find_plans(str(tmp_path))
        assert len(results) == 1
        assert results[0]["name"] == "my-feat"
        assert results[0]["lifecycle"] == "inprogress"
        assert results[0]["type"] == "feature"

    def test_find_plans_pending_feature(self, tmp_path):
        plan_dir = tmp_path / "docs" / "PENDING_Feature_backlog-item"
        plan_dir.mkdir(parents=True)
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        _write_yaml_plan(plan_dir / "execution-plan.yaml", plan)

        results = find_plans(str(tmp_path))
        assert len(results) == 1
        assert results[0]["name"] == "backlog-item"
        assert results[0]["lifecycle"] == "pending"
        assert results[0]["type"] == "feature"

    def test_find_plans_root_yaml_fallback(self, tmp_path):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        _write_yaml_plan(tmp_path / "execution-plan.yaml", plan)

        results = find_plans(str(tmp_path))
        assert len(results) == 1
        assert results[0]["lifecycle"] == "root"

    def test_find_plans_root_json_fallback(self, tmp_path):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        (tmp_path / "execution-plan.json").write_text(json.dumps(plan))

        results = find_plans(str(tmp_path))
        assert len(results) == 1
        assert results[0]["lifecycle"] == "root"

    def test_find_plans_no_docs_dir(self, tmp_path):
        results = find_plans(str(tmp_path))
        assert results == []

    def test_find_plans_multiple(self, tmp_path):
        for name, prefix in [("feat-a", "INPROGRESS_Plan_"), ("feat-b", "DONE_Plan_")]:
            plan_dir = tmp_path / "docs" / f"{prefix}{name}"
            plan_dir.mkdir(parents=True)
            plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
            _write_yaml_plan(plan_dir / "execution-plan.yaml", plan)

        results = find_plans(str(tmp_path))
        assert len(results) == 2
        names = {r["name"] for r in results}
        assert names == {"feat-a", "feat-b"}

    def test_find_plans_malformed_yaml(self, tmp_path):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_bad"
        plan_dir.mkdir(parents=True)
        (plan_dir / "execution-plan.yaml").write_text("{{invalid yaml:::")

        good_dir = tmp_path / "docs" / "INPROGRESS_Plan_good"
        good_dir.mkdir(parents=True)
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        _write_yaml_plan(good_dir / "execution-plan.yaml", plan)

        results = find_plans(str(tmp_path))
        assert len(results) == 1
        assert results[0]["name"] == "good"


# ─── find_task tests ──────────────────────────────────────────────────


class TestFindTask:
    def test_exact_match(self):
        plan = _make_plan([
            _make_phase("p1", [_make_task("vector-store"), _make_task("ui-search")])
        ])
        task = find_task(plan, "vector-store")
        assert task is not None
        assert task["id"] == "vector-store"

    def test_normalized_match(self):
        plan = _make_plan([
            _make_phase("p1", [_make_task("vector-store")])
        ])
        task = find_task(plan, "vector_store")
        assert task is not None
        assert task["id"] == "vector-store"

    def test_fuzzy_match(self):
        plan = _make_plan([
            _make_phase("p1", [_make_task("dark-mode-ui")])
        ])
        task = find_task(plan, "dark-mode")
        assert task is not None
        assert task["id"] == "dark-mode-ui"

    def test_no_match(self):
        plan = _make_plan([
            _make_phase("p1", [_make_task("vector-store")])
        ])
        task = find_task(plan, "nonexistent")
        assert task is None

    def test_searches_all_phases(self):
        plan = _make_plan([
            _make_phase("p1", [_make_task("task-a")]),
            _make_phase("p2", [_make_task("task-b")]),
        ])
        task = find_task(plan, "task-b")
        assert task is not None
        assert task["id"] == "task-b"


# ─── evaluate_gate tests ─────────────────────────────────────────────


class TestEvaluateGate:
    def test_all_done(self):
        plan = _make_plan([
            _make_phase("p1", [
                _make_task("t1", status="done"),
                _make_task("t2", status="done"),
            ])
        ])
        result = evaluate_gate(plan, "p1")
        assert result["phase_id"] == "p1"
        assert result["all_complete"] is True
        assert result["gate_passed"] is True

    def test_partial(self):
        plan = _make_plan([
            _make_phase("p1", [
                _make_task("t1", status="done"),
                _make_task("t2", status="pending"),
            ])
        ])
        result = evaluate_gate(plan, "p1")
        assert result["all_complete"] is False
        assert result["gate_passed"] is False

    def test_with_skipped(self):
        plan = _make_plan([
            _make_phase("p1", [
                _make_task("t1", status="done"),
                _make_task("t2", status="skipped"),
            ])
        ])
        result = evaluate_gate(plan, "p1")
        assert result["all_complete"] is True
        assert result["gate_passed"] is True

    def test_unknown_phase(self):
        plan = _make_plan([
            _make_phase("p1", [_make_task("t1", status="done")])
        ])
        result = evaluate_gate(plan, "nonexistent")
        assert result["all_complete"] is False
        assert result["gate_passed"] is False


# ─── merge_file_status R6a matching tests ─────────────────────────────


class TestMergeFileStatusR6a:
    def test_normalized_match(self, tmp_path):
        """task-a matches DONE_Feature_task_a/ via normalized matching."""
        docs = tmp_path / "docs"
        (docs / "DONE_Feature_task_a").mkdir(parents=True)
        plan = _make_plan([
            _make_phase("p1", [_make_task("task-a", status="pending")])
        ])
        result = merge_file_status(plan, str(tmp_path))
        assert result["phases"][0]["tasks"][0]["status"] == "done"

    def test_fuzzy_match(self, tmp_path):
        """dark-mode matches INPROGRESS_Feature_dark-mode-ui/ via fuzzy (75% coverage)."""
        docs = tmp_path / "docs"
        (docs / "INPROGRESS_Feature_dark-mode-ui").mkdir(parents=True)
        plan = _make_plan([
            _make_phase("p1", [_make_task("dark-mode", status="pending")])
        ])
        result = merge_file_status(plan, str(tmp_path))
        assert result["phases"][0]["tasks"][0]["status"] == "wip"

    def test_fuzzy_rejects_short_match(self, tmp_path):
        """capacity should NOT match absence-aware-capacity (36% coverage)."""
        docs = tmp_path / "docs"
        (docs / "DONE_Feature_capacity").mkdir(parents=True)
        plan = _make_plan([
            _make_phase("p1", [_make_task("absence-aware-capacity", status="pending")])
        ])
        result = merge_file_status(plan, str(tmp_path))
        assert result["phases"][0]["tasks"][0]["status"] == "pending"

    def test_exact_preserved(self, tmp_path):
        """Existing exact match behavior is preserved (regression test)."""
        docs = tmp_path / "docs"
        (docs / "DONE_Feature_task-a").mkdir(parents=True)
        plan = _make_plan([
            _make_phase("p1", [_make_task("task-a", status="pending")])
        ])
        result = merge_file_status(plan, str(tmp_path))
        assert result["phases"][0]["tasks"][0]["status"] == "done"


# ─── _load_plan_file tests ───────────────────────────────────────────


class TestLoadPlanFile:
    def test_load_yaml(self, tmp_path):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        plan_path = tmp_path / "execution-plan.yaml"
        _write_yaml_plan(plan_path, plan)
        result = _load_plan_file(plan_path)
        assert result is not None
        assert result["name"] == "Test Plan"

    def test_load_json(self, tmp_path):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        plan_path = tmp_path / "execution-plan.json"
        plan_path.write_text(json.dumps(plan))
        result = _load_plan_file(plan_path)
        assert result is not None
        assert result["name"] == "Test Plan"

    def test_malformed_returns_none(self, tmp_path):
        plan_path = tmp_path / "execution-plan.json"
        plan_path.write_text("{{not valid json")
        result = _load_plan_file(plan_path)
        assert result is None

    def test_yaml_with_json_content(self, tmp_path):
        """A .yaml file containing valid JSON should still load."""
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        plan_path = tmp_path / "execution-plan.yaml"
        plan_path.write_text(json.dumps(plan))
        result = _load_plan_file(plan_path)
        assert result is not None
        assert result["name"] == "Test Plan"


# ─── evaluate_gate edge case tests ───────────────────────────────────


class TestEvaluateGateEdge:
    def test_empty_tasks(self):
        """Phase with no tasks should not pass gate."""
        plan = _make_plan([_make_phase("p1", [])])
        result = evaluate_gate(plan, "p1")
        assert result["all_complete"] is False
        assert result["gate_passed"] is False


# ─── _normalize_checklist tests ──────────────────────────────────────


class TestNormalizeChecklist:
    def test_nc1_plain_string_items(self):
        result = _normalize_checklist(["item1", "item2"])
        assert len(result) == 2
        assert result[0] == {"item": "item1", "kind": "human", "lastResult": None}
        assert result[1] == {"item": "item2", "kind": "human", "lastResult": None}

    def test_nc2_object_with_shell_check(self):
        result = _normalize_checklist([
            {"item": "x", "check": {"kind": "shell", "cmd": "y"}},
        ])
        assert result[0]["item"] == "x"
        assert result[0]["kind"] == "shell"
        assert result[0]["lastResult"] is None
        assert result[0]["check"] == {"kind": "shell", "cmd": "y"}

    def test_nc3_object_with_no_check_field(self):
        result = _normalize_checklist([{"item": "review"}])
        assert result[0] == {"item": "review", "kind": "human", "lastResult": None}

    def test_nc4_object_with_kind_human(self):
        result = _normalize_checklist([
            {"item": "x", "check": {"kind": "human"}},
        ])
        assert result[0]["kind"] == "human"

    def test_nc5_unknown_kind_defaults_to_human(self):
        result = _normalize_checklist([
            {"item": "x", "check": {"kind": "magic"}},
        ])
        assert result[0]["kind"] == "human"

    def test_nc6_mixed_string_and_object(self):
        result = _normalize_checklist([
            "s",
            {"item": "o", "check": {"kind": "shell", "cmd": "c"}},
        ])
        assert result[0]["kind"] == "human"
        assert result[1]["kind"] == "shell"

    def test_nc7_empty_checklist(self):
        result = _normalize_checklist([])
        assert result == []


# ─── _apply_evaluations tests ────────────────────────────────────────


class TestApplyEvaluations:
    def test_ae1_matching_count(self):
        normalized = [
            {"item": "a", "kind": "shell", "lastResult": None},
            {"item": "b", "kind": "human", "lastResult": None},
        ]
        evals = [
            {"text": "a", "kind": "shell", "result": "passed"},
            {"text": "b", "kind": "human", "result": "needs_review"},
        ]
        result = _apply_evaluations(normalized, evals)
        assert result[0]["lastResult"] == "passed"
        assert result[1]["lastResult"] == "needs_review"

    def test_ae2_more_eval_items_than_checklist(self):
        normalized = [
            {"item": "a", "kind": "shell", "lastResult": None},
            {"item": "b", "kind": "shell", "lastResult": None},
        ]
        evals = [
            {"text": "a", "kind": "shell", "result": "passed"},
            {"text": "b", "kind": "shell", "result": "failed"},
            {"text": "c", "kind": "shell", "result": "passed"},
        ]
        result = _apply_evaluations(normalized, evals)
        assert len(result) == 2
        assert result[0]["lastResult"] == "passed"
        assert result[1]["lastResult"] == "failed"

    def test_ae3_fewer_eval_items_than_checklist(self):
        normalized = [
            {"item": "a", "kind": "shell", "lastResult": None},
            {"item": "b", "kind": "shell", "lastResult": None},
            {"item": "c", "kind": "shell", "lastResult": None},
        ]
        evals = [
            {"text": "a", "kind": "shell", "result": "passed"},
            {"text": "b", "kind": "shell", "result": "failed"},
        ]
        result = _apply_evaluations(normalized, evals)
        assert result[0]["lastResult"] == "passed"
        assert result[1]["lastResult"] == "failed"
        assert result[2]["lastResult"] is None

    def test_ae4_empty_eval_items(self):
        normalized = [
            {"item": "a", "kind": "shell", "lastResult": None},
            {"item": "b", "kind": "shell", "lastResult": None},
        ]
        result = _apply_evaluations(normalized, [])
        assert result[0]["lastResult"] is None
        assert result[1]["lastResult"] is None


# ─── enrich_gates integration tests ─────────────────────────────────


class TestEnrichGates:
    def test_eg1_full_enrichment(self, tmp_path):
        """EG1: Plan with gate + chain-events → enriched items."""
        ndjson = tmp_path / "chain-events.ndjson"
        ndjson.write_text(json.dumps({
            "type": "gate_evaluated", "phase": "p1",
            "items": [{"text": "tests", "kind": "shell", "result": "passed"}],
        }) + "\n")
        plan = _make_plan([
            _make_phase("p1", [_make_task("t1")], gate={
                "name": "G", "checklist": ["tests"], "passed": False,
            }),
        ])
        result = enrich_gates(plan, str(tmp_path))
        gate = result["phases"][0]["gate"]
        assert "enrichedChecklist" in gate
        assert gate["enrichedChecklist"][0]["lastResult"] == "passed"
        assert gate["enrichedChecklist"][0]["kind"] == "human"  # derived from string item

    def test_eg2_no_chain_events(self, tmp_path):
        """EG2: No chain-events.ndjson → items have lastResult=None."""
        plan = _make_plan([
            _make_phase("p1", [_make_task("t1")], gate={
                "name": "G", "checklist": ["tests"], "passed": False,
            }),
        ])
        result = enrich_gates(plan, str(tmp_path))
        gate = result["phases"][0]["gate"]
        assert gate["enrichedChecklist"][0]["lastResult"] is None

    def test_eg3_gate_passed_overrides(self, tmp_path):
        """EG3: gate.passed=true overrides all items to passed."""
        ndjson = tmp_path / "chain-events.ndjson"
        ndjson.write_text(json.dumps({
            "type": "gate_evaluated", "phase": "p1",
            "items": [{"text": "tests", "kind": "shell", "result": "failed"}],
        }) + "\n")
        plan = _make_plan([
            _make_phase("p1", [_make_task("t1")], gate={
                "name": "G", "checklist": ["tests"], "passed": True,
            }),
        ])
        result = enrich_gates(plan, str(tmp_path))
        gate = result["phases"][0]["gate"]
        assert gate["enrichedChecklist"][0]["lastResult"] == "passed"

    def test_eg4_plan_without_gates(self, tmp_path):
        """EG4: Plan with no gates returns unchanged."""
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        result = enrich_gates(plan, str(tmp_path))
        assert "gate" not in result["phases"][0]

    def test_eg5_multiple_phases_with_gates(self, tmp_path):
        """EG5: Multiple phases with gates, each enriched from own events."""
        ndjson = tmp_path / "chain-events.ndjson"
        lines = [
            json.dumps({"type": "gate_evaluated", "phase": "p1",
                         "items": [{"text": "a", "kind": "shell", "result": "passed"}]}),
            json.dumps({"type": "gate_evaluated", "phase": "p2",
                         "items": [{"text": "b", "kind": "shell", "result": "failed"}]}),
        ]
        ndjson.write_text("\n".join(lines) + "\n")
        plan = _make_plan([
            _make_phase("p1", [_make_task("t1")], gate={
                "name": "G1", "checklist": ["a"], "passed": False,
            }),
            _make_phase("p2", [_make_task("t2")], gate={
                "name": "G2", "checklist": ["b"], "passed": False,
            }),
        ])
        result = enrich_gates(plan, str(tmp_path))
        assert result["phases"][0]["gate"]["enrichedChecklist"][0]["lastResult"] == "passed"
        assert result["phases"][1]["gate"]["enrichedChecklist"][0]["lastResult"] == "failed"


# ─── Schema 2.0 adoption tests (C22) ──────────────────────────────────


PROJECT_ROOT_PATH = Path(__file__).resolve().parent.parent
FIXTURE_2_0_FULL = PROJECT_ROOT_PATH / "tests" / "fixtures" / "plan-2.0.0" / "full.yaml"


class TestLoadPlanFile2_0:
    def test_2_0_preserves_top_level_keys(self):
        plan = _load_plan_file(FIXTURE_2_0_FULL)
        assert plan is not None
        assert plan["schema_version"].startswith("2.")
        for key in [
            "vision", "users", "success_criteria", "scope", "tech_stack",
            "existing_infrastructure_to_reuse", "test_targets", "setup",
            "kill_criteria", "design_notes", "risks", "phases", "deferred",
        ]:
            assert key in plan, f"missing top-level key: {key}"

    def test_2_0_first_task_has_2_0_fields(self):
        plan = _load_plan_file(FIXTURE_2_0_FULL)
        first_task = plan["phases"][0]["tasks"][0]
        for key in ["task_type", "what", "why", "where", "acceptance", "artifact_refs"]:
            assert key in first_task, f"first task missing {key}"


class TestDiscoverAllPlansV2SchemaVersion:
    def _setup_root(self, tmp_path):
        # Create docs/INPROGRESS_Plan_*/execution-plan.yaml structure.
        return tmp_path

    def test_returns_schema_version_for_2_0_plan(self, tmp_path, monkeypatch):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_two_oh"
        plan_dir.mkdir(parents=True)
        # Use the actual fixture
        import shutil
        shutil.copy(FIXTURE_2_0_FULL, plan_dir / "execution-plan.yaml")

        from dashboard.server import plan_helpers
        monkeypatch.setattr(plan_helpers, "_resolve_repo_roots",
                            lambda: {str(tmp_path)})
        result = discover_all_plans_v2()
        assert len(result) == 1
        assert result[0]["schema_version"].startswith("2.")
        assert result[0]["lifecycle"] == "inprogress"

    def test_legacy_no_schema_version_falls_back_to_1_0_0(self, tmp_path, monkeypatch):
        plan_dir = tmp_path / "docs" / "INPROGRESS_Plan_legacy"
        plan_dir.mkdir(parents=True)
        # Plan with NO schema_version field at all
        plan_data = {"name": "Legacy", "phases": [{"id": "p1", "name": "P1", "tasks": []}]}
        _write_yaml_plan(plan_dir / "execution-plan.yaml", plan_data)

        from dashboard.server import plan_helpers
        monkeypatch.setattr(plan_helpers, "_resolve_repo_roots",
                            lambda: {str(tmp_path)})
        result = discover_all_plans_v2()
        assert len(result) == 1
        assert result[0]["schema_version"] == "1.0.0"

    def test_legacy_root_level_fallback_no_schema_version(self, tmp_path, monkeypatch):
        # No docs/ dir; root-level plan via load_execution_plan fallback
        plan_data = {"name": "RootLegacy", "phases": []}
        _write_yaml_plan(tmp_path / "execution-plan.yaml", plan_data)

        from dashboard.server import plan_helpers
        monkeypatch.setattr(plan_helpers, "_resolve_repo_roots",
                            lambda: {str(tmp_path)})
        result = discover_all_plans_v2()
        assert len(result) == 1
        assert result[0]["schema_version"] == "1.0.0"
        assert result[0]["lifecycle"] == "root"

    def test_coexistence_1_x_and_2_0(self, tmp_path, monkeypatch):
        one_x_dir = tmp_path / "docs" / "INPROGRESS_Plan_one_x"
        two_oh_dir = tmp_path / "docs" / "INPROGRESS_Plan_two_oh"
        one_x_dir.mkdir(parents=True)
        two_oh_dir.mkdir(parents=True)
        plan_1x = _make_plan([_make_phase("p1", [_make_task("t1")])])
        _write_yaml_plan(one_x_dir / "execution-plan.yaml", plan_1x)
        import shutil
        shutil.copy(FIXTURE_2_0_FULL, two_oh_dir / "execution-plan.yaml")

        from dashboard.server import plan_helpers
        monkeypatch.setattr(plan_helpers, "_resolve_repo_roots",
                            lambda: {str(tmp_path)})
        result = discover_all_plans_v2()
        assert len(result) == 2
        versions = sorted([r["schema_version"] for r in result])
        assert versions[0].startswith("1.")
        assert versions[1].startswith("2.")
        for r in result:
            assert r["lifecycle"] == "inprogress"

    def test_two_2_0_plans(self, tmp_path, monkeypatch):
        for name in ("two_oh_a", "two_oh_b"):
            d = tmp_path / "docs" / f"INPROGRESS_Plan_{name}"
            d.mkdir(parents=True)
            import shutil
            shutil.copy(FIXTURE_2_0_FULL, d / "execution-plan.yaml")
        from dashboard.server import plan_helpers
        monkeypatch.setattr(plan_helpers, "_resolve_repo_roots",
                            lambda: {str(tmp_path)})
        result = discover_all_plans_v2()
        assert len(result) == 2
        for r in result:
            assert r["schema_version"].startswith("2.")


class TestMergeFileStatus2_0:
    def test_2_0_status_override_applies(self, tmp_path):
        plan = {
            "schema_version": "2.0.0",
            "name": "Demo",
            "phases": [{
                "id": "p1", "name": "Phase 1",
                "tasks": [{"id": "demo-task", "name": "Demo", "status": "pending"}],
            }],
        }
        (tmp_path / "docs" / "DONE_Feature_demo-task").mkdir(parents=True)
        result = merge_file_status(plan, str(tmp_path))
        assert result["phases"][0]["tasks"][0]["status"] == "done"


class TestSession2_0BranchMatch:
    def test_branch_name_to_task_id_match(self):
        # The hook contract: task IDs match branch names via _match_task_to_dir.
        # 2.0 plans use the same task.id format as 1.x — confirm coexistence.
        result, tier = _match_task_to_dir("validator-2-0", ["validator-2-0", "other-task"])
        assert result == "validator-2-0"
        assert tier == "exact"


# ─── C28: get_plan_artifact descended-path mode ──────────────────────


class TestGetPlanArtifactDescended:
    def _make_project(self, tmp_path):
        feature = tmp_path / "docs" / "INPROGRESS_Feature_demo"
        feature.mkdir(parents=True)
        plan_md = feature / "PLAN.md"
        plan_md.write_text("# Demo plan body")
        (tmp_path / "execution-plan.yaml").write_text("schema_version: 1.0.0\nname: x\nphases: []\n")
        return tmp_path

    def test_descended_path_resolves(self, tmp_path, monkeypatch):
        root = self._make_project(tmp_path)
        from dashboard.server import plan_helpers
        monkeypatch.setattr(plan_helpers, "PROJECTS_ROOT", root.parent)
        content = get_plan_artifact(
            cwd=str(root), plan_dir=None, task="t1",
            filename="docs/INPROGRESS_Feature_demo/PLAN.md",
        )
        assert content == "# Demo plan body"

    def test_descended_path_dotdot_returns_escape_marker(self, tmp_path, monkeypatch):
        root = self._make_project(tmp_path)
        from dashboard.server import plan_helpers
        monkeypatch.setattr(plan_helpers, "PROJECTS_ROOT", root.parent)
        content = get_plan_artifact(
            cwd=str(root), plan_dir=None, task="t1",
            filename="../../etc/passwd",
        )
        assert content == PLAN_ARTIFACT_ESCAPE_MARKER

    def test_descended_path_cwd_outside_projects_root_returns_marker(self, tmp_path, monkeypatch):
        from dashboard.server import plan_helpers
        monkeypatch.setattr(plan_helpers, "PROJECTS_ROOT", tmp_path / "elsewhere")
        # cwd / is definitely outside the override
        content = get_plan_artifact(
            cwd="/", plan_dir=None, task="t1",
            filename="docs/foo/PLAN.md",
        )
        assert content == PLAN_ARTIFACT_OUTSIDE_ROOT_MARKER

    def test_basename_mode_unchanged(self, tmp_path, monkeypatch):
        # Pre-existing flat-basename mode — task/cwd path still works
        feature = tmp_path / "docs" / "INPROGRESS_Feature_legacy"
        feature.mkdir(parents=True)
        (feature / "PLAN.md").write_text("legacy plan body")
        from dashboard.server import plan_helpers
        monkeypatch.setattr(plan_helpers, "PROJECTS_ROOT", tmp_path.parent)
        content = get_plan_artifact(
            cwd=str(tmp_path), plan_dir=None, task="legacy",
            filename="PLAN.md",
        )
        assert content == "legacy plan body"

    def test_descended_path_basename_must_be_in_allowlist(self, tmp_path, monkeypatch):
        root = self._make_project(tmp_path)
        feature = root / "docs" / "INPROGRESS_Feature_demo"
        (feature / "random.txt").write_text("nope")
        from dashboard.server import plan_helpers
        monkeypatch.setattr(plan_helpers, "PROJECTS_ROOT", root.parent)
        content = get_plan_artifact(
            cwd=str(root), plan_dir=None, task="t1",
            filename="docs/INPROGRESS_Feature_demo/random.txt",
        )
        # random.txt is not in the basename allowlist
        assert content is None

    # ─── T7: C28 security guard — direct unit coverage ────────────────

    def test_get_plan_artifact_descended_dotdot_rejects(self, tmp_path, monkeypatch):
        """T7-a: descended path with '..' traversal returns escape marker."""
        root = self._make_project(tmp_path)
        from dashboard.server import plan_helpers
        monkeypatch.setattr(plan_helpers, "PROJECTS_ROOT", root.parent)
        result = get_plan_artifact(
            cwd=str(root), plan_dir=None, task="t1",
            filename="../../etc/passwd",
        )
        assert result == PLAN_ARTIFACT_ESCAPE_MARKER

    def test_get_plan_artifact_descended_absolute_path_rejects(self, tmp_path, monkeypatch):
        """T7-b: descended path with absolute filename returns escape marker.

        pathlib: Path('/some/cwd') / '/PLAN.md' == Path('/PLAN.md'), which is
        not relative to cwd — the containment guard catches this.
        """
        root = self._make_project(tmp_path)
        from dashboard.server import plan_helpers
        monkeypatch.setattr(plan_helpers, "PROJECTS_ROOT", root.parent)
        # '/PLAN.md' contains '/' so is_descended=True; but resolves outside cwd
        result = get_plan_artifact(
            cwd=str(root), plan_dir=None, task="t1",
            filename="/PLAN.md",
        )
        assert result == PLAN_ARTIFACT_ESCAPE_MARKER


# ─── active_session_count tests ───────────────────────────────────────


def _patch_workers(monkeypatch, sessions, autopilots, root_map, repo_roots=None):
    """Stub the four upstream surfaces of discover_all_plans_v2.

    sessions   — list[dict] returned by session_helpers.get_session_states
    autopilots — list[dict] returned by autopilot_helpers.discover_autopilots
    root_map   — dict[str, str] consulted by the _canonical_main_root stub
                 (path → main_repo_root); unmapped paths return path unchanged
    repo_roots — optional iterable of project_root paths returned by
                 _resolve_repo_roots; defaults to set(root_map.values())
    """
    from dashboard.server import plan_helpers
    if repo_roots is None:
        repo_roots = set(root_map.values())
    monkeypatch.setattr(plan_helpers, "_resolve_repo_roots", lambda: set(repo_roots))
    monkeypatch.setattr(plan_helpers.session_helpers, "get_session_states",
                        lambda: list(sessions))
    monkeypatch.setattr(plan_helpers.autopilot_helpers, "discover_autopilots",
                        lambda: list(autopilots))
    monkeypatch.setattr(plan_helpers, "_canonical_main_root",
                        lambda p: root_map.get(p))


def _setup_plan(tmp_path, plan_name, plan_dict, lifecycle="inprogress"):
    """Create docs/INPROGRESS_Plan_<name>/execution-plan.yaml under tmp_path."""
    prefix = {"inprogress": "INPROGRESS_Plan_", "done": "DONE_Plan_"}[lifecycle]
    plan_dir = tmp_path / "docs" / f"{prefix}{plan_name}"
    plan_dir.mkdir(parents=True, exist_ok=True)
    _write_yaml_plan(plan_dir / "execution-plan.yaml", plan_dict)
    return plan_dir


class TestCanonicalMainRoot:
    """Direct subprocess + log path coverage for _canonical_main_root (C1)."""

    def test_canonical_main_root_returns_none_on_invalid_path(self, caplog):
        # Case #25: does NOT patch the helper — exercises the real
        # subprocess + WARNING log path so a regression in C1 cannot
        # hide behind the stubs the rest of the grid uses.
        from dashboard.server import plan_helpers
        with caplog.at_level("WARNING"):
            result = plan_helpers._canonical_main_root("/nonexistent/12345")
        assert result is None
        assert any(
            "git worktree list" in rec.getMessage() and "/nonexistent/12345" in rec.getMessage()
            for rec in caplog.records
            if rec.levelname == "WARNING"
        ), f"expected WARNING with path, got: {[r.getMessage() for r in caplog.records]}"


class TestDiscoverAllPlansV2ActiveSessionCount:
    """24-case grid for the active_session_count field on /api/plans entries.

    Class name contains 'active_session_count' to satisfy the R9 grep gate.
    """

    # ── Group A — Field contract (R1, R3, R4, AS9) ────────────────────

    def test_field_present_and_integer_when_zero(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        _setup_plan(tmp_path, "alpha", plan)
        _patch_workers(monkeypatch, sessions=[], autopilots=[],
                       root_map={}, repo_roots={str(tmp_path)})
        result = discover_all_plans_v2()
        assert len(result) == 1
        entry = result[0]
        assert "active_session_count" in entry
        assert isinstance(entry["active_session_count"], int)
        assert entry["active_session_count"] == 0

    # ── Group B — Worker counting positives (R2) ──────────────────────

    def test_two_live_sessions_match_two_tasks(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [
            _make_task("t1"), _make_task("t2"), _make_task("t3"),
        ])])
        root_a = str(tmp_path / "repo_a")
        root_b = str(tmp_path / "repo_b")
        _setup_plan(Path(root_a), "alpha", plan)
        sessions = [
            {"branch": "feature/t1", "worktree": "/wt/t1", "status": "working"},
            {"branch": "feature/t2", "worktree": "/wt/t2", "status": "needs_input"},
            {"branch": "feature/other", "worktree": "/wt/other", "status": "working"},
        ]
        root_map = {
            "/wt/t1": root_a,
            "/wt/t2": root_a,
            "/wt/other": root_b,
        }
        _patch_workers(monkeypatch, sessions=sessions, autopilots=[],
                       root_map=root_map, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert len(result) == 1
        assert result[0]["active_session_count"] == 2

    def test_running_autopilot_contributes_to_count(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        autopilots = [{
            "branch": "feature/t1",
            "stream_path": "/wt/t1/docs/INPROGRESS_Feature_t1/autopilot-stream.ndjson",
            "log_path": "/wt/t1/docs/INPROGRESS_Feature_t1/autopilot.log",
            "status": "running",
        }]
        ap_parent = "/wt/t1/docs/INPROGRESS_Feature_t1"
        root_map = {ap_parent: root_a}
        _patch_workers(monkeypatch, sessions=[], autopilots=autopilots,
                       root_map=root_map, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 1

    def test_session_and_autopilot_same_pair_dedup(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        sessions = [
            {"branch": "feature/t1", "worktree": "/wt/t1", "status": "working"},
        ]
        autopilots = [{
            "branch": "feature/t1",
            "stream_path": "/wt/t1/docs/INPROGRESS_Feature_t1/autopilot-stream.ndjson",
            "status": "running",
        }]
        ap_parent = "/wt/t1/docs/INPROGRESS_Feature_t1"
        root_map = {"/wt/t1": root_a, ap_parent: root_a}
        _patch_workers(monkeypatch, sessions=sessions, autopilots=autopilots,
                       root_map=root_map, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 1

    def test_two_sessions_same_pair_dedup(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        sessions = [
            {"branch": "feature/t1", "worktree": "/wt/t1", "status": "working"},
            {"branch": "feature/t1", "worktree": "/wt/t1", "status": "needs_input"},
        ]
        _patch_workers(monkeypatch, sessions=sessions, autopilots=[],
                       root_map={"/wt/t1": root_a}, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 1

    # ── Group C — Worker filtering negatives ──────────────────────────

    def test_idle_closed_stale_sessions_not_counted(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        sessions = [
            {"branch": "feature/t1", "worktree": "/wt/t1", "status": "idle"},
            {"branch": "feature/t1", "worktree": "/wt/t1", "status": "closed"},
            {"branch": "feature/t1", "worktree": "/wt/t1", "status": "stale"},
        ]
        _patch_workers(monkeypatch, sessions=sessions, autopilots=[],
                       root_map={"/wt/t1": root_a}, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 0

    def test_completed_failed_autopilots_not_counted(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        autopilots = [
            {"branch": "feature/t1", "stream_path": "/wt/t1/docs/x/autopilot-stream.ndjson",
             "status": "completed"},
            {"branch": "feature/t1", "stream_path": "/wt/t1/docs/y/autopilot-stream.ndjson",
             "status": "failed"},
        ]
        root_map = {"/wt/t1/docs/x": root_a, "/wt/t1/docs/y": root_a}
        _patch_workers(monkeypatch, sessions=[], autopilots=autopilots,
                       root_map=root_map, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 0

    def test_branch_on_different_root_does_not_count(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        root_a = str(tmp_path / "repo_a")
        root_b = str(tmp_path / "repo_b")
        _setup_plan(Path(root_a), "alpha", plan)
        sessions = [
            {"branch": "feature/t1", "worktree": "/wt/t1", "status": "working"},
        ]
        _patch_workers(monkeypatch, sessions=sessions, autopilots=[],
                       root_map={"/wt/t1": root_b}, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 0

    # ── Group D — Branch suffix derivation ────────────────────────────

    def test_branch_suffix_uses_last_slash_segment(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("add-search")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        sessions = [
            {"branch": "feature/UI/add-search", "worktree": "/wt/x", "status": "working"},
        ]
        _patch_workers(monkeypatch, sessions=sessions, autopilots=[],
                       root_map={"/wt/x": root_a}, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 1

    def test_branch_with_no_slash_uses_whole_branch(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("hotfix-2026-05")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        sessions = [
            {"branch": "hotfix-2026-05", "worktree": "/wt/x", "status": "working"},
        ]
        _patch_workers(monkeypatch, sessions=sessions, autopilots=[],
                       root_map={"/wt/x": root_a}, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 1

    def test_underscore_hyphen_equivalence(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("plans-active-session-count")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        sessions = [
            {"branch": "feature/plans_active_session_count",
             "worktree": "/wt/x", "status": "working"},
        ]
        _patch_workers(monkeypatch, sessions=sessions, autopilots=[],
                       root_map={"/wt/x": root_a}, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 1

    def test_branch_none_or_empty_session_no_match(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        sessions = [
            {"branch": None, "worktree": "/wt/x", "status": "working"},
            {"branch": "", "worktree": "/wt/y", "status": "working"},
            {"branch": "   ", "worktree": "/wt/z", "status": "working"},
        ]
        root_map = {"/wt/x": root_a, "/wt/y": root_a, "/wt/z": root_a}
        _patch_workers(monkeypatch, sessions=sessions, autopilots=[],
                       root_map=root_map, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 0

    def test_autopilot_branch_none_no_match(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        autopilots = [
            {"branch": None, "stream_path": "/wt/x/docs/x/autopilot-stream.ndjson",
             "status": "running"},
        ]
        _patch_workers(monkeypatch, sessions=[], autopilots=autopilots,
                       root_map={"/wt/x/docs/x": root_a}, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 0

    def test_main_master_branch_does_not_match(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        sessions = [
            {"branch": "main", "worktree": "/wt/x", "status": "working"},
            {"branch": "master", "worktree": "/wt/y", "status": "working"},
        ]
        root_map = {"/wt/x": root_a, "/wt/y": root_a}
        _patch_workers(monkeypatch, sessions=sessions, autopilots=[],
                       root_map=root_map, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 0

    # ── Group E — Error containment ───────────────────────────────────

    def test_session_helper_raises_count_zero_continues(self, tmp_path, monkeypatch, caplog):
        from dashboard.server import plan_helpers
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        monkeypatch.setattr(plan_helpers, "_resolve_repo_roots",
                            lambda: {root_a})
        def boom():
            raise RuntimeError("jsonl corrupt")
        monkeypatch.setattr(plan_helpers.session_helpers,
                            "get_session_states", boom)
        monkeypatch.setattr(plan_helpers.autopilot_helpers,
                            "discover_autopilots", lambda: [])
        monkeypatch.setattr(plan_helpers, "_canonical_main_root", lambda p: p)
        with caplog.at_level("ERROR"):
            result = discover_all_plans_v2()
        assert len(result) == 1
        assert result[0]["active_session_count"] == 0
        assert any(
            "RuntimeError" in rec.getMessage()
            for rec in caplog.records if rec.levelname == "ERROR"
        )

    def test_autopilot_helper_raises_count_zero_continues_other_source(
            self, tmp_path, monkeypatch, caplog):
        from dashboard.server import plan_helpers
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        sessions = [
            {"branch": "feature/t1", "worktree": "/wt/t1", "status": "working"},
        ]
        monkeypatch.setattr(plan_helpers, "_resolve_repo_roots",
                            lambda: {root_a})
        monkeypatch.setattr(plan_helpers.session_helpers,
                            "get_session_states", lambda: list(sessions))
        def boom():
            raise OSError("disk on fire")
        monkeypatch.setattr(plan_helpers.autopilot_helpers,
                            "discover_autopilots", boom)
        monkeypatch.setattr(plan_helpers, "_canonical_main_root",
                            lambda p: root_a)
        with caplog.at_level("ERROR"):
            result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 1
        assert any(
            "OSError" in rec.getMessage()
            for rec in caplog.records if rec.levelname == "ERROR"
        )

    def test_both_helpers_raise_count_zero(self, tmp_path, monkeypatch, caplog):
        from dashboard.server import plan_helpers
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        monkeypatch.setattr(plan_helpers, "_resolve_repo_roots",
                            lambda: {root_a})
        def boom_s():
            raise RuntimeError("s")
        def boom_a():
            raise OSError("a")
        monkeypatch.setattr(plan_helpers.session_helpers,
                            "get_session_states", boom_s)
        monkeypatch.setattr(plan_helpers.autopilot_helpers,
                            "discover_autopilots", boom_a)
        monkeypatch.setattr(plan_helpers, "_canonical_main_root", lambda p: p)
        with caplog.at_level("ERROR"):
            result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 0
        error_msgs = [rec.getMessage() for rec in caplog.records
                      if rec.levelname == "ERROR"]
        assert any("RuntimeError" in m for m in error_msgs)
        assert any("OSError" in m for m in error_msgs)

    # ── Group F — Worktree resolution edge ────────────────────────────

    def test_canonical_main_root_returns_none_session_skipped(
            self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        sessions = [
            {"branch": "feature/t1", "worktree": "/wt/gone", "status": "working"},
        ]
        # root_map doesn't include /wt/gone — stub returns None for it.
        _patch_workers(monkeypatch, sessions=sessions, autopilots=[],
                       root_map={}, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 0

    # ── Group G — Multi-plan locality (R8, AS12, EC12) ────────────────

    def test_two_plans_same_root_each_gets_own_count(self, tmp_path, monkeypatch):
        plan_x = _make_plan([_make_phase("p1", [_make_task("a"), _make_task("b")])])
        plan_y = _make_plan([_make_phase("p1", [_make_task("c"), _make_task("d")])])
        plan_x["name"] = "Plan X"
        plan_y["name"] = "Plan Y"
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "x", plan_x)
        _setup_plan(tmp_path, "y", plan_y)
        sessions = [
            {"branch": "feature/a", "worktree": "/wt/a", "status": "working"},
            {"branch": "feature/c", "worktree": "/wt/c1", "status": "working"},
            {"branch": "feature/c", "worktree": "/wt/c2", "status": "working"},
        ]
        root_map = {"/wt/a": root_a, "/wt/c1": root_a, "/wt/c2": root_a}
        _patch_workers(monkeypatch, sessions=sessions, autopilots=[],
                       root_map=root_map, repo_roots={root_a})
        result = discover_all_plans_v2()
        by_name = {r["project"]: r for r in result}
        assert by_name["Plan X"]["active_session_count"] == 1
        assert by_name["Plan Y"]["active_session_count"] == 2

    def test_two_plans_same_task_id_both_count(self, tmp_path, monkeypatch):
        plan_x = _make_plan([_make_phase("p1", [_make_task("t1")])])
        plan_y = _make_plan([_make_phase("p1", [_make_task("t1")])])
        plan_x["name"] = "Plan X"
        plan_y["name"] = "Plan Y"
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "x", plan_x)
        _setup_plan(tmp_path, "y", plan_y)
        sessions = [
            {"branch": "feature/t1", "worktree": "/wt/t1", "status": "working"},
        ]
        _patch_workers(monkeypatch, sessions=sessions, autopilots=[],
                       root_map={"/wt/t1": root_a}, repo_roots={root_a})
        result = discover_all_plans_v2()
        for r in result:
            assert r["active_session_count"] == 1

    # ── Group H — Empty plan shapes ───────────────────────────────────

    def test_zero_tasks_zero_count(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [])])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        sessions = [
            {"branch": "feature/anything", "worktree": "/wt/x", "status": "working"},
        ]
        _patch_workers(monkeypatch, sessions=sessions, autopilots=[],
                       root_map={"/wt/x": root_a}, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 0

    def test_zero_phases_zero_count(self, tmp_path, monkeypatch):
        plan = _make_plan([])
        root_a = str(tmp_path)
        _setup_plan(tmp_path, "alpha", plan)
        _patch_workers(monkeypatch, sessions=[], autopilots=[],
                       root_map={}, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert result[0]["active_session_count"] == 0

    # ── Group I — Both code paths in C4 ───────────────────────────────

    def test_root_level_fallback_plan_has_field(self, tmp_path, monkeypatch):
        # No docs/ dir; root-level execution-plan.yaml triggers fallback.
        plan = {"name": "RootPlan", "phases": [
            {"id": "p1", "name": "P1", "tasks": [{"id": "t1", "status": "pending"}]},
        ]}
        _write_yaml_plan(tmp_path / "execution-plan.yaml", plan)
        root_a = str(tmp_path)
        _patch_workers(monkeypatch, sessions=[], autopilots=[],
                       root_map={}, repo_roots={root_a})
        result = discover_all_plans_v2()
        assert len(result) == 1
        entry = result[0]
        assert entry["lifecycle"] == "root"
        assert "active_session_count" in entry
        assert isinstance(entry["active_session_count"], int)
        assert entry["active_session_count"] == 0

    # ── Group J — Performance / single-call cache (EC14) ──────────────

    def test_workers_collected_once_not_per_plan(self, tmp_path, monkeypatch):
        from dashboard.server import plan_helpers
        plan_x = _make_plan([_make_phase("p1", [_make_task("a")])])
        plan_y = _make_plan([_make_phase("p1", [_make_task("b")])])
        plan_z = _make_plan([_make_phase("p1", [_make_task("c")])])
        plan_x["name"] = "X"
        plan_y["name"] = "Y"
        plan_z["name"] = "Z"
        root_a = str(tmp_path / "ra")
        root_b = str(tmp_path / "rb")
        Path(root_a).mkdir(parents=True)
        Path(root_b).mkdir(parents=True)
        _setup_plan(Path(root_a), "x", plan_x)
        _setup_plan(Path(root_a), "y", plan_y)
        _setup_plan(Path(root_b), "z", plan_z)

        session_calls: list[int] = []
        autopilot_calls: list[int] = []

        def sess_stub():
            session_calls.append(1)
            return []

        def ap_stub():
            autopilot_calls.append(1)
            return []

        monkeypatch.setattr(plan_helpers, "_resolve_repo_roots",
                            lambda: {root_a, root_b})
        monkeypatch.setattr(plan_helpers.session_helpers,
                            "get_session_states", sess_stub)
        monkeypatch.setattr(plan_helpers.autopilot_helpers,
                            "discover_autopilots", ap_stub)
        monkeypatch.setattr(plan_helpers, "_canonical_main_root",
                            lambda p: p)
        result = discover_all_plans_v2()
        assert len(result) == 3
        assert len(session_calls) == 1
        assert len(autopilot_calls) == 1


class TestDiscoverAllPlansV2LastActivity:
    """last_activity field on /api/plans entries.

    Sourced from the plan YAML's mtime — captures /done task-status flips,
    /plan-project --update edits, and any other write that touches the file.
    Replaces the active_session_count proxy that the RECENT sort chip used
    to map onto (audit-list-filters #1+#2+#3 — backend port to honest recency).
    """

    def test_field_present_as_iso_string(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        _setup_plan(tmp_path, "alpha", plan)
        _patch_workers(monkeypatch, sessions=[], autopilots=[],
                       root_map={}, repo_roots={str(tmp_path)})
        result = discover_all_plans_v2()
        assert len(result) == 1
        entry = result[0]
        assert "last_activity" in entry
        assert isinstance(entry["last_activity"], str)
        from datetime import datetime
        # Must parse as ISO 8601 (raises ValueError otherwise)
        datetime.fromisoformat(entry["last_activity"])

    def test_reflects_plan_file_mtime_ordering(self, tmp_path, monkeypatch):
        import os
        import time
        plan_a = _make_plan([_make_phase("pa", [_make_task("ta")])])
        plan_b = _make_plan([_make_phase("pb", [_make_task("tb")])])
        path_a = _setup_plan(tmp_path, "alpha", plan_a)
        path_b = _setup_plan(tmp_path, "beta", plan_b)
        old, new = time.time() - 1000, time.time()
        os.utime(path_a / "execution-plan.yaml", (old, old))
        os.utime(path_b / "execution-plan.yaml", (new, new))
        _patch_workers(monkeypatch, sessions=[], autopilots=[],
                       root_map={}, repo_roots={str(tmp_path)})
        result = discover_all_plans_v2()
        by_dir = {e["plan_dir"]: e for e in result}
        a_la = by_dir[str(path_a)]["last_activity"]
        b_la = by_dir[str(path_b)]["last_activity"]
        assert b_la > a_la, (
            f"beta (newer mtime) should have larger ISO timestamp than alpha; "
            f"got beta={b_la!r} alpha={a_la!r}"
        )

    def test_root_fallback_branch_also_populated(self, tmp_path, monkeypatch):
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        _write_yaml_plan(tmp_path / "execution-plan.yaml", plan)
        _patch_workers(monkeypatch, sessions=[], autopilots=[],
                       root_map={}, repo_roots={str(tmp_path)})
        result = discover_all_plans_v2()
        assert len(result) == 1
        assert "last_activity" in result[0]
        assert isinstance(result[0]["last_activity"], str)

    def test_plan_2_task_last_updated_trumps_file_mtime(self, tmp_path, monkeypatch):
        """Plan-2.0 task last_updated is the most accurate activity signal.

        Mtime is sensitive to git checkout reset (RSK-D in feature_helpers.py:214).
        When task last_updated is newer than file mtime, prefer it so plans
        sort by genuine work events (a /done flip on the day of work) rather
        than the day the operator last switched branches.
        """
        import os
        import time
        # Plan with a task carrying a very recent last_updated.
        recent_iso = "2099-01-01T00:00:00+00:00"
        task = _make_task("t1")
        task["last_updated"] = recent_iso
        plan = _make_plan([_make_phase("p1", [task])])
        plan["schema_version"] = "2.0.0"
        plan_dir = _setup_plan(tmp_path, "alpha", plan)
        # Force file mtime far in the past so the task ts must win.
        old_ts = time.time() - 86400 * 365  # 1 year ago
        os.utime(plan_dir / "execution-plan.yaml", (old_ts, old_ts))
        _patch_workers(monkeypatch, sessions=[], autopilots=[],
                       root_map={}, repo_roots={str(tmp_path)})
        result = discover_all_plans_v2()
        assert len(result) == 1
        assert result[0]["last_activity"] == recent_iso

    def test_plan_2_falls_back_to_mtime_when_no_task_last_updated(
        self, tmp_path, monkeypatch,
    ):
        """Plan-2.0 plan with empty/missing task last_updated still gets a
        timestamp via file mtime — so RECENT can still order it relative to
        plans that do carry task last_updated."""
        plan = _make_plan([_make_phase("p1", [_make_task("t1")])])
        plan["schema_version"] = "2.0.0"
        _setup_plan(tmp_path, "alpha", plan)
        _patch_workers(monkeypatch, sessions=[], autopilots=[],
                       root_map={}, repo_roots={str(tmp_path)})
        result = discover_all_plans_v2()
        assert len(result) == 1
        assert isinstance(result[0]["last_activity"], str)
        from datetime import datetime
        datetime.fromisoformat(result[0]["last_activity"])

    def test_max_across_multiple_task_last_updated(self, tmp_path, monkeypatch):
        """Plans with several tasks return the most recent last_updated."""
        import os
        import time
        t1 = _make_task("t1")
        t1["last_updated"] = "2026-01-01T00:00:00+00:00"
        t2 = _make_task("t2")
        t2["last_updated"] = "2026-06-01T00:00:00+00:00"  # newest
        t3 = _make_task("t3")
        t3["last_updated"] = "2026-03-15T00:00:00+00:00"
        plan = _make_plan([_make_phase("p1", [t1, t2, t3])])
        plan["schema_version"] = "2.0.0"
        plan_dir = _setup_plan(tmp_path, "alpha", plan)
        old_ts = time.time() - 86400 * 365
        os.utime(plan_dir / "execution-plan.yaml", (old_ts, old_ts))
        _patch_workers(monkeypatch, sessions=[], autopilots=[],
                       root_map={}, repo_roots={str(tmp_path)})
        result = discover_all_plans_v2()
        assert result[0]["last_activity"] == "2026-06-01T00:00:00+00:00"


class TestDataDirOverride:
    """DASHBOARD_DATA_DIR override (consistency with feature_helpers/metrics_helpers)."""

    def test_data_dir_honors_env(self, tmp_path, monkeypatch):
        """``_data_dir`` returns DASHBOARD_DATA_DIR when set."""
        from dashboard.server import plan_helpers as ph
        monkeypatch.setenv("DASHBOARD_DATA_DIR", str(tmp_path))
        assert ph._data_dir() == tmp_path

    def test_data_dir_falls_back_to_default(self, monkeypatch):
        """``_data_dir`` returns ``<repo>/dashboard/data`` when env unset."""
        from dashboard.server import plan_helpers as ph
        monkeypatch.delenv("DASHBOARD_DATA_DIR", raising=False)
        expected = Path(ph.__file__).resolve().parent.parent / "data"
        assert ph._data_dir() == expected

    def test_resolve_repo_roots_reads_env_data_dir(self, tmp_path, monkeypatch):
        """``_resolve_repo_roots`` reads sessions.jsonl from DASHBOARD_DATA_DIR."""
        from dashboard.server import plan_helpers as ph
        repo = tmp_path / "fake-repo"
        repo.mkdir()
        # Make it a real git repo so _validate_root_path can resolve it
        import subprocess
        subprocess.run(["git", "-C", str(repo), "init", "-q"], check=True)
        fake_data = tmp_path / "data"
        fake_data.mkdir()
        (fake_data / "sessions.jsonl").write_text(
            json.dumps({"sid": "x", "cwd": str(repo)}) + "\n",
            encoding="utf-8",
        )
        monkeypatch.setenv("DASHBOARD_DATA_DIR", str(fake_data))
        # Disable the cache by pointing the cache file at a non-existent path
        # within the env-pointed dir (it will be empty and not pollute results).
        monkeypatch.setattr(ph, "PROJECTS_ROOT", tmp_path)
        roots = ph._resolve_repo_roots()
        # The env-pointed sessions.jsonl named our fake repo cwd, so it must
        # appear in the resolved roots — proving that the env override took
        # effect rather than falling through to the default data dir.
        assert any(str(repo) in r for r in roots), (
            f"Expected env-pointed sessions.jsonl to seed roots, got {roots!r}"
        )

    def test_root_cache_uses_env_data_dir(self, tmp_path, monkeypatch):
        """Cache reads/writes follow DASHBOARD_DATA_DIR override."""
        from dashboard.server import plan_helpers as ph
        fake_data = tmp_path / "data"
        fake_data.mkdir()
        monkeypatch.setenv("DASHBOARD_DATA_DIR", str(fake_data))
        monkeypatch.setattr(ph, "PROJECTS_ROOT", tmp_path)
        sample_root = str(tmp_path / "alpha")
        (tmp_path / "alpha").mkdir()
        ph._save_root_cache({sample_root})
        cache_file = fake_data / ".plan_roots_cache"
        assert cache_file.is_file(), (
            f"_save_root_cache should write under DASHBOARD_DATA_DIR; "
            f"checked {cache_file}"
        )
        loaded = ph._load_root_cache()
        assert sample_root in loaded
