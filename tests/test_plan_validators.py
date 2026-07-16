"""Unit tests for ``claude/tools/lib/plan_validators.py``.

Each test feeds a small dict directly to a single validator function so
that pattern checks can be exercised without a full fixture file.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
LIB_DIR = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "lib"
sys.path.insert(0, str(LIB_DIR))

import plan_validators as pv  # noqa: E402


def _ctx(plan: dict, plan_dir: Path | None = None) -> pv.ValidationContext:
    return pv.ValidationContext.build(plan, plan_dir or REPO_ROOT)


def _minimal_task(**overrides) -> dict:
    base = {
        "id": "t1",
        "name": "T1",
        "task_type": "development",
        "status": "pending",
        "what": "x" * 100,
        "why": "y" * 130,
        "where": {"modify": ["src/x.py"], "create": [], "delete": []},
        "acceptance": ["When the task runs, it shall succeed."],
        "prompt": "do it",
    }
    base.update(overrides)
    return base


def _sized_task(**overrides) -> dict:
    """``_minimal_task`` plus a default in-target estimate.

    Sizing tests use this so they don't incidentally trigger the EC-A.4
    missing-estimate WARNING. Closure W2 from PLAN.md.

    Default values must match LINES_ESTIMATE_TARGET (100) and
    DURATION_HOURS_TARGET (2) so sizing tests asserting `warnings == []`
    are not affected by the helper's default estimate. Previously this
    used lines_estimate=150 — that exceeded the soft target after the
    2026-05-07 cap-tightening (commit 5e1c8dc) and every test in
    TestValidateTaskSizing began incidentally tripping the
    "split candidate" warning.
    """
    estimate = overrides.pop("estimate", {"lines_estimate": 100, "duration_hours": 2})
    task = _minimal_task(**overrides)
    task["estimate"] = estimate
    return task


def _minimal_plan(tasks=None, **overrides) -> dict:
    plan = {
        "schema_version": "2.0.0",
        "name": "x",
        "vision": "v",
        "users": ["a"],
        "success_criteria": [{"id": "SC-1", "description": "ok"}],
        "scope": {"in_scope": [], "out_of_scope": []},
        "tech_stack": ["py"],
        "existing_infrastructure_to_reuse": [],
        "test_targets": [{"id": "dotfiles", "path": "."}],
        "setup": {
            "prerequisites": [],
            "runtime_dependencies": [],
            "services_to_provision": [],
            "environment_verification": [],
            "out_of_scope": [],
        },
        "kill_criteria": [],
        "design_notes": [],
        "risks": [],
        "phases": [
            {
                "id": "p1",
                "name": "P1",
                "overview_summary": "ov",
                "sequencing_rationale": "sr",
                "tasks": tasks or [_minimal_task()],
            }
        ],
    }
    plan.update(overrides)
    return plan


def _phase_with_tasks(
    phase_id: str, tasks: list[dict], rationale: str = "walking-skeleton"
) -> dict:
    """Build a phase dict with an enum-valid sequencing_rationale by default."""
    return {
        "id": phase_id,
        "name": phase_id.upper(),
        "overview_summary": "ov",
        "sequencing_rationale": rationale,
        "tasks": tasks,
    }


def _split(out: list[str]) -> tuple[list[str], list[str]]:
    """Split validator output into (errors, warnings)."""
    errors = [m for m in out if not m.startswith("WARNING:")]
    warnings = [m for m in out if m.startswith("WARNING:")]
    return errors, warnings


class TestCompleteness:
    def test_clean_plan_has_no_completeness_errors(self):
        assert pv.validate_2_0_completeness(_ctx(_minimal_plan())) == []

    def test_optional_array_empty_accepted(self):
        """TC-V51: optional array field quality_warnings: [] is accepted (no error)."""
        plan = _minimal_plan()
        plan["quality_warnings"] = []
        out = pv.validate_2_0_completeness(_ctx(plan))
        assert out == [], f"empty quality_warnings should not error, got: {out}"

    def test_missing_task_what_emits_required_error(self):
        plan = _minimal_plan(tasks=[_minimal_task(what="")])
        out = pv.validate_2_0_completeness(_ctx(plan))
        assert any("task.t1.what required" in e for e in out)

    def test_missing_phase_field_emits_required_error(self):
        plan = _minimal_plan()
        del plan["phases"][0]["sequencing_rationale"]
        out = pv.validate_2_0_completeness(_ctx(plan))
        assert any("phase.p1.sequencing_rationale required" in e for e in out)


class TestUniqueTaskIds:
    def test_dup_task_id_across_phases_caught(self):
        plan = _minimal_plan()
        plan["phases"].append(
            {
                "id": "p2",
                "name": "P2",
                "overview_summary": "ov",
                "sequencing_rationale": "sr",
                "tasks": [_minimal_task(id="t1", where={"modify": ["x.py"]})],
            }
        )
        out = pv.validate_unique_task_ids(_ctx(plan))
        assert out and "duplicated" in out[0]

    def test_duplicate_id_within_phase_rejected(self):
        """TC-V53: two tasks in the same phase sharing the same id."""
        plan = _minimal_plan(
            tasks=[
                _minimal_task(id="dup"),
                _minimal_task(
                    id="dup", where={"modify": ["src/other.py"], "create": [], "delete": []}
                ),
            ]
        )
        out = pv.validate_unique_task_ids(_ctx(plan))
        assert out and "duplicated" in out[0]


class TestPolymorphicDeferred:
    def test_unknown_kind_emits_dispatch_error(self):
        plan = _minimal_plan()
        plan["deferred"] = [{"id": "x", "kind": "bogus"}]
        out = pv.validate_polymorphic_deferred(_ctx(plan))
        assert any("must be one of" in e for e in out)

    def test_duplicate_deferred_id_caught(self):
        plan = _minimal_plan()
        plan["deferred"] = [
            {"id": "DUP", "kind": "future_enhancement"},
            {"id": "DUP", "kind": "future_enhancement"},
        ]
        out = pv.validate_polymorphic_deferred(_ctx(plan))
        assert any("duplicated" in e for e in out)


class TestPattern1StubStrings:
    def test_short_what_emits_min_length(self):
        plan = _minimal_plan(tasks=[_minimal_task(what="short")])
        out = pv.detect_pattern_1_stub_strings(_ctx(plan))
        assert any("minimum length" in e and "task.t1.what" in e for e in out)

    def test_short_why_emits_min_length(self):
        plan = _minimal_plan(tasks=[_minimal_task(why="short")])
        out = pv.detect_pattern_1_stub_strings(_ctx(plan))
        assert any("task.t1.why" in e for e in out)

    def test_duplicate_60_char_window_caught(self):
        shared = "a" * 80
        plan = _minimal_plan(
            tasks=[
                _minimal_task(id="t1", what=shared),
                _minimal_task(id="t2", what=shared, where={"modify": ["src/y.py"]}),
            ]
        )
        out = pv.detect_pattern_1_stub_strings(_ctx(plan))
        assert any("duplicates" in e for e in out)

    def test_what_exactly_80_chars_passes(self):
        """TC-V02: boundary — `what` of exactly WHAT_MIN_CHARS passes."""
        what_80 = "x" * pv.WHAT_MIN_CHARS
        plan = _minimal_plan(tasks=[_minimal_task(what=what_80)])
        out = pv.detect_pattern_1_stub_strings(_ctx(plan))
        assert not any("task.t1.what: minimum length" in e for e in out), (
            f"80-char what should pass, got: {out}"
        )

    def test_shared_59_char_window_passes(self):
        """TC-V05: boundary — sharing 59 chars (below 60) does not trip dup."""
        # Two tasks share a 59-char prefix but each has unique tail to push
        # length over WHAT_MIN_CHARS without ever forming a 60-char overlap.
        shared = "a" * 59
        plan = _minimal_plan(
            tasks=[
                _minimal_task(id="t1", what=shared + ("b" * 50)),
                _minimal_task(
                    id="t2",
                    what=shared + ("c" * 50),
                    where={"modify": ["src/y.py"]},
                ),
            ]
        )
        out = pv.detect_pattern_1_stub_strings(_ctx(plan))
        assert not any("duplicates" in e for e in out), (
            f"59-char overlap should NOT trip dup detector, got: {out}"
        )

    def test_emoji_count_uses_python_len(self):
        """TC-V06: edge 8 — Python `len()` counts code points, not bytes.

        79 emojis fails (< WHAT_MIN_CHARS), 80 emojis passes (>= 80).
        """
        what_79 = "🚀" * 79
        what_80 = "🚀" * 80
        # 79 emojis → fail
        plan_fail = _minimal_plan(tasks=[_minimal_task(id="t1", what=what_79)])
        out_fail = pv.detect_pattern_1_stub_strings(_ctx(plan_fail))
        assert any("task.t1.what: minimum length" in e for e in out_fail), (
            f"79 emojis should fail, got: {out_fail}"
        )
        # 80 emojis → pass
        plan_ok = _minimal_plan(tasks=[_minimal_task(id="t2", what=what_80)])
        out_ok = pv.detect_pattern_1_stub_strings(_ctx(plan_ok))
        assert not any("task.t2.what: minimum length" in e for e in out_ok), (
            f"80 emojis should pass, got: {out_ok}"
        )

    def test_perf_100_tasks_under_1s(self):
        """TC-V07: shingle algorithm completes < 1s for 100 unique tasks."""
        import time

        tasks = []
        for i in range(100):
            # Each what is 500+ chars and deliberately unique (no shared
            # 60-char window) so the duplication scan does maximum work.
            unique_seed = f"{i:08d}-task-content-"
            what = unique_seed + (chr(0x40 + (i % 26)) * (520 - len(unique_seed)))
            why = f"why-{i:08d}-" + ("y" * 200)
            tasks.append(
                _minimal_task(
                    id=f"t{i}",
                    what=what,
                    why=why,
                    where={"modify": [f"src/m_{i}.py"], "create": [], "delete": []},
                )
            )
        plan = _minimal_plan(tasks=tasks)
        start = time.monotonic()
        pv.detect_pattern_1_stub_strings(_ctx(plan))
        elapsed = time.monotonic() - start
        assert elapsed < 1.0, f"shingle scan took {elapsed:.3f}s for 100 tasks"


class TestPattern2MeasurableCriteria:
    """TC-V08, TC-V09, TC-V10 — R16 success_criteria checks."""

    def _plan_with_sc(self, sc: dict) -> dict:
        plan = _minimal_plan()
        plan["success_criteria"] = [sc]
        return plan

    def test_manual_check_without_verification_fails(self):
        """TC-V08: measurable_via=manual-check with no verification → error."""
        sc = {
            "id": "SC-1",
            "description": "operator confirms output looks right",
            "measurable_via": "manual-check",
        }
        out = pv.detect_pattern_2_measurable_criteria(_ctx(self._plan_with_sc(sc)))
        assert any("manual-check requires" in e and "SC-1" in e for e in out), (
            f"expected R16 manual-check error, got: {out}"
        )
        # Plain error (no WARNING prefix) so the validator drives exit 1.
        assert any(
            not e.startswith("WARNING:") and "SC-1" in e and "manual-check" in e for e in out
        )

    def test_aspirational_language_warns(self):
        """TC-V09: well-designed without measurable artefact → WARNING only."""
        sc = {
            "id": "SC-2",
            "description": "the system shall be well-designed",
            "measurable_via": "test",
        }
        out = pv.detect_pattern_2_measurable_criteria(_ctx(self._plan_with_sc(sc)))
        warnings = [e for e in out if e.startswith("WARNING:")]
        assert any("SC-2" in e and "aspirational" in e for e in warnings), (
            f"expected aspirational WARNING, got: {out}"
        )
        # No non-WARNING errors for SC-2 because aspirational is a soft signal.
        assert not any((not e.startswith("WARNING:")) and "SC-2" in e for e in out)

    def test_aspirational_with_measurable_artefact_passes(self):
        """TC-V09 contrast: aspirational adjective + path-like artefact OK."""
        sc = {
            "id": "SC-3",
            "description": "well-designed: tests/coverage.xml line count > 0",
            "measurable_via": "test",
            "verified_at_phase": "qa",
        }
        out = pv.detect_pattern_2_measurable_criteria(_ctx(self._plan_with_sc(sc)))
        assert not any("SC-3" in e for e in out), out

    def test_measurable_via_test_without_verified_at_phase_warns(self):
        """TC-V10: edge 3 — measurable_via=test without verified_at_phase → WARNING."""
        sc = {
            "id": "SC-4",
            "description": "pytest suite passes with 0 failures",
            "measurable_via": "test",
            # deliberately omit verified_at_phase
        }
        out = pv.detect_pattern_2_measurable_criteria(_ctx(self._plan_with_sc(sc)))
        warnings = [e for e in out if e.startswith("WARNING:")]
        assert any("SC-4" in e and "verified_at_phase" in e for e in warnings), (
            f"expected TC-V10 WARNING, got: {out}"
        )
        # Must be WARNING (not a hard error), so validator should not exit 1 on this alone.
        assert not any((not e.startswith("WARNING:")) and "SC-4" in e for e in out)

    def test_measurable_via_test_with_verified_at_phase_passes(self):
        """TC-V10 contrast: measurable_via=test + verified_at_phase → no warning."""
        sc = {
            "id": "SC-5",
            "description": "pytest suite passes with 0 failures",
            "measurable_via": "test",
            "verified_at_phase": "qa",
        }
        out = pv.detect_pattern_2_measurable_criteria(_ctx(self._plan_with_sc(sc)))
        assert not any("SC-5" in e for e in out), out


class TestPattern3ExactPaths:
    def test_glob_in_modify_caught(self):
        plan = _minimal_plan(
            tasks=[_minimal_task(where={"modify": ["claude/**"], "create": [], "delete": []})]
        )
        out = pv.detect_pattern_3_exact_paths(_ctx(plan))
        assert any("glob pattern" in e for e in out)

    def test_pending_task_with_empty_where_caught(self):
        plan = _minimal_plan(
            tasks=[_minimal_task(where={"modify": [], "create": [], "delete": []})]
        )
        out = pv.detect_pattern_3_exact_paths(_ctx(plan))
        assert any("at least one" in e for e in out)

    def test_done_task_with_empty_where_accepted(self):
        plan = _minimal_plan(
            tasks=[_minimal_task(status="done", where={"modify": [], "create": [], "delete": []})]
        )
        out = pv.detect_pattern_3_exact_paths(_ctx(plan))
        assert out == []


class TestPattern4EARS:
    def test_non_ears_prefix_caught(self):
        plan = _minimal_plan(tasks=[_minimal_task(acceptance=["The system works"])])
        out = pv.detect_pattern_4_ears(_ctx(plan))
        assert any("EARS notation" in e for e in out)

    def test_missing_shall_caught(self):
        plan = _minimal_plan(tasks=[_minimal_task(acceptance=["When x, y happens."])])
        out = pv.detect_pattern_4_ears(_ctx(plan))
        assert any("EARS notation" in e for e in out)

    def test_where_prefix_accepted(self):
        plan = _minimal_plan(
            tasks=[_minimal_task(acceptance=["Where applicable, the system shall hold."])]
        )
        out = pv.detect_pattern_4_ears(_ctx(plan))
        assert out == []

    def test_shall_substring_in_marshalling_rejected(self):
        """TC-V18: 'marshalling' contains 'shall' as substring but not word-boundary.
        Verifies EARS_VERB_RE uses \\bshall\\b, not substring search."""
        plan = _minimal_plan(
            tasks=[_minimal_task(acceptance=["When the marshalling layer executes, it returns."])]
        )
        out = pv.detect_pattern_4_ears(_ctx(plan))
        assert any("EARS notation" in e for e in out), (
            "validator must reject: 'shall' only appears inside 'marshalling', not as a whole word"
        )


class TestPattern5XRefs:
    def test_dangling_phase_ref_caught(self):
        plan = _minimal_plan()
        plan["phases"][0]["kill_criteria_refs"] = ["KC-NONE"]
        out = pv.detect_pattern_5_xrefs(_ctx(plan))
        assert any("does not resolve" in e for e in out)

    def test_dangling_depends_caught(self):
        plan = _minimal_plan(tasks=[_minimal_task(depends=["nope"])])
        out = pv.detect_pattern_5_xrefs(_ctx(plan))
        assert any("depends" in e and "does not resolve" in e for e in out)

    def test_dangling_deferred_refs(self):
        """TC-V20: task.deferred_refs pointing to a non-existent deferred id."""
        plan = _minimal_plan(tasks=[_minimal_task(deferred_refs=["DF-GHOST"])])
        out = pv.detect_pattern_5_xrefs(_ctx(plan))
        assert any("deferred_refs" in e and "does not resolve" in e for e in out)

    def test_dangling_plan_phase_id_in_scope_mapping(self):
        """TC-V23: scope_mapping_from_backlog.plan_phase_id pointing to absent phase."""
        plan = _minimal_plan()
        plan["scope_mapping_from_backlog"] = [{"plan_phase_id": "GHOST-PHASE", "backlog_item": "x"}]
        out = pv.detect_pattern_5_xrefs(_ctx(plan))
        assert any("plan_phase_id" in e and "does not resolve" in e for e in out)

    @pytest.mark.parametrize(
        "ref_field",
        [
            "kill_criteria_refs",
            "design_notes_refs",
            "risks_refs",
            "deferred_refs",
            "depends",
            "plan_phase_id",
        ],
    )
    def test_xref_field_parametrised(self, ref_field):
        """TC-V24: each xref field emits a 'does not resolve' error for a bogus value."""
        if ref_field == "plan_phase_id":
            plan = _minimal_plan()
            plan["scope_mapping_from_backlog"] = [{"plan_phase_id": "BOGUS", "backlog_item": "x"}]
        elif ref_field == "depends":
            plan = _minimal_plan(tasks=[_minimal_task(depends=["BOGUS"])])
        else:
            plan = _minimal_plan()
            plan["phases"][0][ref_field] = ["BOGUS"]
        out = pv.detect_pattern_5_xrefs(_ctx(plan))
        assert any("does not resolve" in e for e in out), (
            f"{ref_field}: expected 'does not resolve' error, got: {out}"
        )


class TestPathQualifier:
    def test_qualifier_required_when_multiple_targets(self, tmp_path):
        plan = _minimal_plan()
        plan["test_targets"] = [
            {"id": "a", "path": "."},
            {"id": "b", "path": "."},
        ]
        plan["phases"][0]["tasks"][0]["where"] = {
            "modify": ["unqualified-path.py"],
            "create": [],
            "delete": [],
        }
        out = pv.validate_path_qualifier(_ctx(plan, tmp_path))
        assert any("must be qualified" in e for e in out)

    def test_unknown_qualifier_caught(self, tmp_path):
        plan = _minimal_plan()
        plan["test_targets"] = [
            {"id": "a", "path": "."},
            {"id": "b", "path": "."},
        ]
        plan["phases"][0]["tasks"][0]["where"] = {
            "modify": ["zzz:src/x.py"],
            "create": [],
            "delete": [],
        }
        out = pv.validate_path_qualifier(_ctx(plan, tmp_path))
        assert any("does not resolve to a test_target" in e for e in out)

    def test_nul_byte_rejected(self, tmp_path):
        """TC-V29: path containing NUL byte is rejected."""
        plan = _minimal_plan()
        plan["test_targets"] = [{"id": "dotfiles", "path": "."}]
        plan["phases"][0]["tasks"][0]["where"] = {
            "modify": ["src/fo\x00o.py"],
            "create": [],
            "delete": [],
        }
        out = pv.validate_path_qualifier(_ctx(plan, tmp_path))
        assert any("invalid path characters" in e for e in out), out

    def test_control_char_rejected(self, tmp_path):
        """TC-V30: path containing control char \x01 is rejected."""
        plan = _minimal_plan()
        plan["test_targets"] = [{"id": "dotfiles", "path": "."}]
        plan["phases"][0]["tasks"][0]["where"] = {
            "modify": ["src/fo\x01o.py"],
            "create": [],
            "delete": [],
        }
        out = pv.validate_path_qualifier(_ctx(plan, tmp_path))
        assert any("invalid path characters" in e for e in out), out

    def test_windows_separator_rejected(self, tmp_path):
        """TC-V31: path containing backslash (Windows separator) is rejected."""
        plan = _minimal_plan()
        plan["test_targets"] = [{"id": "dotfiles", "path": "."}]
        plan["phases"][0]["tasks"][0]["where"] = {
            "modify": ["src\\foo.py"],
            "create": [],
            "delete": [],
        }
        out = pv.validate_path_qualifier(_ctx(plan, tmp_path))
        assert any("invalid path characters" in e for e in out), out

    def test_symlink_escaping_root_rejected(self, tmp_path):
        """TC-V32: symlink that points outside the test_target root is rejected."""
        import os

        # Create a target root subtree and a symlink that escapes it.
        target_root = tmp_path / "target"
        target_root.mkdir()
        outside = tmp_path / "outside"
        outside.mkdir()
        evil_link = target_root / "evil"
        os.symlink(str(outside), str(evil_link))

        plan = _minimal_plan()
        plan["test_targets"] = [{"id": "tgt", "path": str(target_root)}]
        plan["phases"][0]["tasks"][0]["where"] = {
            "modify": ["tgt:evil/secret.py"],
            "create": [],
            "delete": [],
        }
        ctx = pv.ValidationContext.build(plan, tmp_path)
        out = pv.validate_path_qualifier(ctx)
        # The resolved symlink target (outside/) is outside target_root →
        # path traversal error must be emitted.
        assert any("path traversal" in e or "invalid path" in e for e in out), out


class TestArtifactRefs:
    def test_done_task_with_missing_path_caught(self, tmp_path):
        plan = _minimal_plan(
            tasks=[
                _minimal_task(
                    status="done",
                    artifact_refs={"plan_path": "no_such_file.md"},
                )
            ]
        )
        out = pv.validate_artifact_refs(_ctx(plan, tmp_path))
        assert any("file not found" in e for e in out)

    def test_pending_task_artifact_refs_skipped(self, tmp_path):
        plan = _minimal_plan(
            tasks=[
                _minimal_task(
                    status="pending",
                    artifact_refs={"plan_path": "no_such_file.md"},
                )
            ]
        )
        assert pv.validate_artifact_refs(_ctx(plan, tmp_path)) == []


class TestGateMeta:
    def test_bad_bash_syntax_caught(self):
        plan = _minimal_plan()
        plan["phases"][0]["gate"] = {
            "name": "g",
            "passed": False,
            "checklist": [
                {
                    "item": "x",
                    "check": {"kind": "shell", "cmd": "if then"},
                }
            ],
        }
        out = pv.validate_gate_meta(_ctx(plan))
        assert any("bash syntax error" in e for e in out)

    def test_runtime_budget_warning(self):
        plan = _minimal_plan()
        plan["phases"][0]["gate"] = {
            "name": "g",
            "passed": False,
            "checklist": [
                {
                    "item": "x",
                    "check": {"kind": "shell", "cmd": "echo ok", "expected_runtime_seconds": 60},
                }
            ],
        }
        out = pv.validate_gate_meta(_ctx(plan))
        assert any("WARNING" in e and "exceeds" in e for e in out)

    def test_injectable_metavar_does_not_execute(self, tmp_path):
        sentinel = tmp_path / "pwned"
        plan = _minimal_plan()
        plan["phases"][0]["gate"] = {
            "name": "g",
            "passed": False,
            "checklist": [
                {
                    "item": "x",
                    "check": {"kind": "shell", "cmd": f"$(touch {sentinel})"},
                }
            ],
        }
        pv.validate_gate_meta(_ctx(plan))
        assert not sentinel.exists()

    def test_zero_shell_items_in_code_bearing_phase_warns(self):
        """TC-V42: code-bearing phase with human-only checklist emits WARNING."""
        plan = _minimal_plan(
            tasks=[_minimal_task(where={"modify": ["src/foo.py"], "create": [], "delete": []})]
        )
        plan["phases"][0]["gate"] = {
            "name": "g",
            "passed": False,
            "checklist": [{"item": "manually verify", "check": {"kind": "human"}}],
        }
        out = pv.validate_gate_meta(_ctx(plan))
        assert any("WARNING" in e and "human-only" in e for e in out)

    def test_integration_only_gate_not_flagged_human_only(self):
        """A kind=integration gate is machine-verifiable (the orchestrator runs
        the suite), so a code-bearing phase whose only gate item is integration
        must NOT trigger the 'human-only checklist' warning (real integration
        gates — step-1 follow-up)."""
        plan = _minimal_plan(
            tasks=[_minimal_task(where={"modify": ["src/foo.py"], "create": [], "delete": []})]
        )
        plan["phases"][0]["gate"] = {
            "name": "g",
            "passed": False,
            "checklist": [{
                "item": "dashboard subsystems integrate",
                "check": {
                    "kind": "integration",
                    "trigger": ["dashboard/**"],
                    "remediation": {"agent": "lead-developer", "max_iterations": 2, "on_unfixable": "escalate"},
                },
            }],
        }
        out = pv.validate_gate_meta(_ctx(plan))
        assert not any("human-only" in e for e in out), out

    def test_cmd_longer_than_4096_chars_rejected(self):
        """TC-V46: cmd > MAX_GATE_CMD_LEN is rejected by bash checker."""
        long_cmd = "echo " + "x" * 4095
        assert len(long_cmd) > pv.MAX_GATE_CMD_LEN
        plan = _minimal_plan()
        plan["phases"][0]["gate"] = {
            "name": "g",
            "passed": False,
            "checklist": [{"item": "x", "check": {"kind": "shell", "cmd": long_cmd}}],
        }
        out = pv.validate_gate_meta(_ctx(plan))
        assert any("bash syntax error" in e or "exceeds" in e for e in out)

    def test_cmd_with_nul_byte_rejected(self):
        """TC-V47: cmd containing NUL byte is rejected by bash checker."""
        plan = _minimal_plan()
        plan["phases"][0]["gate"] = {
            "name": "g",
            "passed": False,
            "checklist": [{"item": "x", "check": {"kind": "shell", "cmd": "echo\x00bad"}}],
        }
        out = pv.validate_gate_meta(_ctx(plan))
        assert any("bash syntax error" in e or "control" in e for e in out)


class TestLegacyArtefacts:
    def test_warns_per_sibling_file(self, tmp_path):
        (tmp_path / "deferred-findings.json").write_text("[]")
        (tmp_path / "EXECUTION_PLAN.md").write_text("# x")
        ctx = pv.ValidationContext(plan={}, plan_dir=tmp_path)
        out = pv.detect_legacy_artefacts(ctx)
        assert sum("WARNING:" in e for e in out) == 2


# --- Part A — per-task sizing limits (R-A1..R-A9) -----------------------------


class TestValidateTaskSizing:
    """Direct unit tests for ``pv.validate_task_sizing(_ctx(plan))``."""

    def _run(self, task: dict) -> tuple[list[str], list[str]]:
        plan = _minimal_plan(tasks=[task])
        return _split(pv.validate_task_sizing(_ctx(plan)))

    # --- acceptance count (R-A1, EC-A.1, AS-A1) ---

    def test_acceptance_count_at_cap_passes(self):
        """EC-A.1: 5 ACs → silence."""
        acc = [f"When n={i}, the system shall do something." for i in range(5)]
        errors, warnings = self._run(_sized_task(acceptance=acc))
        assert errors == []
        assert warnings == []

    def test_acceptance_count_over_cap_errors(self):
        """R-A1, AS-A1: 6 ACs → 1 error naming task and rule."""
        acc = [f"When n={i}, the system shall do x." for i in range(6)]
        errors, _warnings = self._run(_sized_task(id="oversized-task", acceptance=acc))
        assert len(errors) == 1
        assert "oversized-task" in errors[0]
        assert "acceptance count > 5" in errors[0]

    def test_acceptance_count_seven_still_one_error(self):
        """R-A1: 7 ACs → still 1 error (counts > 5 collapse)."""
        acc = [f"When n={i}, the system shall do x." for i in range(7)]
        errors, _ = self._run(_sized_task(acceptance=acc))
        assert len(errors) == 1

    # --- lines_estimate (R-A2, R-A5, EC-A.2, EC-A.3, AS-A2, AS-A4) ---

    def test_lines_estimate_at_target_no_warning(self):
        """EC-A.2: lines=100 → silence (LINES_ESTIMATE_TARGET as of 2026-05-07)."""
        errors, warnings = self._run(
            _sized_task(estimate={"lines_estimate": 100, "duration_hours": 2})
        )
        assert errors == []
        assert warnings == []

    def test_lines_estimate_at_hard_cap_no_error(self):
        """EC-A.3: lines=200 → silence (LINES_ESTIMATE_HARD_CAP, cap inclusive — no error AND no warning)."""
        errors, warnings = self._run(
            _sized_task(estimate={"lines_estimate": 200, "duration_hours": 2})
        )
        assert errors == []
        assert warnings == []

    def test_lines_estimate_just_over_target_emits_warning(self):
        """R-A5: lines=101 → 1 WARNING (just above LINES_ESTIMATE_TARGET=100)."""
        errors, warnings = self._run(
            _sized_task(estimate={"lines_estimate": 101, "duration_hours": 2})
        )
        assert errors == []
        assert len(warnings) == 1
        assert "lines_estimate" in warnings[0]

    def test_lines_estimate_in_warning_band_emits_warning(self):
        """R-A5, AS-A4: lines=150 → 1 WARNING (open interval (100, 200) under new caps)."""
        errors, warnings = self._run(
            _sized_task(id="medium-task", estimate={"lines_estimate": 150, "duration_hours": 2})
        )
        assert errors == []
        assert len(warnings) == 1
        assert "medium-task" in warnings[0]
        assert warnings[0].startswith("WARNING:")

    def test_lines_estimate_over_hard_cap_errors(self):
        """R-A2, AS-A2: lines=250 → 1 error naming task and rule (above LINES_ESTIMATE_HARD_CAP=200)."""
        errors, _ = self._run(
            _sized_task(id="huge-task", estimate={"lines_estimate": 250, "duration_hours": 2})
        )
        assert len(errors) == 1
        assert "huge-task" in errors[0]
        assert "lines_estimate > 200" in errors[0]

    def test_lines_estimate_at_201_errors(self):
        """R-A2 boundary: lines=201 → error (strict > LINES_ESTIMATE_HARD_CAP=200)."""
        errors, _ = self._run(_sized_task(estimate={"lines_estimate": 201, "duration_hours": 2}))
        assert len(errors) == 1
        assert "lines_estimate > 200" in errors[0]

    # --- duration_hours (R-A3, R-A5) ---

    def test_duration_hours_at_target_silent(self):
        """duration=2 → silent (DURATION_HOURS_TARGET as of 2026-05-07)."""
        errors, warnings = self._run(
            _sized_task(estimate={"lines_estimate": 100, "duration_hours": 2})
        )
        assert errors == []
        assert warnings == []

    def test_duration_hours_at_cap_no_error(self):
        """EC-A.3 analog: duration=3 → silence (DURATION_HOURS_HARD_CAP, cap inclusive — no error AND no warning)."""
        errors, warnings = self._run(
            _sized_task(estimate={"lines_estimate": 100, "duration_hours": 3})
        )
        assert errors == []
        assert warnings == []

    def test_duration_hours_warning_band_emits_warning(self):
        """R-A5: 2.5h → 1 WARNING (open interval (2, 3) under new caps)."""
        errors, warnings = self._run(
            _sized_task(estimate={"lines_estimate": 100, "duration_hours": 2.5})
        )
        assert errors == []
        assert any("duration_hours" in w for w in warnings)

    def test_duration_hours_over_cap_errors(self):
        """R-A3: 3.5h → 1 error (above DURATION_HOURS_HARD_CAP=3)."""
        errors, _ = self._run(_sized_task(estimate={"lines_estimate": 100, "duration_hours": 3.5}))
        assert any("duration_hours > 3" in e for e in errors)

    # --- touched paths (R-A4, R-A5, EC-A.7, AS-A3) ---

    def test_touched_paths_at_target_silent(self):
        where = {"modify": ["a.py", "b.py", "c.py"], "create": [], "delete": []}
        errors, warnings = self._run(_sized_task(where=where))
        assert errors == []
        assert warnings == []

    def test_touched_paths_at_cap_no_error(self):
        """MAX_TOUCHED_PATHS_HARD_CAP=4 (since 2026-05-07) — 4 paths is at cap.
        The open-interval warning band ``target < x < hard_cap`` excludes the
        hard cap, so 4 paths → silent (no warning, no error)."""
        where = {
            "modify": ["a.py", "b.py", "c.py"],
            "create": ["d.py"],
            "delete": [],
        }
        errors, warnings = self._run(_sized_task(where=where))
        assert errors == []
        assert warnings == []

    def test_touched_paths_warning_band_emits_warning(self):
        """R-A5: with MAX_TOUCHED_PATHS_TARGET=3 and MAX_TOUCHED_PATHS_HARD_CAP=4
        (since 2026-05-07), the open-interval warning band ``target < x < hard_cap``
        contains no integer values — every integer path count is either at target
        (silent), at cap (silent), or over cap (error). The warning band is
        structurally empty, so this test is no longer applicable. Kept as a
        documented skip so the design intent is visible if caps change again."""
        import pytest
        pytest.skip(
            "Warning band for touched_paths is empty under MAX_TOUCHED_PATHS_TARGET=3 "
            "/ MAX_TOUCHED_PATHS_HARD_CAP=4 — no integer fits (3, 4). Re-enable if "
            "the gap between target and hard cap widens."
        )

    def test_touched_paths_over_cap_errors(self):
        """R-A4, AS-A3: 3 modify + 2 create + 1 delete = 6 → 1 error."""
        where = {
            "modify": ["a.py", "b.py", "c.py"],
            "create": ["d.py", "e.py"],
            "delete": ["f.py"],
        }
        errors, _ = self._run(_sized_task(id="wide-task", where=where))
        assert any("wide-task" in e and "touched paths > 4" in e for e in errors)

    def test_touched_paths_modify_only_over_cap(self):
        """R-A4: 6 modify → 1 error (rule sums all three)."""
        where = {
            "modify": ["a.py", "b.py", "c.py", "d.py", "e.py", "f.py"],
            "create": [],
            "delete": [],
        }
        errors, _ = self._run(_sized_task(where=where))
        assert any("touched paths > 4" in e for e in errors)

    # --- missing estimate (EC-A.4 / EC-A.5) ---

    def test_estimate_absent_emits_warning(self):
        """EC-A.4: task without estimate field → 1 WARNING."""
        errors, warnings = self._run(_minimal_task())  # no estimate
        assert errors == []
        assert any("estimate missing" in w for w in warnings)

    def test_estimate_lines_zero_emits_warning(self):
        """EC-A.5: lines_estimate=0 treated as marker for absent → WARNING."""
        errors, warnings = self._run(
            _sized_task(estimate={"lines_estimate": 0, "duration_hours": 2})
        )
        assert errors == []
        assert any("estimate missing" in w for w in warnings)

    def test_estimate_absent_does_not_short_circuit_other_checks(self):
        """W1 closure: missing-estimate WARNING + duration>4 ERROR fire together."""
        task = _minimal_task()
        task["estimate"] = {"duration_hours": 5}  # lines_estimate absent
        errors, warnings = self._run(task)
        assert any("estimate missing" in w for w in warnings)
        assert any("duration_hours > 3" in e for e in errors)

    # --- status exemptions (EC-A.6) ---

    def test_skipped_status_exempts_from_sizing(self):
        """EC-A.6: status=skipped + 5000 LOC → silence."""
        task = _sized_task(
            status="skipped", estimate={"lines_estimate": 5000, "duration_hours": 99}
        )
        # 7 ACs, 6 paths, all over cap — but skipped is exempt.
        task["acceptance"] = [f"When n={i}, the system shall do x." for i in range(7)]
        task["where"] = {"modify": ["a.py"] * 6, "create": [], "delete": []}
        errors, warnings = self._run(task)
        assert errors == []
        assert warnings == []

    def test_done_status_exempts_from_sizing(self):
        """EC-A.6: status=done + over-cap → silence."""
        task = _sized_task(status="done", estimate={"lines_estimate": 5000, "duration_hours": 99})
        errors, warnings = self._run(task)
        assert errors == []
        assert warnings == []

    def test_blocked_status_exempts_from_sizing(self):
        task = _sized_task(
            status="blocked", estimate={"lines_estimate": 5000, "duration_hours": 99}
        )
        errors, warnings = self._run(task)
        assert errors == []
        assert warnings == []

    def test_failed_status_exempts_from_sizing(self):
        task = _sized_task(status="failed", estimate={"lines_estimate": 5000, "duration_hours": 99})
        errors, warnings = self._run(task)
        assert errors == []
        assert warnings == []

    def test_pending_status_not_exempt(self):
        """EC-A.6 inverse: pending + 7 ACs → error (positive control)."""
        acc = [f"When n={i}, the system shall do x." for i in range(7)]
        errors, _ = self._run(_sized_task(status="pending", acceptance=acc))
        assert errors

    def test_wip_status_not_exempt(self):
        """EC-A.6 inverse: wip + over-cap fires."""
        errors, _ = self._run(
            _sized_task(status="wip", estimate={"lines_estimate": 500, "duration_hours": 2})
        )
        assert any("lines_estimate > 200" in e for e in errors)

    # --- multi-violation (EC-A.7) ---

    def test_multi_violation_no_short_circuit(self):
        """EC-A.7: 7 ACs + 6 paths + 400 LOC + 5h → 4 distinct error lines."""
        task = _sized_task(
            id="bad-task",
            acceptance=[f"When n={i}, the system shall do x." for i in range(7)],
            where={
                "modify": ["a.py", "b.py", "c.py", "d.py", "e.py", "f.py"],
                "create": [],
                "delete": [],
            },
            estimate={"lines_estimate": 400, "duration_hours": 5},
        )
        errors, _ = self._run(task)
        assert len(errors) == 4, f"expected 4 distinct errors, got: {errors}"

    # --- error string contracts (R-A6, R-A9) ---

    def test_error_string_names_task_id(self):
        acc = [f"When n={i}, the system shall do x." for i in range(6)]
        errors, _ = self._run(_sized_task(id="my-cool-task", acceptance=acc))
        assert any("my-cool-task" in e for e in errors)

    def test_error_string_names_rule_text(self):
        """Each rule string must appear in the matching error message."""
        # acceptance
        acc = [f"When n={i}, the system shall do x." for i in range(6)]
        errors, _ = self._run(_sized_task(acceptance=acc))
        assert any("acceptance count" in e for e in errors)
        # lines
        errors, _ = self._run(_sized_task(estimate={"lines_estimate": 400, "duration_hours": 2}))
        assert any("lines_estimate" in e for e in errors)
        # duration
        errors, _ = self._run(_sized_task(estimate={"lines_estimate": 150, "duration_hours": 6}))
        assert any("duration_hours" in e for e in errors)
        # paths
        where = {"modify": ["a.py"] * 6, "create": [], "delete": []}
        errors, _ = self._run(_sized_task(where=where))
        assert any("touched paths" in e for e in errors)

    def test_constants_are_module_level(self):
        """R-A9: every threshold lives as a module-level constant."""
        for name in (
            "MAX_ACCEPTANCE_COUNT",
            "LINES_ESTIMATE_TARGET",
            "LINES_ESTIMATE_HARD_CAP",
            "DURATION_HOURS_TARGET",
            "DURATION_HOURS_HARD_CAP",
            "MAX_TOUCHED_PATHS_TARGET",
            "MAX_TOUCHED_PATHS_HARD_CAP",
        ):
            assert hasattr(pv, name), f"plan_validators missing constant {name!r}"

    def test_constants_appear_in_error_strings(self):
        """R-A9: error string for lines>LINES_ESTIMATE_HARD_CAP must contain '200'."""
        errors, _ = self._run(_sized_task(estimate={"lines_estimate": 400, "duration_hours": 2}))
        assert any("200" in e for e in errors)

    def test_validators_2_0_registers_function(self):
        """R-A6: validate_task_sizing must be in VALIDATORS_2_0."""
        assert pv.validate_task_sizing in pv.VALIDATORS_2_0

    def test_run_all_on_minimal_task_emits_only_estimate_warning(self):
        """W2 boundary: _minimal_task has no estimate → 1 WARNING via run_all, no sizing errors."""
        plan = _minimal_plan()
        out = pv.run_all(_ctx(plan))
        sizing_warnings = [w for w in out if w.startswith("WARNING:") and "estimate missing" in w]
        sizing_errors = [
            e
            for e in out
            if not e.startswith("WARNING:")
            and any(
                k in e
                for k in ("acceptance count", "lines_estimate", "duration_hours", "touched paths")
            )
        ]
        assert len(sizing_warnings) == 1
        assert sizing_errors == []


# --- Part C — phase parallelism (R-C1..R-C3, R-C5) ----------------------------


class TestValidatePhaseParallelism:
    """Direct unit tests for ``pv.validate_phase_parallelism(_ctx(plan))``."""

    def _plan(self, phases: list[dict]) -> dict:
        return _minimal_plan() | {"phases": phases}

    def test_disjoint_paths_pass(self):
        """R-C1 baseline: no path overlap → 0 warnings."""
        tasks = [
            _minimal_task(id="t1", where={"modify": ["a.py"], "create": [], "delete": []}),
            _minimal_task(id="t2", where={"modify": ["b.py"], "create": [], "delete": []}),
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert errors == []
        assert warnings == []

    def test_overlap_emits_warning_naming_both_tasks_and_path(self):
        """R-C1, R-C2, AS-C1: shared modify path → 1 WARNING with both ids and path."""
        tasks = [
            _minimal_task(id="t1", where={"modify": ["src/foo.py"], "create": [], "delete": []}),
            _minimal_task(id="t2", where={"modify": ["src/foo.py"], "create": [], "delete": []}),
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert errors == []
        assert len(warnings) == 1
        msg = warnings[0]
        assert "t1" in msg and "t2" in msg
        assert "src/foo.py" in msg
        assert "p1" in msg

    def test_modify_create_overlap_emits_warning(self):
        tasks = [
            _minimal_task(id="t1", where={"modify": ["x.py"], "create": [], "delete": []}),
            _minimal_task(id="t2", where={"modify": [], "create": ["x.py"], "delete": []}),
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert errors == []
        assert len(warnings) == 1

    def test_create_create_overlap_emits_warning(self):
        tasks = [
            _minimal_task(id="t1", where={"modify": [], "create": ["x.py"], "delete": []}),
            _minimal_task(id="t2", where={"modify": [], "create": ["x.py"], "delete": []}),
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert len(warnings) == 1

    def test_where_delete_excluded_from_check(self):
        """R-C3: shared delete path → 0 warnings."""
        tasks = [
            _minimal_task(id="t1", where={"modify": [], "create": [], "delete": ["x.py"]}),
            _minimal_task(id="t2", where={"modify": [], "create": [], "delete": ["x.py"]}),
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert errors == []
        assert warnings == []

    def test_delete_paired_with_modify_no_warning(self):
        """R-C3: a deletes, b modifies same path → 0 warnings (delete excluded)."""
        tasks = [
            _minimal_task(id="t1", where={"modify": [], "create": [], "delete": ["x.py"]}),
            _minimal_task(id="t2", where={"modify": ["x.py"], "create": [], "delete": []}),
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert warnings == []

    def test_direct_depends_excludes_pair(self):
        """EC-C.1: direct depends edge → not parallel-eligible."""
        tasks = [
            _minimal_task(id="a", where={"modify": ["x.py"], "create": [], "delete": []}),
            _minimal_task(
                id="b", where={"modify": ["x.py"], "create": [], "delete": []}, depends=["a"]
            ),
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert warnings == []

    def test_transitive_depends_excludes_pair(self):
        """EC-C.1: a → mid → b chain → no warning."""
        tasks = [
            _minimal_task(id="a", where={"modify": ["x.py"], "create": [], "delete": []}),
            _minimal_task(
                id="mid", where={"modify": ["m.py"], "create": [], "delete": []}, depends=["a"]
            ),
            _minimal_task(
                id="b", where={"modify": ["x.py"], "create": [], "delete": []}, depends=["mid"]
            ),
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert warnings == []

    def test_cross_phase_overlap_ignored(self):
        """EC-C.2: same path in two phases → silence."""
        tasks_a = [_minimal_task(id="a", where={"modify": ["x.py"], "create": [], "delete": []})]
        tasks_b = [_minimal_task(id="b", where={"modify": ["x.py"], "create": [], "delete": []})]
        plan = self._plan(
            [
                _phase_with_tasks("p1", tasks_a),
                _phase_with_tasks("p2", tasks_b),
            ]
        )
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert warnings == []

    def test_three_way_overlap_emits_pairwise(self):
        """EC-C.3: 3 tasks share path → 3 WARNINGs."""
        tasks = [
            _minimal_task(id=tid, where={"modify": ["x.py"], "create": [], "delete": []})
            for tid in ("a", "b", "c")
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert len(warnings) == 3

    def test_single_task_phase_silent(self):
        tasks = [_minimal_task(id="solo")]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert warnings == []

    def test_zero_task_phase_silent(self):
        plan = self._plan([_phase_with_tasks("p1", [])])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert warnings == []

    def test_warning_cap_at_20_with_truncation_summary(self):
        """EC-C.5: 7 tasks all sharing one path → C(7,2)=21 pairs → 20 + truncation line."""
        tasks = [
            _minimal_task(id=f"t{i}", where={"modify": ["x.py"], "create": [], "delete": []})
            for i in range(7)
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert len(warnings) == 21  # 20 pair warnings + 1 truncation summary line
        assert any("more" in w for w in warnings)

    def test_done_status_excluded(self):
        """R-C5: done + pending sharing path → 0 warnings."""
        tasks = [
            _minimal_task(
                id="a", status="done", where={"modify": ["x.py"], "create": [], "delete": []}
            ),
            _minimal_task(
                id="b", status="pending", where={"modify": ["x.py"], "create": [], "delete": []}
            ),
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert warnings == []

    def test_skipped_status_excluded(self):
        tasks = [
            _minimal_task(
                id="a", status="skipped", where={"modify": ["x.py"], "create": [], "delete": []}
            ),
            _minimal_task(
                id="b", status="pending", where={"modify": ["x.py"], "create": [], "delete": []}
            ),
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert warnings == []

    def test_blocked_failed_status_excluded(self):
        for st in ("blocked", "failed"):
            tasks = [
                _minimal_task(
                    id="a", status=st, where={"modify": ["x.py"], "create": [], "delete": []}
                ),
                _minimal_task(
                    id="b", status="pending", where={"modify": ["x.py"], "create": [], "delete": []}
                ),
            ]
            plan = self._plan([_phase_with_tasks("p1", tasks)])
            errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
            assert warnings == [], f"status={st} should be excluded"

    def test_two_pending_tasks_compared(self):
        tasks = [
            _minimal_task(
                id="a", status="pending", where={"modify": ["x.py"], "create": [], "delete": []}
            ),
            _minimal_task(
                id="b", status="pending", where={"modify": ["x.py"], "create": [], "delete": []}
            ),
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert len(warnings) == 1

    def test_pending_and_wip_compared(self):
        tasks = [
            _minimal_task(
                id="a", status="pending", where={"modify": ["x.py"], "create": [], "delete": []}
            ),
            _minimal_task(
                id="b", status="wip", where={"modify": ["x.py"], "create": [], "delete": []}
            ),
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        errors, warnings = _split(pv.validate_phase_parallelism(_ctx(plan)))
        assert len(warnings) == 1

    def test_no_errors_only_warnings(self):
        """C-5: function never returns an unprefixed string."""
        tasks = [
            _minimal_task(id="a", where={"modify": ["x.py"], "create": [], "delete": []}),
            _minimal_task(id="b", where={"modify": ["x.py"], "create": [], "delete": []}),
        ]
        plan = self._plan([_phase_with_tasks("p1", tasks)])
        out = pv.validate_phase_parallelism(_ctx(plan))
        for line in out:
            assert line.startswith("WARNING:"), f"unexpected non-WARNING line: {line!r}"

    def test_validators_2_0_registers_function(self):
        assert pv.validate_phase_parallelism in pv.VALIDATORS_2_0


# --- Part C — sequencing rationale enum (R-C4) --------------------------------


class TestValidateSequencingRationaleEnum:
    """Direct unit tests for ``pv.validate_sequencing_rationale_enum(_ctx(plan))``."""

    def _plan_with_rationale(self, rationale: str) -> dict:
        plan = _minimal_plan()
        plan["phases"][0]["sequencing_rationale"] = rationale
        return plan

    def test_walking_skeleton_passes(self):
        out = pv.validate_sequencing_rationale_enum(
            _ctx(self._plan_with_rationale("walking-skeleton"))
        )
        assert out == []

    def test_data_model_first_passes(self):
        out = pv.validate_sequencing_rationale_enum(
            _ctx(self._plan_with_rationale("data-model-first"))
        )
        assert out == []

    def test_riskiest_first_passes(self):
        out = pv.validate_sequencing_rationale_enum(
            _ctx(self._plan_with_rationale("riskiest-first"))
        )
        assert out == []

    def test_smallest_first_passes(self):
        out = pv.validate_sequencing_rationale_enum(
            _ctx(self._plan_with_rationale("smallest-first"))
        )
        assert out == []

    def test_custom_at_40_chars_passes(self):
        """EC-C.6: exactly 40-char custom string → silence."""
        rationale = "x" * 40
        assert len(rationale) == 40
        out = pv.validate_sequencing_rationale_enum(_ctx(self._plan_with_rationale(rationale)))
        assert out == []

    def test_custom_at_39_chars_fails(self):
        """EC-C.6 boundary: 39 chars → 1 error containing rule text."""
        rationale = "x" * 39
        out = pv.validate_sequencing_rationale_enum(_ctx(self._plan_with_rationale(rationale)))
        assert len(out) == 1
        assert "40" in out[0]

    def test_custom_under_40_chars_fails(self):
        """R-C4, AS-C2: 'foo' → 1 error naming phase and rule."""
        out = pv.validate_sequencing_rationale_enum(_ctx(self._plan_with_rationale("foo")))
        assert len(out) == 1
        assert "p1" in out[0]
        assert "sequencing_rationale" in out[0]
        assert "walking-skeleton" in out[0]

    def test_enum_with_em_dash_trailing_prose_passes(self):
        """EC-C.7, R5 mitigation: 'walking-skeleton — chosen because ...' → silence."""
        rationale = "walking-skeleton — chosen because the core risk is in module X"
        out = pv.validate_sequencing_rationale_enum(_ctx(self._plan_with_rationale(rationale)))
        assert out == []

    def test_enum_with_space_trailing_prose_passes(self):
        rationale = "walking-skeleton scope is core subdomain X for the validator"
        out = pv.validate_sequencing_rationale_enum(_ctx(self._plan_with_rationale(rationale)))
        assert out == []

    def test_enum_followed_by_letter_does_not_match(self):
        """R5 mitigation: 'walking-skeletons-everywhere' → fails (treats as < 40 chars or non-enum)."""
        rationale = "walking-skeletons"  # 17 chars, no separator after enum prefix
        out = pv.validate_sequencing_rationale_enum(_ctx(self._plan_with_rationale(rationale)))
        # Either fails as non-enum (17 < 40 chars) — must produce error.
        assert len(out) == 1

    def test_empty_rationale_skipped_here(self):
        """R-C4 + R10 split: empty string → no error here (R10 owns presence)."""
        out = pv.validate_sequencing_rationale_enum(_ctx(self._plan_with_rationale("")))
        assert out == []

    def test_missing_rationale_skipped_here(self):
        plan = _minimal_plan()
        del plan["phases"][0]["sequencing_rationale"]
        out = pv.validate_sequencing_rationale_enum(_ctx(plan))
        assert out == []

    def test_error_string_names_phase_id(self):
        out = pv.validate_sequencing_rationale_enum(_ctx(self._plan_with_rationale("foo")))
        assert any("p1" in e for e in out)

    def test_error_string_lists_enum_values(self):
        out = pv.validate_sequencing_rationale_enum(_ctx(self._plan_with_rationale("foo")))
        joined = " ".join(out)
        for token in ("walking-skeleton", "data-model-first", "riskiest-first", "smallest-first"):
            assert token in joined

    def test_error_string_mentions_40_char_min(self):
        out = pv.validate_sequencing_rationale_enum(_ctx(self._plan_with_rationale("foo")))
        joined = " ".join(out)
        assert "40" in joined

    def test_validators_2_0_registers_function(self):
        assert pv.validate_sequencing_rationale_enum in pv.VALIDATORS_2_0

    def test_constants_are_module_level(self):
        for name in ("SEQUENCING_RATIONALE_ENUM", "SEQUENCING_RATIONALE_MIN_CHARS_CUSTOM"):
            assert hasattr(pv, name), f"plan_validators missing constant {name!r}"


class TestGateScopeR_G1:
    """Gate scope subset check (BACKLOG #48 R-G1).

    Negative gate checks must scope their path argument to the union of
    phase task paths. Broader scopes are flagged unless the operator
    documents the wider scope via scope_rationale.
    """

    def _plan_with_gate(
        self,
        cmd,
        scope_rationale=None,
        task_path="dashboard/app/src/components/features/FeatureList.tsx",
    ):
        task = _minimal_task(where={"modify": [task_path], "create": [], "delete": []})
        plan = _minimal_plan(tasks=[task])
        item = {"item": "x", "check": {"kind": "shell", "cmd": cmd}}
        if scope_rationale:
            item["scope_rationale"] = scope_rationale
        plan["phases"][0]["gate"] = {"name": "g", "passed": False, "checklist": [item]}
        return plan

    def test_negative_check_overbroad_path_warns(self):
        """The historical STATUS_SORT_ORDER incident: gate searches the
        whole frontend but tasks only touch features/."""
        plan = self._plan_with_gate("! grep -rn 'X' dashboard/app/src")
        out = pv.validate_gate_scope(_ctx(plan))
        assert any("WARNING" in e and "broader than phase task scope" in e for e in out), (
            f"Expected over-broad warning. out: {out}"
        )

    def test_negative_check_within_scope_passes(self):
        """Gate search path equal to the task path's parent dir is OK."""
        plan = self._plan_with_gate("! grep -rn 'X' dashboard/app/src/components/features/")
        out = pv.validate_gate_scope(_ctx(plan))
        assert not any("broader than phase task scope" in e for e in out), (
            f"In-scope path should not warn. out: {out}"
        )

    def test_scope_rationale_suppresses_warning(self):
        """Operator can document a deliberate broader scope."""
        plan = self._plan_with_gate(
            "! grep -rn 'X' dashboard/app/src",
            scope_rationale="Cross-cutting refactor — must verify removal across all dashboard frontend",
        )
        out = pv.validate_gate_scope(_ctx(plan))
        assert not any("broader than phase task scope" in e for e in out), (
            f"scope_rationale must suppress R-G1 warning. out: {out}"
        )

    def test_positive_check_does_not_trigger_R_G1(self):
        """Positive checks (e.g. cd path && vitest run) reference paths
        as artefacts, not scopes — must not produce R-G1 warnings.
        """
        plan = self._plan_with_gate("cd dashboard/app && npx vitest run src/__tests__/X.test.tsx")
        out = pv.validate_gate_scope(_ctx(plan))
        assert not any("broader than phase task scope" in e for e in out), (
            f"Positive check must not trigger R-G1. out: {out}"
        )

    def test_validators_2_0_registers_function(self):
        assert pv.validate_gate_scope in pv.VALIDATORS_2_0


class TestGateScopeRationaleR_G3:
    """Negative gate checks require scope_rationale (BACKLOG #48 R-G3).

    Negative checks (`! grep`, `test !`) are the easiest gate kind to
    over-author with broad path scope. Requiring scope_rationale forces
    the planner to defend the choice in the plan itself.
    """

    def _plan_with_check(self, cmd, scope_rationale=None):
        plan = _minimal_plan()
        item = {"item": "x", "check": {"kind": "shell", "cmd": cmd}}
        if scope_rationale:
            item["scope_rationale"] = scope_rationale
        plan["phases"][0]["gate"] = {"name": "g", "passed": False, "checklist": [item]}
        return plan

    def test_negative_grep_without_rationale_warns(self):
        plan = self._plan_with_check("! grep -rn 'X' src/")
        out = pv.validate_gate_scope_rationale(_ctx(plan))
        assert any("scope_rationale" in e and "negative check" in e for e in out), (
            f"Expected R-G3 warning. out: {out}"
        )

    def test_test_negation_without_rationale_warns(self):
        plan = self._plan_with_check("test ! -f src/old-file.py")
        out = pv.validate_gate_scope_rationale(_ctx(plan))
        assert any("scope_rationale" in e for e in out)

    def test_bracket_negation_without_rationale_warns(self):
        plan = self._plan_with_check("[ ! -e src/foo ]")
        out = pv.validate_gate_scope_rationale(_ctx(plan))
        assert any("scope_rationale" in e for e in out)

    def test_negative_with_rationale_passes(self):
        plan = self._plan_with_check(
            "! grep -rn 'STATUS_SORT_ORDER' dashboard/app/src/components/features/",
            scope_rationale="Guard against ghost re-introduction of the FeatureList constant in the features module only — other domains keep their own STATUS_SORT_ORDER for SessionStatus and AutopilotSessionStatus",
        )
        out = pv.validate_gate_scope_rationale(_ctx(plan))
        assert not any("scope_rationale" in e for e in out), (
            f"Rationale should suppress warning. out: {out}"
        )

    def test_positive_check_does_not_trigger(self):
        """Positive checks (no `!`) don't need a rationale."""
        plan = self._plan_with_check("grep -q 'X' src/foo.py")
        out = pv.validate_gate_scope_rationale(_ctx(plan))
        assert not any("scope_rationale" in e for e in out)

    def test_history_expansion_in_string_does_not_falsely_trigger(self):
        """Bare `!` without a following space (history expansion in
        non-bash contexts) must not be treated as negation."""
        plan = self._plan_with_check("echo 'hello!world'")
        out = pv.validate_gate_scope_rationale(_ctx(plan))
        assert not any("scope_rationale" in e for e in out), (
            f"Bare `!` not at word boundary must not trigger. out: {out}"
        )

    def test_validators_2_0_registers_function(self):
        assert pv.validate_gate_scope_rationale in pv.VALIDATORS_2_0


class TestGateDryRunR_G2:
    """Dry-run negative gate checks against current state (BACKLOG #48 R-G2).

    Detects gates that are mathematically broken before any work has
    happened. Opt-in via dry_run_gates=True on the context (mapped from
    --dry-run-gates CLI flag).
    """

    def _plan_with_check(self, cmd):
        plan = _minimal_plan()
        plan["phases"][0]["gate"] = {
            "name": "g",
            "passed": False,
            "checklist": [{"item": "x", "check": {"kind": "shell", "cmd": cmd}}],
        }
        return plan

    def test_off_by_default(self):
        """Without dry_run_gates flag, the validator returns []."""
        plan = self._plan_with_check("! grep -rn 'definitely-not-here-xyz' .")
        ctx = pv.ValidationContext.build(plan, REPO_ROOT)
        # Default dry_run_gates is False
        assert ctx.dry_run_gates is False
        out = pv.validate_gate_dry_run(ctx, REPO_ROOT)
        assert out == []

    def test_pre_broken_check_flagged(self, tmp_path):
        """When the gate's negative check already matches against the
        current state, the gate is mathematically broken."""
        # Set up a temp dir with a file that the gate's grep will match.
        (tmp_path / "src").mkdir()
        (tmp_path / "src" / "f.py").write_text("STATUS_SORT_ORDER = {}\n")
        plan = self._plan_with_check("! grep -rn 'STATUS_SORT_ORDER' src/")
        ctx = pv.ValidationContext.build(plan, tmp_path, dry_run_gates=True)
        out = pv.validate_gate_dry_run(ctx, tmp_path)
        assert any("mathematically pre-broken" in e for e in out), (
            f"Expected pre-broken finding. out: {out}"
        )

    def test_clean_check_passes(self, tmp_path):
        """When the gate's negative check finds nothing in the current
        state, no finding is emitted (the gate is satisfiable)."""
        (tmp_path / "src").mkdir()
        plan = self._plan_with_check("! grep -rn 'definitely-absent-token' src/")
        ctx = pv.ValidationContext.build(plan, tmp_path, dry_run_gates=True)
        out = pv.validate_gate_dry_run(ctx, tmp_path)
        assert out == [], f"Clean check should produce no finding. out: {out}"

    def test_destructive_cmd_skipped(self, tmp_path):
        """Cmd containing destructive operators (>, >>, rm) is NOT
        executed even with dry_run_gates=True."""
        sentinel = tmp_path / "pwned"
        plan = self._plan_with_check(f"! test -f {sentinel} > {sentinel}")
        ctx = pv.ValidationContext.build(plan, tmp_path, dry_run_gates=True)
        pv.validate_gate_dry_run(ctx, tmp_path)
        assert not sentinel.exists(), f"Destructive cmd must not execute. sentinel: {sentinel}"

    def test_only_whitelisted_negative_kinds_run(self, tmp_path):
        """Cmd not matching the whitelist (! grep | find | test | [) is
        skipped — only the safe absence-check forms execute."""
        # `! cat foo` is not whitelisted (cat is not in the safe set).
        plan = self._plan_with_check("! cat /etc/passwd")
        ctx = pv.ValidationContext.build(plan, tmp_path, dry_run_gates=True)
        out = pv.validate_gate_dry_run(ctx, tmp_path)
        # The cmd is skipped silently — no finding emitted.
        assert not any("pre-broken" in e for e in out)

    def test_validators_2_0_does_not_register_dry_run(self):
        """validate_gate_dry_run is intentionally NOT in the default
        VALIDATORS_2_0 list — invoked separately via CLI flag."""
        assert pv.validate_gate_dry_run not in pv.VALIDATORS_2_0


class TestPathExtraction:
    """Path-extraction heuristic correctness."""

    def test_extracts_repo_relative_path(self):
        paths = pv._extract_paths_from_cmd("! grep -rn 'X' dashboard/app/src")
        assert "dashboard/app/src" in paths

    def test_skips_flags(self):
        paths = pv._extract_paths_from_cmd("! grep -rn -i --include=*.ts 'X' dashboard/app/src")
        assert "-rn" not in paths
        assert "--include=*.ts" not in paths
        assert "dashboard/app/src" in paths

    def test_skips_quoted_search_pattern(self):
        paths = pv._extract_paths_from_cmd("! grep -rn 'STATUS_SORT_ORDER' src/")
        assert "STATUS_SORT_ORDER" not in paths
        assert "src/" in paths or "src" in paths

    def test_extracts_multiple_paths(self):
        paths = pv._extract_paths_from_cmd(
            "! grep -E 'X|Y' dashboard/app/src adapters/claude-code/"
        )
        assert "dashboard/app/src" in paths
        assert "adapters/claude-code/" in paths

    def test_no_paths_returns_empty(self):
        paths = pv._extract_paths_from_cmd("echo ok")
        assert paths == []


class TestPathWithinScope:
    """Subset-of-scope helper correctness."""

    def test_exact_match_is_within_scope(self):
        assert pv._path_within_scope(
            "dashboard/app/src/components/features/FeatureList.tsx",
            ["dashboard/app/src/components/features/FeatureList.tsx"],
        )

    def test_parent_dir_is_within_scope(self):
        """Gate path equal to task's parent dir is acceptable —
        searches the directory the task lives in."""
        assert pv._path_within_scope(
            "dashboard/app/src/components/features/",
            ["dashboard/app/src/components/features/FeatureList.tsx"],
        )

    def test_broader_path_is_NOT_within_scope(self):
        """Historical STATUS_SORT_ORDER scope: gate dashboard/app/src
        is broader than task dashboard/app/src/components/features/X."""
        assert not pv._path_within_scope(
            "dashboard/app/src",
            ["dashboard/app/src/components/features/FeatureList.tsx"],
        )

    def test_glob_double_star_anywhere(self):
        """**/path is treated as match-anywhere."""
        assert pv._path_within_scope("**/foo.py", ["src/foo.py"])

    def test_subdir_of_task_is_within_scope(self):
        """Gate looking at a deeper subdir than task is allowed (rare)."""
        assert pv._path_within_scope(
            "dashboard/app/src/components/features/sub/",
            ["dashboard/app/src/components/features/"],
        )
