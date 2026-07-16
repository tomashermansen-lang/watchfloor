#!/usr/bin/env bash
# test_start_system_dashboard.sh — TDD harness for the fastapi-cutover (T0.3)
# launcher swap. Covers the new helpers ``ensure_port_free`` and
# ``wait_for_health`` and the rewritten ``start_dashboard()`` body in
# start-system.sh.
#
# Test types per TESTPLAN § Test Type Legend:
#   * bash-unit (C1.a / C1.b / white-box C1.c) — source start-system.sh under
#     ``set +e`` and call helpers directly.
#   * bash-int (C1.c full-launcher) — booted under ``DASHBOARD_PORT`` random
#     high port; trapped to ``start-system stop``. Skipped on any host where
#     the workspace .venv is unprovisioned (uvicorn would not be importable).
#
# Risk-C: production timeout for ``wait_for_health`` is 30s; tests override
# via ``DASHBOARD_HEALTH_TIMEOUT=2`` (test-only sentinel; production code
# never sets it).
#
# Usage: bash tests/test_start_system_dashboard.sh

set -uo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
START_SYSTEM="$REPO_DIR/start-system.sh"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'

passed=0
failed=0

check() {
    local name="$1"
    shift
    if "$@"; then
        echo -e "${GREEN}✓${NC} $name"
        passed=$((passed + 1))
    else
        echo -e "${RED}✗${NC} $name"
        failed=$((failed + 1))
    fi
}

# ─── Source helpers without invoking the case dispatch ───────────────
# start-system.sh runs a `case "${1:-all}"` at the bottom; we sniff arg 0
# of the bash subshell. Sourcing under "noop" arg keeps the dispatch in
# the * branch which prints usage and exits 1. We instead set
# DASHBOARD_TEST_NO_DISPATCH=1 (introduced by C1) to tell the script to
# skip the case dispatch when sourced for testing.
load_helpers() {
    DASHBOARD_TEST_NO_DISPATCH=1 source "$START_SYSTEM"
}

# Pick a free random high port via Python so we don't collide with any
# local dashboard.
pick_free_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()'
}

# ─── C1.a: ensure_port_free ──────────────────────────────────────────

test_ensure_port_free_when_port_is_free() {
    (
        load_helpers
        local port
        port=$(pick_free_port)
        local stderr
        stderr=$(ensure_port_free "$port" 2>&1 >/dev/null)
        [ -z "$stderr" ] || { echo "stderr: $stderr"; return 1; }
        ensure_port_free "$port"
    )
}

test_ensure_port_free_when_port_is_bound() {
    (
        load_helpers
        local port
        port=$(pick_free_port)
        # Bind the port with a background http.server fixture.
        python3 -m http.server "$port" >/dev/null 2>&1 &
        local fixture_pid=$!
        # Give the server a moment to bind.
        sleep 0.3
        local rc=0
        local stderr
        stderr=$(ensure_port_free "$port" 2>&1 >/dev/null) || rc=$?
        # Fixture must still be alive (R5 fail-closed: no auto-kill).
        kill -0 "$fixture_pid" 2>/dev/null || {
            echo "fixture pid $fixture_pid was killed by helper — R5 violation"
            kill "$fixture_pid" 2>/dev/null || true
            return 1
        }
        kill "$fixture_pid" 2>/dev/null || true
        wait "$fixture_pid" 2>/dev/null || true
        [ "$rc" -eq 1 ] || { echo "expected exit 1, got $rc"; return 1; }
        echo "$stderr" | grep -qF "Error: port $port already in use; refusing to start dashboard"
    )
}

test_ensure_port_free_rejects_non_numeric_port() {
    (
        load_helpers
        local rc=0
        ensure_port_free abc >/dev/null 2>&1 || rc=$?
        [ "$rc" -eq 1 ]
    )
}

# ─── C1.b: wait_for_health ───────────────────────────────────────────

# Spawn a tiny http.server that returns 200 on /health.
spawn_health_fixture_200() {
    local port=$1
    python3 -c "
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/health':
            self.send_response(200); self.end_headers(); self.wfile.write(b'ok')
        else:
            self.send_error(404)
    def log_message(self, *a, **kw): pass
http.server.HTTPServer(('127.0.0.1', $port), H).serve_forever()
" >/dev/null 2>&1 &
    echo $!
}

