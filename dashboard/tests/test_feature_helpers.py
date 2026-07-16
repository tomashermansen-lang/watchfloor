"""Tests for server/feature_helpers.py — project-root canonicalization
and worktree-vs-main deduplication in /api/features.

Background: when a feature has both a tracked
docs/INPROGRESS_Feature_<name>/ directory in the main repo (typically
just SOURCE.md as backlog anchor) and an active git worktree (where the
real artifacts live), discovery used to produce two separate rows in
the Features tab — one per project_root. The fix canonicalises any
worktree path to its main repo path so docs- and sessions-discovery
produce identical keys, then prefers the artifact-richer entry on
collision.

Uses unittest (stdlib) — no pytest dependency required.
"""

import datetime as _dt
import json
import os
import shutil
import sys
import tempfile
import time
import typing
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import dashboard.server.feature_helpers as fh
from dashboard.server import plan_helpers

_discover_from_docs = fh._discover_from_docs
_guess_project_root = fh._guess_project_root


def _canonical_project_root(path):
    return fh._canonical_project_root(path)


class TmpDirMixin:
    def setUp(self):
        self._tmp_dir = tempfile.mkdtemp(prefix="feature-helpers-test-")
        self.tmp_path = Path(self._tmp_dir)

    def tearDown(self):
        shutil.rmtree(self._tmp_dir, ignore_errors=True)


def _make_main_repo(parent: Path, name: str) -> Path:
    """Create a directory that looks like a main git worktree (.git/ as dir)."""
    repo = parent / name
    (repo / ".git").mkdir(parents=True)
    return repo


def _make_worktree(parent: Path, name: str, main: Path) -> Path:
    """Create a directory that looks like a secondary worktree (.git as file)."""
    wt = parent / name
    wt.mkdir()
    (wt / ".git").write_text(
        f"gitdir: {main}/.git/worktrees/{name}\n",
        encoding="utf-8",
    )
    return wt


def _seed_inprogress(root: Path, name: str, files: list[str]) -> Path:
    d = root / "docs" / f"INPROGRESS_Feature_{name}"
    d.mkdir(parents=True)
    for f in files:
        (d / f).write_text(f"# {f}\n", encoding="utf-8")
    return d


def _seed_pending(root: Path, name: str, files: list[str]) -> Path:
    d = root / "docs" / f"PENDING_Feature_{name}"
    d.mkdir(parents=True)
    for f in files:
        (d / f).write_text(f"# {f}\n", encoding="utf-8")
    return d


def _seed_done(
    root: Path,
    name: str,
    files: list[str],
    mtime: float | None = None,
) -> Path:
    d = root / "docs" / f"DONE_Feature_{name}"
    d.mkdir(parents=True)
    for f in files:
        (d / f).write_text(f"# {f}\n", encoding="utf-8")
    if mtime is not None:
        os.utime(d, (mtime, mtime))
    return d


def _reset_cache():
    """Force discover_features to bypass its 3s TTL on the next call."""
    fh._cache["data"] = []
    fh._cache["ts"] = 0


def _seed_plan(
    root: Path,
    plan_dir_name: str,
    task_ids: list[str],
    lifecycle: str = "inprogress",
    plan_type: str = "plan",
) -> Path:
    """Write a minimal execution-plan.yaml under root/docs/.

    Builds <lifecycle.upper()>_<Plan|Feature>_<plan_dir_name>/ and writes
    a body sufficient for plan_helpers.find_plans + find_task. Returns
    the directory path so callers can assert plan_dir.
    """
    type_seg = "Plan" if plan_type == "plan" else "Feature"
    dir_name = f"{lifecycle.upper()}_{type_seg}_{plan_dir_name}"
    d = root / "docs" / dir_name
    d.mkdir(parents=True)
    tasks_yaml = "\n".join(
        f"      - id: {tid}\n        name: {tid}\n        status: pending\n        depends: []"
        for tid in task_ids
    )
    body = (
        f'schema_version: "1.4.0"\n'
        f"name: {plan_dir_name}\n"
        f"phases:\n"
        f"  - id: phase-1\n"
        f"    name: Phase 1\n"
        f"    tasks:\n"
        f"{tasks_yaml}\n"
    )
    (d / "execution-plan.yaml").write_text(body, encoding="utf-8")
    return d


# ─── _canonical_project_root ────────────────────────────────────────


