"""Tests for FastAPI app routing precedence + SPA fallback (C4 — T10.*, T12.*).

Covers REQUIREMENTS.md R10 (router include + SPA fallback ordering) and R12
(other 15 endpoints return JSON 404 from FastAPI). The literal R10 ordering
is amended in PLAN.md Risk-A — the actual sequence is

    1. /health (existing)
    2. APIRouter (7 in-batch endpoints)
    3. /api/{rest:path} explicit 404 fallback for unported API paths
    4. StaticFiles(html=True) mount serving the SPA from <_SPA_ROOT>

The behavioural acceptance criteria of R10 (HTML for non-API paths, JSON 404
for unmatched API paths) hold under this composition. SPA-root-variant tests
build a parallel app via ``_compose_routes(test_app, tmp_path)`` so they can
verify the StaticFiles mount without re-executing module-level state.
"""

from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.testclient import TestClient
from starlette.routing import Mount


def _build_test_app_with_spa_root(spa_root: Path) -> FastAPI:
    """Compose a FastAPI app exactly like production but with a custom SPA root."""
    from dashboard.server.app import _compose_routes

    test_app = FastAPI()
    _compose_routes(test_app, spa_root)
    return test_app


def _csrf_token(client: TestClient) -> str:
    # Acquire a CSRF cookie via the first GET so unsafe-method requests
    # below reach their route handler instead of being rejected with 403
    # by CSRFMiddleware (fastapi-csrf-middleware, R4/EC-9).
    response = client.get("/health")
    assert response.status_code == 200, (
        f"CSRF preflight GET /health failed: status={response.status_code}; "
        "without this assert a downstream KeyError on cookies['csrf_token'] "
        "would mask the real cause."
    )
    return client.cookies["csrf_token"]


# ---------------------------------------------------------------------------
# T-CSRF-EP-* — body-token endpoint (controls-06 #11)
# ---------------------------------------------------------------------------


def test_t_csrf_ep_1_csrf_endpoint_returns_token_in_body() -> None:
    """T-CSRF-EP-1 (controls-06 #11): GET /api/csrf returns `{token: '...'}`.

    The body-token endpoint exists so Vite-dev (proxy at
    localhost:5175 → 127.0.0.1:8787) operators can read the CSRF
    token via JSON when the proxy hop + SameSite=Strict combination
    keeps `document.cookie` from exposing the cookie to the page
    script. The token in the body must NOT be empty.
    """
    from dashboard.server.app import app

    client = TestClient(app)
    response = client.get("/api/csrf")
    assert response.status_code == 200
    body = response.json()
    assert isinstance(body.get("token"), str)
    assert len(body["token"]) >= 32  # secrets.token_urlsafe(32) → ≥43 chars


def test_t_csrf_ep_2_csrf_body_token_matches_cookie() -> None:
    """T-CSRF-EP-2 (controls-06 #11): body token == Set-Cookie token.

    Single source of truth. If these diverge the double-submit
    compare on the server side would reject every POST.
    """
    from dashboard.server.app import app

    client = TestClient(app)
    response = client.get("/api/csrf")
    body_token = response.json()["token"]
    cookie_token = client.cookies["csrf_token"]
    assert body_token == cookie_token


def test_t_csrf_ep_3_csrf_idempotent_when_cookie_present() -> None:
    """T-CSRF-EP-3 (controls-06 #11): second call returns the SAME token.

    Once a cookie is established, subsequent GET /api/csrf returns
    the existing token rather than generating a new one — otherwise
    in-flight POSTs would see token churn on every page refresh.
    """
    from dashboard.server.app import app

    client = TestClient(app)
    first = client.get("/api/csrf").json()["token"]
    second = client.get("/api/csrf").json()["token"]
    assert first == second