# Spawn a tiny http.server that always returns 503.
spawn_health_fixture_503() {
    local port=$1
    python3 -c "
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_error(503)
    def log_message(self, *a, **kw): pass
http.server.HTTPServer(('127.0.0.1', $port), H).serve_forever()
" >/dev/null 2>&1 &
    echo $!
}

test_wait_for_health_returns_zero_when_server_returns_200() {
    (
        load_helpers
        local port
        port=$(pick_free_port)
        local pid
        pid=$(spawn_health_fixture_200 "$port")
        sleep 0.3
        local rc=0
        DASHBOARD_HEALTH_TIMEOUT=2 wait_for_health "$port" "Test API" >/dev/null || rc=$?
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        [ "$rc" -eq 0 ]
    )
}

test_wait_for_health_times_out_when_server_returns_503() {
    (
        load_helpers
        local port
        port=$(pick_free_port)
        local pid
        pid=$(spawn_health_fixture_503 "$port")
        sleep 0.3
        local rc=0
        local stderr
        stderr=$(DASHBOARD_HEALTH_TIMEOUT=2 wait_for_health "$port" "Test API" 2>&1 >/dev/null) || rc=$?
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
        [ "$rc" -eq 1 ] || { echo "expected exit 1, got $rc"; return 1; }
        echo "$stderr" | grep -qF "uv sync --extra dev"
    )
}

test_wait_for_health_times_out_on_unbound_port() {
    (
        load_helpers
        local port
        port=$(pick_free_port)
        local rc=0
        DASHBOARD_HEALTH_TIMEOUT=2 wait_for_health "$port" "Test API" >/dev/null 2>&1 || rc=$?
        [ "$rc" -eq 1 ]
    )
}

test_wait_for_health_production_default_is_30s() {
    # White-box (C1B-06): the helper body must reference the documented 30s
    # production sentinel so future edits don't silently drift.
    grep -qE 'DASHBOARD_HEALTH_TIMEOUT:?-30' "$START_SYSTEM"
}

# ─── C1.c: start_dashboard body white-box checks ─────────────────────

test_start_dashboard_does_not_call_kill_ports() {
    # C1C-08: the rewritten body must NOT auto-kill on conflict.
    awk '/^start_dashboard\(\)/,/^}/' "$START_SYSTEM" | grep -qE 'kill_ports' && return 1
    return 0
}

test_start_dashboard_invokes_wait_for_health_not_wait_for_port() {
    # C1C-09: dashboard start uses wait_for_health, not wait_for_port.
    # Strip comment lines so prose mentioning the deprecated helper doesn't
    # trip the test.
    local body
    body=$(awk '/^start_dashboard\(\)/,/^}/' "$START_SYSTEM" | grep -vE '^[[:space:]]*#')
    echo "$body" | grep -qE 'wait_for_port' && return 1
    echo "$body" | grep -qE 'wait_for_health'
}

test_wait_for_port_definition_preserved_for_oih_eulex() {
    # C1C-10: wait_for_port stays defined for start_oih / start_eulex (EC-15).
    grep -cE '^wait_for_port\(\)' "$START_SYSTEM" | grep -qx 1
}

test_start_dashboard_returns_not_exits() {
    # C1C-11: function uses `return 1`, NOT `exit 1`, so callers under
    # `set -e` decide propagation behavior (Risk-A). Strip comments so
    # prose like "(NOT exit 1)" doesn't masquerade as a real `exit 1`.
    local body
    body=$(awk '/^start_dashboard\(\)/,/^}/' "$START_SYSTEM" | grep -vE '^[[:space:]]*#')
    echo "$body" | grep -qE '\bexit\s+1\b' && return 1
    echo "$body" | grep -qE '\breturn\s+1\b'
}

