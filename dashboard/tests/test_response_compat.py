"""Byte-equivalent response baseline harness for the dashboard FastAPI app.

After fastapi-cutover (T0.3) the harness asserts FastAPI byte equivalence
only; the stdlib launcher half was deleted because ``dashboard/serve.py``
is tombstoned. The 22 committed fixtures continue to drive the assertion.

Interfaces:

* **Capture CLI** — ``python3 dashboard/tests/test_response_compat.py
  capture --server-url <url>`` probes a live server, hits every endpoint
  declared in ``MANIFEST``, and writes 22 JSON fixtures to
  ``dashboard/tests/fixtures/response-baseline/``. Operators must point
  at an external server explicitly (e.g., a uvicorn instance launched
  via ``test-fastapi-integration.sh`` on port 8798); the
  hermetically-spawned stdlib subprocess that previously backed the
  default URL was deleted with the cutover.

* **Pytest replay** — ``pytest dashboard/tests/test_response_compat.py``
  spawns the FastAPI app via ``uvicorn`` on ``127.0.0.1:8798``, replays
  the manifest, and asserts byte-for-byte equality against the committed
  fixtures.

Per-batch invocation uses ``DASHBOARD_RESPONSE_COMPAT_ENDPOINTS`` to scope
the assertion to a CSV path subset. Unknown paths in the filter cause a
session-startup failure BEFORE any uvicorn subprocess spawns.

Open-question resolutions live in PLAN.md; load-bearing choices include
OQ#1 (capture HTML 4xx as-is — Option A), OQ#2 (do NOT modify run-all.sh —
Option B), OQ#5 (uvicorn subprocess, not TestClient).
"""

from __future__ import annotations

import argparse
import atexit
import base64
import contextlib
import difflib
import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
from collections.abc import Iterator
from pathlib import Path
from typing import NamedTuple

import pytest

# ---------------------------------------------------------------------------
# Module-level constants — all tunable values and load-bearing strings live
# here so that consumers reference them by name, not by literal.
# ---------------------------------------------------------------------------

# Stdlib server probed by capture mode.
_STDLIB_BASE_URL: str = "http://127.0.0.1:8787"
_STDLIB_HEALTH_PATH: str = "/health"

# FastAPI replay subprocess.
_TEST_HOST: str = "127.0.0.1"
_TEST_PORT: int = 8798
_HEALTH_DEADLINE_SECONDS: float = 10.0
_HEALTH_POLL_INTERVAL_SECONDS: float = 0.2
_TEARDOWN_GRACE_SECONDS: float = 5.0

# Reachability probe (capture mode).
_PROBE_RETRIES: int = 5
_PROBE_BACKOFF_SECONDS: float = 1.0
_PROBE_TIMEOUT_SECONDS: float = 2.0

# Filter env-var name (single source — referenced by C8, C12, C14).
_FILTER_ENV_VAR: str = "DASHBOARD_RESPONSE_COMPAT_ENDPOINTS"

# Fixture schema — required keys validated by both writer (C5) and loader
# (C7). Adding a field requires editing this constant only.
_FIXTURE_REQUIRED_FIELDS: tuple[str, ...] = (
    "slug",
    "method",
    "path",
    "query",
    "status",
    "content_type",
    "body_encoding",
    "body",
)
_FIXTURE_VALID_BODY_ENCODINGS: frozenset[str] = frozenset({"utf-8", "base64"})

# Diagnostic truncation threshold for body diff output.
_DIFF_TRUNCATE_BYTES: int = 2048

# Resolved at import: the fixture directory committed in this repo.
FIXTURE_DIR: Path = (
    Path(__file__).resolve().parents[2] / "dashboard" / "tests" / "fixtures" / "response-baseline"
)

# Hermetic test data — committed templates rendered into a runtime tree at
# capture/replay time so fixtures are byte-stable regardless of operator
# data state, worktree, or wall-clock time.
HERMETIC_TEMPLATE_DIR: Path = (
    Path(__file__).resolve().parents[2] / "dashboard" / "tests" / "fixtures" / "data"
)
_HERMETIC_RUNTIME_DIRNAME: str = ".dashboard-hermetic-rt"

# Placeholders written into committed fixtures in place of runtime-specific
# absolute paths. Keys MUST be ordered most-specific-first when applied —
# substring overlap matters (alpha sub-path contains projects-root).
_HERMETIC_PLACEHOLDERS: tuple[tuple[str, str], ...] = (
    ("alpha_root", "__HERMETIC_HOME__"),
    ("data_dir", "__HERMETIC_DATA_DIR__"),
    ("projects_root", "__HERMETIC_PROJECTS_ROOT__"),
    ("runtime_root", "__HERMETIC_RUNTIME_ROOT__"),
)


# ---------------------------------------------------------------------------
# C1 — MANIFEST: 22 endpoint specs, single source of truth.
# ---------------------------------------------------------------------------


class EndpointSpec(NamedTuple):
    slug: str
    method: str
    path: str
    query_template: str


MANIFEST: tuple[EndpointSpec, ...] = (
    EndpointSpec("api-flow-status", "GET", "/api/flow-status", "cwd={HOME}"),
    EndpointSpec("api-worktrees", "GET", "/api/worktrees", "cwd={HOME}"),
    EndpointSpec("api-plan", "GET", "/api/plan", "cwd={HOME}"),
    EndpointSpec("api-plans", "GET", "/api/plans", ""),
    EndpointSpec("api-sessions", "GET", "/api/sessions", ""),
    EndpointSpec("api-metrics", "GET", "/api/metrics", ""),
    EndpointSpec("api-autopilots", "GET", "/api/autopilots", ""),
    EndpointSpec(
        "api-autopilot-log",
        "GET",
        "/api/autopilot/log",
        "task=zzznonexistent&offset=0",
    ),
    EndpointSpec(
        "api-autopilot-stream",
        "GET",
        "/api/autopilot/stream",
        "task=zzznonexistent&offset=0",
    ),
    EndpointSpec(
        "api-autopilot-summary",
        "GET",
        "/api/autopilot/summary",
        "task=zzznonexistent",
    ),
    EndpointSpec(
        "api-autopilot-artifacts",
        "GET",
        "/api/autopilot/artifacts",
        "task=zzznonexistent",
    ),
    EndpointSpec(
        "api-autopilot-artifact",
        "GET",
        "/api/autopilot/artifact",
        "task=zzznonexistent&file=PLAN.md",
    ),
    EndpointSpec(
        "api-autopilot-activity",
        "GET",
        "/api/autopilot/activity",
        "task=zzznonexistent",
    ),
    EndpointSpec(
        "api-plan-artifacts",
        "GET",
        "/api/plan/artifacts",
        "cwd={HOME}&task=zzznonexistent",
    ),
    EndpointSpec(
        "api-plan-artifact",
        "GET",
        "/api/plan/artifact",
        "file=NONEXISTENT.md",
    ),
    EndpointSpec("api-features", "GET", "/api/features", ""),
    EndpointSpec(
        "api-feature-artifacts",
        "GET",
        "/api/feature/artifacts",
        "feature=zzznonexistent&project_root={HOME}",
    ),
    EndpointSpec(
        "api-feature-artifact",
        "GET",
        "/api/feature/artifact",
        "feature=zzznonexistent&project_root={HOME}&file=PLAN.md",
    ),
    EndpointSpec("api-grinder", "GET", "/api/grinder", ""),
    EndpointSpec(
        "api-grinder-stream",
        "GET",
        "/api/grinder/stream",
        "project=zzznonexistent&offset=0",
    ),
    EndpointSpec(
        "post-api-grinder-pause",
        "POST",
        "/api/grinder/pause",
        "project=zzznonexistent",
    ),
    EndpointSpec(
        "delete-api-grinder-pause",
        "DELETE",
        "/api/grinder/pause",
        "project=zzznonexistent",
    ),
)


# ---------------------------------------------------------------------------
# C3 — _slug: pure derivation of slug from method + path.
# ---------------------------------------------------------------------------


def _slug(method: str, path: str) -> str:
    """Derive the fixture-filename stem from an HTTP method and URL path."""
    stem = path.lstrip("/").replace("/", "-")
    if method.upper() == "GET":
        return stem
    return f"{method.lower()}-{stem}"


# ---------------------------------------------------------------------------
# C6 — _render_query: substitute ``{HOME}`` placeholder.
# ---------------------------------------------------------------------------


def _render_query(template: str, home: str | None = None) -> str:
    """Substitute ``{HOME}`` with ``home`` (default: ``expanduser('~')``).

    No other placeholders are recognised — unknown braces pass through
    unchanged so the harness never silently expands an injected key. The
    ``home`` argument lets the hermetic-env builder pin queries to the
    runtime test tree rather than the operator's real ``$HOME``.
    """
    resolved_home = home if home is not None else os.path.expanduser("~")
    return template.replace("{HOME}", resolved_home)


# ---------------------------------------------------------------------------
# Hermetic environment — render committed templates into a per-process tmp
# tree, expose deterministic ``PROJECTS_ROOT`` / ``DASHBOARD_DATA_DIR`` /
# ``HOME`` paths, and provide path-placeholder normalization so fixtures
# stay byte-stable across operators, worktrees, and wall-clock time.
# ---------------------------------------------------------------------------


