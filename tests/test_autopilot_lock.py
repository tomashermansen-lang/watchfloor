"""Tests for autopilot.sh merge lock integration (AL-1..4).

Note: These tests verify source-level ordering constraints (lock acquire before
finalize, release after). Behavioral tests are impractical because autopilot.sh
requires a live Claude API session. The lock functions themselves are tested
behaviorally in test_merge_lock.py (ML-1..7).
"""

from __future__ import annotations

import re

from conftest import REPO_ROOT

AUTOPILOT_SH = REPO_ROOT / "adapters" / "claude-code" / "claude" / "tools" / "autopilot.sh"

# Match actual `bash …/commit-finalize.sh` invocations at start-of-line
# (excluding mentions inside log/echo strings and help-text boxes).
_FINALIZE_INVOCATION_RE = re.compile(
    r"^\s*bash\s+~/\.claude/tools/commit-finalize\.sh", re.MULTILINE
)


class TestNoLockByDefault:
    """AL-1: CHAIN_MERGE_LOCK unset — no lock behavior (backwards compat)."""

    def test_no_lock_references_without_env(self):
        content = AUTOPILOT_SH.read_text()
        # The script sources merge-lock.sh — verify it's conditional
        assert "CHAIN_MERGE_LOCK" in content
        # Verify acquire is guarded by the env var
        assert 'if [[ -n "${CHAIN_MERGE_LOCK:-}" ]]' in content


class TestLockAcquireBeforeFinalize:
    """AL-2: CHAIN_MERGE_LOCK set — lock acquired before finalize."""

    def test_acquire_before_finalize(self):
        content = AUTOPILOT_SH.read_text()
        # Find acquire_merge_lock call
        acquire_pos = content.find("acquire_merge_lock")
        # Find commit-finalize.sh call (the first one after the lock section)
        finalize_pos = content.find("commit-finalize.sh", acquire_pos)
        assert acquire_pos > 0, "acquire_merge_lock not found in autopilot.sh"
        assert finalize_pos > acquire_pos, "acquire must come before finalize"


class TestLockReleaseAfterFinalize:
    """AL-3: Lock released after finalize completes."""

    def test_release_after_finalize(self):
        content = AUTOPILOT_SH.read_text()
        # Last actual `bash …/commit-finalize.sh` invocation — exclude
        # mentions in log strings and the box-drawn help text at the EOF.
        invocations = list(_FINALIZE_INVOCATION_RE.finditer(content))
        assert invocations, "no commit-finalize.sh invocation found in autopilot.sh"
        last_finalize = invocations[-1].start()
        release_pos = content.find("release_merge_lock", last_finalize)
        assert release_pos > last_finalize, "release must come after finalize"


class TestExitTrapPreserved:
    """AL-4: Existing EXIT trap (FINALIZE_LOG cleanup) preserved."""

    def test_trap_composes_cleanup(self):
        content = AUTOPILOT_SH.read_text()
        # The original trap cleaned up FINALIZE_LOG. The new code should
        # compose cleanup to handle both FINALIZE_LOG and CHAIN_MERGE_LOCK.
        # Verify cleanup function exists
        assert "finalize_cleanup" in content or "FINALIZE_LOG" in content
        # Verify the trap still removes FINALIZE_LOG
        assert 'rm -f "$FINALIZE_LOG"' in content