def test_t_csrf_ep_4_csrf_body_token_works_as_post_header() -> None:
    """T-CSRF-EP-4 (controls-06 #11): the body token validates as X-CSRF-Token.

    End-to-end proof: a POST that uses the token from the JSON
    body (not from the cookie) passes the CSRF middleware's
    double-submit compare. This is the production failure mode
    Vite-dev operators hit — JS read the body token, sent it as the
    header, browser sent the cookie automatically; both sides match
    so the middleware accepts.
    """
    from dashboard.server.app import app

    client = TestClient(app)
    body_token = client.get("/api/csrf").json()["token"]
    # Use the body token (NOT client.cookies["csrf_token"]) as proof
    # that the body channel is sufficient when the cookie reaches
    # the browser silently but JS can't read it.
    response = client.post(
        "/api/grinder/pause",
        headers={"X-CSRF-Token": body_token, "Origin": "http://127.0.0.1:8787"},
    )
    # 400 (missing `project` parameter) is the expected route response;
    # the test passes as long as it's NOT 403 (CSRF reject).
    assert response.status_code != 403


# ---------------------------------------------------------------------------
# T-CSRF-LB-* — controls-07 #8: loopback clients skip CSRF check
#
# Rationale: the dashboard binds to 127.0.0.1 only. The only HTTP clients
# that can ever reach the CSRF middleware are (a) the operator's browser
# pointed at localhost, (b) a malicious process already running on this
# machine, or (c) an Electron renderer on this machine. For (a), the
# Origin allowlist (loopback-permissive cycle-9) already blocks every
# cross-site fetch. For (b), CSRF tokens don't help — a local process can
# read the token from DevTools, the cookie jar, or via curl. For (c),
# the renderer is the operator's own code. Cookie-based double-submit
# adds belt-and-suspenders that breaks on Safari's known WS-cookie bug
# (Apple Developer Forums thread 104488 — Safari fails to send cookies
# on subsequent WebSocket connects) and on browser-side cookie state
# divergence. The loopback skip restores the dashboard's usability on
# Safari while losing zero security in the actual threat model.
# ---------------------------------------------------------------------------


def test_t_csrf_lb_1_helper_recognises_ipv4_loopback() -> None:
    """T-CSRF-LB-1: `_is_loopback_client("127.0.0.1")` returns True."""
    from dashboard.server.middleware.csrf import _is_loopback_client

    assert _is_loopback_client("127.0.0.1") is True


def test_t_csrf_lb_2_helper_recognises_ipv6_loopback() -> None:
    """T-CSRF-LB-2: `_is_loopback_client("::1")` returns True."""
    from dashboard.server.middleware.csrf import _is_loopback_client

    assert _is_loopback_client("::1") is True


def test_t_csrf_lb_3_helper_rejects_non_loopback() -> None:
    """T-CSRF-LB-3: non-loopback hosts (incl. None / empty) → False."""
    from dashboard.server.middleware.csrf import _is_loopback_client

    for host in ("testclient", "0.0.0.0", "192.168.1.1", "example.com", "", None):
        assert _is_loopback_client(host) is False, f"{host!r} must not pass"


def test_t_csrf_lb_4_loopback_post_skips_csrf_check(monkeypatch) -> None:
    """T-CSRF-LB-4: POST from a loopback client succeeds WITHOUT
    X-CSRF-Token header. Monkeypatches `_is_loopback_client` because
    TestClient identifies as "testclient", not 127.0.0.1; the patch
    flips the policy decision so the middleware exercises the skip
    path. Asserts the response is NOT 403 (the route may still return
    400/404/etc for other reasons; only the CSRF gate matters here)."""
    from dashboard.server.app import app
    from dashboard.server.middleware import csrf as _csrf

    monkeypatch.setattr(_csrf, "_is_loopback_client", lambda _host: True)
    client = TestClient(app)
    # Deliberately NO X-CSRF-Token header. Pre-#8 this 403s with
    # `{"error": "csrf"}` (missing_header reason).
    response = client.post(
        "/api/grinder/pause",
        headers={"Origin": "http://127.0.0.1:8787"},
    )
    assert response.status_code != 403, response.text


def test_t_csrf_lb_5_non_loopback_still_enforces_csrf(monkeypatch) -> None:
    """T-CSRF-LB-5: regression guard — when client is NOT loopback,
    CSRF is still enforced (so a future 0.0.0.0 bind or reverse-proxy
    deploy doesn't silently drop the defence)."""
    from dashboard.server.app import app
    from dashboard.server.middleware import csrf as _csrf

    monkeypatch.setattr(_csrf, "_is_loopback_client", lambda _host: False)
    client = TestClient(app)
    response = client.post(
        "/api/grinder/pause",
        headers={"Origin": "http://127.0.0.1:8787"},
    )
    assert response.status_code == 403
    assert response.json() == {"error": "csrf"}