class HermeticEnv(NamedTuple):
    """Bundle of paths for the rendered hermetic runtime tree."""

    runtime_root: Path
    projects_root: Path
    alpha_root: Path
    data_dir: Path

    def env_overlay(self) -> dict[str, str]:
        """Return the env-var dict to merge into the child server process."""
        return {
            "PROJECTS_ROOT": str(self.projects_root),
            "DASHBOARD_DATA_DIR": str(self.data_dir),
            "HOME": str(self.alpha_root),
        }

    def normalize(self, body: bytes) -> bytes:
        """Replace runtime-tree paths with stable placeholders.

        Order matters: longest/most-specific path first so a parent
        substitution does not shadow a child match. Applied to BOTH the
        captured body (before fixture write) and the live response body
        (before diff) — keeps fixtures byte-stable across machines.
        """
        path_map = {
            "alpha_root": str(self.alpha_root),
            "data_dir": str(self.data_dir),
            "projects_root": str(self.projects_root),
            "runtime_root": str(self.runtime_root),
        }
        out = body
        for key, placeholder in _HERMETIC_PLACEHOLDERS:
            target = path_map[key].encode("utf-8")
            out = out.replace(target, placeholder.encode("utf-8"))
        return out


# Resolved ONCE at import. `Path.home()` reads the live ``$HOME`` env var,
# which tests routinely mutate via monkeypatch — pinning the result here
# guarantees the runtime root stays at a stable, non-``/tmp`` location
# regardless of subsequent operator-env mutations.
_HERMETIC_RUNTIME_ROOT_DEFAULT: Path = (
    Path(os.environ.get("XDG_CACHE_HOME") or str(Path.home() / ".cache"))
    / _HERMETIC_RUNTIME_DIRNAME
)


def _hermetic_runtime_root() -> Path:
    """Return the hermetic runtime root.

    Uses ``$XDG_CACHE_HOME`` (default ``~/.cache``) instead of ``$TMPDIR``
    because the dashboard server-side filters anything containing
    ``/tmp/``, ``.test-tmp``, or ``/test-project`` out of session/feature
    discovery (an existing safety filter for noisy test runs). A tmp path
    would silently produce empty discovery results and yield identical-
    yet-empty fixtures across runs — passing the byte-equivalence check
    for the wrong reason. The path is resolved at import time so later
    ``monkeypatch.setenv('HOME', ...)`` calls do not move the runtime
    tree out from under an in-flight test.
    """
    return _HERMETIC_RUNTIME_ROOT_DEFAULT


def _build_hermetic_env(
    *,
    template_dir: Path = HERMETIC_TEMPLATE_DIR,
    runtime_root: Path | None = None,
) -> HermeticEnv:
    """Render the committed template tree into ``runtime_root`` and return it.

    Idempotent — wipes any pre-existing tree before re-rendering. The
    rendered tree contains:

    - ``projects-root/alpha/`` initialized as a git repo (so plan-helpers'
      ``git worktree list`` resolution succeeds).
    - ``dashboard-data/sessions.jsonl`` with template placeholders
      (``__PROJECTS_ROOT__``) substituted for the runtime ``projects_root``.
    """
    if not template_dir.is_dir():
        raise FileNotFoundError(
            f"hermetic template directory missing: {template_dir} — "
            f"committed test data must accompany the harness"
        )
    target_root = runtime_root if runtime_root is not None else _hermetic_runtime_root()

    # EC: wipe any prior tree (different test sessions may leave stale state).
    if target_root.exists():
        import shutil

        shutil.rmtree(target_root)
    target_root.mkdir(parents=True, exist_ok=True)

    # Mirror the template tree (skip *.template files — handled below).
    import shutil

    for src in template_dir.rglob("*"):
        rel = src.relative_to(template_dir)
        dst = target_root / rel
        if src.is_dir():
            dst.mkdir(parents=True, exist_ok=True)
            continue
        if src.name.endswith(".template"):
            continue
        dst.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(src, dst)

    projects_root = target_root / "projects-root"
    alpha_root = projects_root / "alpha"
    data_dir = target_root / "dashboard-data"

    # Render sessions.jsonl from template — substitute __PROJECTS_ROOT__
    # with the runtime path. Other placeholders may be added later.
    template_path = template_dir / "dashboard-data" / "sessions.jsonl.template"
    if template_path.is_file():
        rendered = template_path.read_text(encoding="utf-8")
        rendered = rendered.replace("__PROJECTS_ROOT__", str(projects_root))
        (data_dir / "sessions.jsonl").write_text(rendered, encoding="utf-8")

    # Pin every rendered file's mtime to a known epoch so endpoints that
    # surface filesystem mtime (e.g., /api/plans' ``last_activity``)
    # produce deterministic output across captures.
    pinned_epoch = 1704067200  # 2024-01-01T00:00:00Z
    for path in target_root.rglob("*"):
        if path.is_file():
            os.utime(path, (pinned_epoch, pinned_epoch))

    # Initialize alpha as a git repo so plan-helpers' worktree resolution
    # picks it up. Quiet, deterministic — no commits, just an empty repo.
    alpha_root.mkdir(parents=True, exist_ok=True)
    git_init_proc = subprocess.run(
        [
            "git",
            "-c",
            "init.defaultBranch=main",
            "-C",
            str(alpha_root),
            "init",
            "--quiet",
        ],
        capture_output=True,
        text=True,
        timeout=10,
    )
    if git_init_proc.returncode != 0:
        raise RuntimeError(
            f"git init failed in hermetic alpha root: {git_init_proc.stderr.strip()}"
        )

    return HermeticEnv(
        runtime_root=target_root,
        projects_root=projects_root,
        alpha_root=alpha_root,
        data_dir=data_dir,
    )


# ---------------------------------------------------------------------------
# C8 — _parse_endpoint_filter: parse the env-var into a path filter set.
# ---------------------------------------------------------------------------


def _parse_endpoint_filter(env_value: str | None) -> set[str] | None:
    """Parse the value of ``_FILTER_ENV_VAR`` into a path-set or ``None``.

    Returns ``None`` for unset / empty / whitespace-only inputs (means
    "assert all 22"). Returns a set of canonical paths otherwise; raises
    ``ValueError`` if any post-trim entry is not in ``MANIFEST``.
    """
    if env_value is None:
        return None
    stripped = env_value.strip()
    if not stripped:
        return None

    known_paths = {spec.path for spec in MANIFEST}
    parsed: set[str] = set()
    for raw in stripped.split(","):
        path = raw.strip()
        if not path:
            continue
        if path not in known_paths:
            raise ValueError(f"unknown manifest path: {path!r} (env var {_FILTER_ENV_VAR})")
        parsed.add(path)
    return parsed


# ---------------------------------------------------------------------------
# C11 — _diff_response: byte-for-byte comparison with truncated diagnostic.
# ---------------------------------------------------------------------------


def _decode_fixture_body(fixture: dict) -> bytes:
    """Decode a fixture's ``body`` field into raw bytes by encoding."""
    encoding = fixture.get("body_encoding", "utf-8")
    body: str = fixture["body"]
    if encoding == "base64":
        return base64.b64decode(body)
    return body.encode("utf-8")


def _diff_response(
    fixture: dict,
    actual_status: int,
    actual_body: bytes,
) -> str | None:
    """Compare a captured fixture to a live response.

    Returns ``None`` if status AND body match. Otherwise returns a
    formatted diagnostic capped at ``_DIFF_TRUNCATE_BYTES`` bytes.
    Content-Type is intentionally NOT diffed (informational only).
    """
    expected_bytes = _decode_fixture_body(fixture)
    expected_status = fixture["status"]
    slug = fixture.get("slug", "<unknown-slug>")

    status_match = actual_status == expected_status
    body_match = actual_body == expected_bytes
    if status_match and body_match:
        return None

    parts: list[str] = [f"slug={slug}"]
    if not status_match:
        parts.append(f"status: expected {expected_status} / actual {actual_status}")

    if not body_match:
        if fixture.get("body_encoding") == "base64":
            divergence = _first_divergence(expected_bytes, actual_body)
            parts.append(
                "body (binary): "
                f"expected_len={len(expected_bytes)} actual_len={len(actual_body)} "
                f"first_divergence_byte={divergence}"
            )
        else:
            try:
                expected_text = expected_bytes.decode("utf-8")
                actual_text = actual_body.decode("utf-8")
                diff = "\n".join(
                    difflib.unified_diff(
                        expected_text.splitlines(keepends=True),
                        actual_text.splitlines(keepends=True),
                        fromfile="expected",
                        tofile="actual",
                        n=2,
                    )
                )
                if diff:
                    parts.append("body diff:\n" + diff)
                else:
                    divergence = _first_divergence(expected_bytes, actual_body)
                    parts.append(
                        "body bytes diverge "
                        f"(expected_len={len(expected_bytes)} "
                        f"actual_len={len(actual_body)} "
                        f"first_divergence_byte={divergence})"
                    )
            except UnicodeDecodeError:
                divergence = _first_divergence(expected_bytes, actual_body)
                parts.append(f"body (non-utf8): first_divergence_byte={divergence}")

    raw = "\n".join(parts)
    if len(raw) > _DIFF_TRUNCATE_BYTES:
        truncated = raw[:_DIFF_TRUNCATE_BYTES]
        divergence = _first_divergence(expected_bytes, actual_body)
        return f"{truncated}\n... (truncated, divergence at byte {divergence})"
    return raw


