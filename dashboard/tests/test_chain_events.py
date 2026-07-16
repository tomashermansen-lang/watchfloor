"""Unit tests for server/chain_events.py — parse_gate_evaluations.

Tests: CE1-CE9 from TESTPLAN.md.
"""
import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from dashboard.server.chain_events import parse_gate_evaluations


class TestParseGateEvaluations:
    def test_ce1_happy_path_single_event(self, tmp_path):
        """CE1: Single gate_evaluated event produces correct dict."""
        ndjson = tmp_path / "chain-events.ndjson"
        ndjson.write_text(json.dumps({
            "type": "gate_evaluated", "phase": "p1",
            "items": [{"text": "t", "kind": "shell", "result": "passed"}],
        }) + "\n")
        result = parse_gate_evaluations(str(tmp_path))
        assert result == {"p1": [{"text": "t", "kind": "shell", "result": "passed"}]}

    def test_ce2_multiple_phases(self, tmp_path):
        """CE2: Two events with different phases produce both keys."""
        ndjson = tmp_path / "chain-events.ndjson"
        lines = [
            json.dumps({"type": "gate_evaluated", "phase": "p1",
                         "items": [{"text": "a", "kind": "shell", "result": "passed"}]}),
            json.dumps({"type": "gate_evaluated", "phase": "p2",
                         "items": [{"text": "b", "kind": "human", "result": "needs_review"}]}),
        ]
        ndjson.write_text("\n".join(lines) + "\n")
        result = parse_gate_evaluations(str(tmp_path))
        assert "p1" in result
        assert "p2" in result
        assert result["p1"][0]["text"] == "a"
        assert result["p2"][0]["text"] == "b"

    def test_ce3_multiple_events_same_phase_last_wins(self, tmp_path):
        """CE3: Multiple gate_evaluated for same phase — last one wins."""
        ndjson = tmp_path / "chain-events.ndjson"
        lines = [
            json.dumps({"type": "gate_evaluated", "phase": "p1",
                         "items": [{"text": "old", "kind": "shell", "result": "failed"}]}),
            json.dumps({"type": "gate_evaluated", "phase": "p1",
                         "items": [{"text": "new", "kind": "shell", "result": "passed"}]}),
        ]
        ndjson.write_text("\n".join(lines) + "\n")
        result = parse_gate_evaluations(str(tmp_path))
        assert result["p1"][0]["text"] == "new"
        assert result["p1"][0]["result"] == "passed"

    def test_ce4_file_not_found(self, tmp_path):
        """CE4: Non-existent directory returns empty dict."""
        result = parse_gate_evaluations(str(tmp_path / "nonexistent"))
        assert result == {}

    def test_ce5_empty_file(self, tmp_path):
        """CE5: Empty chain-events.ndjson returns empty dict."""
        ndjson = tmp_path / "chain-events.ndjson"
        ndjson.write_text("")
        result = parse_gate_evaluations(str(tmp_path))
        assert result == {}

    def test_ce6_malformed_lines_skipped(self, tmp_path):
        """CE6: Malformed NDJSON lines are skipped, valid events parsed."""
        ndjson = tmp_path / "chain-events.ndjson"
        lines = [
            "not json at all",
            json.dumps({"type": "gate_evaluated", "phase": "p1",
                         "items": [{"text": "ok", "kind": "shell", "result": "passed"}]}),
            "{broken json",
        ]
        ndjson.write_text("\n".join(lines) + "\n")
        result = parse_gate_evaluations(str(tmp_path))
        assert "p1" in result
        assert result["p1"][0]["text"] == "ok"

    def test_ce7_non_gate_events_ignored(self, tmp_path):
        """CE7: Non-gate_evaluated events are ignored."""
        ndjson = tmp_path / "chain-events.ndjson"
        lines = [
            json.dumps({"type": "task_started", "phase": "p1", "task": "t1"}),
            json.dumps({"type": "gate_evaluated", "phase": "p1",
                         "items": [{"text": "x", "kind": "shell", "result": "passed"}]}),
            json.dumps({"type": "phase_completed", "phase": "p1"}),
        ]
        ndjson.write_text("\n".join(lines) + "\n")
        result = parse_gate_evaluations(str(tmp_path))
        assert len(result) == 1
        assert "p1" in result

    def test_ce8_event_missing_items_field(self, tmp_path):
        """CE8: gate_evaluated event with no items field — phase gets empty list."""
        ndjson = tmp_path / "chain-events.ndjson"
        ndjson.write_text(json.dumps({"type": "gate_evaluated", "phase": "p1"}) + "\n")
        result = parse_gate_evaluations(str(tmp_path))
        assert result == {"p1": []}

    def test_ce9_all_result_types_preserved(self, tmp_path):
        """CE9: Items with all result types are preserved correctly."""
        items = [
            {"text": "a", "kind": "shell", "result": "passed"},
            {"text": "b", "kind": "shell", "result": "failed"},
            {"text": "c", "kind": "shell", "result": "timeout"},
            {"text": "d", "kind": "human", "result": "needs_review"},
        ]
        ndjson = tmp_path / "chain-events.ndjson"
        ndjson.write_text(json.dumps({
            "type": "gate_evaluated", "phase": "p1", "items": items,
        }) + "\n")
        result = parse_gate_evaluations(str(tmp_path))
        assert len(result["p1"]) == 4
        assert result["p1"][0]["result"] == "passed"
        assert result["p1"][1]["result"] == "failed"
        assert result["p1"][2]["result"] == "timeout"
        assert result["p1"][3]["result"] == "needs_review"
