"""Shared helper for ``project.deferred[]`` access in 2.0 execution-plan.yaml.

Public API
==========

* ``detect_plan_version(plan_path)`` — returns ``"2.0"``, ``"1.x"``, or ``None``.
* ``find_colocated_plan(start_dir)`` — walks parents looking for a sibling
  ``execution-plan.yaml``. Returns the path or ``None``.
* ``read_deferred(plan_path, kind_filter=None)`` — yields ``deferred[]`` from
  a 2.0 plan. Raises :class:`LegacyPlanError` for 1.x plans.
* ``write_deferred(plan_path, entries)`` — atomic in-place rewrite that
  preserves all keys outside ``project.deferred``.
* ``append_deferred(plan_path, new_entry)`` — convenience wrapper around
  ``read_deferred`` / ``write_deferred``.
* ``make_*_entry(...)`` factory functions — emit canonical entries with
  ``kind`` set; consumers do not import enum strings.

CLI
===

``python3 -m plan_yaml_deferred dump -- <plan-or-dir>`` prints the deferred
array as JSON to stdout. Bash callers shell out via this CLI so they never
inspect ``schema_version`` themselves. Current bash callers:
``commit-preflight.sh``. (``get-findings.sh`` reads the legacy JSON path
directly today; migration is tracked in ``docs/DEFERRED.md``.)

Note: ``append_deferred`` is intended for single-entry callers only.
For bulk inserts (e.g. ``finalise-deferred.py`` or ``ratchet-autolog.py``),
use ``read_deferred`` + in-memory mutation + a single ``write_deferred``
call to avoid O(k) parse cycles per finding.
"""

from __future__ import annotations

import json
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

# Suppress comment-loss WARNING after the first emission per process.
_COMMENT_WARNING_EMITTED = False


class LegacyPlanError(Exception):
    """Raised when a 1.x plan is supplied where 2.0 is required."""

    def __init__(self, plan_path: Path, schema_version: str, message: str = ""):
        super().__init__(message or f"legacy plan at {plan_path} (schema_version={schema_version})")
        self.plan_path = plan_path
        self.schema_version = schema_version


class SchemaViolation(Exception):
    """Raised when an append would violate schema 2.0 ``deferred[]`` shape."""


class SecurityError(Exception):
    """Raised when a path traversal or symlink-target rewrite is attempted."""


_VERSION_RE = re.compile(r"^(\d+)\.\d+\.\d+(?:\D|$)")

# Maximum size for a legacy deferred-findings.json read via _cli_dump.
# Prevents memory exhaustion from pathologically large files.
MAX_JSON_SIZE = 10 * 1024 * 1024  # 10 MB

# Minimum length for free-text justification fields on deferred entries.
# Mirrors plan_validators.SUCCESS_CRITERIA_REASON_MIN; declared here so the
# schema 2.0 deferred[] validator does not depend on plan_validators.py.
DEFERRED_REASON_MIN_CHARS = 40


def _read_yaml(plan_path: Path) -> dict:
    import yaml  # local import — keep this module importable when PyYAML is missing

    return yaml.safe_load(plan_path.read_text()) or {}


def detect_plan_version(plan_path: Path) -> str | None:
    """Return ``"2.0"``, ``"1.x"``, or ``None`` if the plan path is missing
    or is not parseable as YAML (the caller falls back to legacy handling).
    """
    p = Path(plan_path)
    if not p.exists():
        return None
    try:
        plan = _read_yaml(p)
    except Exception:
        return None
    sv = plan.get("schema_version")
    if not isinstance(sv, str):
        return None
    m = _VERSION_RE.match(sv)
    if not m:
        return None
    major = int(m.group(1))
    if major >= 2:
        return "2.0"
    return "1.x"


def find_colocated_plan(start_dir: Path) -> Path | None:
    """Walk up from ``start_dir`` looking for ``execution-plan.yaml``."""
    cur = Path(start_dir).resolve()
    if cur.is_file():
        cur = cur.parent
    while True:
        candidate = cur / "execution-plan.yaml"
        if candidate.exists():
            return candidate
        if cur.parent == cur:
            return None
        cur = cur.parent