def _first_divergence(a: bytes, b: bytes) -> int:
    """Return the byte index where ``a`` and ``b`` first differ."""
    for i, (x, y) in enumerate(zip(a, b, strict=False)):
        if x != y:
            return i
    return min(len(a), len(b))


# ---------------------------------------------------------------------------
# C7 — _load_fixtures: parse + validate every fixture JSON file.
# ---------------------------------------------------------------------------


def _load_fixtures(fixture_dir: Path) -> dict[str, dict]:
    """Load every ``<slug>.json`` file under ``fixture_dir``.

    Raises ``FileNotFoundError`` if the directory is missing or contains
    no ``*.json`` files. Raises ``RuntimeError`` if any file is malformed
    (unparseable JSON, missing required field, wrong type, unknown
    body_encoding). Strict-fail: short-circuits on first failure, never
    returns a partial dict.
    """
    if not fixture_dir.exists() or not fixture_dir.is_dir():
        raise FileNotFoundError(
            f"empty baseline fixture directory: {fixture_dir} does not exist; "
            f"run capture mode against the running stdlib server first"
        )
    json_files = sorted(fixture_dir.glob("*.json"))
    if not json_files:
        raise FileNotFoundError(
            f"empty baseline fixture directory: {fixture_dir} has no *.json files; "
            f"run capture mode against the running stdlib server first"
        )

    out: dict[str, dict] = {}
    for path in json_files:
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as exc:
            raise RuntimeError(f"malformed fixture {path.name}: JSON parse error: {exc}") from exc

        if not isinstance(data, dict):
            raise RuntimeError(
                f"malformed fixture {path.name}: expected JSON object, got {type(data).__name__}"
            )

        for field in _FIXTURE_REQUIRED_FIELDS:
            if field not in data:
                raise RuntimeError(
                    f"malformed fixture {path.name}: missing required field {field!r}"
                )

        if not isinstance(data["status"], int) or isinstance(data["status"], bool):
            raise RuntimeError(
                f"malformed fixture {path.name}: 'status' must be int, got "
                f"{type(data['status']).__name__}"
            )
        if data["body_encoding"] not in _FIXTURE_VALID_BODY_ENCODINGS:
            raise RuntimeError(
                f"malformed fixture {path.name}: 'body_encoding' must be one of "
                f"{sorted(_FIXTURE_VALID_BODY_ENCODINGS)}, got {data['body_encoding']!r}"
            )

        out[data["slug"]] = data
    return out


# ---------------------------------------------------------------------------
# C10 — _silent_log_config_path: writes a uvicorn dictConfig that silences
# the access + error loggers, returns its temp-file path.
# ---------------------------------------------------------------------------


def _silent_log_config_path() -> Path:
    """Write a JSON dictConfig file that silences uvicorn loggers to WARNING."""
    config = {
        "version": 1,
        "disable_existing_loggers": False,
        "loggers": {
            "uvicorn": {"level": "WARNING"},
            "uvicorn.access": {"level": "WARNING"},
            "uvicorn.error": {"level": "WARNING"},
        },
    }
    tmp = tempfile.NamedTemporaryFile(
        mode="w",
        suffix=".json",
        delete=False,
        encoding="utf-8",
    )
    json.dump(config, tmp)
    tmp.close()
    path = Path(tmp.name)

    def _cleanup(p: Path = path) -> None:
        p.unlink(missing_ok=True)

    atexit.register(_cleanup)
    return path


# ---------------------------------------------------------------------------
# C4 — _probe_health: TCP-reachability probe with retry/backoff.
# ---------------------------------------------------------------------------


def _probe_health(
    url: str,
    *,
    timeout: float = _PROBE_TIMEOUT_SECONDS,
    retries: int = _PROBE_RETRIES,
    backoff: float = _PROBE_BACKOFF_SECONDS,
) -> None:
    """Issue ``GET <url>`` and treat any HTTP response as success.

    Retries up to ``retries`` times with ``backoff`` sleep between
    attempts. Raises ``RuntimeError`` (with the URL and underlying error)
    if every attempt fails at the TCP/socket layer.
    """
    last_error: BaseException | None = None
    for attempt in range(1, retries + 1):
        try:
            with urllib.request.urlopen(url, timeout=timeout) as resp:
                resp.read()  # drain — any HTTP response = alive
            return
        except urllib.error.HTTPError:
            return  # 4xx / 5xx = TCP-alive per OQ#3
        except (TimeoutError, urllib.error.URLError, OSError) as exc:
            last_error = exc
            sys.stderr.write(
                f"_probe_health: attempt {attempt}/{retries} failed for {url}: "
                f"{type(exc).__name__}: {exc}\n"
            )
            if attempt < retries:
                time.sleep(backoff)
    raise RuntimeError(
        f"_probe_health: {url} unreachable after {retries} attempts: "
        f"{type(last_error).__name__}: {last_error}"
    )


# ---------------------------------------------------------------------------
# C5 — _capture: orchestrate the capture phase against the live stdlib.
# ---------------------------------------------------------------------------


def _is_text_content_type(content_type: str) -> bool:
    """Return True iff body bytes safely round-trip via UTF-8."""
    ct = content_type.lower()
    return ct.startswith("text/") or "application/json" in ct


def _request_endpoint(
    server_url: str,
    spec: EndpointSpec,
    rendered_query: str,
    *,
    timeout: float = 5.0,
) -> tuple[int, bytes, str]:
    """Issue one HTTP request from the manifest. Returns (status, body, ct).

    ``rendered_query`` is the post-substitution query string (callers own the
    template render so the same string lands in the URL and the fixture
    payload — a single source of truth for what was actually sent).
    """
    url = server_url + spec.path
    if rendered_query:
        url += "?" + rendered_query
    request = urllib.request.Request(url, method=spec.method)
    try:
        with urllib.request.urlopen(request, timeout=timeout) as resp:
            body = resp.read()
            return resp.status, body, resp.headers.get("Content-Type", "")
    except urllib.error.HTTPError as exc:
        body = exc.read() or b""
        return exc.code, body, exc.headers.get("Content-Type", "") if exc.headers else ""


def _capture(
    server_url: str,
    fixture_dir: Path,
    hermetic: HermeticEnv | None = None,
) -> None:
    """Probe reachability, then write 22 fixtures atomically.

    Truncates pre-existing ``*.json`` files before writing (EC-3.1) but
    preserves non-JSON siblings (e.g. ``.gitkeep``). Each fixture is
    written via ``<slug>.json.tmp`` + ``os.replace()`` so a partially
    populated directory is impossible (EC-3.2).

    When ``hermetic`` is provided, query templates are rendered with the
    hermetic ``HOME`` (so cwd-driven queries point inside the runtime
    tree) and response bodies are run through
    ``hermetic.normalize`` before the fixture is written — fixtures-on-disk
    contain placeholders, not runtime ``$TMPDIR`` paths, so they remain
    byte-stable across operators and worktrees.
    """
    _probe_health(
        server_url + _STDLIB_HEALTH_PATH,
        retries=_PROBE_RETRIES,
        backoff=_PROBE_BACKOFF_SECONDS,
        timeout=_PROBE_TIMEOUT_SECONDS,
    )

    fixture_dir.mkdir(parents=True, exist_ok=True)

    # EC-3.1: truncate stale *.json (preserve non-JSON like .gitkeep) plus
    # any orphan .tmp from a prior crashed run.
    for stale in fixture_dir.glob("*.json"):
        stale.unlink()
    for orphan in fixture_dir.glob("*.json.tmp"):
        orphan.unlink()

    home_for_query = str(hermetic.alpha_root) if hermetic is not None else None

    current_slug = "<before-first-spec>"
    try:
        for spec in MANIFEST:
            current_slug = spec.slug
            query = _render_query(spec.query_template, home=home_for_query)
            status, body_bytes, content_type = _request_endpoint(server_url, spec, query)

            if hermetic is not None:
                body_bytes = hermetic.normalize(body_bytes)
                stored_query = hermetic.normalize(query.encode("utf-8")).decode("utf-8")
            else:
                stored_query = query

            if _is_text_content_type(content_type):
                try:
                    body_str = body_bytes.decode("utf-8")
                    body_encoding = "utf-8"
                except UnicodeDecodeError:
                    body_str = base64.b64encode(body_bytes).decode("ascii")
                    body_encoding = "base64"
            else:
                body_str = base64.b64encode(body_bytes).decode("ascii")
                body_encoding = "base64"

            payload = {
                "slug": spec.slug,
                "method": spec.method,
                "path": spec.path,
                "query": stored_query,
                "status": status,
                "content_type": content_type,
                "body_encoding": body_encoding,
                "body": body_str,
            }
            target = fixture_dir / f"{spec.slug}.json"
            tmp = fixture_dir / f"{spec.slug}.json.tmp"
            with tmp.open("w", encoding="utf-8") as fh:
                json.dump(payload, fh, ensure_ascii=False, indent=2)
                fh.flush()
                os.fsync(fh.fileno())
            os.replace(tmp, target)
    except Exception as exc:
        # Cleanup orphan .tmp files on any partial failure.
        for orphan in fixture_dir.glob("*.json.tmp"):
            with contextlib.suppress(OSError):
                orphan.unlink()
        raise RuntimeError(f"capture failed at slug={current_slug!r}: {exc}") from exc


