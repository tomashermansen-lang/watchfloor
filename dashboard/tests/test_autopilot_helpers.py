"""Tests for server/autopilot_helpers.py — log parsing, discovery, incremental read.

See also: app/src/__tests__/useAutopilotLog.test.ts for frontend hook tests
(covers Strict Mode double-mount, task reset, stale closure guard).

Uses unittest (stdlib) — no pytest dependency required.
"""

import json
import os
import shutil
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from dashboard.server.autopilot_helpers import (
    _KNOWN_ARTIFACTS,
    _determine_overall_status,
    _extract_cost,
    _is_allowed_path,
    _parse_header,
    _resolve_log_path,
    _resolve_stream_path,
    _status_from_log,
    _status_from_stream,
    discover_autopilots,
    list_autopilot_artifacts,
    load_summary,
    parse_log_phases,
    parse_stream_phases,
    read_log_incremental,
    read_stream_incremental,
)

# ─── Fixtures ────────────────────────────────────────────────────────

SAMPLE_HEADER = """\
╔══════════════════════════════════════════╗
║  AUTOPILOT                               ║
╠══════════════════════════════════════════╣
║  Task:     auth-module                   ║
║  Project:  OIH                           ║
║  Branch:   feature/auth-module           ║
║  Mode:     full                          ║
╚══════════════════════════════════════════╝
"""

SAMPLE_LOG = f"""\
{SAMPLE_HEADER}
[10:00:00] Running: /ba flow autopilot auth-module
✓ Requirements written
Phase completed in 120s
Total cost: $0.42

[10:02:00] Running: /plan flow autopilot auth-module
✓ Architecture plan written
Phase completed in 180s

[10:05:00] Running: /team-review flow autopilot auth-module
⚠ 3 findings (1 WARNING)
Phase completed in 240s

[10:09:00] Running: /implement flow autopilot auth-module

AUTOPILOT COMPLETE
Total duration: 540s
"""

# autopilot.sh actual log format (timestamped, no box header)
SAMPLE_AUTOPILOTSH_HEADER = """\
[15:11:14] Autopilot started for task: auth-module
[15:11:14] Worktree: /Users/test/Projekter/OIH-auth-module
[15:11:14] Branch: feature/auth-module
[15:11:14] Full mode: true
[15:11:14] Pipeline: full
"""

SAMPLE_AUTOPILOTSH_LOG = f"""\
{SAMPLE_AUTOPILOTSH_HEADER}[15:11:30] Sending: /ba flow autopilot auth-module
[15:11:30] Waiting for phase completion...
[15:14:30] Phase checkpoint reached
[15:14:30] Auto-approved checkpoint with: plan
[15:14:35] Sending: /plan flow autopilot auth-module
[15:18:00] Phase checkpoint reached
"""


class TmpDirMixin:
    """Mixin that provides a fresh temp directory per test (replaces pytest tmp_path)."""

    def setUp(self):
        self._tmp_dir = tempfile.mkdtemp(prefix="autopilot-test-")
        self.tmp_path = Path(self._tmp_dir)

    def tearDown(self):
        shutil.rmtree(self._tmp_dir, ignore_errors=True)


# ─── parse_log_phases ────────────────────────────────────────────────