test_start_dashboard_argv_contains_uvicorn_against_fastapi_app() {
    # C1C-02 white-box: the body composes a uvicorn argv pointing at the
    # FastAPI app, with the literal --host 127.0.0.1.
    local body
    body=$(awk '/^start_dashboard\(\)/,/^}/' "$START_SYSTEM")
    echo "$body" | grep -qF 'uvicorn dashboard.server.app:app' || {
        echo "$body" | grep -qE 'uvicorn[^"]*dashboard\.server\.app:app'
    } || return 1
    echo "$body" | grep -qF -- '--host 127.0.0.1'
}

test_start_dashboard_dev_branch_appends_reload() {
    # C1C-04 white-box: DASHBOARD_ENV=dev appends --reload --reload-dir.
    local body
    body=$(awk '/^start_dashboard\(\)/,/^}/' "$START_SYSTEM")
    echo "$body" | grep -qE '\bDASHBOARD_ENV.*dev\b' || return 1
    echo "$body" | grep -qF -- '--reload'
    echo "$body" | grep -qF -- '--reload-dir dashboard/server'
}

test_start_dashboard_dashboard_port_with_backend_fallback() {
    # R13: DASHBOARD_PORT canonical, DASHBOARD_BACKEND fallback.
    local body
    body=$(awk '/^start_dashboard\(\)/,/^}/' "$START_SYSTEM")
    echo "$body" | grep -qE 'DASHBOARD_PORT.*:-.*DASHBOARD_BACKEND'
}

# ─── Run ──────────────────────────────────────────────────────────────

echo "=== start-system.sh dashboard launcher tests ==="

check "C1A-01: ensure_port_free returns 0 on free port" test_ensure_port_free_when_port_is_free
check "C1A-02 + C1A-03: ensure_port_free returns 1 + leaves fixture alive" test_ensure_port_free_when_port_is_bound
check "C1A-05: ensure_port_free rejects non-numeric port" test_ensure_port_free_rejects_non_numeric_port

check "C1B-01: wait_for_health returns 0 on /health 200" test_wait_for_health_returns_zero_when_server_returns_200
check "C1B-02: wait_for_health times out + emits venv hint" test_wait_for_health_times_out_when_server_returns_503
check "C1B-03: wait_for_health times out on unbound port" test_wait_for_health_times_out_on_unbound_port
check "C1B-06: production timeout default is 30s" test_wait_for_health_production_default_is_30s

check "C1C-08: start_dashboard does NOT call kill_ports" test_start_dashboard_does_not_call_kill_ports
check "C1C-09: start_dashboard uses wait_for_health, not wait_for_port" test_start_dashboard_invokes_wait_for_health_not_wait_for_port
check "C1C-10: wait_for_port definition preserved" test_wait_for_port_definition_preserved_for_oih_eulex
check "C1C-11: start_dashboard returns, not exits (Risk-A)" test_start_dashboard_returns_not_exits
check "C1C-02: start_dashboard argv has uvicorn + FastAPI app + 127.0.0.1" test_start_dashboard_argv_contains_uvicorn_against_fastapi_app
check "C1C-04: DASHBOARD_ENV=dev branch appends --reload + --reload-dir" test_start_dashboard_dev_branch_appends_reload
check "R13:    DASHBOARD_PORT canonical with DASHBOARD_BACKEND fallback" test_start_dashboard_dashboard_port_with_backend_fallback

# ─── C2: per-service stop functions ───────────────────────────────────
# Goal: `stop_dashboard` kills ONLY DASHBOARD_BACKEND + DASHBOARD_FRONTEND.
# It must not kill SONARQUBE_PORT, OIH_BACKEND, etc. The legacy
# `stop_all` (matching `start-system stop` with no second arg) keeps its
# old behaviour for backward compat.

test_stop_dashboard_function_exists() {
    grep -qE '^stop_dashboard\(\)' "$START_SYSTEM"
}

test_stop_oih_function_exists() {
    grep -qE '^stop_oih\(\)' "$START_SYSTEM"
}

test_stop_eulex_function_exists() {
    grep -qE '^stop_eulex\(\)' "$START_SYSTEM"
}

test_stop_sonarqube_function_exists() {
    grep -qE '^stop_sonarqube\(\)' "$START_SYSTEM"
}