class TestCanonicalProjectRoot(TmpDirMixin, unittest.TestCase):
    def test_main_repo_returns_self(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        self.assertEqual(_canonical_project_root(str(main)), str(main))

    def test_worktree_returns_main(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        wt = _make_worktree(self.tmp_path, "dotfiles-foo", main)
        self.assertEqual(_canonical_project_root(str(wt)), str(main))

    def test_non_git_returns_self(self):
        plain = self.tmp_path / "sonarqube"
        plain.mkdir()
        self.assertEqual(_canonical_project_root(str(plain)), str(plain))

    def test_malformed_git_file_returns_self(self):
        bad = self.tmp_path / "broken"
        bad.mkdir()
        (bad / ".git").write_text("not a real gitdir line\n")
        self.assertEqual(_canonical_project_root(str(bad)), str(bad))


# ─── _guess_project_root ────────────────────────────────────────────


class TestGuessProjectRoot(TmpDirMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self._original_env = os.environ.get("PROJECTS_ROOT")
        os.environ["PROJECTS_ROOT"] = str(self.tmp_path)

    def tearDown(self):
        if self._original_env is None:
            os.environ.pop("PROJECTS_ROOT", None)
        else:
            os.environ["PROJECTS_ROOT"] = self._original_env
        super().tearDown()

    def test_cwd_in_main_repo(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        cwd = str(main / "src" / "deep" / "nested")
        self.assertEqual(_guess_project_root(cwd), str(main))

    def test_cwd_in_worktree_canonicalises_to_main(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        wt = _make_worktree(self.tmp_path, "dotfiles-plan-decomposition-rules", main)
        cwd = str(wt / "docs" / "INPROGRESS_Feature_x")
        self.assertEqual(_guess_project_root(cwd), str(main))

    def test_cwd_outside_projects_root(self):
        cwd = "/var/log/something"
        self.assertEqual(_guess_project_root(cwd), cwd)


# ─── _discover_from_docs ────────────────────────────────────────────


class TestDiscoverFromDocs(TmpDirMixin, unittest.TestCase):
    """End-to-end: same feature in main + worktree → 1 row, worktree artifacts."""

    def test_main_only_yields_one_row(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        _seed_inprogress(main, "feat-a", ["SOURCE.md"])

        result = _discover_from_docs([str(main)])

        self.assertEqual(len(result), 1)
        key = next(iter(result))
        self.assertTrue(key.endswith(":feat-a"))
        self.assertEqual(result[key]["project_root"], str(main))

    def test_main_and_worktree_dedup_to_one_row_under_main(self):
        """Regression: main has SOURCE.md anchor, worktree has full artifacts.

        Both must collapse into a single row keyed under the main repo path,
        and the row must keep the artifact-richer worktree variant.
        """
        main = _make_main_repo(self.tmp_path, "dotfiles")
        wt = _make_worktree(
            self.tmp_path,
            "dotfiles-plan-decomposition-rules",
            main,
        )
        # Main has only the backlog anchor
        _seed_inprogress(main, "plan-decomposition-rules", ["SOURCE.md"])
        # Worktree has the full artifact set
        _seed_inprogress(
            wt,
            "plan-decomposition-rules",
            ["SOURCE.md", "REQUIREMENTS.md", "PLAN.md", "REVIEW.md", "TESTPLAN.md"],
        )

        result = _discover_from_docs([str(main), str(wt)])

        self.assertEqual(len(result), 1, f"expected single deduped row, got: {list(result.keys())}")
        key = next(iter(result))
        self.assertTrue(
            key.startswith(str(main) + ":"),
            f"expected key under main repo, got {key}",
        )
        feat = result[key]
        self.assertEqual(feat["project_root"], str(main))
        artifact_names = {a["name"] for a in feat["artifacts"]}
        self.assertIn("REQUIREMENTS.md", artifact_names)
        self.assertIn("PLAN.md", artifact_names)


class ApplyAutopilotPhaseProgress(unittest.TestCase):
    """Regression: when a feature is also an autopilot session, its
    `phase_index` must come from the live autopilot phases (count of
    completed phases) — NOT from the file-based detect_flow_phase
    artifact scan, which lags 1+ phases behind.

    Symptom on the watchfloor: FeatureCard progress bar showed ~30%
    while the SessionPanel sidebar correctly rendered the feature on
    the COMMIT phase (~87%). Root cause: _mark_autopilot_features
    only stamped is_autopilot=True without overriding phase_index.
    """

    def _feat(self, **overrides):
        base = fh.FeatureDict(
            name="some-task",
            project="dotfiles",
            project_root="/tmp/x",
            phase="ba",
            phase_index=0,
            total_phases=8,
            pipeline_type="full",
            artifacts=[],
            sessions=[],
            status="active",
            stuck_info=None,
            last_activity=None,
            is_autopilot=False,
        )
        base.update(overrides)
        return base

    def test_completed_phase_count_overrides_file_based_index(self):
        feat = self._feat(phase_index=2)  # file-based detection lagging
        ap = {
            "task": "some-task",
            "phases": [
                {"name": "BA", "status": "completed"},
                {"name": "Plan", "status": "completed"},
                {"name": "Review", "status": "completed"},
                {"name": "Implement", "status": "completed"},
                {"name": "Static-analysis", "status": "completed"},
                {"name": "QA", "status": "completed"},
                {"name": "Static-analysis", "status": "completed"},
                {"name": "Commit", "status": "running"},
            ],
        }
        fh._apply_autopilot_phase_progress(feat, ap)
        self.assertTrue(feat["is_autopilot"])
        self.assertEqual(feat["phase_index"], 7)

    def test_no_phases_leaves_phase_index_untouched(self):
        feat = self._feat(phase_index=2)
        ap = {"task": "some-task", "phases": []}
        fh._apply_autopilot_phase_progress(feat, ap)
        self.assertTrue(feat["is_autopilot"])
        self.assertEqual(feat["phase_index"], 2)

    def test_only_completed_phases_count_not_running(self):
        feat = self._feat(phase_index=0)
        ap = {
            "task": "some-task",
            "phases": [
                {"name": "BA", "status": "completed"},
                {"name": "Plan", "status": "running"},
            ],
        }
        fh._apply_autopilot_phase_progress(feat, ap)
        self.assertEqual(feat["phase_index"], 1)

    def test_failed_phase_does_not_count_as_completed(self):
        feat = self._feat(phase_index=0)
        ap = {
            "task": "some-task",
            "phases": [
                {"name": "BA", "status": "completed"},
                {"name": "Plan", "status": "failed"},
            ],
        }
        fh._apply_autopilot_phase_progress(feat, ap)
        self.assertEqual(feat["phase_index"], 1)

    def test_capped_at_total_phases(self):
        feat = self._feat(phase_index=0, total_phases=8)
        ap = {
            "task": "some-task",
            "phases": [{"name": f"P{i}", "status": "completed"} for i in range(20)],
        }
        fh._apply_autopilot_phase_progress(feat, ap)
        self.assertEqual(feat["phase_index"], 8)


# ─── _match_lifecycle_prefix (C5) ───────────────────────────────────


class TestMatchLifecyclePrefix(unittest.TestCase):
    def test_match_lifecycle_prefix_returns_inprogress(self):
        self.assertEqual(
            fh._match_lifecycle_prefix("INPROGRESS_Feature_dark-mode"),
            ("INPROGRESS_Feature_", "inprogress"),
        )

    def test_match_lifecycle_prefix_returns_done(self):
        self.assertEqual(
            fh._match_lifecycle_prefix("DONE_Feature_old-feat"),
            ("DONE_Feature_", "done"),
        )

    def test_match_lifecycle_prefix_returns_pending(self):
        self.assertEqual(
            fh._match_lifecycle_prefix("PENDING_Feature_auth-rewrite"),
            ("PENDING_Feature_", "pending"),
        )

    def test_match_lifecycle_prefix_returns_none_for_unknown(self):
        self.assertIsNone(fh._match_lifecycle_prefix("BACKLOG.md"))
        self.assertIsNone(fh._match_lifecycle_prefix("random_dir"))


# ─── _done_at_iso (C3) ──────────────────────────────────────────────


class TestDoneAtIso(TmpDirMixin, unittest.TestCase):
    def _make_entry(self, mtime: float | None = None) -> Path:
        d = self.tmp_path / "DONE_Feature_x"
        d.mkdir()
        if mtime is not None:
            os.utime(d, (mtime, mtime))
        return d

    def test_done_at_iso_returns_iso_string_for_known_mtime(self):
        # 2024-05-01T00:00:00 UTC = 1714521600
        entry = self._make_entry(mtime=1714521600.0)
        self.assertEqual(
            fh._done_at_iso(entry),
            "2024-05-01T00:00:00+00:00",
        )

    def test_done_at_iso_falls_back_to_none_on_oserror(self):
        entry = self._make_entry()
        with mock.patch.object(Path, "stat", side_effect=OSError("denied")):
            self.assertIsNone(fh._done_at_iso(entry))

    def test_done_at_iso_round_trips_via_fromisoformat(self):
        entry = self._make_entry(mtime=1714723200.123456)
        result = fh._done_at_iso(entry)
        self.assertIsNotNone(result)
        # Round-trip parse.
        parsed = _dt.datetime.fromisoformat(result)
        self.assertEqual(parsed.tzinfo, _dt.UTC)

    def test_done_at_iso_handles_future_mtime(self):
        entry = self._make_entry(mtime=time.time() + 86400)
        result = fh._done_at_iso(entry)
        self.assertIsNotNone(result)
        # Just verify it parses; no clamping is performed (RSK-D).
        _dt.datetime.fromisoformat(result)


# ─── _build_docs_feature (C6) ───────────────────────────────────────


class TestBuildDocsFeatureBranches(TmpDirMixin, unittest.TestCase):
    def test_build_docs_feature_done_sets_phase_and_status(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        entry = _seed_done(
            main,
            "old-feat",
            ["REQUIREMENTS.md"],
            mtime=1714521600.0,
        )
        feat = fh._build_docs_feature(str(main), entry, "old-feat", "done")
        self.assertEqual(feat["lifecycle"], "done")
        self.assertEqual(feat["phase"], "done")
        self.assertEqual(feat["status"], "done")
        self.assertEqual(feat["total_phases"], len(fh.FLOW_PHASES_FULL))
        self.assertEqual(feat["phase_index"], feat["total_phases"])
        self.assertEqual(feat["done_at"], "2024-05-01T00:00:00+00:00")

    def test_build_docs_feature_pending_sets_phase_started(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        entry = _seed_pending(main, "auth-rewrite", ["REQUIREMENTS.md"])
        feat = fh._build_docs_feature(
            str(main),
            entry,
            "auth-rewrite",
            "pending",
        )
        self.assertEqual(feat["lifecycle"], "pending")
        self.assertEqual(feat["phase"], "started")
        self.assertEqual(feat["phase_index"], 0)
        self.assertEqual(feat["total_phases"], len(fh.FLOW_PHASES_FULL))
        self.assertEqual(feat["status"], "paused")
        self.assertIsNone(feat["done_at"])

    def test_build_docs_feature_inprogress_uses_detect_flow(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        entry = _seed_inprogress(
            main,
            "dark-mode",
            ["REQUIREMENTS.md", "PLAN.md", "TESTPLAN.md"],
        )
        feat = fh._build_docs_feature(
            str(main),
            entry,
            "dark-mode",
            "inprogress",
        )
        self.assertEqual(feat["lifecycle"], "inprogress")
        self.assertIsNone(feat["done_at"])
        self.assertEqual(feat["status"], "paused")
        # detect_flow_phase result varies, but the field is populated.
        self.assertIn("phase", feat)
        self.assertIn("phase_index", feat)


# ─── _scan_docs_dir lifecycle dispatch (C4) ─────────────────────────


class TestScanDocsDirLifecycles(TmpDirMixin, unittest.TestCase):
    def test_pending_dir_yields_pending_lifecycle(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        _seed_pending(main, "auth-rewrite", ["REQUIREMENTS.md"])

        result = _discover_from_docs([str(main)])

        self.assertEqual(len(result), 1)
        feat = next(iter(result.values()))
        self.assertEqual(feat["name"], "auth-rewrite")
        self.assertEqual(feat["lifecycle"], "pending")
        self.assertEqual(feat["status"], "paused")
        self.assertIsNone(feat["done_at"])
        self.assertIn("REQUIREMENTS.md", {a["name"] for a in feat["artifacts"]})

    def test_done_dir_yields_done_lifecycle_with_done_at(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        _seed_done(
            main,
            "old-feature",
            ["REQUIREMENTS.md"],
            mtime=1714521600.0,
        )

        result = _discover_from_docs([str(main)])

        self.assertEqual(len(result), 1)
        feat = next(iter(result.values()))
        self.assertEqual(feat["name"], "old-feature")
        self.assertEqual(feat["lifecycle"], "done")
        self.assertEqual(feat["status"], "done")
        self.assertEqual(feat["done_at"], "2024-05-01T00:00:00+00:00")

    def test_inprogress_dir_marked_with_lifecycle_inprogress(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        _seed_inprogress(main, "dark-mode", ["SOURCE.md"])

        result = _discover_from_docs([str(main)])

        self.assertEqual(len(result), 1)
        feat = next(iter(result.values()))
        self.assertEqual(feat["name"], "dark-mode")
        self.assertEqual(feat["lifecycle"], "inprogress")
        self.assertIsNone(feat["done_at"])
        # Existing INPROGRESS fields preserved.
        self.assertEqual(feat["project_root"], str(main))
        self.assertEqual(feat["status"], "paused")
        self.assertEqual(feat["sessions"], [])
        self.assertIsNone(feat["stuck_info"])
        self.assertFalse(feat["is_autopilot"])

    def test_done_at_is_none_for_non_done_lifecycles(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        _seed_pending(main, "p1", ["REQUIREMENTS.md"])
        _seed_inprogress(main, "i1", ["REQUIREMENTS.md"])

        result = _discover_from_docs([str(main)])

        for feat in result.values():
            self.assertIn("done_at", feat)
            self.assertIsNone(feat["done_at"])

    def test_artifact_allowlist_applied_to_pending(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        _seed_pending(
            main,
            "p1",
            ["REQUIREMENTS.md", "PLAN.md", "SCRATCH.md"],
        )

        result = _discover_from_docs([str(main)])
        feat = next(iter(result.values()))
        names = {a["name"] for a in feat["artifacts"]}
        self.assertEqual(names, {"REQUIREMENTS.md", "PLAN.md"})

    def test_artifact_allowlist_applied_to_done(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        _seed_done(
            main,
            "d1",
            ["REQUIREMENTS.md", "PLAN.md", "SCRATCH.md"],
        )

        result = _discover_from_docs([str(main)])
        feat = next(iter(result.values()))
        names = {a["name"] for a in feat["artifacts"]}
        self.assertEqual(names, {"REQUIREMENTS.md", "PLAN.md"})

    def test_pending_with_no_artifacts(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        _seed_pending(main, "empty", [])

        result = _discover_from_docs([str(main)])
        self.assertEqual(len(result), 1)
        feat = next(iter(result.values()))
        self.assertEqual(feat["lifecycle"], "pending")
        self.assertEqual(feat["status"], "paused")
        self.assertEqual(feat["artifacts"], [])

    def test_empty_feature_name_skipped_for_pending_and_done(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        # Directory whose name is exactly the prefix.
        (main / "docs" / "PENDING_Feature_").mkdir(parents=True)
        (main / "docs" / "DONE_Feature_").mkdir()
        (main / "docs" / "INPROGRESS_Feature_").mkdir()

        result = _discover_from_docs([str(main)])
        self.assertEqual(result, {})

    def test_no_docs_dir_skipped_silently(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        # Note: no docs/ directory created at all.
        features: dict = {}
        # Should not raise.
        fh._scan_docs_dir(str(main), features)
        self.assertEqual(features, {})


class TestPermissionDeniedOnDocsDir(TmpDirMixin, unittest.TestCase):
    def test_permission_denied_on_docs_dir_fails_silently(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        (main / "docs").mkdir()
        features: dict = {}
        with mock.patch.object(
            Path,
            "iterdir",
            side_effect=PermissionError("denied"),
        ):
            # Should not raise.
            fh._scan_docs_dir(str(main), features)
        self.assertEqual(features, {})


class TestLifecycleCollisions(TmpDirMixin, unittest.TestCase):
    def test_collision_inprogress_wins_over_done(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        _seed_inprogress(main, "foo", ["REQUIREMENTS.md"])
        _seed_done(main, "foo", ["SOURCE.md"])

        result = _discover_from_docs([str(main)])
        self.assertEqual(len(result), 1)
        feat = next(iter(result.values()))
        self.assertEqual(feat["name"], "foo")
        self.assertEqual(feat["lifecycle"], "inprogress")
        self.assertIsNone(feat["done_at"])

    def test_collision_done_wins_over_pending(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        _seed_done(main, "bar", ["SOURCE.md"], mtime=1714521600.0)
        _seed_pending(main, "bar", ["REQUIREMENTS.md"])

        result = _discover_from_docs([str(main)])
        self.assertEqual(len(result), 1)
        feat = next(iter(result.values()))
        self.assertEqual(feat["lifecycle"], "done")

    def test_three_way_collision_picks_inprogress(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        _seed_pending(main, "trip", ["REQUIREMENTS.md"])
        _seed_inprogress(main, "trip", ["SOURCE.md"])
        _seed_done(main, "trip", ["PLAN.md"])

        result = _discover_from_docs([str(main)])
        self.assertEqual(len(result), 1)
        feat = next(iter(result.values()))
        self.assertEqual(feat["lifecycle"], "inprogress")
        self.assertIsNone(feat["done_at"])

    def test_equal_precedence_falls_back_to_artifact_richer(self):
        # Regression: main + worktree both INPROGRESS — artifact-richer wins.
        main = _make_main_repo(self.tmp_path, "dotfiles")
        wt = _make_worktree(self.tmp_path, "dotfiles-x", main)
        _seed_inprogress(main, "x", ["SOURCE.md"])
        _seed_inprogress(
            wt,
            "x",
            ["SOURCE.md", "REQUIREMENTS.md", "PLAN.md", "REVIEW.md", "TESTPLAN.md"],
        )

        result = _discover_from_docs([str(main), str(wt)])
        self.assertEqual(len(result), 1)
        feat = next(iter(result.values()))
        artifact_names = {a["name"] for a in feat["artifacts"]}
        self.assertIn("REQUIREMENTS.md", artifact_names)
        self.assertIn("PLAN.md", artifact_names)


# ─── _derive_feature_status (C7) ────────────────────────────────────


class TestDeriveFeatureStatusEarlyReturn(unittest.TestCase):
    def _feat(self, **overrides):
        base = fh.FeatureDict(
            name="x",
            project="p",
            project_root="/tmp/x",
            phase="started",
            phase_index=0,
            total_phases=8,
            pipeline_type="light",
            artifacts=[],
            sessions=[],
            status="paused",
            stuck_info=None,
            last_activity=None,
            is_autopilot=False,
            lifecycle="inprogress",
            done_at=None,
        )
        base.update(overrides)
        return base

    def test_done_lifecycle_returns_done_status(self):
        feat = self._feat(lifecycle="done", sessions=[])
        self.assertEqual(fh._derive_feature_status(feat), "done")

    def test_inprogress_lifecycle_falls_through(self):
        # Sessions with a working status should yield "active".
        feat = self._feat(
            lifecycle="inprogress",
            sessions=[{"sid": "s1", "status": "working"}],
        )
        self.assertEqual(fh._derive_feature_status(feat), "active")

    def test_pending_lifecycle_returns_paused_status(self):
        feat = self._feat(lifecycle="pending", sessions=[])
        self.assertEqual(fh._derive_feature_status(feat), "paused")


# ─── _merge_features lifecycle (C8) ─────────────────────────────────


class TestSessionMergeLifecycle(TmpDirMixin, unittest.TestCase):
    def _session_feat(self, name: str, project_root: str) -> dict:
        return {
            "name": name,
            "project": Path(project_root).name,
            "project_root": project_root,
            "sessions": {
                "s1": {"sid": "s1", "status": "working", "last_ts": "2026-05-04T00:00:00Z"}
            },
            "last_activity": "2026-05-04T00:00:00Z",
            "events": [],
        }

    def test_session_only_feature_lifecycle_inprogress(self):
        # Project root must exist on disk for session-only features.
        main = _make_main_repo(self.tmp_path, "dotfiles")
        sessions = {
            f"{main}:foo": self._session_feat("foo", str(main)),
        }
        result = fh._merge_features({}, sessions)
        self.assertEqual(len(result), 1)
        feat = result[0]
        self.assertEqual(feat["lifecycle"], "inprogress")
        self.assertIsNone(feat["done_at"])

    def test_session_merges_into_done_docs_row(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        entry = _seed_done(main, "foo", ["REQUIREMENTS.md"], mtime=1714521600.0)
        docs_feat = fh._build_docs_feature(str(main), entry, "foo", "done")
        docs = {f"{main}:foo": docs_feat}
        sessions = {f"{main}:foo": self._session_feat("foo", str(main))}
        result = fh._merge_features(docs, sessions)
        self.assertEqual(len(result), 1)
        feat = result[0]
        self.assertEqual(feat["lifecycle"], "done")
        self.assertEqual(feat["done_at"], "2024-05-01T00:00:00+00:00")
        self.assertEqual(feat["last_activity"], "2026-05-04T00:00:00Z")

    def test_session_merges_into_inprogress_docs_row(self):
        main = _make_main_repo(self.tmp_path, "dotfiles")
        entry = _seed_inprogress(main, "foo", ["REQUIREMENTS.md"])
        docs_feat = fh._build_docs_feature(
            str(main),
            entry,
            "foo",
            "inprogress",
        )
        docs = {f"{main}:foo": docs_feat}
        sessions = {f"{main}:foo": self._session_feat("foo", str(main))}
        result = fh._merge_features(docs, sessions)
        feat = result[0]
        self.assertEqual(feat["lifecycle"], "inprogress")
        self.assertIsNone(feat["done_at"])


# ─── End-to-end: discover_features + cache (REQ-6, REQ-8) ───────────


class TestDiscoverFeaturesEndToEnd(TmpDirMixin, unittest.TestCase):
    def setUp(self):
        super().setUp()
        self.main = _make_main_repo(self.tmp_path, "dotfiles")
        # Patch project-root discovery to return only our isolated tmpdir,
        # and force _discover_from_sessions to a no-op via empty DATA_DIR.
        self._roots_patch = mock.patch.object(
            fh,
            "get_project_roots",
            return_value=[str(self.main)],
        )
        self._roots_patch.start()
        self._original_data_dir = os.environ.get("DASHBOARD_DATA_DIR")
        data_dir = self.tmp_path / "_data"
        data_dir.mkdir()
        os.environ["DASHBOARD_DATA_DIR"] = str(data_dir)
        _reset_cache()

    def tearDown(self):
        self._roots_patch.stop()
        if self._original_data_dir is None:
            os.environ.pop("DASHBOARD_DATA_DIR", None)
        else:
            os.environ["DASHBOARD_DATA_DIR"] = self._original_data_dir
        _reset_cache()
        super().tearDown()

    def test_api_features_response_includes_lifecycle_and_done_at(self):
        _seed_pending(self.main, "p1", ["REQUIREMENTS.md"])
        _seed_inprogress(self.main, "i1", ["REQUIREMENTS.md"])
        _seed_done(self.main, "d1", ["REQUIREMENTS.md"], mtime=1714521600.0)

        result = fh.discover_features()

        names = {f["name"] for f in result}
        self.assertEqual(names, {"p1", "i1", "d1"})
        for feat in result:
            self.assertIn("lifecycle", feat)
            self.assertIn(feat["lifecycle"], {"pending", "inprogress", "done"})
            self.assertIn("done_at", feat)
            self.assertTrue(feat["done_at"] is None or isinstance(feat["done_at"], str))
        by_name = {f["name"]: f for f in result}
        self.assertEqual(by_name["d1"]["done_at"], "2024-05-01T00:00:00+00:00")
        self.assertIsNone(by_name["i1"]["done_at"])
        self.assertIsNone(by_name["p1"]["done_at"])

    def test_cache_ttl_unchanged(self):
        _seed_pending(self.main, "p1", ["REQUIREMENTS.md"])

        first = fh.discover_features()
        self.assertEqual(len(first), 1)

        # Add a new fixture — cached call must NOT see it.
        _seed_pending(self.main, "p2", ["REQUIREMENTS.md"])
        second = fh.discover_features()
        self.assertEqual([f["name"] for f in second], [f["name"] for f in first])

        # Reset cache and verify the new fixture appears.
        _reset_cache()
        third = fh.discover_features()
        names = {f["name"] for f in third}
        self.assertEqual(names, {"p1", "p2"})


# ─── Plan-link enrichment (REQ-1..REQ-12, EC-1..EC-12) ──────────────


class TestPlanLinkTypedDict(unittest.TestCase):
    """REQ-9 — TypedDict additions are non-breaking."""

    def test_typeddict_total_false_preserved_with_new_fields(self):
        hints = typing.get_type_hints(fh.FeatureDict)
        self.assertIn("plan_dir", hints)
        self.assertIs(hints["plan_dir"], str)
        self.assertIn("plan_task_id", hints)
        self.assertIs(hints["plan_task_id"], str)
        # User-request 2026-05-08 - FeatureCard header pairs feature.name
        # (primary) with plan_task_name (secondary) when the linked task's
        # display name differs from the feature folder slug.
        self.assertIn("plan_task_name", hints)
        self.assertIs(hints["plan_task_name"], str)
        self.assertFalse(fh.FeatureDict.__total__)


class _PlanLinkTestBase(TmpDirMixin, unittest.TestCase):
    """Common setUp: tmp main repo, patched roots and DASHBOARD_DATA_DIR.

    Subclasses seed plans / features per scenario and call
    fh.discover_features() under _reset_cache().
    """

    def setUp(self):
        super().setUp()
        self.main = _make_main_repo(self.tmp_path, "repo")
        # Two import-paths reach the same source file — the test module
        # imports `server.feature_helpers` (sys.path-injected dashboard/
        # parent), while the FastAPI route at dashboard/server/routes/api.py
        # imports `dashboard.server.feature_helpers`. Python treats those as
        # distinct modules with distinct globals, so a patch on `fh` alone
        # leaves the route's `get_project_roots` lookup untouched and the
        # /api/features integration test below still scans the real disk.
        # Patch both module instances and clear both caches. (Pre-fastapi-
        # cutover the legacy stdlib serve.py routed via `server.*` so a
        # single patch sufficed.)
        import dashboard.server.feature_helpers as dash_fh
        import dashboard.server.plan_helpers as dash_plan_helpers
        self._dash_fh = dash_fh
        self._dash_plan_helpers = dash_plan_helpers
        self._roots_patch = mock.patch.object(
            fh,
            "get_project_roots",
            return_value=[str(self.main)],
        )
        self._roots_patch_dash = mock.patch.object(
            dash_fh,
            "get_project_roots",
            return_value=[str(self.main)],
        )
        self._roots_patch.start()
        self._roots_patch_dash.start()
        self._original_data_dir = os.environ.get("DASHBOARD_DATA_DIR")
        data_dir = self.tmp_path / "_data"
        data_dir.mkdir()
        os.environ["DASHBOARD_DATA_DIR"] = str(data_dir)
        plan_helpers._LOAD_CACHE.clear()
        dash_plan_helpers._LOAD_CACHE.clear()
        dash_fh._cache["data"] = []
        dash_fh._cache["ts"] = 0
        _reset_cache()

    def tearDown(self):
        self._roots_patch_dash.stop()
        self._roots_patch.stop()
        if self._original_data_dir is None:
            os.environ.pop("DASHBOARD_DATA_DIR", None)
        else:
            os.environ["DASHBOARD_DATA_DIR"] = self._original_data_dir
        plan_helpers._LOAD_CACHE.clear()
        self._dash_plan_helpers._LOAD_CACHE.clear()
        self._dash_fh._cache["data"] = []
        self._dash_fh._cache["ts"] = 0
        _reset_cache()
        super().tearDown()


class TestPlanLinkSingleMatch(_PlanLinkTestBase):
    """REQ-1, AS-1 — match in a single plan populates both fields."""

    def test_match_in_single_plan_sets_plan_dir_and_plan_task_id(self):
        _seed_inprogress(self.main, "dark-mode", ["REQUIREMENTS.md"])
        plan_dir = _seed_plan(self.main, "watchfloor", ["dark-mode"])

        features = fh.discover_features()

        feat = next(f for f in features if f["name"] == "dark-mode")
        self.assertEqual(feat["plan_dir"], str(plan_dir))
        self.assertEqual(feat["plan_task_id"], "dark-mode")

    def test_match_in_single_plan_also_sets_plan_task_name(self):
        """User-request 2026-05-08 — FeatureCard subtitle needs the long
        human-readable task name. The id is already the feature folder slug;
        the long name lives in task.name on the linked plan task."""
        _seed_inprogress(self.main, "dark-mode", ["REQUIREMENTS.md"])
        # Hand-write the plan so id and name diverge (the _seed_plan helper
        # hardcodes name = id).
        d = self.main / "docs" / "INPROGRESS_Plan_watchfloor"
        d.mkdir(parents=True)
        body = (
            'schema_version: "1.4.0"\n'
            "name: watchfloor\n"
            "phases:\n"
            "  - id: phase-1\n"
            "    name: Phase 1\n"
            "    tasks:\n"
            "      - id: dark-mode\n"
            "        name: Add a dark-mode toggle to the settings panel\n"
            "        status: pending\n"
            "        depends: []\n"
        )
        (d / "execution-plan.yaml").write_text(body, encoding="utf-8")

        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "dark-mode")
        self.assertEqual(
            feat["plan_task_name"],
            "Add a dark-mode toggle to the settings panel",
        )

    def test_no_plan_link_omits_plan_task_name(self):
        """Features without a matching plan task must not surface a stale
        or empty plan_task_name field — keeps the FeatureCard subtitle
        line gated cleanly on presence."""
        _seed_inprogress(self.main, "orphan", ["REQUIREMENTS.md"])
        # No plan seeded, so no plan-link match is possible.
        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "orphan")
        self.assertNotIn("plan_task_name", feat)

    def test_match_surfaces_task_estimate_duration_hours(self):
        """Run Economy / FeatureDetail need the linked task's estimate so
        actual time can be compared against the planner's projection. When
        the plan task carries `estimate.duration_hours`, surface it on the
        feature dict as `plan_task_estimate_hours` (number, hours)."""
        _seed_inprogress(self.main, "dark-mode", ["REQUIREMENTS.md"])
        d = self.main / "docs" / "INPROGRESS_Plan_watchfloor"
        d.mkdir(parents=True)
        body = (
            'schema_version: "1.4.0"\n'
            "name: watchfloor\n"
            "phases:\n"
            "  - id: phase-1\n"
            "    name: Phase 1\n"
            "    tasks:\n"
            "      - id: dark-mode\n"
            "        name: Dark mode\n"
            "        status: pending\n"
            "        depends: []\n"
            "        estimate:\n"
            "          duration_hours: 4\n"
        )
        (d / "execution-plan.yaml").write_text(body, encoding="utf-8")

        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "dark-mode")
        self.assertEqual(feat.get("plan_task_estimate_hours"), 4)

    def test_match_without_duration_hours_omits_estimate_field(self):
        """Tasks with only lines_estimate (no duration_hours) leave the
        new field absent so the frontend can rely on presence."""
        _seed_inprogress(self.main, "dark-mode", ["REQUIREMENTS.md"])
        d = self.main / "docs" / "INPROGRESS_Plan_watchfloor"
        d.mkdir(parents=True)
        body = (
            'schema_version: "1.4.0"\n'
            "name: watchfloor\n"
            "phases:\n"
            "  - id: phase-1\n"
            "    name: Phase 1\n"
            "    tasks:\n"
            "      - id: dark-mode\n"
            "        name: Dark mode\n"
            "        status: pending\n"
            "        depends: []\n"
            "        estimate:\n"
            "          lines_estimate: 100\n"
        )
        (d / "execution-plan.yaml").write_text(body, encoding="utf-8")

        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "dark-mode")
        self.assertNotIn("plan_task_estimate_hours", feat)

    def test_no_plan_link_omits_estimate_field(self):
        """Features without a plan match leave the new field absent."""
        _seed_inprogress(self.main, "orphan", ["REQUIREMENTS.md"])
        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "orphan")
        self.assertNotIn("plan_task_estimate_hours", feat)


class TestPlanLinkMultipleMatches(_PlanLinkTestBase):
    """REQ-2, AS-2, EC-5 — first plan in iteration order wins."""

    def test_multiple_matching_plans_first_alphabetical_wins(self):
        _seed_inprogress(self.main, "foo", ["REQUIREMENTS.md"])
        alpha_dir = _seed_plan(self.main, "alpha", ["foo"], lifecycle="done")
        _seed_plan(self.main, "beta", ["foo"], lifecycle="inprogress")

        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "foo")

        self.assertTrue(feat["plan_dir"].endswith("/DONE_Plan_alpha"))
        self.assertEqual(feat["plan_dir"], str(alpha_dir))
        self.assertEqual(feat["plan_task_id"], "foo")


class TestPlanLinkNoMatch(_PlanLinkTestBase):
    """REQ-3 + EC-1, EC-2, EC-8, EC-9, EC-11 — no match: keys omitted."""

    def test_no_match_omits_plan_dir_and_plan_task_id(self):
        _seed_inprogress(self.main, "lonely", ["REQUIREMENTS.md"])
        _seed_plan(self.main, "p", ["other-task"])

        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "lonely")
        self.assertNotIn("plan_dir", feat)
        self.assertNotIn("plan_task_id", feat)

    def test_no_plans_in_root_omits_link_fields(self):
        _seed_inprogress(self.main, "x", ["REQUIREMENTS.md"])

        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "x")
        self.assertNotIn("plan_dir", feat)
        self.assertNotIn("plan_task_id", feat)

    def test_plan_present_but_no_matching_task_omits_fields(self):
        _seed_inprogress(self.main, "x", ["REQUIREMENTS.md"])
        _seed_plan(self.main, "p", ["unrelated-id"])

        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "x")
        self.assertNotIn("plan_dir", feat)
        self.assertNotIn("plan_task_id", feat)

    def test_no_plan_in_root_matches_omits_fields(self):
        _seed_inprogress(self.main, "x", ["REQUIREMENTS.md"])
        for i in range(1, 5):
            _seed_plan(self.main, f"p{i}", [f"other-{i}"])

        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "x")
        self.assertNotIn("plan_dir", feat)
        self.assertNotIn("plan_task_id", feat)

    def test_empty_project_root_omits_plan_link_fields(self):
        feat: fh.FeatureDict = {"name": "x", "project_root": ""}
        # _canonical_project_root("") canonicalises to str(Path("")) == "."
        # which delegates to find_plans(".") — i.e. the test's cwd. To keep
        # the assertion stable across run locations (the dotfiles repo root
        # has its own docs/ plans), chdir into the clean tmp dir first.
        cwd_before = os.getcwd()
        os.chdir(self.tmp_path)
        try:
            plans_by_root = fh._collect_plans_by_root([feat])
            canonical_empty = fh._canonical_project_root("")
            self.assertEqual(plans_by_root, {canonical_empty: []})
            fh._apply_plan_link([feat], plans_by_root)
        finally:
            os.chdir(cwd_before)
        self.assertNotIn("plan_dir", feat)
        self.assertNotIn("plan_task_id", feat)

    def test_unknown_project_root_omits_plan_link_fields(self):
        sandbox = self.tmp_path / "sandbox-unknown"
        feat: fh.FeatureDict = {
            "name": "ghost",
            "project_root": str(sandbox),
        }
        plans_by_root = fh._collect_plans_by_root([feat])
        self.assertEqual(plans_by_root[str(sandbox)], [])
        fh._apply_plan_link([feat], plans_by_root)
        self.assertNotIn("plan_dir", feat)
        self.assertNotIn("plan_task_id", feat)


class TestPlanLinkExceptionPath(_PlanLinkTestBase):
    """REQ-4, EC-3, EC-4, EC-10 — defensive paths must not propagate."""

    def test_find_plans_exception_does_not_propagate(self):
        # Two main repos: a yields a match, b raises from find_plans.
        root_a = _make_main_repo(self.tmp_path, "ra")
        root_b = _make_main_repo(self.tmp_path, "rb")
        _seed_inprogress(root_a, "foo", ["REQUIREMENTS.md"])
        _seed_plan(root_a, "p", ["foo"])
        _seed_inprogress(root_b, "bar", ["REQUIREMENTS.md"])

        # Override the base-class single-root patch.
        self._roots_patch.stop()
        roots_patch = mock.patch.object(
            fh,
            "get_project_roots",
            return_value=[str(root_a), str(root_b)],
        )
        roots_patch.start()
        self.addCleanup(roots_patch.stop)

        original_find_plans = plan_helpers.find_plans

        def side_effect(path: str) -> list[dict]:
            if path == str(root_b):
                raise OSError("denied")
            return original_find_plans(path)

        with mock.patch.object(
            plan_helpers,
            "find_plans",
            side_effect=side_effect,
        ) as wrapped:
            _reset_cache()
            features = fh.discover_features()

        feat_foo = next(f for f in features if f["name"] == "foo")
        feat_bar = next(f for f in features if f["name"] == "bar")
        self.assertTrue(feat_foo["plan_dir"].endswith("/INPROGRESS_Plan_p"))
        self.assertEqual(feat_foo["plan_task_id"], "foo")
        self.assertNotIn("plan_dir", feat_bar)
        self.assertNotIn("plan_task_id", feat_bar)
        # Exactly one call per canonical root, even with one of them raising.
        self.assertEqual(wrapped.call_count, 2)

    def test_unparseable_plan_does_not_block_other_plans(self):
        _seed_inprogress(self.main, "x", ["REQUIREMENTS.md"])
        _seed_plan(self.main, "good", ["x"])
        bad_dir = self.main / "docs" / "INPROGRESS_Plan_bad"
        bad_dir.mkdir()
        (bad_dir / "execution-plan.yaml").write_text(
            'b": [unbalanced"\n',
            encoding="utf-8",
        )

        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "x")
        self.assertTrue(feat["plan_dir"].endswith("/INPROGRESS_Plan_good"))
        self.assertEqual(feat["plan_task_id"], "x")

    def test_plan_with_idless_tasks_does_not_raise(self):
        _seed_inprogress(self.main, "real-task", ["REQUIREMENTS.md"])
        plan_dir = self.main / "docs" / "INPROGRESS_Plan_p"
        plan_dir.mkdir(parents=True)
        (plan_dir / "execution-plan.yaml").write_text(
            'schema_version: "1.4.0"\n'
            "name: p\n"
            "phases:\n"
            "  - id: phase-1\n"
            "    name: P1\n"
            "    tasks:\n"
            "      - name: nameless\n"
            "        status: pending\n"
            "      - id: real-task\n"
            "        name: real-task\n"
            "        status: pending\n"
            "        depends: []\n",
            encoding="utf-8",
        )

        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "real-task")
        self.assertEqual(feat["plan_task_id"], "real-task")


class TestPlanLinkBatching(TmpDirMixin, unittest.TestCase):
    """REQ-5, REQ-6, AS-5, AS-6 — find_plans is K-bounded by canonical roots."""

    def setUp(self):
        super().setUp()
        self._original_data_dir = os.environ.get("DASHBOARD_DATA_DIR")
        data_dir = self.tmp_path / "_data"
        data_dir.mkdir()
        os.environ["DASHBOARD_DATA_DIR"] = str(data_dir)
        plan_helpers._LOAD_CACHE.clear()
        _reset_cache()

    def tearDown(self):
        if self._original_data_dir is None:
            os.environ.pop("DASHBOARD_DATA_DIR", None)
        else:
            os.environ["DASHBOARD_DATA_DIR"] = self._original_data_dir
        plan_helpers._LOAD_CACHE.clear()
        _reset_cache()
        super().tearDown()

    def test_find_plans_called_at_most_once_per_canonical_root(self):
        root_a = _make_main_repo(self.tmp_path, "a")
        root_b = _make_main_repo(self.tmp_path, "b")
        for i in range(5):
            _seed_inprogress(root_a, f"a{i}", ["REQUIREMENTS.md"])
            _seed_inprogress(root_b, f"b{i}", ["REQUIREMENTS.md"])
        _seed_plan(root_a, "p", [f"a{i}" for i in range(5)])
        _seed_plan(root_b, "p", [f"b{i}" for i in range(5)])

        with (
            mock.patch.object(
                fh,
                "get_project_roots",
                return_value=[str(root_a), str(root_b)],
            ),
            mock.patch.object(
                plan_helpers,
                "find_plans",
                wraps=plan_helpers.find_plans,
            ) as wrapped,
        ):
            _reset_cache()
            fh.discover_features()

        self.assertEqual(wrapped.call_count, 2)

    def test_canonical_root_used_for_plan_lookup_keying(self):
        main = _make_main_repo(self.tmp_path, "repo")
        wt = _make_worktree(self.tmp_path, "repo-feature", main)
        _seed_inprogress(main, "shared", ["REQUIREMENTS.md"])
        _seed_inprogress(wt, "shared", ["REQUIREMENTS.md"])
        _seed_plan(main, "p", ["shared"])

        with (
            mock.patch.object(
                fh,
                "get_project_roots",
                return_value=[str(main), str(wt)],
            ),
            mock.patch.object(
                plan_helpers,
                "find_plans",
                wraps=plan_helpers.find_plans,
            ) as wrapped,
        ):
            _reset_cache()
            features = fh.discover_features()

        self.assertEqual(wrapped.call_count, 1)
        feat = next(f for f in features if f["name"] == "shared")
        self.assertTrue(feat["plan_dir"].endswith("/INPROGRESS_Plan_p"))
        self.assertEqual(feat["plan_task_id"], "shared")


class TestPlanLinkCacheContract(_PlanLinkTestBase):
    """REQ-7, REQ-8, REQ-11, EC-7 — cache invariants."""

    def test_no_duplicate_mtime_cache_in_feature_helpers(self):
        import ast
        import inspect

        source = inspect.getsource(fh)
        tree = ast.parse(source)

        allowed = {
            "_cache",
            "_STATUS_ORDER",
            "_SESSION_STATUS_MAP",
            "LIFECYCLE_PRECEDENCE",
        }
        module_dicts: list[str] = []
        for node in tree.body:
            if not isinstance(node, ast.Assign):
                continue
            target = node.targets[0]
            if not isinstance(target, ast.Name):
                continue
            if isinstance(node.value, ast.Dict):
                module_dicts.append(target.id)
            elif isinstance(node.value, ast.Call):
                func = node.value.func
                if isinstance(func, ast.Name) and func.id == "dict":
                    module_dicts.append(target.id)
        # Also check AnnAssign (e.g. `_cache: dict = {...}`).
        for node in tree.body:
            if not isinstance(node, ast.AnnAssign):
                continue
            if not isinstance(node.target, ast.Name):
                continue
            if isinstance(node.value, ast.Dict):
                module_dicts.append(node.target.id)
        forbidden = set(module_dicts) - allowed
        self.assertEqual(
            forbidden,
            set(),
            f"Unexpected module-level dict(s) in feature_helpers.py: "
            f"{forbidden}. Plan REQ-7 forbids new mtime-style caches; "
            f"if a non-cache dict is genuinely needed, add it to the "
            f"allowed set in this test and reference REQ-7.",
        )
        self.assertNotIn("_LOAD_CACHE", source)

    def test_plan_scan_dict_rebuilt_on_each_cache_miss(self):
        _seed_inprogress(self.main, "x", ["REQUIREMENTS.md"])
        _seed_plan(self.main, "p1", ["x"])

        _reset_cache()
        features1 = fh.discover_features()
        feat1 = next(f for f in features1 if f["name"] == "x")
        self.assertTrue(feat1["plan_dir"].endswith("/INPROGRESS_Plan_p1"))

        old_dir = self.main / "docs" / "INPROGRESS_Plan_p1"
        new_dir = self.main / "docs" / "INPROGRESS_Plan_p2"
        old_dir.rename(new_dir)
        (new_dir / "execution-plan.yaml").write_text(
            'schema_version: "1.4.0"\n'
            "name: p2\n"
            "phases:\n"
            "  - id: phase-1\n"
            "    name: Phase 1\n"
            "    tasks:\n"
            "      - id: x\n"
            "        name: x\n"
            "        status: pending\n"
            "        depends: []\n",
            encoding="utf-8",
        )
        plan_helpers._LOAD_CACHE.clear()
        _reset_cache()

        features2 = fh.discover_features()
        feat2 = next(f for f in features2 if f["name"] == "x")
        self.assertTrue(feat2["plan_dir"].endswith("/INPROGRESS_Plan_p2"))

    def test_cached_features_retain_plan_link_fields(self):
        _seed_inprogress(self.main, "x", ["REQUIREMENTS.md"])
        _seed_plan(self.main, "p", ["x"])

        _reset_cache()
        features1 = fh.discover_features()
        feat1 = next(f for f in features1 if f["name"] == "x")
        self.assertIn("plan_dir", feat1)

        with mock.patch.object(
            plan_helpers,
            "find_plans",
            wraps=plan_helpers.find_plans,
        ) as wrapped:
            features2 = fh.discover_features()

        self.assertEqual(wrapped.call_count, 0)
        feat2 = next(f for f in features2 if f["name"] == "x")
        self.assertEqual(feat2["plan_dir"], feat1["plan_dir"])
        self.assertEqual(feat2["plan_task_id"], feat1["plan_task_id"])


class TestPlanLinkSessionOnly(TmpDirMixin, unittest.TestCase):
    """REQ-12, AS-7 — session-only feature receives plan-link."""

    def setUp(self):
        super().setUp()
        self.main = _make_main_repo(self.tmp_path, "repo")
        self._roots_patch = mock.patch.object(
            fh,
            "get_project_roots",
            return_value=[str(self.main)],
        )
        self._roots_patch.start()
        self.data_dir = self.tmp_path / "_data"
        self.data_dir.mkdir()
        self._env_patch = mock.patch.dict(
            os.environ,
            {
                "DASHBOARD_DATA_DIR": str(self.data_dir),
                "PROJECTS_ROOT": str(self.tmp_path),
            },
        )
        self._env_patch.start()
        # tempfile.mkdtemp on this host can place tmpdirs under /tmp/; the
        # session parser excludes such cwds. Override the filter so the
        # session event survives into discover_features.
        self._exclude_patch = mock.patch.object(
            fh,
            "_EXCLUDE_PATTERNS",
            (".test-tmp", "/test-project"),
        )
        self._exclude_patch.start()
        plan_helpers._LOAD_CACHE.clear()
        _reset_cache()

    def tearDown(self):
        self._roots_patch.stop()
        self._env_patch.stop()
        self._exclude_patch.stop()
        plan_helpers._LOAD_CACHE.clear()
        _reset_cache()
        super().tearDown()

    def test_session_only_feature_with_matching_plan_gets_plan_link(self):
        plan_dir = _seed_plan(self.main, "p", ["y"])
        sessions_path = self.data_dir / "sessions.jsonl"
        event = {
            "branch": "feature/y",
            "cwd": str(self.main / "src" / "deep"),
            "sid": "s1",
            "ts": "2026-05-04T00:00:00Z",
            "event": "PreToolUse",
        }
        sessions_path.write_text(json.dumps(event) + "\n", encoding="utf-8")

        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "y")
        self.assertEqual(feat["lifecycle"], "inprogress")
        self.assertEqual(feat["plan_dir"], str(plan_dir))
        self.assertEqual(feat["plan_task_id"], "y")


class TestPlanLinkNormalisedMatch(_PlanLinkTestBase):
    """EC-6 — normalized match stores the task id, not the feature name."""

    def test_normalized_match_stores_task_id_not_feature_name(self):
        _seed_inprogress(self.main, "dark_mode", ["REQUIREMENTS.md"])
        plan_dir = _seed_plan(self.main, "watchfloor", ["dark-mode"])

        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "dark_mode")
        self.assertEqual(feat["plan_task_id"], "dark-mode")
        self.assertEqual(feat["plan_dir"], str(plan_dir))


class TestPlanLinkFeatureLevelPlan(_PlanLinkTestBase):
    """EC-12 — feature-level execution-plan.yaml participates in lookup."""

    def test_feature_level_plan_with_matching_task_participates_in_lookup(self):
        _seed_inprogress(self.main, "host", ["REQUIREMENTS.md"])
        _seed_inprogress(self.main, "other-feature", ["REQUIREMENTS.md"])
        # Replace host's docs dir with a feature-level execution-plan
        # whose task targets "other-feature".
        host_dir = self.main / "docs" / "INPROGRESS_Feature_host"
        (host_dir / "execution-plan.yaml").write_text(
            'schema_version: "1.4.0"\n'
            "name: host\n"
            "phases:\n"
            "  - id: phase-1\n"
            "    name: Phase 1\n"
            "    tasks:\n"
            "      - id: other-feature\n"
            "        name: other-feature\n"
            "        status: pending\n"
            "        depends: []\n",
            encoding="utf-8",
        )

        features = fh.discover_features()
        feat = next(f for f in features if f["name"] == "other-feature")
        self.assertTrue(feat["plan_dir"].endswith("/INPROGRESS_Feature_host"))
        self.assertEqual(feat["plan_task_id"], "other-feature")


class TestApiFeaturesPlanLink(_PlanLinkTestBase):
    """REQ-10, AS-8, AS-9 — /api/features carries the keys when matched, omits otherwise."""

    def _invoke_api(self) -> list[dict]:
        # Post fastapi-cutover (T0.3): drive the FastAPI router via
        # TestClient instead of importing serve.py's stdlib handler. The
        # JSON payload shape is byte-equivalent to the previous stdlib
        # response (T0.2.c, 22/22 fixtures), so the assertions below
        # remain valid against the new transport.
        from fastapi import FastAPI
        from fastapi.testclient import TestClient

        from dashboard.server.routes.api import router

        app = FastAPI()
        app.include_router(router)
        client = TestClient(app)
        response = client.get("/api/features")
        self.assertEqual(response.status_code, 200)
        payload = response.json()
        self.assertIsInstance(payload, list)
        return payload

    def test_api_features_omits_keys_when_no_match(self):
        _seed_inprogress(self.main, "lonely", ["REQUIREMENTS.md"])

        payload = self._invoke_api()
        roundtrip = json.loads(json.dumps(payload))
        feat = next(o for o in roundtrip if o["name"] == "lonely")
        self.assertNotIn("plan_dir", feat)
        self.assertNotIn("plan_task_id", feat)

    def test_api_features_carries_keys_when_matched(self):
        _seed_inprogress(self.main, "ready", ["REQUIREMENTS.md"])
        plan_dir = _seed_plan(self.main, "watchfloor", ["ready"])

        payload = self._invoke_api()
        roundtrip = json.loads(json.dumps(payload))
        feat = next(o for o in roundtrip if o["name"] == "ready")
        self.assertEqual(feat["plan_dir"], str(plan_dir))
        self.assertEqual(feat["plan_task_id"], "ready")
        self.assertIsInstance(feat["plan_dir"], str)
        self.assertIsInstance(feat["plan_task_id"], str)


if __name__ == "__main__":
    unittest.main()