# ---------------------------------------------------------------------------
# T10.* — routing precedence + SPA fallback
# ---------------------------------------------------------------------------


def test_t10_1_route_registration_order() -> None:
    """T10.1 (R10, AS-1): routes registered in the documented order."""
    from dashboard.server.app import app

    paths = [getattr(route, "path", None) for route in app.routes]
    assert "/health" in paths

    api_paths = {
        "/api/flow-status",
        "/api/worktrees",
        "/api/plan",
        "/api/plans",
        "/api/sessions",
        "/api/features",
        "/api/metrics",
    }
    assert api_paths <= set(paths)
    assert "/api/{rest:path}" in paths

    health_idx = paths.index("/health")
    api_fallback_idx = paths.index("/api/{rest:path}")
    api_indices = [paths.index(p) for p in api_paths]
    assert all(health_idx < idx < api_fallback_idx for idx in api_indices), (
        "API routes must be registered AFTER /health and BEFORE /api/{rest:path}"
    )


def test_t10_2_static_files_mount_uses_html_true() -> None:
    """T10.2 (R10): the trailing Mount('/') uses StaticFiles(html=True)."""
    from dashboard.server.app import app

    mounts = [r for r in app.routes if isinstance(r, Mount) and r.path == ""]
    assert mounts, "Mount('/') must be registered"
    mount = mounts[-1]
    static_app = mount.app
    assert getattr(static_app, "html", False) is True
    assert getattr(static_app, "directory", None) is not None


def test_t10_3_spa_root_resolves_to_dist_when_present(tmp_path, monkeypatch) -> None:
    """T10.3 (R10, OQ#4): _resolve_spa_root() returns APP_DIST when it exists."""
    import dashboard.server.app as app_module

    fake_dist = tmp_path / "dist"
    fake_dist.mkdir()
    monkeypatch.setattr(app_module, "_APP_DIST", fake_dist)
    assert app_module._resolve_spa_root() == fake_dist


def test_t10_4_spa_root_falls_back_when_dist_missing(tmp_path, monkeypatch) -> None:
    """T10.4 (R10, EC-10.3): falls back to DASHBOARD_DIR when dist absent."""
    import dashboard.server.app as app_module

    monkeypatch.setattr(app_module, "_APP_DIST", tmp_path / "nope")
    assert app_module._resolve_spa_root() == app_module._DASHBOARD_DIR


def test_t10_5_spa_catchall_serves_index_html_for_non_api_path(tmp_path) -> None:
    """T10.5 (R10, AS-3, DN-6): GET /watchfloor → 200 with index.html bytes."""
    fake_dist = tmp_path / "dist"
    fake_dist.mkdir()
    index_bytes = b"<html><body>SPA</body></html>"
    (fake_dist / "index.html").write_bytes(index_bytes)

    test_app = _build_test_app_with_spa_root(fake_dist)
    client = TestClient(test_app)
    response = client.get("/watchfloor")
    assert response.status_code == 200
    assert response.content == index_bytes


def test_t10_6_root_path_serves_index_html(tmp_path) -> None:
    """T10.6 (R10): GET / → 200 with index.html bytes."""
    fake_dist = tmp_path / "dist"
    fake_dist.mkdir()
    index_bytes = b"<html><body>ROOT</body></html>"
    (fake_dist / "index.html").write_bytes(index_bytes)

    test_app = _build_test_app_with_spa_root(fake_dist)
    client = TestClient(test_app)
    response = client.get("/")
    assert response.status_code == 200
    assert response.content == index_bytes


def test_t10_7_static_asset_returned_when_present(tmp_path) -> None:
    """T10.7 (R10, EC-10.2): GET /assets/foo.js returns the file, NOT index.html."""
    fake_dist = tmp_path / "dist"
    (fake_dist / "assets").mkdir(parents=True)
    asset_bytes = b"console.log('hi');\n"
    (fake_dist / "assets" / "foo.js").write_bytes(asset_bytes)
    (fake_dist / "index.html").write_bytes(b"<html>SPA</html>")

    test_app = _build_test_app_with_spa_root(fake_dist)
    client = TestClient(test_app)
    response = client.get("/assets/foo.js")
    assert response.status_code == 200
    assert response.content == asset_bytes