test_stop_dashboard_only_kills_dashboard_ports() {
    # White-box: stop_dashboard must call kill_ports with the two dashboard
    # ports — and must NOT mention SONARQUBE_PORT, OIH_*, EULEX_*.
    local body
    body=$(awk '/^stop_dashboard\(\)/,/^}/' "$START_SYSTEM")
    echo "$body" | grep -qE 'DASHBOARD_BACKEND' || return 1
    echo "$body" | grep -qE 'DASHBOARD_FRONTEND' || return 1
    echo "$body" | grep -qE 'SONARQUBE_PORT' && return 1
    echo "$body" | grep -qE 'OIH_BACKEND|OIH_FRONTEND' && return 1
    echo "$body" | grep -qE 'EULEX_BACKEND|EULEX_FRONTEND' && return 1
    return 0
}

test_stop_oih_only_kills_oih_ports() {
    local body
    body=$(awk '/^stop_oih\(\)/,/^}/' "$START_SYSTEM")
    echo "$body" | grep -qE 'OIH_BACKEND' || return 1
    echo "$body" | grep -qE 'OIH_FRONTEND' || return 1
    echo "$body" | grep -qE 'SONARQUBE_PORT' && return 1
    echo "$body" | grep -qE 'DASHBOARD_BACKEND|DASHBOARD_FRONTEND' && return 1
    return 0
}

test_stop_eulex_only_kills_eulex_ports() {
    local body
    body=$(awk '/^stop_eulex\(\)/,/^}/' "$START_SYSTEM")
    echo "$body" | grep -qE 'EULEX_BACKEND' || return 1
    echo "$body" | grep -qE 'EULEX_FRONTEND' || return 1
    echo "$body" | grep -qE 'SONARQUBE_PORT' && return 1
    echo "$body" | grep -qE 'DASHBOARD_BACKEND|DASHBOARD_FRONTEND' && return 1
    return 0
}

test_stop_oih_brings_down_docker_stack() {
    # OIH's docker stack (postgres + langfuse) is opt-in, started by
    # start_oih. To keep start/stop symmetric, stop_oih must also bring
    # the stack down — otherwise `start-system stop` leaves heavy
    # containers running indefinitely.
    local body
    body=$(awk '/^stop_oih\(\)/,/^}/' "$START_SYSTEM")
    echo "$body" | grep -qE 'docker compose stop'
}

test_stop_sonarqube_uses_docker_compose_stop() {
    # Sonar runs as a Docker container; killing the host-side port confuses
    # the container. The graceful stop is `docker compose stop`.
    local body
    body=$(awk '/^stop_sonarqube\(\)/,/^}/' "$START_SYSTEM")
    echo "$body" | grep -qE 'docker compose stop'
}

test_stop_sonarqube_does_not_kill_port() {
    # Sanity: stop_sonarqube must NOT call kill_port directly — Docker
    # owns the port lifecycle.
    local body
    body=$(awk '/^stop_sonarqube\(\)/,/^}/' "$START_SYSTEM")
    echo "$body" | grep -qE 'kill_port' && return 1
    return 0
}

# ─── C3: smart sonar start ────────────────────────────────────────────

test_start_sonarqube_does_not_kill_port() {
    # Removing the kill_port call eliminates the Docker-container friction
    # that motivated this redesign. Container lifecycle is Docker's job.
    # Strip comments so prose mentioning the deprecated kill_port doesn't
    # masquerade as a real call (same shape as C1C-09).
    local body
    body=$(awk '/^start_sonarqube\(\)/,/^}/' "$START_SYSTEM" | grep -vE '^[[:space:]]*#')
    echo "$body" | grep -qE 'kill_port' && return 1
    return 0
}

test_start_sonarqube_skips_when_already_up() {
    # Smart-detect: if /api/system/status reports UP, no-op.
    local body
    body=$(awk '/^start_sonarqube\(\)/,/^}/' "$START_SYSTEM")
    echo "$body" | grep -qE 'api/system/status'
}

# ─── C4: dispatch — stop <service>, restart <service>, status ────────

test_dispatch_handles_stop_dashboard() {
    grep -qE '^[[:space:]]*dashboard\)[[:space:]]*stop_dashboard' "$START_SYSTEM"
}