class TestParseLogPhases(TmpDirMixin, unittest.TestCase):
    def test_parse_phase_start(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("[10:00:00] Running: /ba flow autopilot task\nWorking...\n")
        phases = parse_log_phases(str(log))
        self.assertEqual(len(phases), 1)
        self.assertEqual(phases[0]["name"], "BA")
        self.assertEqual(phases[0]["status"], "running")

    def test_parse_phase_completion(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("[10:00:00] Running: /ba flow autopilot task\nPhase completed in 42s\n")
        phases = parse_log_phases(str(log))
        self.assertEqual(len(phases), 1)
        self.assertEqual(phases[0]["duration_s"], 42)
        self.assertEqual(phases[0]["status"], "completed")

    def test_parse_success_marker(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text(
            "[10:00:00] Running: /ba flow autopilot task\n✓ Requirements written\nPhase completed in 10s\n"
        )
        phases = parse_log_phases(str(log))
        self.assertEqual(phases[0]["status"], "completed")

    def test_parse_warning_no_status_change(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text(
            "[10:00:00] Running: /review flow autopilot task\n⚠ 3 findings\nPhase completed in 10s\n"
        )
        phases = parse_log_phases(str(log))
        self.assertEqual(phases[0]["status"], "completed")

    def test_parse_autopilot_complete(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text(SAMPLE_LOG)
        phases = parse_log_phases(str(log))
        completed_names = [p["name"] for p in phases if p["status"] == "completed"]
        self.assertIn("BA", completed_names)
        self.assertIn("Plan", completed_names)
        self.assertIn("Team Review", completed_names)

    def test_parse_autopilot_failed(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text(
            "[10:00:00] Running: /ba flow autopilot task\nError occurred\nAUTOPILOT FAILED\n"
        )
        phases = parse_log_phases(str(log))
        self.assertEqual(phases[0]["status"], "failed")

    def test_empty_log(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("")
        phases = parse_log_phases(str(log))
        self.assertEqual(phases, [])

    def test_malformed_log(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("random text\nno phase markers\njust garbage\n")
        phases = parse_log_phases(str(log))
        self.assertEqual(phases, [])

    def test_multiple_phases_ordered(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text(SAMPLE_LOG)
        phases = parse_log_phases(str(log))
        names = [p["name"] for p in phases]
        self.assertEqual(names, ["BA", "Plan", "Team Review", "Implement"])

    def test_phase_cost_extracted(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text(
            "[10:00:00] Running: /ba flow autopilot task\nTotal cost: $0.42\nPhase completed in 10s\n"
        )
        phases = parse_log_phases(str(log))
        self.assertEqual(phases[0]["cost"], 0.42)

    def test_phase_artifact_mapping(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("[10:00:00] Running: /ba flow autopilot task\nPhase completed in 10s\n")
        phases = parse_log_phases(str(log))
        self.assertEqual(phases[0]["artifact"], "REQUIREMENTS.md")

    # ─── autopilot.sh format ─────────────────────────────────────────

    def test_sending_format_phase_start(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("Sending: /ba flow autopilot my-task\n")
        phases = parse_log_phases(str(log))
        self.assertEqual(len(phases), 1)
        self.assertEqual(phases[0]["name"], "BA")
        self.assertEqual(phases[0]["status"], "running")

    def test_checkpoint_format_phase_completion(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("Sending: /ba flow autopilot my-task\nPhase checkpoint reached\n")
        phases = parse_log_phases(str(log))
        self.assertEqual(phases[0]["status"], "completed")

    def test_autopilotsh_multiple_phases(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text(SAMPLE_AUTOPILOTSH_LOG)
        phases = parse_log_phases(str(log))
        names = [p["name"] for p in phases]
        self.assertEqual(names, ["BA", "Plan"])
        self.assertEqual(phases[0]["status"], "completed")
        self.assertEqual(phases[1]["status"], "completed")


# ─── _parse_header ───────────────────────────────────────────────────


class TestParseHeader(unittest.TestCase):
    def test_extract_fields(self):
        lines = SAMPLE_HEADER.splitlines()
        header = _parse_header(lines)
        self.assertEqual(header["task"], "auth-module")
        self.assertEqual(header["project"], "OIH")
        self.assertEqual(header["branch"], "feature/auth-module")

    def test_missing_fields(self):
        header = _parse_header(["no header here", "just text"])
        self.assertIsNone(header["task"])
        self.assertIsNone(header["project"])
        self.assertIsNone(header["branch"])

    def test_autopilotsh_timestamped_header(self):
        lines = SAMPLE_AUTOPILOTSH_HEADER.splitlines()
        header = _parse_header(lines)
        self.assertEqual(header["task"], "auth-module")
        self.assertEqual(header["project"], "OIH")
        self.assertEqual(header["branch"], "feature/auth-module")


# ─── _extract_cost ───────────────────────────────────────────────────


class TestExtractCost(unittest.TestCase):
    def test_dollar_amount(self):
        self.assertEqual(_extract_cost("Total cost: $0.42"), 0.42)

    def test_zero_cost(self):
        self.assertEqual(_extract_cost("Total cost: $0.00"), 0.0)

    def test_no_cost(self):
        self.assertIsNone(_extract_cost("No cost info here"))

    def test_multiple_amounts_first_match(self):
        self.assertEqual(_extract_cost("Cost: $0.42 and $1.23"), 0.42)


# ─── read_log_incremental ───────────────────────────────────────────


class TestReadLogIncremental(TmpDirMixin, unittest.TestCase):
    def test_read_from_zero(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("line1\nline2\n")
        content, offset = read_log_incremental(str(log), 0)
        self.assertIn("line1", content)
        self.assertIn("line2", content)
        self.assertEqual(offset, len(log.read_bytes()))

    def test_read_from_offset(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("line1\nline2\nline3\n")
        first_line_len = len(b"line1\n")
        content, offset = read_log_incremental(str(log), first_line_len)
        self.assertNotIn("line1", content)
        self.assertIn("line2", content)

    def test_path_traversal_blocked(self):
        result = read_log_incremental("/etc/passwd", 0)
        self.assertIsNone(result)

    def test_nonexistent_file(self):
        result = read_log_incremental(str(self.tmp_path / "nonexistent.log"), 0)
        self.assertIsNone(result)

    def test_ansi_codes_stripped(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("\x1b[32mgreen\x1b[0m normal\n")
        content, _ = read_log_incremental(str(log), 0)
        self.assertNotIn("\x1b[", content)
        self.assertIn("green", content)

    def test_tail_bounds_initial_read(self):
        """max_tail_bytes (dashboard-perf 2026-06-02 #5) caps the offset-0 read
        to the trailing window; new_offset still points at EOF."""
        log = self.tmp_path / "autopilot.log"
        log.write_text("\n".join(f"line{i}" for i in range(100)) + "\n")
        size = len(log.read_bytes())
        content, offset = read_log_incremental(str(log), 0, max_tail_bytes=40)
        self.assertEqual(offset, size)
        self.assertNotIn("line0", content)
        self.assertIn("line99", content)

    def test_tail_noop_when_file_smaller_than_cap(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("line1\nline2\n")
        content, offset = read_log_incremental(str(log), 0, max_tail_bytes=10_000)
        self.assertIn("line1", content)
        self.assertEqual(offset, len(log.read_bytes()))


# ─── _resolve_log_path ──────────────────────────────────────────────


class TestResolveLogPath(TmpDirMixin, unittest.TestCase):
    def test_finds_inprogress_log(self):
        feature_dir = self.tmp_path / "docs" / "INPROGRESS_Feature_my-task"
        feature_dir.mkdir(parents=True)
        log = feature_dir / "autopilot.log"
        log.write_text("test log")
        result = _resolve_log_path("my-task", search_roots=[str(self.tmp_path)])
        self.assertIsNotNone(result)
        self.assertTrue(str(result).endswith("autopilot.log"))

    def test_finds_done_log(self):
        feature_dir = self.tmp_path / "docs" / "DONE_Feature_old-task"
        feature_dir.mkdir(parents=True)
        log = feature_dir / "autopilot.log"
        log.write_text("test log")
        result = _resolve_log_path("old-task", search_roots=[str(self.tmp_path)])
        self.assertIsNotNone(result)
        self.assertTrue(str(result).endswith("autopilot.log"))

    def test_returns_none_when_missing(self):
        result = _resolve_log_path("nonexistent-task", search_roots=[str(self.tmp_path)])
        self.assertIsNone(result)


class TestResolveStreamPath(TmpDirMixin, unittest.TestCase):
    def test_finds_inprogress_stream(self):
        feature_dir = self.tmp_path / "docs" / "INPROGRESS_Feature_my-task"
        feature_dir.mkdir(parents=True)
        stream = feature_dir / "autopilot-stream.ndjson"
        stream.write_text('{"type":"phase"}\n')
        result = _resolve_stream_path("my-task", search_roots=[str(self.tmp_path)])
        self.assertIsNotNone(result)
        self.assertTrue(str(result).endswith("autopilot-stream.ndjson"))

    def test_finds_done_stream(self):
        feature_dir = self.tmp_path / "docs" / "DONE_Feature_old-task"
        feature_dir.mkdir(parents=True)
        stream = feature_dir / "autopilot-stream.ndjson"
        stream.write_text('{"type":"phase"}\n')
        result = _resolve_stream_path("old-task", search_roots=[str(self.tmp_path)])
        self.assertIsNotNone(result)
        self.assertTrue(str(result).endswith("autopilot-stream.ndjson"))

    def test_returns_none_when_missing(self):
        result = _resolve_stream_path("nonexistent", search_roots=[str(self.tmp_path)])
        self.assertIsNone(result)


# ─── discover_autopilots ────────────────────────────────────────────


class TestDiscoverAutopilots(TmpDirMixin, unittest.TestCase):
    def _discover_with_roots(self, roots):
        """Call discover_autopilots with patched project roots."""
        import dashboard.server.autopilot_helpers as ah

        original = ah._get_all_project_roots
        ah._get_all_project_roots = lambda: roots
        try:
            # Bypass cache by using _tmux_cmd (forces fresh scan)
            return discover_autopilots(_tmux_cmd=["echo", ""])
        finally:
            ah._get_all_project_roots = original

    def test_no_log_files(self):
        """Empty project root returns no sessions."""
        (self.tmp_path / "docs").mkdir()
        sessions = self._discover_with_roots([str(self.tmp_path)])
        self.assertEqual(sessions, [])

    def test_discovers_running_session(self):
        """Finds a session from an autopilot.log in INPROGRESS_Feature_ dir."""
        feature = self.tmp_path / "docs" / "INPROGRESS_Feature_test-task"
        feature.mkdir(parents=True)
        log = feature / "autopilot.log"
        log.write_text("[10:00:00] Running: /ba flow autopilot test-task\n")
        sessions = self._discover_with_roots([str(self.tmp_path)])
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["task"], "test-task")

    def test_task_name_validation(self):
        """Rejects task names with path traversal characters."""
        feature = self.tmp_path / "docs" / "INPROGRESS_Feature_../../etc"
        try:
            feature.mkdir(parents=True)
            (feature / "autopilot.log").write_text("test")
        except (OSError, ValueError):
            pass  # OS rejects the path — that's fine, the task is invalid
        sessions = self._discover_with_roots([str(self.tmp_path)])
        self.assertEqual(len(sessions), 0)

    def test_discovers_done_feature_with_stream(self):
        """Finds a completed session from DONE_Feature_ with NDJSON stream."""
        feature = self.tmp_path / "docs" / "DONE_Feature_my-done-task"
        feature.mkdir(parents=True)
        stream = feature / "autopilot-stream.ndjson"
        stream.write_text('{"type":"phase","phase":"BA","status":"completed","duration_s":30}\n')
        sessions = self._discover_with_roots([str(self.tmp_path)])
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["task"], "my-done-task")
        self.assertEqual(sessions[0]["status"], "completed")

    def test_discovers_done_feature_with_log(self):
        """Finds a completed session from DONE_Feature_ with text log."""
        feature = self.tmp_path / "docs" / "DONE_Feature_old-task"
        feature.mkdir(parents=True)
        log = feature / "autopilot.log"
        log.write_text(
            "[10:00:00] Running: /ba flow autopilot old-task\nPhase completed in 42s\nAUTOPILOT COMPLETE\n"
        )
        sessions = self._discover_with_roots([str(self.tmp_path)])
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["task"], "old-task")
        self.assertEqual(sessions[0]["status"], "completed")

    def test_done_feature_always_completed_status(self):
        """DONE_Feature_ sessions are always 'completed', never 'running'."""
        feature = self.tmp_path / "docs" / "DONE_Feature_recent-task"
        feature.mkdir(parents=True)
        stream = feature / "autopilot-stream.ndjson"
        # Write a stream file that would be "running" if in INPROGRESS
        stream.write_text('{"type":"phase","phase":"BA","status":"running"}\n')
        sessions = self._discover_with_roots([str(self.tmp_path)])
        self.assertEqual(len(sessions), 1)
        self.assertEqual(sessions[0]["status"], "completed")

    def test_dedupes_identical_streams_across_worktrees(self):
        """When the SAME DONE_Feature_<task>/ exists in multiple project roots
        with byte-identical autopilot-stream.ndjson contents (the typical
        case after `git worktree add` snapshots a project that already had
        shipped features), discover_autopilots must collapse them to ONE
        session — not one per project root.

        Without this dedupe, the dashboard's per-feature cost rollup
        sums the cost N times (once per worktree copy). Real-world impact
        measured 2026-05-25: terminal-websocket-bridge displayed $1012
        instead of its true $126 because 7 active canary worktrees each
        carried an identical DONE_Feature_terminal-websocket-bridge/ dir.
        """
        # Build TWO project roots with identical DONE_Feature_dup/ content
        # to simulate `git worktree add` having cloned an already-DONE feature.
        root_main = self.tmp_path / "proj-main"
        root_worktree = self.tmp_path / "proj-worktree-clone"
        for root in (root_main, root_worktree):
            feat = root / "docs" / "DONE_Feature_dup-task"
            feat.mkdir(parents=True)
            (feat / "autopilot-stream.ndjson").write_text(
                '{"type":"phase","phase":"BA","status":"completed","duration_s":30}\n'
                '{"type":"result","session_id":"sid-X","total_cost_usd":5.00}\n'
            )

        sessions = self._discover_with_roots([str(root_main), str(root_worktree)])

        # Single session despite two copies of the stream.
        self.assertEqual(
            len(sessions), 1,
            f"expected 1 dedup'd session, got {len(sessions)}: "
            f"{[(s['task'], s.get('stream_path')) for s in sessions]}",
        )
        self.assertEqual(sessions[0]["task"], "dup-task")

    def test_does_not_dedupe_streams_with_different_content(self):
        """Two DONE_Feature dirs with the SAME task name but DIFFERENT stream
        contents are kept as separate sessions. Different content = different
        run (maybe the operator manually re-ran the feature in a second
        project, or worktrees diverged after parallel work).

        Dedupe must be CONTENT-based, not task-name based — otherwise
        legitimate independent runs of the same task would silently merge.
        """
        root_a = self.tmp_path / "proj-a"
        root_b = self.tmp_path / "proj-b"
        (root_a / "docs" / "DONE_Feature_same-name").mkdir(parents=True)
        (root_b / "docs" / "DONE_Feature_same-name").mkdir(parents=True)
        (root_a / "docs" / "DONE_Feature_same-name" / "autopilot-stream.ndjson").write_text(
            '{"type":"phase","phase":"BA","status":"completed","duration_s":30}\n'
            '{"type":"result","session_id":"sid-A","total_cost_usd":5.00}\n'
        )
        (root_b / "docs" / "DONE_Feature_same-name" / "autopilot-stream.ndjson").write_text(
            '{"type":"phase","phase":"BA","status":"completed","duration_s":99}\n'  # different
            '{"type":"result","session_id":"sid-B","total_cost_usd":7.50}\n'
        )

        sessions = self._discover_with_roots([str(root_a), str(root_b)])
        self.assertEqual(len(sessions), 2)

    def test_dedupes_three_identical_copies_keep_one(self):
        """N copies of one stream collapse to 1 session. Generalised case
        of the canary-worktree multiplier (8 copies in production).
        """
        roots = []
        for i in range(5):
            root = self.tmp_path / f"proj-{i}"
            feat = root / "docs" / "DONE_Feature_multi-clone"
            feat.mkdir(parents=True)
            (feat / "autopilot-stream.ndjson").write_text(
                '{"type":"phase","phase":"BA","status":"completed","duration_s":30}\n'
                '{"type":"result","session_id":"sid","total_cost_usd":10.00}\n'
            )
            roots.append(str(root))
        sessions = self._discover_with_roots(roots)
        self.assertEqual(len(sessions), 1)

    def test_done_feature_phases_all_completed(self):
        """All phases in DONE_Feature_ sessions should be 'completed', not 'running'."""
        feature = self.tmp_path / "docs" / "DONE_Feature_finished-task"
        feature.mkdir(parents=True)
        stream = feature / "autopilot-stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"BA","status":"completed","duration_s":30}\n'
            '{"type":"phase","phase":"Plan","status":"completed","duration_s":60}\n'
            '{"type":"phase","phase":"Commit & Merge","status":"running"}\n'
        )
        sessions = self._discover_with_roots([str(self.tmp_path)])
        self.assertEqual(len(sessions), 1)
        for phase in sessions[0]["phases"]:
            self.assertEqual(
                phase["status"],
                "completed",
                f"Phase '{phase['name']}' should be 'completed' in DONE feature",
            )


# ─── load_summary ───────────────────────────────────────────────────


class TestLoadSummary(TmpDirMixin, unittest.TestCase):
    def test_load_valid_summary(self):
        feature_dir = self.tmp_path / "docs" / "INPROGRESS_Feature_my-task"
        feature_dir.mkdir(parents=True)
        summary = {
            "task": "my-task",
            "project": "Test",
            "status": "success",
            "phases": [],
            "duration_s": 100,
        }
        (feature_dir / "autopilot-summary.json").write_text(json.dumps(summary))
        result = load_summary("my-task", search_roots=[str(self.tmp_path)])
        self.assertIsNotNone(result)
        self.assertEqual(result["task"], "my-task")

    def test_no_summary_file(self):
        result = load_summary("nonexistent", search_roots=[str(self.tmp_path)])
        self.assertIsNone(result)


# ─── read_stream_incremental (TG1) ─────────────────────────────────


class TestReadStreamIncremental(TmpDirMixin, unittest.TestCase):
    def test_read_from_zero(self):
        """Read entire file from offset 0, returns all non-filtered events + file size."""
        stream = self.tmp_path / "autopilot-stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"BA","status":"running"}\n'
            '{"type":"assistant","message":{"content":[{"type":"text","text":"hello"}]}}\n'
        )
        events, offset = read_stream_incremental(str(stream), 0)
        self.assertEqual(len(events), 2)
        self.assertEqual(offset, len(stream.read_bytes()))

    def test_read_from_offset(self):
        """Read from mid-file offset, returns only events after that byte position."""
        stream = self.tmp_path / "autopilot-stream.ndjson"
        line1 = '{"type":"phase","phase":"BA","status":"running"}\n'
        line2 = '{"type":"result","total_cost_usd":0.42}\n'
        stream.write_text(line1 + line2)
        offset = len(line1.encode())
        events, new_offset = read_stream_incremental(str(stream), offset)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["type"], "result")

    def test_filters_system_events(self):
        """Lines with type=system are excluded from returned events."""
        stream = self.tmp_path / "autopilot-stream.ndjson"
        stream.write_text(
            '{"type":"system","message":"init"}\n{"type":"phase","phase":"BA","status":"running"}\n'
        )
        events, _ = read_stream_incremental(str(stream), 0)
        types = [e["type"] for e in events]
        self.assertNotIn("system", types)
        self.assertEqual(len(events), 1)

    def test_filters_rate_limit_events(self):
        """Lines with type=rate_limit_event are excluded."""
        stream = self.tmp_path / "autopilot-stream.ndjson"
        stream.write_text(
            '{"type":"rate_limit_event","retry_after":5}\n'
            '{"type":"phase","phase":"BA","status":"running"}\n'
        )
        events, _ = read_stream_incremental(str(stream), 0)
        self.assertEqual(len(events), 1)

    def test_malformed_json_line_skipped(self):
        """Corrupted JSON lines are skipped; valid lines around them are returned."""
        stream = self.tmp_path / "autopilot-stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"BA","status":"running"}\n'
            "not valid json\n"
            '{"type":"result","total_cost_usd":0.42}\n'
        )
        events, _ = read_stream_incremental(str(stream), 0)
        self.assertEqual(len(events), 2)

    def test_empty_file(self):
        """Empty file returns ([], file_size) with no crash."""
        stream = self.tmp_path / "autopilot-stream.ndjson"
        stream.write_text("")
        events, offset = read_stream_incremental(str(stream), 0)
        self.assertEqual(events, [])
        self.assertEqual(offset, 0)

    def test_nonexistent_file(self):
        """Non-existent file returns None."""
        result = read_stream_incremental(str(self.tmp_path / "nonexistent.ndjson"), 0)
        self.assertIsNone(result)

    def test_path_traversal_blocked(self):
        """Path outside PROJECTS_ROOT / tmp dirs returns None."""
        result = read_stream_incremental("/etc/passwd", 0)
        self.assertIsNone(result)

    def test_offset_at_eof(self):
        """Offset == file size returns ([], file_size) -- no re-reading."""
        stream = self.tmp_path / "autopilot-stream.ndjson"
        stream.write_text('{"type":"phase","phase":"BA","status":"running"}\n')
        file_size = len(stream.read_bytes())
        events, offset = read_stream_incremental(str(stream), file_size)
        self.assertEqual(events, [])
        self.assertEqual(offset, file_size)

    # ── max_tail_bytes (dashboard-perf 2026-06-02 #5) ──────────────────
    def test_tail_bounds_initial_read(self):
        """max_tail_bytes caps the offset-0 read to the trailing window and
        drops the partial first line; new_offset still points at EOF so the
        next poll continues from there."""
        stream = self.tmp_path / "autopilot-stream.ndjson"
        line = '{"type":"phase","phase":"BA","status":"running"}\n'
        stream.write_text(line * 20)
        size = len(stream.read_bytes())
        events, offset = read_stream_incremental(
            str(stream), 0, max_tail_bytes=len(line) * 3
        )
        self.assertEqual(offset, size)
        self.assertGreater(len(events), 0)
        self.assertLess(len(events), 20)

    def test_tail_ignored_when_offset_nonzero(self):
        """max_tail_bytes applies only to the initial (offset 0) read."""
        stream = self.tmp_path / "autopilot-stream.ndjson"
        line1 = '{"type":"phase","phase":"BA","status":"running"}\n'
        line2 = '{"type":"result","total_cost_usd":0.42}\n'
        stream.write_text(line1 + line2)
        offset = len(line1.encode())
        events, _ = read_stream_incremental(str(stream), offset, max_tail_bytes=1)
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["type"], "result")

    def test_tail_noop_when_file_smaller_than_cap(self):
        """A file smaller than the cap behaves identically to a full read."""
        stream = self.tmp_path / "autopilot-stream.ndjson"
        stream.write_text('{"type":"phase","phase":"BA","status":"running"}\n')
        events, offset = read_stream_incremental(str(stream), 0, max_tail_bytes=10_000)
        self.assertEqual(len(events), 1)
        self.assertEqual(offset, len(stream.read_bytes()))


# ─── _is_allowed_path ──────────────────────────────────────────────


class TestIsAllowedPath(unittest.TestCase):
    def test_projects_root_allowed(self):
        import dashboard.server.autopilot_helpers as ah

        projects_root = str(ah.PROJECTS_ROOT)
        test_path = projects_root + "/some-project/file.txt"
        self.assertTrue(_is_allowed_path(test_path))

    def test_tmp_allowed(self):
        self.assertTrue(_is_allowed_path("/tmp/test/file.txt"))
        self.assertTrue(_is_allowed_path("/private/tmp/test/file.txt"))
        self.assertTrue(_is_allowed_path("/var/folders/xx/yy/file.txt"))

    def test_resolved_var_folders_allowed(self):
        # macOS resolves /var to /private/var via root symlink; tempfile.mkdtemp()
        # returns /var/folders/... but Path.resolve() returns /private/var/folders/.
        # Both must be allowed — they refer to the same physical path.
        self.assertTrue(_is_allowed_path("/private/var/folders/p3/abc/T/probe-xx/file.txt"))
        self.assertTrue(_is_allowed_path("/private/var/tmp/foo.txt"))

    def test_etc_blocked(self):
        self.assertFalse(_is_allowed_path("/etc/passwd"))

    def test_home_dir_blocked(self):
        self.assertFalse(_is_allowed_path("/Users/someone/.ssh/id_rsa"))


# ─── parse_stream_phases (TG2) ─────────────────────────────────────


class TestParseStreamPhases(TmpDirMixin, unittest.TestCase):
    def test_single_completed_phase(self):
        """Running + completed events merge into one entry."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"BA","status":"running"}\n'
            '{"type":"phase","phase":"BA","status":"completed","duration_s":42}\n'
        )
        phases = parse_stream_phases(str(stream))
        self.assertEqual(len(phases), 1)
        self.assertEqual(phases[0]["name"], "BA")
        self.assertEqual(phases[0]["status"], "completed")
        self.assertEqual(phases[0]["duration_s"], 42)

    def test_running_phase_no_completed(self):
        """A running phase with no completed event stays status=running."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text('{"type":"phase","phase":"Plan","status":"running"}\n')
        phases = parse_stream_phases(str(stream))
        self.assertEqual(len(phases), 1)
        self.assertEqual(phases[0]["status"], "running")
        self.assertIsNone(phases[0]["duration_s"])

    def test_phase_name_normalization(self):
        """Full phase names are normalized via _PHASE_NAME_NORMALIZE."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"Business Analysis","status":"completed","duration_s":10}\n'
            '{"type":"phase","phase":"Architecture Plan","status":"completed","duration_s":20}\n'
        )
        phases = parse_stream_phases(str(stream))
        names = [p["name"] for p in phases]
        self.assertEqual(names, ["BA", "Plan"])

    def test_cost_assigned_from_result(self):
        """Cost from result event assigned to most recent completed phase."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"BA","status":"completed","duration_s":30}\n'
            '{"type":"result","total_cost_usd":1.23}\n'
        )
        phases = parse_stream_phases(str(stream))
        self.assertEqual(phases[0]["cost"], 1.23)

    def test_token_usage_assigned_from_result(self):
        """Tokens + num_turns from result event assigned to most recent completed phase (audit-23 #5).

        Captures the four usage components (input/cache_creation/cache_read/output) and
        num_turns alongside cost so the sidebar can display per-phase token economy.
        """
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"BA","status":"completed","duration_s":30}\n'
            '{"type":"result","total_cost_usd":1.23,"num_turns":33,'
            '"usage":{"input_tokens":32,"cache_creation_input_tokens":30129,'
            '"cache_read_input_tokens":4148262,"output_tokens":19485}}\n'
        )
        phases = parse_stream_phases(str(stream))
        self.assertEqual(phases[0]["input_tokens"], 32)
        self.assertEqual(phases[0]["cache_creation_tokens"], 30129)
        self.assertEqual(phases[0]["cache_read_tokens"], 4148262)
        self.assertEqual(phases[0]["output_tokens"], 19485)
        self.assertEqual(phases[0]["num_turns"], 33)

    def test_results_attribute_to_chronological_phase_not_reversed(self):
        """Each result event credits the phase it was emitted DURING, not the
        phase at the same index from the end (audit-23 attribution bug).

        Stream order: BA running -> BA result -> BA completed -> Plan running
        -> Plan result -> Plan completed.

        BA's result (cost=$1.00, turns=10) MUST land on BA, not on Plan.
        Plan's result (cost=$5.00, turns=50) MUST land on Plan, not on BA.

        The pre-fix `_assign_costs_to_phases` walked phases in REVERSE order
        per result, so result#0 hit phases[-1] and result#1 hit phases[-2].
        With BA at index 0 and Plan at index 1 (chronological), that meant
        BA's result was credited to Plan and vice versa — every phase got
        its temporally-mirrored sibling's data.
        """
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"BA","status":"running"}\n'
            '{"type":"result","total_cost_usd":1.00,"num_turns":10,'
            '"usage":{"input_tokens":1,"output_tokens":100}}\n'
            '{"type":"phase","phase":"BA","status":"completed","duration_s":30}\n'
            '{"type":"phase","phase":"Plan","status":"running"}\n'
            '{"type":"result","total_cost_usd":5.00,"num_turns":50,'
            '"usage":{"input_tokens":5,"output_tokens":500}}\n'
            '{"type":"phase","phase":"Plan","status":"completed","duration_s":60}\n'
        )
        phases = parse_stream_phases(str(stream))
        self.assertEqual(phases[0]["name"], "BA")
        self.assertEqual(phases[0]["cost"], 1.00)
        self.assertEqual(phases[0]["num_turns"], 10)
        self.assertEqual(phases[0]["output_tokens"], 100)
        self.assertEqual(phases[1]["name"], "Plan")
        self.assertEqual(phases[1]["cost"], 5.00)
        self.assertEqual(phases[1]["num_turns"], 50)
        self.assertEqual(phases[1]["output_tokens"], 500)

    def test_multiple_result_events_distinct_sessions_sum(self):
        """Multi-agent phases (e.g. /team-review) emit multiple result events
        within a single phase. Each agent is a separate claude -p invocation
        with its OWN session_id, so num_turns/cost/tokens are independent
        per session and must SUM at the phase level — last-wins would
        silently drop the orchestrator or sub-agent contribution.

        The session_id distinction is load-bearing: two result events sharing
        a session_id are auto-resume segments where cost is cumulative-
        per-session (see test_phantom_result_events_same_session_dedupe).
        Real multi-agent and real retry runs always have distinct sids.
        """
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"Team Review","status":"running"}\n'
            '{"type":"result","session_id":"agent-1","total_cost_usd":2.50,"num_turns":20,'
            '"usage":{"input_tokens":10,"output_tokens":1000}}\n'
            '{"type":"result","session_id":"agent-2","total_cost_usd":3.00,"num_turns":15,'
            '"usage":{"input_tokens":5,"output_tokens":800}}\n'
            '{"type":"phase","phase":"Team Review","status":"completed","duration_s":120}\n'
        )
        phases = parse_stream_phases(str(stream))
        self.assertEqual(phases[0]["cost"], 5.50)
        self.assertEqual(phases[0]["num_turns"], 35)
        self.assertEqual(phases[0]["input_tokens"], 15)
        self.assertEqual(phases[0]["output_tokens"], 1800)

    def test_phantom_result_events_same_session_dedupe(self):
        """When multiple result events share the same session_id (auto-resume
        after a 'Continue?' checkpoint in /implement, or other resume-loop
        activity), total_cost_usd is CUMULATIVE per session and must be
        deduped via max-per-session. Summing the cumulative values would
        double or triple-count the prior segments' cost — the bug surfaced
        by canary G on 2026-05-25 where /implement showed $9.81 on the
        dashboard vs the true $3.68 (cost-summary.py).

        Other usage fields (num_turns, input_tokens, output_tokens, cache_*)
        ARE per-segment in the claude -p stream-json format, so they
        continue to SUM across segments. Only `cost` is special.
        """
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"Implement","status":"running"}\n'
            '{"type":"result","session_id":"sid-A","total_cost_usd":2.65,"num_turns":50,'
            '"usage":{"input_tokens":69,"output_tokens":59811,'
            '"cache_read_input_tokens":4265852,"cache_creation_input_tokens":124912}}\n'
            '{"type":"result","session_id":"sid-A","total_cost_usd":3.48,"num_turns":8,'
            '"usage":{"input_tokens":24,"output_tokens":3062,'
            '"cache_read_input_tokens":1012600,"cache_creation_input_tokens":128667}}\n'
            '{"type":"result","session_id":"sid-A","total_cost_usd":3.68,"num_turns":4,'
            '"usage":{"input_tokens":12,"output_tokens":708,'
            '"cache_read_input_tokens":577623,"cache_creation_input_tokens":5625}}\n'
            '{"type":"phase","phase":"Implement","status":"completed","duration_s":1500}\n'
        )
        phases = parse_stream_phases(str(stream))
        # Cost: max-per-session = $3.68 (NOT 2.65+3.48+3.68=$9.81)
        self.assertEqual(phases[0]["cost"], 3.68)
        # num_turns: per-segment, sum across all = 50+8+4 = 62
        self.assertEqual(phases[0]["num_turns"], 62)
        # Token fields: per-segment, sum
        self.assertEqual(phases[0]["input_tokens"], 69 + 24 + 12)
        self.assertEqual(phases[0]["output_tokens"], 59811 + 3062 + 708)
        self.assertEqual(phases[0]["cache_read_tokens"], 4265852 + 1012600 + 577623)
        self.assertEqual(phases[0]["cache_creation_tokens"], 124912 + 128667 + 5625)

    def test_mixed_phantom_and_retry_costs_correctly(self):
        """A phase with TWO sessions where one session has phantom segments
        and the other is a distinct retry. Cost = max(sid-A) + max(sid-B),
        NOT sum of all 5 result events.
        """
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"QA","status":"running"}\n'
            '{"type":"result","session_id":"sid-A","total_cost_usd":1.00,"num_turns":10}\n'
            '{"type":"result","session_id":"sid-A","total_cost_usd":2.00,"num_turns":5}\n'
            '{"type":"result","session_id":"sid-A","total_cost_usd":2.50,"num_turns":3}\n'
            '{"type":"result","session_id":"sid-B","total_cost_usd":0.75,"num_turns":8}\n'
            '{"type":"result","session_id":"sid-B","total_cost_usd":1.20,"num_turns":4}\n'
            '{"type":"phase","phase":"QA","status":"completed","duration_s":60}\n'
        )
        phases = parse_stream_phases(str(stream))
        # max(sid-A)=2.50 + max(sid-B)=1.20 = $3.70
        self.assertEqual(phases[0]["cost"], 3.70)
        # turns: 10+5+3+8+4 = 30
        self.assertEqual(phases[0]["num_turns"], 30)

    def test_missing_session_id_treated_as_distinct(self):
        """Two result events with no session_id field at all (older streams
        or test stubs) must NOT be deduped together — they're treated as
        independent contributions. Preserves the historical 'sum' semantic
        for legacy data where session attribution was missing.
        """
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"Plan","status":"running"}\n'
            '{"type":"result","total_cost_usd":1.50,"num_turns":12}\n'
            '{"type":"result","total_cost_usd":2.00,"num_turns":8}\n'
            '{"type":"phase","phase":"Plan","status":"completed","duration_s":45}\n'
        )
        phases = parse_stream_phases(str(stream))
        # No sids → each result is its own pseudo-session → sum.
        self.assertEqual(phases[0]["cost"], 3.50)
        self.assertEqual(phases[0]["num_turns"], 20)

    def test_token_keys_initialized_to_none_when_no_result(self):
        """Phases without a matching result event still expose the token keys as None.

        The sidebar contract is that the keys always exist; missing data is None,
        not absent. This avoids defensive `?.` chains in the frontend renderer.
        """
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text('{"type":"phase","phase":"BA","status":"running"}\n')
        phases = parse_stream_phases(str(stream))
        self.assertIsNone(phases[0]["input_tokens"])
        self.assertIsNone(phases[0]["cache_creation_tokens"])
        self.assertIsNone(phases[0]["cache_read_tokens"])
        self.assertIsNone(phases[0]["output_tokens"])
        self.assertIsNone(phases[0]["num_turns"])

    def test_partial_usage_block_handled(self):
        """Result with cost but no usage block leaves token fields None."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"BA","status":"completed","duration_s":30}\n'
            '{"type":"result","total_cost_usd":0.42}\n'
        )
        phases = parse_stream_phases(str(stream))
        self.assertEqual(phases[0]["cost"], 0.42)
        self.assertIsNone(phases[0]["input_tokens"])
        self.assertIsNone(phases[0]["num_turns"])

    def test_phase_timestamps_captured(self):
        """started_at + ended_at captured from event ts (audit-23 #2).

        Phase events carry an ISO 8601 ts. The first sighting of a phase
        (status=running) records started_at; a terminal status (completed
        or failed) records ended_at. Running phases without a terminal
        event yet have ended_at=None.
        """
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"BA","status":"running","ts":"2026-05-09T09:00:31Z"}\n'
            '{"type":"phase","phase":"BA","status":"completed","duration_s":451,'
            '"ts":"2026-05-09T09:08:02Z"}\n'
            '{"type":"phase","phase":"Plan","status":"running","ts":"2026-05-09T09:08:02Z"}\n'
        )
        phases = parse_stream_phases(str(stream))
        self.assertEqual(phases[0]["started_at"], "2026-05-09T09:00:31Z")
        self.assertEqual(phases[0]["ended_at"], "2026-05-09T09:08:02Z")
        self.assertEqual(phases[1]["started_at"], "2026-05-09T09:08:02Z")
        self.assertIsNone(phases[1]["ended_at"])

    def test_failed_phase_records_ended_at(self):
        """A failed terminal status also records ended_at."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"QA","status":"running","ts":"2026-05-09T10:00:00Z"}\n'
            '{"type":"phase","phase":"QA","status":"failed","ts":"2026-05-09T10:05:00Z"}\n'
        )
        phases = parse_stream_phases(str(stream))
        self.assertEqual(phases[0]["status"], "failed")
        self.assertEqual(phases[0]["started_at"], "2026-05-09T10:00:00Z")
        self.assertEqual(phases[0]["ended_at"], "2026-05-09T10:05:00Z")

    def test_phase_timestamp_keys_initialized_to_none_when_no_ts(self):
        """Phases without a ts on the event still have the keys present as None."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text('{"type":"phase","phase":"BA","status":"running"}\n')
        phases = parse_stream_phases(str(stream))
        self.assertIsNone(phases[0]["started_at"])
        self.assertIsNone(phases[0]["ended_at"])

    def test_multiple_phases_ordered(self):
        """Multiple phases returned in stream order."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"BA","status":"completed","duration_s":10}\n'
            '{"type":"phase","phase":"Plan","status":"completed","duration_s":20}\n'
            '{"type":"phase","phase":"Implement","status":"running"}\n'
        )
        phases = parse_stream_phases(str(stream))
        names = [p["name"] for p in phases]
        self.assertEqual(names, ["BA", "Plan", "Implement"])

    def test_unknown_phase_passthrough(self):
        """Unrecognized phase name passed through as-is."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text('{"type":"phase","phase":"CustomPhase","status":"running"}\n')
        phases = parse_stream_phases(str(stream))
        self.assertEqual(phases[0]["name"], "CustomPhase")

    def test_empty_stream(self):
        """Empty stream returns empty list."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text("")
        phases = parse_stream_phases(str(stream))
        self.assertEqual(phases, [])

    def test_artifact_mapping(self):
        """Phase artifacts mapped via PHASE_ARTIFACTS dict."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text('{"type":"phase","phase":"BA","status":"completed","duration_s":10}\n')
        phases = parse_stream_phases(str(stream))
        self.assertEqual(phases[0]["artifact"], "REQUIREMENTS.md")


# ─── _status_from_stream (TG3) ─────────────────────────────────────


class TestStatusFromStream(TmpDirMixin, unittest.TestCase):
    def test_running_when_recent_mtime(self):
        """File mtime < 60s from now -> status 'running'."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text('{"type":"phase","phase":"BA","status":"running"}\n')
        now = os.path.getmtime(str(stream)) + 30  # 30s after write
        status = _status_from_stream(str(stream), now)
        self.assertEqual(status, "running")

    def test_completed_when_old_mtime(self):
        """File mtime > 60s from now -> status 'completed'."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text('{"type":"phase","phase":"BA","status":"completed"}\n')
        now = os.path.getmtime(str(stream)) + 120  # 2 min after write
        status = _status_from_stream(str(stream), now)
        self.assertEqual(status, "completed")

    def test_failed_when_phase_failed(self):
        """Last 20 lines contain phase.status=failed -> status 'failed'."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text('{"type":"phase","phase":"BA","status":"failed"}\n')
        now = os.path.getmtime(str(stream)) + 30
        status = _status_from_stream(str(stream), now)
        self.assertEqual(status, "failed")

    def test_failed_when_result_error(self):
        """Last 20 lines contain result.is_error=true -> status 'failed'."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text('{"type":"result","is_error":true}\n')
        now = os.path.getmtime(str(stream)) + 30
        status = _status_from_stream(str(stream), now)
        self.assertEqual(status, "failed")

    def test_failure_takes_precedence(self):
        """Failure markers override mtime-based running status."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"BA","status":"running"}\n'
            '{"type":"phase","phase":"BA","status":"failed"}\n'
        )
        now = os.path.getmtime(str(stream)) + 10  # Recent = would be "running"
        status = _status_from_stream(str(stream), now)
        self.assertEqual(status, "failed")


