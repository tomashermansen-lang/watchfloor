"""Unit tests for T0.2.c artifact + grinder endpoints (R17).

Covers each of the 8 new endpoints' fixture-replicating path AND the
alternative error-gate paths plus the 200 path (mocked helper). The
byte-equivalence harness (``test_response_compat.py``) verifies fixture-
level byte equality at the protocol level; this module verifies handler-
level dispatch, body bytes, content-type, and method-routing distinction.

Mocking convention: every helper is patched at the **callsite namespace**
(``dashboard.server.routes.api.<name>``), not the source helper module.
Predecessor `test_routes_api.py` uses this pattern; patching the source
module would not affect the bound name in `routes/api.py`.

Content-Type contract:

* JSON 200: ``application/json; charset=utf-8`` (SPACE after ``;``)
* HTML 4xx/5xx: ``text/html;charset=utf-8`` (NO space)
"""

from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from unittest.mock import MagicMock

import pytest
from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.exceptions import HTTPException as StarletteHTTPException

from dashboard.server._exception_handlers import (
    html_4xx_handler,
    html_500_handler,
)
from dashboard.server.plan_helpers import (
    PLAN_ARTIFACT_ESCAPE_MARKER,
    PLAN_ARTIFACT_OUTSIDE_ROOT_MARKER,
)
from dashboard.server.routes import api as routes_api

# ---------------------------------------------------------------------------
# Fixtures — mirror predecessor test_routes_api.py:31-63 conventions.
# ``client`` exercises 200 paths (no HTML handlers); ``client_html`` exercises
# 4xx/5xx paths (registers handlers so body bytes match stdlib template).
# ---------------------------------------------------------------------------


@pytest.fixture()
def client() -> TestClient:
    app = FastAPI()
    app.include_router(routes_api.router)
    return TestClient(app)


@pytest.fixture()
def client_html() -> TestClient:
    app = FastAPI()
    app.add_exception_handler(StarletteHTTPException, html_4xx_handler)
    app.add_exception_handler(Exception, html_500_handler)
    app.include_router(routes_api.router)
    return TestClient(app)


_JSON_CT = "application/json; charset=utf-8"
_HTML_CT = "text/html;charset=utf-8"
_FIXTURE_DIR = Path(__file__).parent / "fixtures" / "response-baseline"


def _html_body(message: str) -> bytes:
    """Render the rendered substring asserted against the HTML 4xx/5xx body."""
    return f"<p>Message: {message}.</p>".encode()


# ===========================================================================
# A.1 — GET /api/plan/artifacts (R2)
# ===========================================================================