test_dispatch_handles_stop_oih() {
    grep -qE '^[[:space:]]*oih\)[[:space:]]*stop_oih' "$START_SYSTEM"
}

test_dispatch_handles_stop_sonarqube() {
    grep -qE '^[[:space:]]*sonarqube\)[[:space:]]*stop_sonarqube' "$START_SYSTEM"
}

test_dispatch_stop_no_arg_remains_stop_all() {
    # Backward compat: `start-system stop` (no second arg) keeps stop_all
    # behaviour so existing operator habits don't break.
    grep -qE 'stop_all' "$START_SYSTEM"
}

test_dispatch_handles_restart() {
    # `start-system restart <service>` — wraps stop+sleep+start.
    grep -qE '^[[:space:]]*restart\)' "$START_SYSTEM"
}

test_dispatch_handles_status() {
    # `start-system status` — no-op probe, never starts/stops anything.
    grep -qE '^[[:space:]]*status\)' "$START_SYSTEM"
}

# ─── C5: lenient `all` ───────────────────────────────────────────────

test_all_mode_does_not_bail_on_partial_failure() {
    # `all` starts the defaults (dashboard + sonarqube) only — OIH and
    # Eulex are opt-in. Each call in the all-branch must be guarded with
    # `|| true` so a failing one doesn't abort the rest.
    local body
    body=$(awk '/^[[:space:]]*all\)/,/^[[:space:]]*;;/' "$START_SYSTEM")
    echo "$body" | grep -qE 'start_dashboard.*\|\|.*true' || return 1
    echo "$body" | grep -qE 'start_sonarqube.*\|\|.*true' || return 1
    # OIH + Eulex must NOT be invoked from the default `all` branch.
    # Mention of their names in the *comment block* is fine — match only
    # actual invocations (line starts with the call, after whitespace).
    if echo "$body" | grep -qE '^[[:space:]]*start_oih([[:space:]]|$)'; then
        return 1
    fi
    if echo "$body" | grep -qE '^[[:space:]]*start_eulex([[:space:]]|$)'; then
        return 1
    fi
    return 0
}

check "C2-01: stop_dashboard function exists" test_stop_dashboard_function_exists
check "C2-02: stop_oih function exists" test_stop_oih_function_exists
check "C2-03: stop_eulex function exists" test_stop_eulex_function_exists
check "C2-04: stop_sonarqube function exists" test_stop_sonarqube_function_exists
check "C2-05: stop_dashboard kills only dashboard ports" test_stop_dashboard_only_kills_dashboard_ports
check "C2-06: stop_oih kills only oih ports" test_stop_oih_only_kills_oih_ports
check "C2-07: stop_eulex kills only eulex ports" test_stop_eulex_only_kills_eulex_ports
check "C2-08: stop_sonarqube uses docker compose stop" test_stop_sonarqube_uses_docker_compose_stop
check "C2-10: stop_oih brings down docker stack" test_stop_oih_brings_down_docker_stack
check "C2-09: stop_sonarqube does NOT kill_port" test_stop_sonarqube_does_not_kill_port

check "C3-01: start_sonarqube does NOT kill_port" test_start_sonarqube_does_not_kill_port
check "C3-02: start_sonarqube health-check skip path" test_start_sonarqube_skips_when_already_up

check "C4-01: dispatch — stop dashboard" test_dispatch_handles_stop_dashboard
check "C4-02: dispatch — stop oih" test_dispatch_handles_stop_oih
check "C4-03: dispatch — stop sonarqube" test_dispatch_handles_stop_sonarqube
check "C4-04: dispatch — stop (no arg) → stop_all (BC)" test_dispatch_stop_no_arg_remains_stop_all
check "C4-05: dispatch — restart <service>" test_dispatch_handles_restart
check "C4-06: dispatch — status" test_dispatch_handles_status

check "C5-01: all-mode lenient (|| true on each start_*)" test_all_mode_does_not_bail_on_partial_failure

echo ""
echo "Passed: $passed"
echo "Failed: $failed"
[ "$failed" -eq 0 ]