# ---------------------------------------------------------------------------
# After fastapi-cutover (T0.3) the hermetic stdlib launcher
# (``_STDLIB_LAUNCHER_SCRIPT`` / ``_spawn_hermetic_stdlib``) was deleted
# because ``dashboard/serve.py`` is tombstoned and stdlib is no longer a
# substrate. The capture CLI now requires an explicit ``--server-url``
# pointing at any live server (FastAPI on 8798, etc.).
# ---------------------------------------------------------------------------


def _pick_free_port() -> int:
    """Bind to ephemeral port 0 to get a free port; close socket and return it."""
    sock = socket.socket()
    try:
        sock.bind(("127.0.0.1", 0))
        return int(sock.getsockname()[1])
    finally:
        sock.close()


# ---------------------------------------------------------------------------
# C13 / C13b — Module-scoped pytest fixtures: _fixtures + _filter_paths.
# Both validate session-startup state BEFORE the C9 uvicorn subprocess
# spawns; failure modes here surface as a single module-level error.
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def _fixtures() -> dict[str, dict]:
    """Load and validate the committed fixture set (R8 + R9)."""
    try:
        return _load_fixtures(FIXTURE_DIR)
    except (FileNotFoundError, RuntimeError) as exc:
        pytest.fail(str(exc))


@pytest.fixture(scope="module")
def _filter_paths() -> set[str] | None:
    """Parse the filter env-var ONCE per session (R6 — early ValueError)."""
    try:
        return _parse_endpoint_filter(os.environ.get(_FILTER_ENV_VAR))
    except ValueError as exc:
        pytest.fail(str(exc))


# ---------------------------------------------------------------------------
# C9 — _uvicorn_subprocess fixture: spawn FastAPI on _TEST_PORT.
# ---------------------------------------------------------------------------