# ─── _status_from_log (TG9 partial) ────────────────────────────────


class TestStatusFromLog(TmpDirMixin, unittest.TestCase):
    def test_completed_when_complete_marker(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("Running: /ba flow\nAUTOPILOT COMPLETE\n")
        status = _status_from_log(str(log), time.time())
        self.assertEqual(status, "completed")

    def test_failed_when_failed_marker(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("Running: /ba flow\nAUTOPILOT FAILED\n")
        status = _status_from_log(str(log), time.time())
        self.assertEqual(status, "failed")

    def test_failed_when_stopping_marker(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("Running: /ba flow\nStopping.\n")
        status = _status_from_log(str(log), time.time())
        self.assertEqual(status, "failed")

    def test_running_when_recent_mtime(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("Running: /ba flow\n")
        now = os.path.getmtime(str(log)) + 30
        status = _status_from_log(str(log), now)
        self.assertEqual(status, "running")

    def test_completed_when_old_mtime(self):
        log = self.tmp_path / "autopilot.log"
        log.write_text("Running: /ba flow\n")
        now = os.path.getmtime(str(log)) + 120
        status = _status_from_log(str(log), now)
        self.assertEqual(status, "completed")


# ─── _determine_overall_status (audit-16) ────────────────────────


class TestDetermineOverallStatus(TmpDirMixin, unittest.TestCase):
    """Audit-16 — phase-state must override mtime-based 'completed' fallback.

    The autopilot wrapper can exit (file mtime stops advancing) while the
    underlying claude session is paused on a permission prompt; the stream
    still shows the last phase as 'running'. Reporting 'completed' in that
    state is misleading — the dashboard then hides progress UI even though
    work is clearly incomplete. Phase data is the authoritative signal.
    """

    def test_running_phase_overrides_completed_mtime_stream(self):
        """Stream + old mtime + phases include 'running' -> 'running'."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text('{"type":"phase","phase":"BA","status":"running"}\n')
        now = os.path.getmtime(str(stream)) + 120  # > 60s -> mtime says 'completed'
        phases = [{"name": "BA", "status": "running"}]
        status = _determine_overall_status(False, True, str(stream), now, phases)
        self.assertEqual(status, "running")

    def test_running_phase_overrides_completed_mtime_log(self):
        """Log + old mtime + phases include 'running' -> 'running'."""
        log = self.tmp_path / "autopilot.log"
        log.write_text("Running: /ba flow\n")
        now = os.path.getmtime(str(log)) + 120
        phases = [{"name": "BA", "status": "running"}]
        status = _determine_overall_status(False, False, str(log), now, phases)
        self.assertEqual(status, "running")

    def test_failure_marker_wins_over_running_phase(self):
        """Failure marker in stream tail beats running-phase override."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text(
            '{"type":"phase","phase":"BA","status":"running"}\n'
            '{"type":"phase","phase":"BA","status":"failed"}\n'
        )
        now = os.path.getmtime(str(stream)) + 120
        phases = [{"name": "BA", "status": "running"}]
        status = _determine_overall_status(False, True, str(stream), now, phases)
        self.assertEqual(status, "failed")

    def test_all_completed_phases_keep_completed_status(self):
        """Phases all completed + old mtime -> 'completed' (no override)."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text('{"type":"phase","phase":"BA","status":"completed"}\n')
        now = os.path.getmtime(str(stream)) + 120
        phases = [{"name": "BA", "status": "completed"}]
        status = _determine_overall_status(False, True, str(stream), now, phases)
        self.assertEqual(status, "completed")

    def test_is_done_overrides_everything(self):
        """is_done=True returns 'completed' regardless of phases."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text('{"type":"phase","phase":"BA","status":"running"}\n')
        now = os.path.getmtime(str(stream)) + 120
        phases = [{"name": "BA", "status": "running"}]
        status = _determine_overall_status(True, True, str(stream), now, phases)
        self.assertEqual(status, "completed")

    def test_recent_mtime_running_no_phase_override_needed(self):
        """Recent mtime already gives 'running' — phase override is no-op."""
        stream = self.tmp_path / "stream.ndjson"
        stream.write_text('{"type":"phase","phase":"BA","status":"running"}\n')
        now = os.path.getmtime(str(stream)) + 10
        phases = [{"name": "BA", "status": "running"}]
        status = _determine_overall_status(False, True, str(stream), now, phases)
        self.assertEqual(status, "running")


# ─── discover_autopilots stream-aware (TG9) ───────────────────────


class TestDiscoverAutopilotsStream(TmpDirMixin, unittest.TestCase):
    def _discover_with_roots(self, roots):
        import dashboard.server.autopilot_helpers as ah

        original = ah._get_all_project_roots
        ah._get_all_project_roots = lambda: roots
        try:
            return discover_autopilots(_tmux_cmd=["echo", ""])
        finally:
            ah._get_all_project_roots = original

    def test_stream_session_includes_stream_path(self):
        """Discovered session with NDJSON stream has stream_path set."""
        feature = self.tmp_path / "docs" / "INPROGRESS_Feature_stream-task"
        feature.mkdir(parents=True)
        (feature / "autopilot-stream.ndjson").write_text(
            '{"type":"phase","phase":"BA","status":"running"}\n'
        )
        sessions = self._discover_with_roots([str(self.tmp_path)])
        self.assertEqual(len(sessions), 1)
        self.assertIsNotNone(sessions[0]["stream_path"])
        self.assertTrue(sessions[0]["stream_path"].endswith("autopilot-stream.ndjson"))

    def test_stream_uses_parse_stream_phases(self):
        """Stream session uses stream-based phase parsing (verify phase format)."""
        feature = self.tmp_path / "docs" / "INPROGRESS_Feature_stream-task"
        feature.mkdir(parents=True)
        (feature / "autopilot-stream.ndjson").write_text(
            '{"type":"phase","phase":"Business Analysis","status":"completed","duration_s":30}\n'
        )
        sessions = self._discover_with_roots([str(self.tmp_path)])
        self.assertEqual(len(sessions), 1)
        # Should use normalized name from parse_stream_phases
        self.assertEqual(sessions[0]["phases"][0]["name"], "BA")

    def test_log_only_session_no_stream_path(self):
        """Log-only session has stream_path=None."""
        feature = self.tmp_path / "docs" / "INPROGRESS_Feature_log-task"
        feature.mkdir(parents=True)
        (feature / "autopilot.log").write_text("[10:00:00] Running: /ba flow autopilot log-task\n")
        sessions = self._discover_with_roots([str(self.tmp_path)])
        self.assertEqual(len(sessions), 1)
        self.assertIsNone(sessions[0]["stream_path"])

    def test_done_stream_phases_all_completed(self):
        """DONE feature with stream has all phases forced to completed."""
        feature = self.tmp_path / "docs" / "DONE_Feature_done-stream"
        feature.mkdir(parents=True)
        (feature / "autopilot-stream.ndjson").write_text(
            '{"type":"phase","phase":"BA","status":"completed","duration_s":30}\n'
            '{"type":"phase","phase":"Plan","status":"running"}\n'
        )
        sessions = self._discover_with_roots([str(self.tmp_path)])
        self.assertEqual(len(sessions), 1)
        for phase in sessions[0]["phases"]:
            self.assertEqual(
                phase["status"],
                "completed",
                f"Phase '{phase['name']}' should be 'completed' in DONE feature",
            )

    def test_stream_takes_precedence_over_log(self):
        """Feature with both stream+log uses stream for phases."""
        feature = self.tmp_path / "docs" / "INPROGRESS_Feature_both-task"
        feature.mkdir(parents=True)
        (feature / "autopilot-stream.ndjson").write_text(
            '{"type":"phase","phase":"Business Analysis","status":"completed","duration_s":99}\n'
        )
        (feature / "autopilot.log").write_text(
            "[10:00:00] Running: /ba flow autopilot both-task\nPhase completed in 10s\n"
        )
        sessions = self._discover_with_roots([str(self.tmp_path)])
        self.assertEqual(len(sessions), 1)
        # Stream phase has duration 99, log phase has 10 — verify stream was used
        self.assertEqual(sessions[0]["phases"][0]["duration_s"], 99)
        self.assertIsNotNone(sessions[0]["stream_path"])


class TestKnownArtifacts(unittest.TestCase):
    def test_static_analysis_in_known_artifacts(self):
        """STATIC_ANALYSIS.md must be in _KNOWN_ARTIFACTS."""
        self.assertIn("STATIC_ANALYSIS.md", _KNOWN_ARTIFACTS)

    def test_lists_static_analysis_artifact(self):
        """list_autopilot_artifacts should return STATIC_ANALYSIS.md when present."""
        import shutil
        import tempfile

        tmp = Path(tempfile.mkdtemp(prefix="artifact-test-"))
        try:
            feature_dir = tmp / "docs" / "DONE_Feature_test-sa"
            feature_dir.mkdir(parents=True)
            (feature_dir / "STATIC_ANALYSIS.md").write_text("# Static Analysis\n")
            (feature_dir / "REQUIREMENTS.md").write_text("# Requirements\n")
            import dashboard.server.autopilot_helpers as ah

            original = ah._get_all_project_roots
            ah._get_all_project_roots = lambda: [str(tmp)]
            try:
                artifacts = list_autopilot_artifacts("test-sa")
            finally:
                ah._get_all_project_roots = original
            names = [a["file"] for a in artifacts]
            self.assertIn("STATIC_ANALYSIS.md", names)
            self.assertIn("REQUIREMENTS.md", names)
        finally:
            shutil.rmtree(tmp, ignore_errors=True)


# ─── Lifecycle event tolerance (R13/R14, AS7) ──────────────────────


class TestLifecycleEventTolerance(TmpDirMixin, unittest.TestCase):
    """RT-1/RT-2 regression tests for `type:"lifecycle"` event tolerance.

    Lifecycle events are emitted by autopilot.sh/chain.sh (see
    dashboard/server/lifecycle_events.py). They are additive and must
    NOT alter parse_stream_phases output or _status_from_stream
    classification — those two reader functions skip them explicitly.
    """

    def test_parse_stream_phases_ignores_lifecycle_events(self):
        """RT-1: interleaving lifecycle events MUST NOT change parse_stream_phases output."""
        s1 = self.tmp_path / "no_lifecycle.ndjson"
        s2 = self.tmp_path / "with_lifecycle.ndjson"
        base = [
            '{"type":"phase","phase":"BA","status":"running","ts":"2026-05-14T10:00:00Z"}\n',
            '{"type":"phase","phase":"BA","status":"completed","duration_s":12,"ts":"2026-05-14T10:00:12Z"}\n',
            '{"type":"result","is_error":false,"ts":"2026-05-14T10:00:13Z"}\n',
        ]
        interleaved = [
            '{"ts":"2026-05-14T10:00:00Z","type":"lifecycle","action":"started","source":"cli","target":"demo"}\n',
            base[0],
            '{"ts":"2026-05-14T10:00:12Z","type":"lifecycle","action":"phase_complete","source":"cli","target":"demo","phase":"ba"}\n',
            base[1],
            base[2],
        ]
        s1.write_text("".join(base))
        s2.write_text("".join(interleaved))
        self.assertEqual(parse_stream_phases(str(s1)), parse_stream_phases(str(s2)))

    def test_parse_stream_phases_handles_lifecycle_only_stream(self):
        """RT-2a: a stream containing only lifecycle events returns [] without raising."""
        s = self.tmp_path / "lifecycle_only.ndjson"
        s.write_text(
            '{"ts":"2026-05-14T10:00:00Z","type":"lifecycle","action":"started","source":"cli","target":"demo"}\n'
            '{"ts":"2026-05-14T10:00:01Z","type":"lifecycle","action":"paused","source":"cli","target":"demo","phase_at_pause":"ba"}\n'
        )
        self.assertEqual(parse_stream_phases(str(s)), [])

    def test_status_from_stream_lifecycle_only_not_failed(self):
        """RT-2b: lifecycle-only stream returns mtime-derived status (not 'failed')."""
        s = self.tmp_path / "lifecycle_only.ndjson"
        s.write_text(
            '{"ts":"2026-05-14T10:00:00Z","type":"lifecycle","action":"started","source":"cli","target":"demo"}\n'
            '{"ts":"2026-05-14T10:00:01Z","type":"lifecycle","action":"paused","source":"cli","target":"demo","phase_at_pause":"ba"}\n'
        )
        # Use a recent now so mtime classification is "running"; the
        # assertion is just that lifecycle records are NOT classified as failed.
        now = os.path.getmtime(str(s)) + 5
        status = _status_from_stream(str(s), now)
        self.assertNotEqual(status, "failed")

    def test_status_from_stream_skips_lifecycle_paused(self):
        """_status_from_stream skips lifecycle action 'paused' — not a failure marker."""
        s = self.tmp_path / "paused.ndjson"
        s.write_text(
            '{"ts":"2026-05-14T10:00:00Z","type":"lifecycle","action":"paused","source":"cli","target":"demo","phase_at_pause":"ba"}\n'
        )
        now = os.path.getmtime(str(s)) + 5
        status = _status_from_stream(str(s), now)
        self.assertNotEqual(status, "failed")


if __name__ == "__main__":
    unittest.main()