def test_t10_8_no_index_html_returns_404_fail_closed(tmp_path) -> None:
    """T10.8 (R10, EC-10.3 fail-closed): empty SPA root → 404 (no silent empty body)."""
    empty_dir = tmp_path / "empty"
    empty_dir.mkdir()
    test_app = _build_test_app_with_spa_root(empty_dir)
    client = TestClient(test_app)
    response = client.get("/watchfloor")
    assert response.status_code == 404


def test_t10_9_health_route_not_shadowed_by_spa_mount() -> None:
    """T10.9 (R10, EC-10.4): GET /health is the existing JSON handler, not HTML."""
    from dashboard.server.app import app

    client = TestClient(app)
    response = client.get("/health")
    assert response.status_code == 200
    body = response.json()
    assert set(body.keys()) == {"status", "version", "ts"}


# ---------------------------------------------------------------------------
# T12.* — Unported endpoints return HTML 404 via R10 handler
# (T0.2.b update: T12.1 retired — /api/autopilots is now a ported endpoint;
# T0.2.c update: T12.2/T12.3 retired — /api/grinder/stream and POST
# /api/grinder/pause are now ported endpoints with their own validation
# chains; the fallback no longer fires for these paths. The fallback
# rendering itself is still covered by T-AR-8 (GET /api/typo).)
# ---------------------------------------------------------------------------


def test_t12_2_ported_grinder_stream_validates_input_html_400() -> None:
    """T12.2 (R7, R10): /api/grinder/stream is ported (T0.2.c) — missing
    ``project`` returns HTML 400 from its own validator, NOT the fallback 404.
    """
    from dashboard.server.app import app

    client = TestClient(app)
    response = client.get("/api/grinder/stream")
    assert response.status_code == 400
    assert response.headers["content-type"] == "text/html;charset=utf-8"
    assert b"<p>Message: Missing or invalid project parameter.</p>" in response.content


def test_t12_3_ported_grinder_pause_post_validates_input_html_400() -> None:
    """T12.3 (R8, R10): POST /api/grinder/pause is ported (T0.2.c) — missing
    ``project`` returns HTML 400 from its own validator, NOT the fallback 404.
    """
    from dashboard.server.app import app

    client = TestClient(app)
    token = _csrf_token(client)
    response = client.post(
        "/api/grinder/pause", headers={"X-CSRF-Token": token, "Origin": "http://127.0.0.1:8787"}
    )
    assert response.status_code == 400
    assert response.headers["content-type"] == "text/html;charset=utf-8"
    assert b"<p>Message: Missing or invalid project parameter.</p>" in response.content


# ---------------------------------------------------------------------------
# T-AR-* — T0.2.b additions: handler registration + POST/DELETE fallbacks
# ---------------------------------------------------------------------------


def test_t_ar_1_starlette_http_exception_handler_registered() -> None:
    """T-AR-1 (R10, AS-1): StarletteHTTPException is in app.exception_handlers."""
    from starlette.exceptions import HTTPException as StarletteHTTPException

    from dashboard.server.app import app

    assert StarletteHTTPException in app.exception_handlers


def test_t_ar_2_exception_handler_registered() -> None:
    """T-AR-2 (R10, OQ#5): Exception is in app.exception_handlers."""
    from dashboard.server.app import app

    assert Exception in app.exception_handlers


def test_t_ar_3_handler_identity_is_html_4xx_handler() -> None:
    """T-AR-3 (R10): the registered handler IS the C2 function (not a lambda)."""
    from starlette.exceptions import HTTPException as StarletteHTTPException

    from dashboard.server._exception_handlers import html_4xx_handler, html_500_handler
    from dashboard.server.app import app

    assert app.exception_handlers[StarletteHTTPException] is html_4xx_handler
    assert app.exception_handlers[Exception] is html_500_handler