def _port_in_use(host: str, port: int) -> bool:
    """Return True iff (host, port) has an active listener.

    Uses ``SO_REUSEADDR`` so a TIME_WAIT socket from a recent shutdown is
    NOT treated as "in use" — only an actual live listener triggers True.
    Uvicorn itself binds with SO_REUSEADDR for the same reason.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.settimeout(0.5)
        sock.bind((host, port))
        return False
    except OSError:
        return True
    finally:
        sock.close()


def _poll_health(url: str, deadline: float, interval: float) -> bool:
    """Poll ``GET <url>`` until 200 or deadline. Returns True on success."""
    end = time.monotonic() + deadline
    while time.monotonic() < end:
        try:
            with urllib.request.urlopen(url, timeout=1.0) as resp:
                if resp.status == 200:
                    return True
        except (urllib.error.URLError, urllib.error.HTTPError, OSError):
            pass
        time.sleep(interval)
    return False


@pytest.fixture(scope="module")
def _hermetic_env() -> HermeticEnv:
    """Render the committed template tree once per module.

    Provided as a separate fixture so capture-time + replay-time share
    the exact same hermetic state and so tests that need direct access
    to the runtime paths (env-independence assertions, etc.) can read
    them without re-rendering.
    """
    return _build_hermetic_env()


@pytest.fixture(scope="module")
def _uvicorn_subprocess(
    _fixtures: dict[str, dict],
    _filter_paths: set[str] | None,
    _hermetic_env: HermeticEnv,
) -> Iterator[tuple[str, int]]:
    """Spawn ``uvicorn dashboard.server.app:app`` on ``_TEST_PORT``.

    Depends on ``_fixtures``, ``_filter_paths``, and ``_hermetic_env`` so
    that R8/R9/R6 failures fire BEFORE this fixture is entered (no orphan
    subprocess on misconfigured runs) AND so the uvicorn child sees the
    same ``PROJECTS_ROOT`` / ``DASHBOARD_DATA_DIR`` / ``HOME`` that the
    fixture-capture saw — keeps replays env-independent of operator data.
    """
    if _port_in_use(_TEST_HOST, _TEST_PORT):
        raise RuntimeError(
            f"port {_TEST_PORT} already bound; run 'lsof -i :{_TEST_PORT}' to identify the holder"
        )

    log_config = _silent_log_config_path()
    repo_root = Path(__file__).resolve().parents[2]

    # PYTHONPATH=REPO_ROOT makes `from dashboard.server.X` resolve in the
    # uvicorn subprocess. The legacy `from server.X` style was removed from
    # the codebase 2026-05-23 (import-style refactor); we no longer need
    # `dashboard/` on the subprocess path.
    env = {
        **os.environ,
        **_hermetic_env.env_overlay(),
        "DASHBOARD_LOG_CONFIG_OPT_OUT": "1",
        "PYTHONPATH": str(repo_root),
    }

    try:
        process = subprocess.Popen(
            [
                sys.executable,
                "-m",
                "uvicorn",
                "dashboard.server.app:app",
                "--host",
                _TEST_HOST,
                "--port",
                str(_TEST_PORT),
                "--log-config",
                str(log_config),
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            env=env,
        )
    except FileNotFoundError as exc:
        raise RuntimeError(
            f"uvicorn not on PATH: {exc}. run 'uv sync --extra dev' to provision dev dependencies"
        ) from exc

    health_url = f"http://{_TEST_HOST}:{_TEST_PORT}/health"
    if not _poll_health(
        health_url,
        deadline=_HEALTH_DEADLINE_SECONDS,
        interval=_HEALTH_POLL_INTERVAL_SECONDS,
    ):
        # Drain stderr non-blockingly for the diagnostic. We terminate the
        # subprocess first; once it exits, stderr has flushed and `read()`
        # returns the buffered output without blocking. Do NOT pre-close
        # stderr — that triggers `ValueError: read of closed file` in the
        # diagnostic path below (which only suppressed OSError, not
        # ValueError) and lost every uvicorn startup error message.
        stderr_text = ""
        try:
            process.terminate()
            try:
                process.wait(timeout=1.0)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1.0)
        finally:
            if process.stderr is not None:
                with contextlib.suppress(OSError, ValueError):
                    stderr_text = process.stderr.read().decode("utf-8", errors="replace")
        raise RuntimeError(
            f"FastAPI failed to start within {_HEALTH_DEADLINE_SECONDS}s "
            f"on {health_url}\n--- uvicorn stderr ---\n{stderr_text}"
        )

    try:
        yield (_TEST_HOST, _TEST_PORT)
    finally:
        process.terminate()
        try:
            process.wait(timeout=_TEARDOWN_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            process.kill()
            try:
                process.wait(timeout=_TEARDOWN_GRACE_SECONDS)
            except subprocess.TimeoutExpired:
                pass
        if process.stderr is not None:
            with contextlib.suppress(OSError):
                process.stderr.close()


# ---------------------------------------------------------------------------
# C2 — Manifest-vs-dispatch sanity test (lazy import).
# ---------------------------------------------------------------------------


@pytest.mark.skip(
    reason=(
        "dashboard.serve was tombstoned at fastapi-cutover (commit dacc79b); "
        "the three dispatch dicts no longer exist. Manifest drift is now "
        "detected by the byte-equivalence replay against the live FastAPI "
        "subprocess (test_response_compat above), which is a stricter check."
    )
)
def test_manifest_matches_dispatch() -> None:
    """T-C1-02 (R1, EC-1.1): MANIFEST equals serve.py's three dispatch dicts.

    Lazy-imports ``dashboard.serve`` inside the test body so that any
    future import-time side effects in ``serve.py`` do not fire when the
    pure-function unit tests in this module are collected.
    """
    import dashboard.serve as serve  # noqa: PLC0415 — lazy by design

    expected_pairs: set[tuple[str, str]] = set()
    for path in serve.ROUTES:
        expected_pairs.add(("GET", path))
    for path in serve.POST_ROUTES:
        expected_pairs.add(("POST", path))
    for path in serve.DELETE_ROUTES:
        expected_pairs.add(("DELETE", path))

    actual_pairs = {(spec.method, spec.path) for spec in MANIFEST}
    assert actual_pairs == expected_pairs, (
        f"manifest drift: only-in-manifest={actual_pairs - expected_pairs}, "
        f"only-in-serve={expected_pairs - actual_pairs}"
    )


# ---------------------------------------------------------------------------
# C12 — Parametrized replay test against the FastAPI subprocess.
# Until the three port batches land, every case is expected to fail with
# FastAPI's default 404 ``{"detail":"Not Found"}`` (R7 pre-port red state).
# ---------------------------------------------------------------------------


def _csrf_preflight_token(host: str, port: int) -> str:
    # Issue GET /health against the live uvicorn subprocess and parse the
    # csrf_token cookie value out of the Set-Cookie header. The middleware
    # always sets the cookie on the first GET of a fresh session, so the
    # response carries a fresh 43-char base64url token regardless of which
    # endpoint the caller will subsequently POST/DELETE.
    url = f"http://{host}:{port}/health"
    with urllib.request.urlopen(urllib.request.Request(url, method="GET"), timeout=5.0) as resp:
        set_cookies = resp.headers.get_all("Set-Cookie") or []
    for header in set_cookies:
        if "csrf_token=" in header:
            return str(header.split("csrf_token=", 1)[1].split(";", 1)[0])
    raise RuntimeError("CSRFMiddleware did not issue a csrf_token cookie on /health")


@pytest.mark.parametrize("spec", list(MANIFEST), ids=lambda s: s.slug)
def test_response_compat(
    spec: EndpointSpec,
    _uvicorn_subprocess: tuple[str, int],
    _fixtures: dict[str, dict],
    _filter_paths: set[str] | None,
    _hermetic_env: HermeticEnv,
) -> None:
    """Replay one manifest entry against the FastAPI subprocess.

    R5 (byte-for-byte status + body), R6 (filter scoping with explicit
    skip reason), R7 (default invocation asserts all 22 — fails loudly
    pre-port). Live response bytes are normalized via
    ``_hermetic_env.normalize`` before diffing so that runtime ``$TMPDIR``
    paths in the body match the placeholders committed in the fixture.
    """
    if _filter_paths is not None and spec.path not in _filter_paths:
        pytest.skip(f"excluded by {_FILTER_ENV_VAR}")

    fixture = _fixtures.get(spec.slug)
    assert fixture is not None, f"fixture missing for slug {spec.slug!r} — re-run capture mode"

    host, port = _uvicorn_subprocess
    query = _render_query(spec.query_template, home=str(_hermetic_env.alpha_root))
    url = f"http://{host}:{port}{spec.path}"
    if query:
        url += "?" + query

    request = urllib.request.Request(url, method=spec.method)
    if spec.method != "GET":
        # CSRFMiddleware (fastapi-csrf-middleware, R4) requires a valid
        # double-submit token on every unsafe-method request. Acquire one
        # from a GET /health preflight so the replay reaches the route
        # handler whose byte-equivalent fixture we're asserting against.
        # OriginMiddleware (fastapi-origin-and-schemas, R3) requires an
        # allowed Origin header on unsafe methods; without it the request
        # 403s before CSRF or the route handler ever runs.
        token = _csrf_preflight_token(host, port)
        request.add_header("Cookie", f"csrf_token={token}")
        request.add_header("X-CSRF-Token", token)
        request.add_header("Origin", f"http://{host}:8787")
    try:
        with urllib.request.urlopen(request, timeout=5.0) as resp:
            actual_status = resp.status
            actual_body = resp.read()
    except urllib.error.HTTPError as exc:
        actual_status = exc.code
        actual_body = exc.read() or b""

    actual_body = _hermetic_env.normalize(actual_body)
    diag = _diff_response(fixture, actual_status, actual_body)
    assert diag is None, diag


# ---------------------------------------------------------------------------
# Capture-mode env-independence tests were deleted at fastapi-cutover (T0.3)
# along with the hermetic stdlib launcher they exercised. Equivalent
# byte-equivalence guarantees now flow through the FastAPI replay tests
# below (parametrized over the same 22-fixture manifest).
# ---------------------------------------------------------------------------


# ---------------------------------------------------------------------------
# C14 — CLI __main__ entry-point.
# ---------------------------------------------------------------------------


def _build_arg_parser() -> argparse.ArgumentParser:
    """Construct the argparse hierarchy with ``capture`` and ``replay`` subcommands."""
    parser = argparse.ArgumentParser(
        prog="test_response_compat",
        description=(
            "Capture or replay the dashboard response baseline against "
            "the stdlib serve.py (capture) or the FastAPI app (replay)."
        ),
    )
    sub = parser.add_subparsers(dest="command", required=True)

    capture_parser = sub.add_parser(
        "capture",
        help="Probe stdlib serve.py and write 22 fixtures.",
    )
    capture_parser.add_argument(
        "--server-url",
        default=_STDLIB_BASE_URL,
        help=f"Base URL of the stdlib server (default: {_STDLIB_BASE_URL}).",
    )
    capture_parser.add_argument(
        "--fixture-dir",
        default=str(FIXTURE_DIR),
        help=f"Output directory (default: {FIXTURE_DIR}).",
    )

    replay_parser = sub.add_parser(
        "replay",
        help="Run the pytest replay in a child process (env-var filter).",
    )
    replay_parser.add_argument(
        "--endpoints",
        default="",
        help=f"CSV of paths to assert (sets {_FILTER_ENV_VAR} in the child).",
    )

    return parser


def _main(argv: list[str] | None = None) -> int:
    """CLI entry-point for ``capture`` and ``replay`` subcommands."""
    parser = _build_arg_parser()
    args = parser.parse_args(argv)

    if args.command == "capture":
        # After fastapi-cutover (T0.3) the hermetic stdlib launcher was
        # deleted; capture mode now requires the operator to point at any
        # live server explicitly via --server-url (e.g., a uvicorn
        # instance launched via test-fastapi-integration.sh on 8798).
        try:
            _capture(args.server_url, Path(args.fixture_dir))
        except RuntimeError as exc:
            sys.stderr.write(f"capture failed: {exc}\n")
            return 1
        except OSError as exc:
            sys.stderr.write(f"capture I/O failure: {exc}\n")
            return 1
        return 0

    if args.command == "replay":
        env = {**os.environ, _FILTER_ENV_VAR: args.endpoints or ""}
        return subprocess.call(
            [sys.executable, "-m", "pytest", "-x", __file__],
            env=env,
        )

    parser.error(f"unknown command: {args.command!r}")
    return 2


# ---------------------------------------------------------------------------
# C14 unit tests — argparse + capture/replay subcommand wiring.
# ---------------------------------------------------------------------------


def test_argparse_defaults() -> None:
    """T-C14-04 (R3): capture defaults match the documented values."""
    parser = _build_arg_parser()
    args = parser.parse_args(["capture"])
    assert args.server_url == _STDLIB_BASE_URL
    assert args.fixture_dir == str(FIXTURE_DIR)


def test_argparse_capture_overrides() -> None:
    """T-C14-03 (R3): ``--fixture-dir`` and ``--server-url`` overrides parse."""
    parser = _build_arg_parser()
    args = parser.parse_args(
        ["capture", "--server-url", "http://h/", "--fixture-dir", "/tmp/x"],
    )
    assert args.server_url == "http://h/"
    assert args.fixture_dir == "/tmp/x"


def test_argparse_replay_endpoints() -> None:
    """T-C14-08 (OQ#4): replay subcommand accepts ``--endpoints``."""
    parser = _build_arg_parser()
    args = parser.parse_args(["replay", "--endpoints", "/api/sessions"])
    assert args.endpoints == "/api/sessions"


def test_main_capture_unreachable_returns_1(tmp_path: Path) -> None:
    """T-C14-02 (R2, AS-2): unreachable server → exit 1."""
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    free_port = sock.getsockname()[1]
    sock.close()
    rc = _main(
        [
            "capture",
            "--server-url",
            f"http://127.0.0.1:{free_port}",
            "--fixture-dir",
            str(tmp_path),
        ],
    )
    assert rc == 1


def test_main_replay_passes_env_to_child(monkeypatch: pytest.MonkeyPatch) -> None:
    """T-C14-05 (OQ#4, R6): replay subcommand sets _FILTER_ENV_VAR in child env;
    parent ``os.environ`` is preserved.
    """
    parent_initial = os.environ.get(_FILTER_ENV_VAR)
    captured_env: dict[str, str] = {}

    def fake_call(_args: list[str], *, env: dict[str, str]) -> int:
        captured_env.update(env)
        return 0

    monkeypatch.setattr(
        sys.modules[_main.__module__].subprocess,
        "call",
        fake_call,
    )

    rc = _main(["replay", "--endpoints", "/api/sessions"])
    assert rc == 0
    assert captured_env.get(_FILTER_ENV_VAR) == "/api/sessions"
    # Parent process env is unchanged.
    assert os.environ.get(_FILTER_ENV_VAR) == parent_initial


def test_main_replay_propagates_child_exit_code(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """T-C14-06 (OQ#4): replay returns the child pytest exit code."""

    def fake_call(_args: list[str], *, env: dict[str, str]) -> int:
        return 42

    monkeypatch.setattr(
        sys.modules[_main.__module__].subprocess,
        "call",
        fake_call,
    )
    rc = _main(["replay"])
    assert rc == 42


def test_main_unknown_subcommand_errors() -> None:
    """T-C14-07 (OQ#4): unknown subcommand exits non-zero via argparse."""
    with pytest.raises(SystemExit) as exc_info:
        _main(["unknown-command"])
    assert exc_info.value.code != 0


# ---------------------------------------------------------------------------
# C9 unit tests — port-collision and uvicorn-PATH guard.
# ---------------------------------------------------------------------------


def test_port_in_use_helper_detects_bound_socket() -> None:
    """T-C9-02 helper coverage: ``_port_in_use`` returns True when bound."""
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    sock.listen(1)
    port = sock.getsockname()[1]
    try:
        assert _port_in_use("127.0.0.1", port) is True
    finally:
        sock.close()
    assert _port_in_use("127.0.0.1", port) is False


# ---------------------------------------------------------------------------
# C13 / C13b fixture-wiring tests — exercise the ``pytest.fail`` wiring
# directly by invoking the fixture functions on a synthetic dir / env.
# ---------------------------------------------------------------------------


def _resolve_fixture_callable(fixture: object) -> object:
    """Pytest fixtures are wrapped in FixtureFunctionMarker; unwrap to the function."""
    if hasattr(fixture, "__wrapped__"):
        return fixture.__wrapped__
    if hasattr(fixture, "__pytest_wrapped__"):
        return fixture.__pytest_wrapped__.obj
    return fixture


def test_fixtures_fixture_fails_on_empty_dir(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """T-C13-01 / T-C13-04 (R8, AS-6): empty FIXTURE_DIR → pytest.fail (no return)."""
    monkeypatch.setattr(
        sys.modules[_load_fixtures.__module__],
        "FIXTURE_DIR",
        tmp_path,
    )
    fn = _resolve_fixture_callable(_fixtures)
    with pytest.raises(pytest.fail.Exception) as exc_info:
        fn()  # type: ignore[operator]
    assert "empty baseline fixture directory" in str(exc_info.value)


def test_filter_paths_fixture_fails_on_unknown(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """T-C13b-01 (R6, AS-5): unknown filter path → pytest.fail (no return)."""
    monkeypatch.setenv(_FILTER_ENV_VAR, "/api/typo-here")
    fn = _resolve_fixture_callable(_filter_paths)
    with pytest.raises(pytest.fail.Exception) as exc_info:
        fn()  # type: ignore[operator]
    msg = str(exc_info.value)
    assert "/api/typo-here" in msg
    assert _FILTER_ENV_VAR in msg


def test_filter_paths_fixture_returns_none_when_unset(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """T-C13b-03 (R6, EC-6.3): unset env var yields ``None``."""
    monkeypatch.delenv(_FILTER_ENV_VAR, raising=False)
    fn = _resolve_fixture_callable(_filter_paths)
    assert fn() is None  # type: ignore[operator]


# ---------------------------------------------------------------------------
# Cross-cutting verification: file-touch boundary (T-XC-02..06).
# ---------------------------------------------------------------------------


def _branch_diff_files() -> list[str]:
    """Return ``git diff main --name-only`` as a list of paths."""
    repo_root = Path(__file__).resolve().parents[2]
    proc = subprocess.run(
        ["git", "diff", "main", "--name-only"],
        cwd=str(repo_root),
        capture_output=True,
        text=True,
        timeout=10,
    )
    if proc.returncode != 0:
        pytest.skip(f"git diff main failed: {proc.stderr}")
    return [line for line in proc.stdout.splitlines() if line.strip()]


def test_xc_no_touched_serve_py() -> None:
    """T-XC-02 (R10, AS-8): ``dashboard/serve.py`` not in branch diff."""
    files = _branch_diff_files()
    assert "dashboard/serve.py" not in files


def test_xc_no_touched_run_all_sh() -> None:
    """T-XC-06 (R10, R12, OQ#2): ``dashboard/tests/run-all.sh`` not in diff."""
    files = _branch_diff_files()
    assert "dashboard/tests/run-all.sh" not in files


def test_xc_no_touched_conftest() -> None:
    """T-XC-05 (R10): ``dashboard/tests/conftest.py`` not in branch diff."""
    files = _branch_diff_files()
    assert "dashboard/tests/conftest.py" not in files


# ---------------------------------------------------------------------------
# CLI shim — invoked via ``python3 dashboard/tests/test_response_compat.py``.
# ---------------------------------------------------------------------------


if __name__ == "__main__":
    sys.exit(_main())


# ---------------------------------------------------------------------------
# Unit tests for the pure helpers above.
# ---------------------------------------------------------------------------


def test_manifest_has_22_entries() -> None:
    """T-C1-01 (R1): MANIFEST contains exactly 22 EndpointSpec tuples."""
    assert len(MANIFEST) == 22


def test_manifest_slugs_unique() -> None:
    """T-C1-03 / test_slugs_unique (R3, EC-1.2): all 22 slugs are distinct."""
    slugs = [spec.slug for spec in MANIFEST]
    assert len(set(slugs)) == 22, f"slug collision: {slugs}"


def test_manifest_iteration_is_deterministic() -> None:
    """T-C1-07 (R1): MANIFEST iteration order is stable across reads."""
    first = tuple(MANIFEST)
    second = tuple(MANIFEST)
    assert first == second


def test_slug_get_path() -> None:
    """T-C1-04 (R3): GET path slug matches lstrip+replace."""
    assert _slug("GET", "/api/flow-status") == "api-flow-status"


def test_slug_post_prefix() -> None:
    """T-C1-05 (R3): POST method prefixes with lowercase ``post-``."""
    assert _slug("POST", "/api/grinder/pause") == "post-api-grinder-pause"


def test_slug_delete_prefix() -> None:
    """T-C1-05 (R3): DELETE method prefixes with lowercase ``delete-``."""
    assert _slug("DELETE", "/api/grinder/pause") == "delete-api-grinder-pause"


def test_slug_nested_path() -> None:
    """T-C1-06 (R3): nested paths flatten with dashes."""
    assert _slug("GET", "/api/autopilot/log") == "api-autopilot-log"


def test_render_query_home_substitution(monkeypatch: pytest.MonkeyPatch) -> None:
    """T-C6-01 (R11, OQ#6): ``{HOME}`` is replaced by expanduser('~')."""
    monkeypatch.setenv("HOME", "/Users/test")
    assert _render_query("cwd={HOME}") == "cwd=/Users/test"


def test_render_query_no_placeholder() -> None:
    """T-C6-02 (R11): template without placeholder is unchanged."""
    assert _render_query("task=zzznonexistent") == "task=zzznonexistent"


def test_render_query_empty_template() -> None:
    """T-C6-03 (R11): empty template returns empty string."""
    assert _render_query("") == ""


def test_render_query_multiple_placeholders(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """T-C6-04 (R11): every ``{HOME}`` in the template is substituted."""
    monkeypatch.setenv("HOME", "/Users/test")
    assert _render_query("a={HOME}&b={HOME}") == "a=/Users/test&b=/Users/test"


def test_render_query_unknown_placeholder_passthrough() -> None:
    """T-C6-05 (R11): unknown ``{...}`` text passes through unchanged."""
    assert _render_query("x={UNKNOWN}") == "x={UNKNOWN}"


def test_parse_filter_unset_returns_none() -> None:
    """T-C8-01 (R6, EC-6.3): ``None`` env value yields ``None``."""
    assert _parse_endpoint_filter(None) is None


def test_parse_filter_empty_returns_none() -> None:
    """T-C8-02 (EC-6.3): empty-string env value yields ``None``."""
    assert _parse_endpoint_filter("") is None


def test_parse_filter_whitespace_returns_none() -> None:
    """T-C8-03 (EC-6.3): whitespace-only env value yields ``None``."""
    assert _parse_endpoint_filter("   ") is None


def test_parse_filter_single_path() -> None:
    """T-C8-04 (R6, AS-4): single path returns single-element set."""
    assert _parse_endpoint_filter("/api/sessions") == {"/api/sessions"}


def test_parse_filter_csv() -> None:
    """T-C8-05 (R6, AS-4): comma-separated paths produce a set."""
    assert _parse_endpoint_filter("/api/sessions,/api/plans") == {
        "/api/sessions",
        "/api/plans",
    }


def test_parse_filter_trims_whitespace() -> None:
    """T-C8-06 (EC-6.2): whitespace around CSV entries is trimmed."""
    assert _parse_endpoint_filter("/api/sessions, /api/plans") == {
        "/api/sessions",
        "/api/plans",
    }


def test_parse_filter_dedupes() -> None:
    """T-C8-07 (EC-6.1): duplicates collapse silently to a single entry."""
    assert _parse_endpoint_filter("/api/sessions,/api/sessions") == {
        "/api/sessions",
    }


def test_parse_filter_unknown_path_raises() -> None:
    """T-C8-08 (R6, AS-5): unknown path raises ``ValueError`` naming both
    the offending path and the env-var.
    """
    with pytest.raises(ValueError) as exc_info:
        _parse_endpoint_filter("/api/typo-here")
    msg = str(exc_info.value)
    assert "/api/typo-here" in msg
    assert _FILTER_ENV_VAR in msg


def test_parse_filter_unknown_among_valid_raises() -> None:
    """T-C8-09 (R6, AS-5): an unknown path raises even if other entries are valid."""
    with pytest.raises(ValueError) as exc_info:
        _parse_endpoint_filter("/api/sessions,/api/typo-here")
    assert "/api/typo-here" in str(exc_info.value)


def test_parse_filter_full_manifest() -> None:
    """T-C8-10 (EC-6.4): listing all paths returns the full set."""
    csv = ",".join(spec.path for spec in MANIFEST)
    parsed = _parse_endpoint_filter(csv)
    assert parsed is not None
    assert parsed == {spec.path for spec in MANIFEST}


def _fixture(
    *,
    slug: str = "api-flow-status",
    method: str = "GET",
    path: str = "/api/flow-status",
    query: str = "",
    status: int = 200,
    content_type: str = "application/json; charset=utf-8",
    body_encoding: str = "utf-8",
    body: str = "[]",
) -> dict:
    """Test helper: build a valid fixture dict for diff tests."""
    return {
        "slug": slug,
        "method": method,
        "path": path,
        "query": query,
        "status": status,
        "content_type": content_type,
        "body_encoding": body_encoding,
        "body": body,
    }


def test_diff_response_match_returns_none() -> None:
    """T-C11-01 (R5): exact match returns ``None``."""
    fixture = _fixture(status=200, body="[]")
    assert _diff_response(fixture, 200, b"[]") is None


def test_diff_response_status_mismatch_reports_both() -> None:
    """T-C11-02 (R5, AS-3): status mismatch surfaces both numbers."""
    fixture = _fixture(status=200, body="[]")
    diag = _diff_response(fixture, 404, b"[]")
    assert diag is not None
    assert "200" in diag
    assert "404" in diag


def test_diff_response_trailing_newline_surfaces() -> None:
    """T-C11-03 (R5, EC-5.1): trailing-newline differences are NOT masked."""
    fixture = _fixture(body="a")
    diag = _diff_response(fixture, 200, b"a\n")
    assert diag is not None


def test_diff_response_json_separator_divergence_surfaces() -> None:
    """T-C11-04 (EC-5.2): the regression-driving stdlib vs FastAPI separator
    difference surfaces as a non-None diagnostic.
    """
    fixture = _fixture(body='{"a": 1, "b": 2}')
    diag = _diff_response(fixture, 200, b'{"a":1,"b":2}')
    assert diag is not None


def test_diff_response_truncates_large_diff() -> None:
    """T-C11-05 (EC-5.3): large bodies are truncated to ``_DIFF_TRUNCATE_BYTES``."""
    expected = "x" * 50_000
    actual_bytes = ("x" * 120 + "y" + "x" * (50_000 - 121)).encode("utf-8")
    fixture = _fixture(body=expected)
    diag = _diff_response(fixture, 200, actual_bytes)
    assert diag is not None
    assert len(diag) <= _DIFF_TRUNCATE_BYTES + 200  # truncation footer overhead
    assert "byte 120" in diag


def test_diff_response_utf8_round_trip() -> None:
    """T-C11-06 (R5): captured UTF-8 strings re-encode to original bytes."""
    fixture = _fixture(body="café")
    assert _diff_response(fixture, 200, "café".encode()) is None


def test_diff_response_base64_round_trip() -> None:
    """T-C11-07 (EC-3.3): base64 fixture bodies decode to raw bytes."""
    raw = b"\x89PNG\r\n\x1a\n"
    fixture = _fixture(
        body_encoding="base64",
        body=base64.b64encode(raw).decode("ascii"),
        content_type="image/png",
    )
    assert _diff_response(fixture, 200, raw) is None


def test_diff_response_base64_mismatch_reports_byte_index() -> None:
    """T-C11-08 (EC-3.3): binary body mismatch reports byte index, no UnicodeDecodeError."""
    raw = b"\x00\x01"
    fixture = _fixture(
        body_encoding="base64",
        body=base64.b64encode(raw).decode("ascii"),
        content_type="image/png",
    )
    diag = _diff_response(fixture, 200, b"\x00\x02")
    assert diag is not None
    assert "first_divergence_byte" in diag


def test_diff_response_content_type_drift_not_diffed() -> None:
    """T-C11-09 (EC-5.4): Content-Type is intentionally NOT part of the diff."""
    fixture = _fixture(content_type="text/html", body="ok")
    # Caller never passes content_type into _diff_response; matching bodies +
    # status return None regardless of any Content-Type drift the caller
    # observed (and discarded).
    assert _diff_response(fixture, 200, b"ok") is None


def test_diff_response_includes_slug() -> None:
    """T-C11-10 (R5): diagnostic mentions the slug for endpoint-attribution."""
    fixture = _fixture(slug="api-flow-status", body="a")
    diag = _diff_response(fixture, 200, b"b")
    assert diag is not None
    assert "api-flow-status" in diag


# ---------------------------------------------------------------------------
# C7 unit tests — _load_fixtures (filesystem isolation via tmp_path).
# ---------------------------------------------------------------------------


def _write_fixture(dir_path: Path, name: str, payload: dict) -> Path:
    """Test helper: write a JSON fixture file."""
    path = dir_path / name
    path.write_text(json.dumps(payload), encoding="utf-8")
    return path


def test_load_fixtures_returns_dict_keyed_by_slug(tmp_path: Path) -> None:
    """T-C7-01 (R5): valid fixtures load into ``{slug: dict}``."""
    _write_fixture(tmp_path, "a.json", _fixture(slug="a"))
    _write_fixture(tmp_path, "b.json", _fixture(slug="b"))
    out = _load_fixtures(tmp_path)
    assert set(out.keys()) == {"a", "b"}


def test_load_fixtures_missing_dir_raises(tmp_path: Path) -> None:
    """T-C7-02 (R8, AS-6): non-existent dir raises with explicit hint."""
    missing = tmp_path / "does-not-exist"
    with pytest.raises(FileNotFoundError) as exc_info:
        _load_fixtures(missing)
    assert "empty baseline fixture directory" in str(exc_info.value)


def test_load_fixtures_empty_dir_raises(tmp_path: Path) -> None:
    """T-C7-03 (R8, AS-6): empty dir raises naming the directory."""
    with pytest.raises(FileNotFoundError) as exc_info:
        _load_fixtures(tmp_path)
    assert "empty baseline fixture directory" in str(exc_info.value)


def test_load_fixtures_only_non_json_raises(tmp_path: Path) -> None:
    """T-C7-04 (R8): directory with only ``.gitkeep`` raises."""
    (tmp_path / ".gitkeep").write_text("", encoding="utf-8")
    with pytest.raises(FileNotFoundError):
        _load_fixtures(tmp_path)


def test_load_fixtures_malformed_json_raises(tmp_path: Path) -> None:
    """T-C7-05 (R9, AS-7): malformed JSON raises naming the offending file."""
    (tmp_path / "bad.json").write_text("{not-valid-json", encoding="utf-8")
    with pytest.raises(RuntimeError) as exc_info:
        _load_fixtures(tmp_path)
    assert "bad.json" in str(exc_info.value)


def test_load_fixtures_missing_field_raises(tmp_path: Path) -> None:
    """T-C7-06 (R9): fixture missing a required field raises naming it."""
    payload = _fixture()
    del payload["status"]
    _write_fixture(tmp_path, "broken.json", payload)
    with pytest.raises(RuntimeError) as exc_info:
        _load_fixtures(tmp_path)
    msg = str(exc_info.value)
    assert "status" in msg
    assert "broken.json" in msg


def test_load_fixtures_string_status_rejected(tmp_path: Path) -> None:
    """T-C7-07 (EC-9.1): string status (not int) is rejected."""
    payload = _fixture()
    payload["status"] = "200"
    _write_fixture(tmp_path, "bad-status.json", payload)
    with pytest.raises(RuntimeError) as exc_info:
        _load_fixtures(tmp_path)
    assert "status" in str(exc_info.value)


def test_load_fixtures_invalid_body_encoding_rejected(tmp_path: Path) -> None:
    """T-C7-08 (R9): unknown ``body_encoding`` raises."""
    payload = _fixture(body_encoding="ascii")
    _write_fixture(tmp_path, "bad-enc.json", payload)
    with pytest.raises(RuntimeError) as exc_info:
        _load_fixtures(tmp_path)
    assert "body_encoding" in str(exc_info.value)


def test_load_fixtures_short_circuits_on_first_failure(tmp_path: Path) -> None:
    """T-C7-09 (R9, AS-7): short-circuits on first malformed file (no partial return)."""
    _write_fixture(tmp_path, "good.json", _fixture(slug="good"))
    (tmp_path / "bad.json").write_text("nope", encoding="utf-8")
    with pytest.raises(RuntimeError):
        _load_fixtures(tmp_path)


def test_load_fixtures_filters_non_json_siblings(tmp_path: Path) -> None:
    """T-C7-10 (EC-3.1): non-JSON siblings (e.g. ``.gitkeep``) are ignored."""
    _write_fixture(tmp_path, "a.json", _fixture(slug="a"))
    (tmp_path / ".gitkeep").write_text("", encoding="utf-8")
    out = _load_fixtures(tmp_path)
    assert set(out.keys()) == {"a"}


# ---------------------------------------------------------------------------
# C10 unit tests — _silent_log_config_path.
# ---------------------------------------------------------------------------


def test_silent_log_config_path_exists() -> None:
    """T-C10-01 (R4, EC-4.4): returned path exists with .json suffix."""
    path = _silent_log_config_path()
    try:
        assert path.exists()
        assert path.suffix == ".json"
    finally:
        path.unlink(missing_ok=True)


def test_silent_log_config_contains_warning_loggers() -> None:
    """T-C10-02 (R4, EC-4.4): config sets uvicorn loggers to WARNING."""
    path = _silent_log_config_path()
    try:
        cfg = json.loads(path.read_text(encoding="utf-8"))
        assert cfg["loggers"]["uvicorn.access"]["level"] == "WARNING"
        assert cfg["loggers"]["uvicorn.error"]["level"] == "WARNING"
    finally:
        path.unlink(missing_ok=True)


def test_silent_log_config_paths_are_distinct() -> None:
    """T-C10-04 (R4): repeated calls return distinct temp paths."""
    a = _silent_log_config_path()
    b = _silent_log_config_path()
    try:
        assert a != b
    finally:
        a.unlink(missing_ok=True)
        b.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# Stub HTTP server infrastructure for C4 / C5 integration tests.
# ---------------------------------------------------------------------------


import http.server  # noqa: E402  — used only by stub-server test helpers
import threading  # noqa: E402


class _StubHandlerFactory:
    """Build a BaseHTTPRequestHandler subclass with a per-test response map."""

    def __init__(
        self,
        *,
        status: int = 200,
        body: bytes = b"[]",
        content_type: str = "application/json; charset=utf-8",
        per_path: dict[str, tuple[int, bytes, str]] | None = None,
        omit_content_type: bool = False,
    ) -> None:
        self.status = status
        self.body = body
        self.content_type = content_type
        self.per_path = per_path or {}
        self.omit_content_type = omit_content_type

    def make_handler(self) -> type[http.server.BaseHTTPRequestHandler]:
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args: object, **kwargs: object) -> None:
                return  # silence server log

            def _respond(self) -> None:
                # Strip query string for per_path lookup.
                base_path = self.path.split("?", 1)[0]
                status, body, ctype = outer.per_path.get(
                    base_path,
                    (outer.status, outer.body, outer.content_type),
                )
                self.send_response(status)
                if not outer.omit_content_type:
                    self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_GET(self) -> None:  # noqa: N802
                self._respond()

            def do_POST(self) -> None:  # noqa: N802
                self.rfile.read(int(self.headers.get("Content-Length", "0") or "0"))
                self._respond()

            def do_DELETE(self) -> None:  # noqa: N802
                self._respond()

        return Handler


@contextlib.contextmanager
def _stub_server(factory: _StubHandlerFactory) -> Iterator[str]:
    """Run a stub HTTPServer in a thread bound to an ephemeral port."""
    server = http.server.HTTPServer(("127.0.0.1", 0), factory.make_handler())
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    try:
        host: str = "127.0.0.1"
        port: int = int(server.server_address[1])
        yield f"http://{host}:{port}"
    finally:
        server.shutdown()
        server.server_close()
        thread.join(timeout=2)


# ---------------------------------------------------------------------------
# C4 integration tests — _probe_health.
# ---------------------------------------------------------------------------


def test_probe_health_alive_200() -> None:
    """T-C4-01 (R2, OQ#3): 200 response = alive (no raise)."""
    with _stub_server(_StubHandlerFactory(status=200, body=b"OK")) as url:
        _probe_health(url + "/health", retries=1)


def test_probe_health_alive_404() -> None:
    """T-C4-02 (R2, EC-2.2): 404 still counts as TCP-alive."""
    with _stub_server(_StubHandlerFactory(status=404, body=b"nope")) as url:
        _probe_health(url + "/health", retries=1)


def test_probe_health_alive_500() -> None:
    """T-C4-03 (EC-2.3): 500 still counts as TCP-alive."""
    with _stub_server(_StubHandlerFactory(status=500, body=b"oops")) as url:
        _probe_health(url + "/health", retries=1)


def test_probe_health_refused_after_retries() -> None:
    """T-C4-04 (R2, AS-2): unreachable port raises RuntimeError after retries."""
    # Pick a port that is reserved / unbound — bind then close to find one.
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    free_port = sock.getsockname()[1]
    sock.close()
    with pytest.raises(RuntimeError) as exc_info:
        _probe_health(
            f"http://127.0.0.1:{free_port}/health",
            retries=2,
            backoff=0.05,
            timeout=0.5,
        )
    msg = str(exc_info.value)
    assert f"127.0.0.1:{free_port}" in msg


def test_probe_health_underlying_error_in_message() -> None:
    """T-C4-08 (R2, EC-2.4): the underlying error type appears in the raise."""
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    free_port = sock.getsockname()[1]
    sock.close()
    with pytest.raises(RuntimeError) as exc_info:
        _probe_health(
            f"http://127.0.0.1:{free_port}/health",
            retries=1,
            timeout=0.5,
        )
    msg = str(exc_info.value)
    # Either ConnectionRefusedError or URLError (which wraps it) — both fine.
    assert "Error" in msg or "refused" in msg.lower()


# ---------------------------------------------------------------------------
# C5 integration tests — _capture.
# ---------------------------------------------------------------------------


def test_capture_writes_22_fixtures(tmp_path: Path) -> None:
    """T-C5-01 / T-C5-03 (R3, AS-1): capture writes exactly 22 fixtures."""
    factory = _StubHandlerFactory(
        status=200,
        body=b"[]",
        content_type="application/json; charset=utf-8",
        per_path={"/health": (200, b"ok", "text/plain")},
    )
    with _stub_server(factory) as url:
        _capture(url, tmp_path)
    files = sorted(tmp_path.glob("*.json"))
    assert len(files) == 22

    captured_pairs: set[tuple[str, str]] = set()
    for path in files:
        data = json.loads(path.read_text(encoding="utf-8"))
        for field in _FIXTURE_REQUIRED_FIELDS:
            assert field in data, f"missing {field} in {path.name}"
        captured_pairs.add((data["method"], data["path"]))
    assert captured_pairs == {(spec.method, spec.path) for spec in MANIFEST}


def test_capture_aborts_on_unreachable_server(tmp_path: Path) -> None:
    """T-C5-04 (R2, AS-2): unreachable server → RuntimeError, no fixtures."""
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    free_port = sock.getsockname()[1]
    sock.close()
    with pytest.raises(RuntimeError):
        _capture(
            f"http://127.0.0.1:{free_port}",
            tmp_path,
        )
    assert list(tmp_path.glob("*.json")) == []


def test_capture_truncates_stale_json(tmp_path: Path) -> None:
    """T-C5-05 (EC-3.1): pre-existing ``*.json`` files are removed."""
    (tmp_path / "stale.json").write_text("{}", encoding="utf-8")
    factory = _StubHandlerFactory(
        status=200,
        body=b"[]",
        per_path={"/health": (200, b"ok", "text/plain")},
    )
    with _stub_server(factory) as url:
        _capture(url, tmp_path)
    assert not (tmp_path / "stale.json").exists()


def test_capture_preserves_gitkeep(tmp_path: Path) -> None:
    """T-C5-06 (EC-3.1): ``.gitkeep`` survives truncation."""
    (tmp_path / ".gitkeep").write_text("", encoding="utf-8")
    factory = _StubHandlerFactory(
        status=200,
        body=b"[]",
        per_path={"/health": (200, b"ok", "text/plain")},
    )
    with _stub_server(factory) as url:
        _capture(url, tmp_path)
    assert (tmp_path / ".gitkeep").exists()


def test_capture_atomic_no_orphan_tmp(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """T-C5-07 / T-C5-08 (EC-3.2, Risk 5): mid-run failure leaves no .tmp orphans."""
    factory = _StubHandlerFactory(
        status=200,
        body=b"[]",
        per_path={"/health": (200, b"ok", "text/plain")},
    )
    call_count = {"n": 0}
    real_request = _request_endpoint

    def flaky_request(
        server_url: str, spec: EndpointSpec, rendered_query: str, **kwargs: object
    ) -> tuple[int, bytes, str]:
        call_count["n"] += 1
        if call_count["n"] == 5:
            raise RuntimeError("injected failure")
        return real_request(server_url, spec, rendered_query, **kwargs)  # type: ignore[arg-type]

    monkeypatch.setattr(
        sys.modules[_capture.__module__],
        "_request_endpoint",
        flaky_request,
    )
    with _stub_server(factory) as url:
        with pytest.raises(RuntimeError, match="injected failure"):
            _capture(url, tmp_path)
    # No .tmp orphans even after partial failure.
    assert list(tmp_path.glob("*.json.tmp")) == []


def test_capture_base64_for_binary(tmp_path: Path) -> None:
    """T-C5-11 (EC-3.3, Risk 4): non-text Content-Type → base64 encoding."""
    binary_payload = b"\x89PNG\r\n\x1a\n\x00\x01\xff"
    factory = _StubHandlerFactory(
        status=200,
        body=binary_payload,
        content_type="image/png",
        per_path={"/health": (200, b"ok", "text/plain")},
    )
    with _stub_server(factory) as url:
        _capture(url, tmp_path)
    sample = json.loads((tmp_path / "api-flow-status.json").read_text(encoding="utf-8"))
    assert sample["body_encoding"] == "base64"
    assert base64.b64decode(sample["body"]) == binary_payload


def test_capture_empty_content_type_recorded_as_empty_string(
    tmp_path: Path,
) -> None:
    """T-C5-12 (EC-3.4): missing Content-Type captured as ``""``."""
    factory = _StubHandlerFactory(
        status=200,
        body=b"[]",
        per_path={"/health": (200, b"ok", "text/plain")},
        omit_content_type=True,
    )
    with _stub_server(factory) as url:
        _capture(url, tmp_path)
    sample = json.loads((tmp_path / "api-flow-status.json").read_text(encoding="utf-8"))
    assert sample["content_type"] == ""


def test_capture_resolves_home_placeholder(tmp_path: Path) -> None:
    """T-C5-13 (OQ#6): ``{HOME}`` is resolved to an absolute path at capture time."""
    factory = _StubHandlerFactory(
        status=200,
        body=b"[]",
        per_path={"/health": (200, b"ok", "text/plain")},
    )
    with _stub_server(factory) as url:
        _capture(url, tmp_path)
    sample = json.loads((tmp_path / "api-flow-status.json").read_text(encoding="utf-8"))
    assert "{HOME}" not in sample["query"]
    assert sample["query"].startswith("cwd=")
    assert "/" in sample["query"]


def test_capture_includes_post_and_delete_methods(tmp_path: Path) -> None:
    """T-C5-15 (R1, R3): POST/DELETE manifest entries are captured with right methods."""
    factory = _StubHandlerFactory(
        status=200,
        body=b"[]",
        per_path={"/health": (200, b"ok", "text/plain")},
    )
    with _stub_server(factory) as url:
        _capture(url, tmp_path)
    post = json.loads((tmp_path / "post-api-grinder-pause.json").read_text(encoding="utf-8"))
    delete = json.loads((tmp_path / "delete-api-grinder-pause.json").read_text(encoding="utf-8"))
    assert post["method"] == "POST"
    assert delete["method"] == "DELETE"
