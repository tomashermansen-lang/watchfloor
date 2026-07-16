"""Parse the JSON result emitted by commit-finalize.sh.

Bash callers stream finalize output through this module to extract the
single trailing JSON line and answer four questions:

    --ok                Is the `ok` field True (every step succeeded)?
    --merge-failed      Did any step named `merge` have status `fail`?
    --merge-succeeded   Did the `merge` step have status `ok` (the feature
                        landed on main, regardless of cleanup hiccups)?
    --post-merge-warnings  Did merge succeed but a later step (post-merge
                        plan update, stash_pop, push, etc.) fail? Used by
                        autopilot.sh to log warnings without flipping
                        PIPELINE_STATUS — RETRO Deviation 11 family.

Exit codes:
    0 — answer printed on stdout (True/False for booleans, parsed value otherwise)
    1 — input could not be parsed as JSON

Why this exists: the previous inline heredoc used `lines.rfind('{')` which
landed on the innermost step-object `{` in finalize's nested JSON, truncating
the blob and causing `json.load` to fail. FINALIZE_OK became "false" on
every successful run. This module implements the correct "last line starting
with {" heuristic and is pytest-testable.

Why the merge_succeeded split: the original `--ok` semantic conflated
"merge landed" with "every cleanup step landed." A successful merge
followed by a stash_pop conflict (the defensive guard from ea373ca
firing) used to flip PIPELINE_STATUS to failed and trigger a chain
re-spawn (RETRO Deviation 11 redux). The merge_succeeded answer lets
autopilot.sh report the feature as complete while logging cleanup
issues as warnings.
"""
from __future__ import annotations

import json
import sys
from typing import Any


def extract_json_line(stream_text: str) -> str | None:
    """Return the last line starting with `{` (after lstrip), or None."""
    last: str | None = None
    for line in stream_text.splitlines():
        if line.lstrip().startswith("{"):
            last = line
    return last.strip() if last else None


def parse_ok(payload: dict[str, Any]) -> bool:
    """Return the boolean value of payload['ok'], defaulting to False."""
    return bool(payload.get("ok", False))


def parse_merge_failed(payload: dict[str, Any]) -> bool:
    """Return True if any step has {'step': 'merge', 'status': 'fail'}."""
    steps = payload.get("steps", [])
    return any(s.get("step") == "merge" and s.get("status") == "fail" for s in steps)


def parse_merge_succeeded(payload: dict[str, Any]) -> bool:
    """Return True if any step has {'step': 'merge', 'status': 'ok'}.

    The feature landed on main if the merge step is `ok`, regardless of
    later steps (post-merge plan update, stash_pop, push). A merge_succeeded
    payload may still report ok=False overall when a later step failed —
    that distinction lets the caller log warnings without flagging the
    feature itself as failed.
    """
    steps = payload.get("steps", [])
    return any(s.get("step") == "merge" and s.get("status") == "ok" for s in steps)


def parse_post_merge_warnings(payload: dict[str, Any]) -> bool:
    """Return True iff merge succeeded AND any later step failed.

    Use case: autopilot.sh wants to print AUTOPILOT COMPLETE for a feature
    whose merge landed but whose post-merge cleanup hit a recoverable
    issue. The caller logs cleanup failures as warnings instead of flipping
    PIPELINE_STATUS=failed.
    """
    steps = payload.get("steps", [])
    merge_ok_idx = -1
    for i, s in enumerate(steps):
        if s.get("step") == "merge" and s.get("status") == "ok":
            merge_ok_idx = i
            break
    if merge_ok_idx == -1:
        return False
    return any(s.get("status") == "fail" for s in steps[merge_ok_idx + 1 :])


def main(argv: list[str]) -> int:
    valid_args = ("--ok", "--merge-failed", "--merge-succeeded", "--post-merge-warnings")
    if len(argv) != 2 or argv[1] not in valid_args:
        print(f"usage: finalize_result.py {{{ '|'.join(valid_args) }}}", file=sys.stderr)
        return 2

    stream_text = sys.stdin.read()
    json_line = extract_json_line(stream_text)
    if json_line is None:
        return 1

    try:
        payload = json.loads(json_line)
    except json.JSONDecodeError:
        return 1

    if argv[1] == "--ok":
        print(parse_ok(payload))
    elif argv[1] == "--merge-failed":
        print(parse_merge_failed(payload))
    elif argv[1] == "--merge-succeeded":
        print(parse_merge_succeeded(payload))
    else:  # --post-merge-warnings
        print(parse_post_merge_warnings(payload))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