def read_deferred(plan_path: Path, kind_filter: str | None = None) -> list[dict]:
    """Read ``deferred[]`` from a 2.0 plan; raise ``LegacyPlanError`` for 1.x."""
    version = detect_plan_version(plan_path)
    if version != "2.0":
        plan = _read_yaml(Path(plan_path)) if Path(plan_path).exists() else {}
        sv = plan.get("schema_version", "?")
        print(
            f"WARNING: legacy 1.x plan at {plan_path}; falling back to JSON",
            file=sys.stderr,
        )
        raise LegacyPlanError(Path(plan_path), str(sv))
    plan = _read_yaml(Path(plan_path))
    entries = plan.get("deferred") or []
    if kind_filter:
        entries = [e for e in entries if e.get("kind") == kind_filter]
    return entries


def _check_required(entry: dict, required: tuple[str, ...]) -> None:
    missing = [k for k in required if not entry.get(k)]
    if missing:
        raise SchemaViolation(f"deferred entry missing required field(s): {', '.join(missing)}")


def _validate_entry(entry: dict) -> None:
    kind = entry.get("kind")
    if kind == "code_finding":
        _check_required(
            entry,
            (
                "id",
                "kind",
                "finding_id",
                "rule",
                "file",
                "line",
                "state",
                "reason",
                "owner",
                "reviewed_at",
                "review_trigger",
            ),
        )
        if len(entry.get("reason", "")) < DEFERRED_REASON_MIN_CHARS:
            raise SchemaViolation(
                f"code_finding.reason must be ≥ {DEFERRED_REASON_MIN_CHARS} chars"
            )
    elif kind == "review_suggestion":
        _check_required(
            entry,
            (
                "id",
                "kind",
                "date",
                "feature_or_task_id",
                "phase_id",
                "reviewer",
                "category",
                "description",
                "reason_deferred",
            ),
        )
        if len(entry.get("reason_deferred", "")) < DEFERRED_REASON_MIN_CHARS:
            raise SchemaViolation(
                f"review_suggestion.reason_deferred must be ≥ {DEFERRED_REASON_MIN_CHARS} chars"
            )
    elif kind == "scope_decision":
        _check_required(
            entry, ("id", "kind", "date", "decided_at_task_id", "decision", "rationale")
        )
    elif kind == "future_enhancement":
        _check_required(entry, ("id", "kind", "date", "description"))
    elif kind == "environment_gap":
        _check_required(
            entry,
            (
                "id",
                "kind",
                "date",
                "detected_at_phase",
                "symptom",
                "root_cause",
                "verification_command",
            ),
        )
        if len(entry.get("root_cause", "")) < DEFERRED_REASON_MIN_CHARS:
            raise SchemaViolation(
                f"environment_gap.root_cause must be ≥ {DEFERRED_REASON_MIN_CHARS} chars"
            )
    else:
        raise SchemaViolation(f"unknown deferred.kind: {kind!r}")


def _fast_schema_version(plan_path: Path) -> str | None:
    """Return the major version string by scanning the first 50 lines for
    ``schema_version:`` without parsing the full YAML document.

    Returns ``"2.0"`` for major ≥ 2, ``"1.x"`` for major 1, or ``None``
    if the line is not found or unparseable.  This avoids the double YAML
    parse that ``detect_plan_version`` triggers when called from
    ``write_deferred`` (which immediately calls ``_read_yaml`` again).
    """
    try:
        with plan_path.open(encoding="utf-8", errors="replace") as fh:
            for _ in range(50):
                line = fh.readline()
                if not line:
                    break
                if line.startswith("schema_version:"):
                    raw = line.split(":", 1)[1].strip().strip("\"'")
                    m = _VERSION_RE.match(raw)
                    if m:
                        return "2.0" if int(m.group(1)) >= 2 else "1.x"
    except OSError:
        pass
    return None