class TestPlanArtifacts:
    """T_pa_1..T_pa_5 — /api/plan/artifacts (R2)."""

    def test_t_pa_1_missing_cwd_and_task(self, client_html: TestClient) -> None:
        response = client_html.get("/api/plan/artifacts")
        assert response.status_code == 400
        assert _html_body("Missing cwd or task parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_pa_2_missing_task_only(self, client_html: TestClient) -> None:
        response = client_html.get("/api/plan/artifacts", params={"cwd": "/tmp"})
        assert response.status_code == 400
        assert _html_body("Missing cwd or task parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_pa_3_present_empty_task_fails_regex(self, client_html: TestClient) -> None:
        response = client_html.get("/api/plan/artifacts", params={"cwd": "/tmp", "task": ""})
        assert response.status_code == 400
        assert _html_body("Invalid task parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_pa_4_fixture_replicating_empty_list(
        self, client: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "list_task_artifacts", lambda c, t: [])
        response = client.get(
            "/api/plan/artifacts",
            params={"cwd": os.environ.get("HOME", "/tmp"), "task": "zzznonexistent"},
        )
        assert response.status_code == 200
        assert response.content == b"[]"
        assert response.headers["content-type"] == _JSON_CT

        fixture = json.loads((_FIXTURE_DIR / "api-plan-artifacts.json").read_text(encoding="utf-8"))
        assert response.content == fixture["body"].encode("utf-8")

    def test_t_pa_5_helper_returns_non_empty_list(
        self, client: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        payload = [{"name": "PLAN.md", "file": "PLAN.md"}, {"name": "REQ.md", "file": "REQ.md"}]
        monkeypatch.setattr(routes_api, "list_task_artifacts", lambda c, t: payload)
        response = client.get("/api/plan/artifacts", params={"cwd": "/x", "task": "ok"})
        assert response.status_code == 200
        assert response.content == json.dumps(payload).encode("utf-8")
        assert response.headers["content-type"] == _JSON_CT


# ===========================================================================
# A.2 — GET /api/plan/artifact (R3)
# ===========================================================================


class TestPlanArtifact:
    """T_pa2_1..T_pa2_8 — /api/plan/artifact (R3)."""

    def test_t_pa2_1_missing_file(self, client_html: TestClient) -> None:
        response = client_html.get("/api/plan/artifact")
        assert response.status_code == 400
        assert _html_body("Missing file parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_pa2_2_invalid_task_when_present(self, client_html: TestClient) -> None:
        response = client_html.get(
            "/api/plan/artifact", params={"file": "PLAN.md", "task": "evil/path"}
        )
        assert response.status_code == 400
        assert _html_body("Invalid task parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_pa2_3_fixture_replicating_invalid_file(self, client_html: TestClient) -> None:
        response = client_html.get("/api/plan/artifact", params={"file": "NONEXISTENT.md"})
        assert response.status_code == 400
        assert _html_body("Invalid file parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

        fixture = json.loads((_FIXTURE_DIR / "api-plan-artifact.json").read_text(encoding="utf-8"))
        assert response.content == fixture["body"].encode("utf-8")

    def test_t_pa2_4_traversal_rejected(self, client_html: TestClient) -> None:
        response = client_html.get("/api/plan/artifact", params={"file": "../../../etc/passwd"})
        assert response.status_code == 400
        assert _html_body("Invalid file parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_pa2_5_escape_marker(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            routes_api, "get_plan_artifact", lambda *a, **k: PLAN_ARTIFACT_ESCAPE_MARKER
        )
        response = client_html.get("/api/plan/artifact", params={"file": "PLAN.md"})
        assert response.status_code == 400
        assert _html_body("path escapes cwd") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_pa2_6_outside_root_marker(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(
            routes_api,
            "get_plan_artifact",
            lambda *a, **k: PLAN_ARTIFACT_OUTSIDE_ROOT_MARKER,
        )
        response = client_html.get("/api/plan/artifact", params={"file": "PLAN.md"})
        assert response.status_code == 400
        assert _html_body("cwd outside PROJECTS_ROOT") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_pa2_7_helper_none_returns_404(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "get_plan_artifact", lambda *a, **k: None)
        response = client_html.get("/api/plan/artifact", params={"file": "PLAN.md"})
        assert response.status_code == 404
        assert _html_body("Artifact not found") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_pa2_8_helper_returns_content_200(
        self, client: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "get_plan_artifact", lambda *a, **k: "# PLAN\n...")
        response = client.get("/api/plan/artifact", params={"file": "PLAN.md"})
        assert response.status_code == 200
        assert response.content == json.dumps({"file": "PLAN.md", "content": "# PLAN\n..."}).encode(
            "utf-8"
        )
        assert response.headers["content-type"] == _JSON_CT


# ===========================================================================
# A.3 — GET /api/feature/artifacts (R4)
# ===========================================================================


class TestFeatureArtifacts:
    """T_fa_1..T_fa_7 — /api/feature/artifacts (R4)."""

    def test_t_fa_1_missing_both(self, client_html: TestClient) -> None:
        response = client_html.get("/api/feature/artifacts")
        assert response.status_code == 400
        assert _html_body("Missing feature or project_root parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_fa_2_missing_project_root(self, client_html: TestClient) -> None:
        response = client_html.get("/api/feature/artifacts", params={"feature": "foo"})
        assert response.status_code == 400
        assert _html_body("Missing feature or project_root parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_fa_3_invalid_feature_regex(self, client_html: TestClient) -> None:
        response = client_html.get(
            "/api/feature/artifacts", params={"feature": "evil/", "project_root": "/tmp"}
        )
        assert response.status_code == 400
        assert _html_body("Invalid feature parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_fa_4_validate_cwd_rejects(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda p: None)
        response = client_html.get(
            "/api/feature/artifacts", params={"feature": "ok", "project_root": "/etc"}
        )
        assert response.status_code == 403
        assert _html_body("Forbidden") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_fa_5_unknown_project_root(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda p: "/legit")
        monkeypatch.setattr(routes_api, "_get_all_project_roots", lambda: set())
        response = client_html.get(
            "/api/feature/artifacts", params={"feature": "ok", "project_root": "/legit"}
        )
        assert response.status_code == 403
        assert _html_body("Unknown project root") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_fa_6_fixture_replicating_empty(
        self, tmp_path: Path, client: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda p: str(tmp_path))
        monkeypatch.setattr(routes_api, "_get_all_project_roots", lambda: {str(tmp_path)})
        response = client.get(
            "/api/feature/artifacts",
            params={"feature": "zzznonexistent", "project_root": str(tmp_path)},
        )
        assert response.status_code == 200
        assert response.content == b"[]"
        assert response.headers["content-type"] == _JSON_CT

        fixture = json.loads(
            (_FIXTURE_DIR / "api-feature-artifacts.json").read_text(encoding="utf-8")
        )
        assert response.content == fixture["body"].encode("utf-8")

    def test_t_fa_7_populated_allowlist_order(
        self, tmp_path: Path, client: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        feature_dir = tmp_path / "docs" / "INPROGRESS_Feature_ok"
        feature_dir.mkdir(parents=True)
        (feature_dir / "PLAN.md").write_text("plan")
        (feature_dir / "REQUIREMENTS.md").write_text("req")
        monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda p: str(tmp_path))
        monkeypatch.setattr(routes_api, "_get_all_project_roots", lambda: {str(tmp_path)})
        response = client.get(
            "/api/feature/artifacts", params={"feature": "ok", "project_root": str(tmp_path)}
        )
        assert response.status_code == 200
        # Allowlist order: REQUIREMENTS.md before PLAN.md (NOT alphabetical).
        assert response.content == json.dumps(
            [
                {"name": "REQUIREMENTS.md", "file": "REQUIREMENTS.md"},
                {"name": "PLAN.md", "file": "PLAN.md"},
            ]
        ).encode("utf-8")
        assert response.headers["content-type"] == _JSON_CT


# ===========================================================================
# A.4 — GET /api/feature/artifact (R5)
# ===========================================================================


class TestFeatureArtifact:
    """T_fa2_1..T_fa2_9 — /api/feature/artifact (R5)."""

    def test_t_fa2_1_missing_all_three(self, client_html: TestClient) -> None:
        response = client_html.get("/api/feature/artifact")
        assert response.status_code == 400
        assert _html_body("Missing feature, project_root, or file parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_fa2_2_missing_file(self, client_html: TestClient) -> None:
        response = client_html.get(
            "/api/feature/artifact", params={"feature": "ok", "project_root": "/tmp"}
        )
        assert response.status_code == 400
        assert _html_body("Missing feature, project_root, or file parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_fa2_3_invalid_feature(self, client_html: TestClient) -> None:
        response = client_html.get(
            "/api/feature/artifact",
            params={"feature": "evil/", "project_root": "/tmp", "file": "PLAN.md"},
        )
        assert response.status_code == 400
        assert _html_body("Invalid feature parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_fa2_4_traversal_in_file(self, client_html: TestClient) -> None:
        response = client_html.get(
            "/api/feature/artifact",
            params={"feature": "ok", "project_root": "/tmp", "file": "../etc/passwd"},
        )
        assert response.status_code == 400
        assert _html_body("Invalid file parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_fa2_5_file_not_in_allowlist(self, client_html: TestClient) -> None:
        response = client_html.get(
            "/api/feature/artifact",
            params={"feature": "ok", "project_root": "/tmp", "file": "PLAN.md.bak"},
        )
        assert response.status_code == 400
        assert _html_body("Invalid file parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_fa2_6_validate_cwd_rejects(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda p: None)
        response = client_html.get(
            "/api/feature/artifact",
            params={"feature": "ok", "project_root": "/tmp", "file": "PLAN.md"},
        )
        assert response.status_code == 403
        assert _html_body("Forbidden") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_fa2_7_symlink_traversal(
        self, tmp_path: Path, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        outside_dir = tmp_path.parent / f"{tmp_path.name}_outside"
        outside_dir.mkdir()
        outside_file = outside_dir / "secret.md"
        outside_file.write_text("secret")

        feature_dir = tmp_path / "docs" / "INPROGRESS_Feature_ok"
        feature_dir.mkdir(parents=True)
        (feature_dir / "PLAN.md").symlink_to(outside_file)

        monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda p: str(tmp_path))
        monkeypatch.setattr(routes_api, "_get_all_project_roots", lambda: {str(tmp_path)})
        response = client_html.get(
            "/api/feature/artifact",
            params={"feature": "ok", "project_root": str(tmp_path), "file": "PLAN.md"},
        )
        assert response.status_code == 403
        assert _html_body("Path traversal detected") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_fa2_8_fixture_replicating_404(
        self, tmp_path: Path, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda p: str(tmp_path))
        monkeypatch.setattr(routes_api, "_get_all_project_roots", lambda: {str(tmp_path)})
        response = client_html.get(
            "/api/feature/artifact",
            params={
                "feature": "zzznonexistent",
                "project_root": str(tmp_path),
                "file": "PLAN.md",
            },
        )
        assert response.status_code == 404
        assert _html_body("Artifact not found") in response.content
        assert response.headers["content-type"] == _HTML_CT

        fixture = json.loads(
            (_FIXTURE_DIR / "api-feature-artifact.json").read_text(encoding="utf-8")
        )
        assert response.content == fixture["body"].encode("utf-8")

    def test_t_fa2_9_200_path(
        self, tmp_path: Path, client: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        feature_dir = tmp_path / "docs" / "INPROGRESS_Feature_ok"
        feature_dir.mkdir(parents=True)
        (feature_dir / "PLAN.md").write_text("# PLAN...")
        monkeypatch.setattr(routes_api, "_validate_cwd_param", lambda p: str(tmp_path))
        monkeypatch.setattr(routes_api, "_get_all_project_roots", lambda: {str(tmp_path)})
        response = client.get(
            "/api/feature/artifact",
            params={
                "feature": "ok",
                "project_root": str(tmp_path),
                "file": "PLAN.md",
            },
        )
        assert response.status_code == 200
        assert response.content == json.dumps(
            {"feature": "ok", "file": "PLAN.md", "content": "# PLAN..."}
        ).encode("utf-8")
        assert response.headers["content-type"] == _JSON_CT


# ===========================================================================
# A.5 — GET /api/grinder (R6)
# ===========================================================================


class TestGrinder:
    """T_gr_1..T_gr_5 — /api/grinder (R6)."""

    def test_t_gr_1_no_project_list_path(
        self, client: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "list_grinder_projects", lambda: [])
        response = client.get("/api/grinder")
        assert response.status_code == 200
        assert response.content == b"[]"
        assert response.headers["content-type"] == _JSON_CT

        fixture = json.loads((_FIXTURE_DIR / "api-grinder.json").read_text(encoding="utf-8"))
        assert response.content == fixture["body"].encode("utf-8")

    def test_t_gr_2_present_empty_project(
        self, client: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        # Post fastapi-cutover (T0.3): ``?project=`` (empty value) is treated
        # as absent — matches stdlib's ``parse_qs(... keep_blank_values=False)``
        # default and the suite-level T2.13 assertion in test-api-grinder.sh.
        monkeypatch.setattr(routes_api, "list_grinder_projects", lambda: [])
        response = client.get("/api/grinder", params={"project": ""})
        assert response.status_code == 200
        assert response.content == b"[]"
        assert response.headers["content-type"] == _JSON_CT

    def test_t_gr_3_invalid_project_regex(self, client_html: TestClient) -> None:
        response = client_html.get("/api/grinder", params={"project": "evil/path"})
        assert response.status_code == 400
        assert _html_body("Invalid project parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_gr_4_unknown_project(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: None)
        response = client_html.get("/api/grinder", params={"project": "valid_unknown"})
        assert response.status_code == 404
        assert _html_body("Project not found or has no grinder data") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_gr_5_200_detail(self, client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: "/fake/root")
        detail = {"project": "ok", "events": [], "events_total": 0}
        monkeypatch.setattr(routes_api, "assemble_project_detail", lambda r: detail)
        response = client.get("/api/grinder", params={"project": "ok"})
        assert response.status_code == 200
        assert response.content == json.dumps(detail).encode("utf-8")
        assert response.headers["content-type"] == _JSON_CT


# ===========================================================================
# A.6 — GET /api/grinder/stream (R7)
# ===========================================================================


class TestGrinderStream:
    """T_gr_s_1..T_gr_s_10 — /api/grinder/stream (R7)."""

    def test_t_gr_s_1_no_project(self, client_html: TestClient) -> None:
        response = client_html.get("/api/grinder/stream")
        assert response.status_code == 400
        assert _html_body("Missing or invalid project parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_gr_s_2_invalid_project_regex(self, client_html: TestClient) -> None:
        response = client_html.get("/api/grinder/stream", params={"project": "evil/"})
        assert response.status_code == 400
        assert _html_body("Missing or invalid project parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_gr_s_3_fixture_replicating_404(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: None)
        response = client_html.get(
            "/api/grinder/stream", params={"project": "zzznonexistent", "offset": "0"}
        )
        assert response.status_code == 404
        assert _html_body("Project not found or has no grinder data") in response.content
        assert response.headers["content-type"] == _HTML_CT

        fixture = json.loads((_FIXTURE_DIR / "api-grinder-stream.json").read_text(encoding="utf-8"))
        assert response.content == fixture["body"].encode("utf-8")

    def test_t_gr_s_4_compound_bad_project_first(self, client_html: TestClient) -> None:
        response = client_html.get(
            "/api/grinder/stream",
            params={"project": "invalid/name", "offset": "-1", "batch": "evil/"},
        )
        assert response.status_code == 400
        assert _html_body("Missing or invalid project parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_gr_s_5_negative_offset(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: "/fake/root")
        response = client_html.get("/api/grinder/stream", params={"project": "ok", "offset": "-1"})
        assert response.status_code == 400
        assert _html_body("Invalid offset parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_gr_s_6_non_int_offset(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: "/fake/root")
        response = client_html.get(
            "/api/grinder/stream", params={"project": "ok", "offset": "notnum"}
        )
        assert response.status_code == 400
        assert _html_body("Invalid offset parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_gr_s_7_read_stream_returns_none(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: "/fake/root")
        monkeypatch.setattr(routes_api, "get_grinder_stream_path", lambda r: "/fake/stream")
        monkeypatch.setattr(
            routes_api, "read_stream_incremental", lambda p, o, max_tail_bytes=None: None
        )
        response = client_html.get("/api/grinder/stream", params={"project": "ok", "offset": "0"})
        assert response.status_code == 500
        assert _html_body("Error reading stream") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_gr_s_8_invalid_batch_after_read(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: "/fake/root")
        monkeypatch.setattr(routes_api, "get_grinder_stream_path", lambda r: "/fake/stream")
        monkeypatch.setattr(
            routes_api, "read_stream_incremental", lambda p, o, max_tail_bytes=None: ([], 0)
        )
        response = client_html.get(
            "/api/grinder/stream",
            params={"project": "ok", "offset": "0", "batch": "evil/"},
        )
        assert response.status_code == 400
        assert _html_body("Invalid batch parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_gr_s_9_200_with_batch_filter(
        self, client: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: "/fake/root")
        monkeypatch.setattr(routes_api, "get_grinder_stream_path", lambda r: "/fake/stream")
        events = [{"batch_id": "valid", "x": 1}, {"batch_id": "other", "y": 2}]
        monkeypatch.setattr(
            routes_api, "read_stream_incremental", lambda p, o, max_tail_bytes=None: (events, 42)
        )
        monkeypatch.setattr(
            routes_api,
            "filter_batch_events",
            lambda evs, b: [e for e in evs if e.get("batch_id") == b],
        )
        response = client.get(
            "/api/grinder/stream",
            params={"project": "ok", "offset": "0", "batch": "valid"},
        )
        assert response.status_code == 200
        assert response.content == json.dumps(
            {
                "events": [{"batch_id": "valid", "x": 1}],
                "offset": 42,
                "project": "ok",
            }
        ).encode("utf-8")
        assert response.headers["content-type"] == _JSON_CT

    def test_t_gr_s_10_stream_path_falsy_404(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: "/fake/root")
        monkeypatch.setattr(routes_api, "get_grinder_stream_path", lambda r: None)
        response = client_html.get("/api/grinder/stream", params={"project": "ok", "offset": "0"})
        assert response.status_code == 404
        assert _html_body("No grinder stream file found") in response.content
        assert response.headers["content-type"] == _HTML_CT


# ===========================================================================
# A.7 — POST /api/grinder/pause (R8)
# ===========================================================================


class TestGrinderPausePost:
    """T_gr_p_1..T_gr_p_5 — POST /api/grinder/pause (R8)."""

    def test_t_gr_p_1_no_project(self, client_html: TestClient) -> None:
        response = client_html.post("/api/grinder/pause")
        assert response.status_code == 400
        assert _html_body("Missing or invalid project parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_gr_p_2_invalid_project(self, client_html: TestClient) -> None:
        response = client_html.post("/api/grinder/pause", params={"project": "evil/"})
        assert response.status_code == 400
        assert _html_body("Missing or invalid project parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_gr_p_3_fixture_replicating_404(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: None)
        response = client_html.post("/api/grinder/pause", params={"project": "zzznonexistent"})
        assert response.status_code == 404
        assert _html_body("Project not found or has no grinder data") in response.content
        assert response.headers["content-type"] == _HTML_CT

        fixture = json.loads(
            (_FIXTURE_DIR / "post-api-grinder-pause.json").read_text(encoding="utf-8")
        )
        assert response.content == fixture["body"].encode("utf-8")

    def test_t_gr_p_4_oserror_500_with_warning(
        self,
        client_html: TestClient,
        monkeypatch: pytest.MonkeyPatch,
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: "/fake/root")
        monkeypatch.setattr(
            routes_api, "create_pause", MagicMock(side_effect=PermissionError("denied"))
        )
        with caplog.at_level(logging.WARNING, logger="dashboard.serve"):
            response = client_html.post("/api/grinder/pause", params={"project": "valid"})
        assert response.status_code == 500
        assert _html_body("Cannot create PAUSE file") in response.content
        assert response.headers["content-type"] == _HTML_CT
        assert any("Cannot create PAUSE file" in rec.message for rec in caplog.records)

    def test_t_gr_p_5_200(self, client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: "/fake/root")
        monkeypatch.setattr(routes_api, "create_pause", MagicMock())
        response = client.post("/api/grinder/pause", params={"project": "valid"})
        assert response.status_code == 200
        assert response.content == b'{"paused": true}'
        assert response.headers["content-type"] == _JSON_CT


# ===========================================================================
# A.8 — DELETE /api/grinder/pause (R9)
# ===========================================================================


class TestGrinderPauseDelete:
    """T_gr_pd_1..T_gr_pd_5 — DELETE /api/grinder/pause (R9)."""

    def test_t_gr_pd_1_no_project(self, client_html: TestClient) -> None:
        response = client_html.delete("/api/grinder/pause")
        assert response.status_code == 400
        assert _html_body("Missing or invalid project parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_gr_pd_2_invalid_project(self, client_html: TestClient) -> None:
        response = client_html.delete("/api/grinder/pause", params={"project": "evil/"})
        assert response.status_code == 400
        assert _html_body("Missing or invalid project parameter") in response.content
        assert response.headers["content-type"] == _HTML_CT

    def test_t_gr_pd_3_fixture_replicating_404(
        self, client_html: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: None)
        response = client_html.delete("/api/grinder/pause", params={"project": "zzznonexistent"})
        assert response.status_code == 404
        assert _html_body("Project not found or has no grinder data") in response.content
        assert response.headers["content-type"] == _HTML_CT

        fixture = json.loads(
            (_FIXTURE_DIR / "delete-api-grinder-pause.json").read_text(encoding="utf-8")
        )
        assert response.content == fixture["body"].encode("utf-8")

    def test_t_gr_pd_4_oserror_500_with_warning(
        self,
        client_html: TestClient,
        monkeypatch: pytest.MonkeyPatch,
        caplog: pytest.LogCaptureFixture,
    ) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: "/fake/root")
        monkeypatch.setattr(
            routes_api, "remove_pause", MagicMock(side_effect=OSError("not pausable"))
        )
        with caplog.at_level(logging.WARNING, logger="dashboard.serve"):
            response = client_html.delete("/api/grinder/pause", params={"project": "valid"})
        assert response.status_code == 500
        assert _html_body("Cannot remove PAUSE file") in response.content
        assert response.headers["content-type"] == _HTML_CT
        assert any("Cannot remove PAUSE file" in rec.message for rec in caplog.records)

    def test_t_gr_pd_5_200(self, client: TestClient, monkeypatch: pytest.MonkeyPatch) -> None:
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: "/fake/root")
        monkeypatch.setattr(routes_api, "remove_pause", MagicMock())
        response = client.delete("/api/grinder/pause", params={"project": "valid"})
        assert response.status_code == 200
        assert response.content == b'{"paused": false}'
        assert response.headers["content-type"] == _JSON_CT


# ===========================================================================
# A.9 — POST/DELETE method-routing distinction (AS-3)
# ===========================================================================


class TestPostDeleteRouting:
    """T_gr_rt_1..T_gr_rt_2 — method dispatch guards AC-2."""

    def test_t_gr_rt_1_post_calls_create_only(
        self, client: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        mock_create = MagicMock()
        mock_remove = MagicMock()
        monkeypatch.setattr(routes_api, "create_pause", mock_create)
        monkeypatch.setattr(routes_api, "remove_pause", mock_remove)
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: "/fake/root")
        response = client.post("/api/grinder/pause", params={"project": "valid"})
        assert response.status_code == 200
        assert response.content == b'{"paused": true}'
        assert response.headers["content-type"] == _JSON_CT
        mock_create.assert_called_once_with("/fake/root")
        mock_remove.assert_not_called()

    def test_t_gr_rt_2_delete_calls_remove_only(
        self, client: TestClient, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        mock_create = MagicMock()
        mock_remove = MagicMock()
        monkeypatch.setattr(routes_api, "create_pause", mock_create)
        monkeypatch.setattr(routes_api, "remove_pause", mock_remove)
        monkeypatch.setattr(routes_api, "_resolve_project_root", lambda p: "/fake/root")
        response = client.delete("/api/grinder/pause", params={"project": "valid"})
        assert response.status_code == 200
        assert response.content == b'{"paused": false}'
        assert response.headers["content-type"] == _JSON_CT
        mock_remove.assert_called_once_with("/fake/root")
        mock_create.assert_not_called()


# ===========================================================================
# A.10 — Router-level inspection (R1, AS-1)
# ===========================================================================


class TestRouterInspection:
    """T_pa_router_1..T_pa_router_2 — router-level inspection."""

    def test_t_pa_router_1_22_paths(self) -> None:
        router = routes_api.router
        # Distinct paths × methods. /api/grinder/pause has BOTH POST and DELETE.
        path_method_pairs = {
            (getattr(route, "path", None), method)
            for route in router.routes
            for method in getattr(route, "methods", set())
        }
        # Exclude HEAD (Starlette auto-adds for GET on some paths)
        get_post_delete = {pm for pm in path_method_pairs if pm[1] in {"GET", "POST", "DELETE"}}
        # 14 GET (T0.2.a + T0.2.b) + 6 GET (T0.2.c) + POST + DELETE +
        # 1 GET (session-status-endpoint) + 1 GET (/api/csrf) = 24.
        # /api/csrf was added by the CSRF middleware work; the count was
        # not updated at that time. Updated 2026-05-23 when the
        # conftest path fix let this collection-error test actually run.
        assert len(get_post_delete) == 24

        new_paths = {
            "/api/plan/artifacts",
            "/api/plan/artifact",
            "/api/feature/artifacts",
            "/api/feature/artifact",
            "/api/grinder",
            "/api/grinder/stream",
        }
        for p in new_paths:
            assert (p, "GET") in get_post_delete, f"missing GET {p}"
        assert ("/api/grinder/pause", "POST") in get_post_delete
        assert ("/api/grinder/pause", "DELETE") in get_post_delete

    def test_t_pa_router_2_separate_post_delete_handlers(self) -> None:
        from dashboard.server.routes.api import (
            api_grinder_pause_delete,
            api_grinder_pause_post,
        )

        assert api_grinder_pause_post is not api_grinder_pause_delete
        assert api_grinder_pause_post.__name__ == "api_grinder_pause_post"
        assert api_grinder_pause_delete.__name__ == "api_grinder_pause_delete"


# ===========================================================================
# A.11 — Import-shape audit (R10, R11, AS-9)
# ===========================================================================


class TestImportShapeAudit:
    """T_pa_imports_1..T_pa_imports_3 — file-content audits."""

    @pytest.fixture(scope="class")
    def source(self) -> str:
        return Path(routes_api.__file__).read_text(encoding="utf-8")

    def test_t_pa_imports_1_no_helper_redeclaration(self, source: str) -> None:
        import re

        assert re.search(r"^def _validate_project_name", source, re.MULTILINE) is None
        assert re.search(r"^def _resolve_project_root", source, re.MULTILINE) is None
        assert re.search(r"^def _validate_artifact_filename", source, re.MULTILINE) is None
        assert re.search(r"^_ERR_GRINDER_NOT_FOUND\s*=", source, re.MULTILINE) is None
        assert re.search(r"^_ERR_INVALID_PROJECT\s*=", source, re.MULTILINE) is None

    def test_t_pa_imports_2_no_allowlist_redeclaration(self, source: str) -> None:
        import re

        assert re.search(r"^FEATURE_ARTIFACT_ALLOWLIST\s*=", source, re.MULTILINE) is None
        assert re.search(r"^_ALL_ALLOWED_FILES\s*=", source, re.MULTILINE) is None

    def test_t_pa_imports_3_no_unprefixed_server_imports(self, source: str) -> None:
        import re

        assert re.search(r"^from server\.", source, re.MULTILINE) is None