def test_t_ar_4_route_table_includes_autopilot_paths() -> None:
    """T-AR-4 (R1, R12): app.routes contains all 7 core + 7 autopilot + fallback."""
    from dashboard.server.app import app

    paths = {getattr(r, "path", None) for r in app.routes}
    expected_api_paths = {
        # core (T0.2.a)
        "/api/flow-status",
        "/api/worktrees",
        "/api/plan",
        "/api/plans",
        "/api/sessions",
        "/api/features",
        "/api/metrics",
        # autopilot (T0.2.b)
        "/api/autopilots",
        "/api/autopilot/log",
        "/api/autopilot/stream",
        "/api/autopilot/summary",
        "/api/autopilot/artifacts",
        "/api/autopilot/artifact",
        "/api/autopilot/activity",
    }
    assert expected_api_paths <= paths
    assert "/api/{rest:path}" in paths


def test_t_ar_5_post_grinder_pause_unknown_project_html_404() -> None:
    """T-AR-5 (R8, R10): POST /api/grinder/pause is ported (T0.2.c). For an
    unknown project the ported handler returns HTML 404 with the
    project-not-found message — this is the byte-equivalent path captured in
    ``post-api-grinder-pause.json``. The earlier OQ#3 fallback is no longer
    on this path.
    """
    from dashboard.server.app import app

    client = TestClient(app)
    token = _csrf_token(client)
    response = client.post(
        "/api/grinder/pause?project=zzznonexistent",
        headers={"X-CSRF-Token": token, "Origin": "http://127.0.0.1:8787"},
    )
    assert response.status_code == 404
    assert response.headers["content-type"] == "text/html;charset=utf-8"
    assert b"<p>Message: Project not found or has no grinder data.</p>" in response.content


def test_t_ar_6_delete_grinder_pause_unknown_project_html_404() -> None:
    """T-AR-6 (R9, R10): DELETE /api/grinder/pause is ported (T0.2.c). For an
    unknown project the ported handler returns HTML 404 with the
    project-not-found message — byte-equivalent to
    ``delete-api-grinder-pause.json``.
    """
    from dashboard.server.app import app

    client = TestClient(app)
    token = _csrf_token(client)
    response = client.delete(
        "/api/grinder/pause?project=zzznonexistent",
        headers={"X-CSRF-Token": token, "Origin": "http://127.0.0.1:8787"},
    )
    assert response.status_code == 404
    assert response.headers["content-type"] == "text/html;charset=utf-8"
    assert b"<p>Message: Project not found or has no grinder data.</p>" in response.content


def test_t_ar_7_put_grinder_pause_is_html_405(client_factory_only=None) -> None:
    """T-AR-7 (EC-12.1): PUT (no fallback) → 405 with HTML rendered by R10."""
    from dashboard.server.app import app

    client = TestClient(app)
    token = _csrf_token(client)
    response = client.put(
        "/api/grinder/pause?project=zzznonexistent",
        headers={"X-CSRF-Token": token, "Origin": "http://127.0.0.1:8787"},
    )
    assert response.status_code == 405
    assert response.headers["content-type"] == "text/html;charset=utf-8"
    assert b"<p>Message: Method Not Allowed.</p>" in response.content


def test_t_ar_8_get_typo_is_html_404() -> None:
    """T-AR-8 (R12, EC-12.2): GET /api/typo → 404 caught by GET fallback, HTML body."""
    from dashboard.server.app import app

    client = TestClient(app)
    response = client.get("/api/typo")
    assert response.status_code == 404
    assert response.headers["content-type"] == "text/html;charset=utf-8"
    assert b"<p>Message: Not Found.</p>" in response.content


def test_t_ar_9_get_autopilots_returns_200_via_include_router() -> None:
    """T-AR-9 (R1, R11): /api/autopilots is auto-picked-up by include_router."""
    from dashboard.server.app import app

    client = TestClient(app)
    response = client.get("/api/autopilots")
    # Hermetic env: discover_autopilots returns []. With or without hermetic
    # fixture the response MUST be 200 (route registered) — and the body MUST
    # be a JSON list (not HTML).
    assert response.status_code == 200
    assert response.headers["content-type"] == "application/json; charset=utf-8"
    assert response.content.startswith(b"[")
    assert response.content.endswith(b"]")


def test_t_ar_10_handlers_present_at_import_time() -> None:
    """T-AR-10 (R10, Risk-C): handlers in registry as soon as app is imported."""
    from dashboard.server.app import app

    assert len(app.exception_handlers) >= 2