def write_deferred(plan_path: Path, entries: list[dict]) -> None:
    """Atomic in-place rewrite — mutate ``project.deferred`` only.

    Uses a fast line-scan for ``schema_version:`` to avoid the double YAML
    parse that would otherwise occur (``detect_plan_version`` + ``_read_yaml``).
    """
    import yaml

    global _COMMENT_WARNING_EMITTED
    plan_path = Path(plan_path)
    if plan_path.is_symlink():
        raise SecurityError(f"plan_path must not be a symlink: {plan_path}")

    # Fast version check — avoids a second full YAML parse.
    fast_ver = _fast_schema_version(plan_path)
    if fast_ver != "2.0":
        # Fall back to full parse only to extract the schema_version for the error message.
        sv = _read_yaml(plan_path).get("schema_version", "?")
        raise LegacyPlanError(
            plan_path, str(sv), f"cannot write_deferred to non-2.0 plan {plan_path}"
        )

    plan = _read_yaml(plan_path)
    for entry in entries:
        _validate_entry(entry)
    plan["deferred"] = entries

    if not _COMMENT_WARNING_EMITTED:
        print(
            "WARNING: write_deferred() does not preserve YAML comments. "
            "Use a `# DEFERRAL_NOTE:` key inside the entry dict for persistent operator notes.",
            file=sys.stderr,
        )
        _COMMENT_WARNING_EMITTED = True

    src_mode = plan_path.stat().st_mode
    fd, tmpname = tempfile.mkstemp(
        dir=str(plan_path.parent),
        prefix=".execution-plan.",
        suffix=".tmp",
        text=True,
    )
    try:
        with os.fdopen(fd, "w") as fh:
            yaml.safe_dump(
                plan,
                fh,
                sort_keys=False,
                default_flow_style=False,
                width=120,
                indent=2,
            )
        os.chmod(tmpname, stat.S_IMODE(src_mode))
        os.replace(tmpname, plan_path)
    except Exception:
        try:
            os.unlink(tmpname)
        except OSError:
            pass
        raise


def append_deferred(plan_path: Path, new_entry: dict) -> bool:
    """Append a new entry; return False if the id is already present."""
    entries = list(read_deferred(plan_path))
    new_id = new_entry.get("id")
    if new_id and any(e.get("id") == new_id for e in entries):
        return False
    entries.append(new_entry)
    write_deferred(plan_path, entries)
    return True


def make_code_finding_entry(
    *,
    id: str,
    finding_id: str,
    rule: str,
    file: str,
    line: int,
    state: str,
    reason: str,
    owner: str,
    reviewed_at: str,
    review_trigger: str,
    ticket: str | None = None,
    deferred_at_task_id: str | None = None,
    deferred_at_phase_id: str | None = None,
) -> dict:
    entry: dict = {
        "id": id,
        "kind": "code_finding",
        "finding_id": finding_id,
        "rule": rule,
        "file": file,
        "line": line,
        "state": state,
        "reason": reason,
        "owner": owner,
        "reviewed_at": reviewed_at,
        "review_trigger": review_trigger,
    }
    if ticket:
        entry["ticket"] = ticket
    if deferred_at_task_id:
        entry["deferred_at_task_id"] = deferred_at_task_id
    if deferred_at_phase_id:
        entry["deferred_at_phase_id"] = deferred_at_phase_id
    return entry


def make_review_suggestion_entry(
    *,
    id: str,
    date: str,
    feature_or_task_id: str,
    phase_id: str,
    reviewer: str,
    category: str,
    description: str,
    reason_deferred: str,
) -> dict:
    return {
        "id": id,
        "kind": "review_suggestion",
        "date": date,
        "feature_or_task_id": feature_or_task_id,
        "phase_id": phase_id,
        "reviewer": reviewer,
        "category": category,
        "description": description,
        "reason_deferred": reason_deferred,
    }


def make_scope_decision_entry(
    *,
    id: str,
    date: str,
    decided_at_task_id: str,
    decision: str,
    rationale: str,
) -> dict:
    return {
        "id": id,
        "kind": "scope_decision",
        "date": date,
        "decided_at_task_id": decided_at_task_id,
        "decision": decision,
        "rationale": rationale,
    }


def make_future_enhancement_entry(
    *,
    id: str,
    date: str,
    description: str,
    target_release: str | None = None,
    effort_estimate: str | None = None,
) -> dict:
    entry: dict = {
        "id": id,
        "kind": "future_enhancement",
        "date": date,
        "description": description,
    }
    if target_release:
        entry["target_release"] = target_release
    if effort_estimate:
        entry["effort_estimate"] = effort_estimate
    return entry


def make_environment_gap_entry(
    *,
    id: str,
    date: str,
    detected_at_phase: str,
    symptom: str,
    root_cause: str,
    verification_command: str,
    detected_at_task_id: str | None = None,
    affected_test_suites: list | None = None,
    workaround: str | None = None,
    status: str | None = None,
) -> dict:
    """Construct a deferred[].kind=environment_gap entry.

    See claude/schema/execution-plan.schema.json#deferred_environment_gap for
    field semantics. ``root_cause`` must be ≥40 chars (DEFERRED_REASON_MIN_CHARS)
    so the entry survives validation.
    """
    entry: dict = {
        "id": id,
        "kind": "environment_gap",
        "date": date,
        "detected_at_phase": detected_at_phase,
        "symptom": symptom,
        "root_cause": root_cause,
        "verification_command": verification_command,
    }
    if detected_at_task_id:
        entry["detected_at_task_id"] = detected_at_task_id
    if affected_test_suites:
        entry["affected_test_suites"] = list(affected_test_suites)
    if workaround is not None:
        entry["workaround"] = workaround
    if status:
        entry["status"] = status
    return entry


