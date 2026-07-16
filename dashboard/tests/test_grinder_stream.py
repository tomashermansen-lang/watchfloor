"""Tests for grinder stream helpers: get_grinder_stream_path, filter_batch_events,
and frontend hook tests live in app/src/__tests__/."""

import os
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from dashboard.server.grinder_helpers import get_grinder_stream_path, filter_batch_events, _find_batch_bounds


class TestGetGrinderStreamPath(unittest.TestCase):
    """C1: get_grinder_stream_path — backend path resolver."""

    def setUp(self):
        self.tmpdir = os.path.realpath(tempfile.mkdtemp())
        self.project_root = os.path.join(self.tmpdir, "test-project")
        os.makedirs(os.path.join(self.project_root, "docs", "grinder"), exist_ok=True)

    def tearDown(self):
        shutil.rmtree(self.tmpdir)

    def _patch_allowed(self):
        """Patch _is_allowed_path to accept our tmpdir."""
        def allowed(resolved):
            return str(resolved).startswith(self.tmpdir)
        return patch("dashboard.server.autopilot_helpers._is_allowed_path", side_effect=allowed)

    def test_c1_1_valid_project_with_stream_file(self):
        """C1.1: Valid project with stream file returns resolved path."""
        stream_path = os.path.join(self.project_root, "docs", "grinder", "grinder-stream.ndjson")
        Path(stream_path).touch()

        with self._patch_allowed():
            result = get_grinder_stream_path(self.project_root)

        self.assertIsNotNone(result)
        self.assertTrue(result.endswith("grinder-stream.ndjson"))

    def test_c1_2_project_without_stream_file(self):
        """C1.2: Project with grinder dir but no stream file returns None."""
        with self._patch_allowed():
            result = get_grinder_stream_path(self.project_root)

        self.assertIsNone(result)

    def test_c1_3_project_without_grinder_dir(self):
        """C1.3: Project without docs/grinder/ returns None."""
        bare_project = os.path.join(self.tmpdir, "bare-project")
        os.makedirs(bare_project)

        with self._patch_allowed():
            result = get_grinder_stream_path(bare_project)

        self.assertIsNone(result)

    def test_c1_4_path_traversal_attempt(self):
        """C1.4: Path traversal via project_root is rejected."""
        with patch("dashboard.server.autopilot_helpers._is_allowed_path", return_value=False):
            result = get_grinder_stream_path("/tmp/../../../etc")

        self.assertIsNone(result)

    def test_c1_5_symlink_escape(self):
        """C1.5: Symlink pointing outside allowed dir returns None."""
        grinder_dir = os.path.join(self.project_root, "docs", "grinder")
        external_file = os.path.join(self.tmpdir, "external.txt")
        Path(external_file).write_text("secret")
        symlink_path = os.path.join(grinder_dir, "grinder-stream.ndjson")
        os.symlink(external_file, symlink_path)

        # _is_allowed_path rejects the resolved (external) path
        def strict_allowed(resolved):
            return str(resolved).startswith(self.project_root + "/")
        with patch("dashboard.server.autopilot_helpers._is_allowed_path", side_effect=strict_allowed):
            result = get_grinder_stream_path(self.project_root)

        self.assertIsNone(result)


class TestFindBatchBounds(unittest.TestCase):
    """C2 — _find_batch_bounds helper."""

    def _make_events(self):
        """Create a realistic multi-batch event sequence."""
        return [
            {"type": "orchestrator", "msg": "batch b1 started"},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "Working on b1"}]}},
            {"type": "orchestrator", "msg": "batch b1 completed"},
            {"type": "orchestrator", "msg": "batch b2 started"},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "Working on b2"}]}},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "Still b2"}]}},
            {"type": "orchestrator", "msg": "batch b2 completed"},
            {"type": "orchestrator", "msg": "batch b3 started"},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "Working on b3"}]}},
        ]

    def test_c2_8_correct_start_end_indices(self):
        """C2.8: Returns correct (start, end) tuple for known batch."""
        events = self._make_events()
        start, end = _find_batch_bounds(events, "b1")
        self.assertEqual(start, 0)
        self.assertEqual(end, 3)  # end marker inclusive → index after end marker

    def test_c2_9_not_found_returns_minus_one(self):
        """C2.9: Batch not found returns (-1, -1)."""
        events = self._make_events()
        start, end = _find_batch_bounds(events, "nonexistent")
        self.assertEqual((start, end), (-1, -1))

    def test_c2_8_batch_b2_bounds(self):
        """C2.8: Batch b2 bounds are correct."""
        events = self._make_events()
        start, end = _find_batch_bounds(events, "b2")
        self.assertEqual(start, 3)
        self.assertEqual(end, 7)

    def test_c2_4_unterminated_batch(self):
        """C2.4: Batch started but not ended returns to end of list."""
        events = self._make_events()
        start, end = _find_batch_bounds(events, "b3")
        self.assertEqual(start, 7)
        self.assertEqual(end, len(events))

    def test_c2_5_multiple_start_markers_uses_last(self):
        """C2.5: Multiple start markers (retry) — uses last start marker."""
        events = [
            {"type": "orchestrator", "msg": "batch b1 started"},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "First attempt"}]}},
            {"type": "orchestrator", "msg": "batch b1 started"},  # Retry
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "Second attempt"}]}},
            {"type": "orchestrator", "msg": "batch b1 completed"},
        ]
        start, end = _find_batch_bounds(events, "b1")
        self.assertEqual(start, 2)  # Last start marker
        self.assertEqual(end, 5)

    def test_c2_6_empty_event_list(self):
        """C2.6: Empty event list returns (-1, -1)."""
        start, end = _find_batch_bounds([], "b1")
        self.assertEqual((start, end), (-1, -1))


class TestFilterBatchEvents(unittest.TestCase):
    """C2 — filter_batch_events."""

    def _make_events(self):
        return [
            {"type": "orchestrator", "msg": "batch b1 started"},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "Working on b1"}]}},
            {"type": "orchestrator", "msg": "batch b1 completed"},
            {"type": "orchestrator", "msg": "batch b2 started"},
            {"type": "assistant", "message": {"content": [{"type": "text", "text": "Working on b2"}]}},
            {"type": "orchestrator", "msg": "batch b2 completed"},
        ]

    def test_c2_1_single_batch_full_lifecycle(self):
        """C2.1: Single batch returns events between markers (inclusive)."""
        events = self._make_events()
        result = filter_batch_events(events, "b1")
        self.assertEqual(len(result), 3)
        self.assertEqual(result[0]["msg"], "batch b1 started")
        self.assertEqual(result[-1]["msg"], "batch b1 completed")

    def test_c2_2_multiple_batches_correct_isolation(self):
        """C2.2: filter(events, 'b2') returns only b2 events."""
        events = self._make_events()
        result = filter_batch_events(events, "b2")
        self.assertEqual(len(result), 3)
        self.assertEqual(result[0]["msg"], "batch b2 started")

    def test_c2_3_batch_not_found(self):
        """C2.3: Batch not found returns empty list."""
        events = self._make_events()
        result = filter_batch_events(events, "nonexistent")
        self.assertEqual(result, [])

    def test_c2_7_no_batch_filter(self):
        """C2.7: No batch_id returns all events."""
        events = self._make_events()
        result = filter_batch_events(events, None)
        self.assertEqual(result, events)


if __name__ == "__main__":
    unittest.main()