_PROJECTS_ROOT = Path.home() / "Projekter"
_SHELL_METACHAR_RE = re.compile(r"[`$;|&><()*?]")


def _trust_roots() -> list[Path]:
    """Resolved roots accepted by the dump CLI.

    Includes ``$PROJECTS_ROOT`` (default ``~/Projekter``), the system temp
    dir (so pytest ``tmp_path`` works), and ``/tmp`` / ``/private/tmp`` for
    macOS sandbox parity.
    """
    roots: list[Path] = []
    for raw in (
        os.environ.get("PROJECTS_ROOT", str(_PROJECTS_ROOT)),
        tempfile.gettempdir(),
        "/tmp",
        "/private/tmp",
    ):
        try:
            roots.append(Path(raw).resolve())
        except OSError:
            continue
    return roots


def _validate_dump_path(raw: str) -> Path:
    """Reject shell metacharacters and out-of-trust-boundary paths."""
    if _SHELL_METACHAR_RE.search(raw):
        raise SecurityError("path contains shell metacharacters")
    candidate = Path(raw).resolve()
    for root in _trust_roots():
        try:
            candidate.relative_to(root)
            return candidate
        except ValueError:
            continue
    raise SecurityError(f"path outside trust boundary: {candidate}")


def _cli_dump(argv: list[str]) -> int:
    """``dump`` subcommand — emit deferred[] as JSON.

    Resolution order:

    1. If ``target`` is a ``.json`` file, emit its raw contents (so the
       caller's parse-and-check pipeline surfaces corruption).
    2. If a sibling 2.0 ``execution-plan.yaml`` is found at ``target`` or
       its ancestors, emit ``project.deferred[]`` as JSON.
    3. Else fall back to a sibling ``deferred-findings.json``; finally
       ``docs/grinder/deferred-findings.json``; finally ``[]``.
    """
    if not argv:
        print("usage: plan_yaml_deferred dump -- <plan-or-dir>", file=sys.stderr)
        return 2
    raw = argv[0]
    try:
        target = _validate_dump_path(raw)
    except SecurityError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2

    # 1. Direct .json target: emit verbatim. Caller's jq checks will catch
    # corruption.
    if target.is_file() and target.suffix == ".json":
        if target.stat().st_size > MAX_JSON_SIZE:
            print(
                f"ERROR: file exceeds size limit ({target.stat().st_size} > {MAX_JSON_SIZE}): {target}",
                file=sys.stderr,
            )
            return 2
        contents = target.read_text()
        sys.stdout.write(contents)
        if not contents.endswith("\n"):
            sys.stdout.write("\n")
        return 0

    # 2. YAML/colocated 2.0 plan.
    plan_path = target if target.is_file() else find_colocated_plan(target)
    if plan_path and detect_plan_version(plan_path) == "2.0":
        try:
            entries = read_deferred(plan_path)
        except LegacyPlanError:
            entries = []
        json.dump(entries, sys.stdout)
        sys.stdout.write("\n")
        return 0

    # 3. Sibling deferred-findings.json fallback.
    json_fallback = (target if target.is_dir() else target.parent) / "deferred-findings.json"
    if not json_fallback.exists():
        json_fallback = Path("docs/grinder/deferred-findings.json")
    if json_fallback.exists():
        contents = json_fallback.read_text()
        sys.stdout.write(contents)
        if not contents.endswith("\n"):
            sys.stdout.write("\n")
        return 0
    sys.stdout.write("[]\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    args = list(argv if argv is not None else sys.argv[1:])
    if not args:
        print(
            "usage: plan_yaml_deferred {dump} -- <plan-or-dir>",
            file=sys.stderr,
        )
        return 2
    cmd, rest = args[0], args[1:]
    if "--" in rest:
        rest = rest[rest.index("--") + 1 :]
    if cmd == "dump":
        return _cli_dump(rest)
    if cmd in ("--help", "-h", "help"):
        print(__doc__)
        return 0
    print(f"ERROR: unknown command {cmd!r}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
