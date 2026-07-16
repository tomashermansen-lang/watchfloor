#!/usr/bin/env bash
set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  System Startup Script — Reserved Port Registry
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#
#  Port Reservations:
#  ┌──────────────────────┬────────────┬───────────────────┐
#  │ Project              │ Backend    │ Frontend          │
#  ├──────────────────────┼────────────┼───────────────────┤
#  │ Claude Dashboard     │ 8787       │ 5175 (vite dev)   │
#  │ OIH                  │ 8100       │ 5174              │
#  │ Eulex RAG            │ 8200       │ 5173              │
#  │ SonarQube            │ 9100       │ —                 │
#  └──────────────────────┴────────────┴───────────────────┘
#
#  OIH Docker services (unchanged):
#    Postgres:  5432 (main), 5433 (test)
#    Langfuse:  3000
#
#  Usage:
#    start-system                       # start defaults: dashboard + sonarqube
#    start-system dashboard             # start only dashboard
#    start-system oih                   # start OIH (incl. docker postgres + langfuse) — opt-in
#    start-system oih /path/to/worktree # start OIH from specific worktree
#    start-system eulex                 # start only Eulex RAG — opt-in
#    start-system sonarqube             # start only SonarQube
#    start-system stop                  # kill all reserved ports
#    start-system check                 # pre-flight health check
#
#  OIH + Eulex are NOT in `start-system all` — they only start when
#  explicitly invoked. OIH's docker stack (postgres + langfuse) is heavy
#  and rarely needed for dashboard work, so we keep it off by default.
#  `stop_oih` brings the docker stack down symmetrically.
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# ── Port Definitions ─────────────────────────────────────
DASHBOARD_BACKEND=8787
DASHBOARD_FRONTEND=5175

OIH_BACKEND=8100
OIH_FRONTEND=5174

EULEX_BACKEND=8200
EULEX_FRONTEND=5173

SONARQUBE_PORT=9100

ALL_PORTS=(
  "$DASHBOARD_BACKEND" "$DASHBOARD_FRONTEND"
  "$OIH_BACKEND" "$OIH_FRONTEND"
  "$EULEX_BACKEND" "$EULEX_FRONTEND"
  "$SONARQUBE_PORT"
)

# ── Project Paths ────────────────────────────────────────
# Override via env vars or ~/.claude/project-dirs.conf (KEY=value, one per line)
CONF_FILE="${HOME}/.claude/project-dirs.conf"
if [[ -f "$CONF_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$CONF_FILE"
fi

PROJECTS_ROOT="${PROJECTS_ROOT:-$HOME/Projekter}"
DASHBOARD_DIR="${DASHBOARD_DIR:-$PROJECTS_ROOT/dotfiles/dashboard}"
# Repo root containing this script — used by error hints to point operators at
# the correct `uv sync` location (R4 / EC-2 / EC-3).
REPO_ROOT_HINT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OIH_DIR="${OIH_DIR:-$PROJECTS_ROOT/OIH}"
EULEX_DIR="${EULEX_DIR:-$PROJECTS_ROOT/eulex-single-law-retrieval-artikel99}"
SONARQUBE_DIR="${SONARQUBE_DIR:-$PROJECTS_ROOT/sonarqube}"

# ── Helpers ──────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ── Worktree Detection ──────────────────────────────────
# Resolve a project directory: use explicit arg, detect from $PWD, or default.
# Usage: resolve_project_dir <default_dir> [explicit_override]
resolve_project_dir() {
  local default_dir=$1
  local override=${2:-}

  # 1. Explicit override takes priority
  if [[ -n "$override" ]]; then
    if git -C "$override" rev-parse --git-dir &>/dev/null; then
      echo "$override"
      return 0
    else
      echo -e "  ${RED}Warning:${NC} $override is not a git directory, using default" >&2
    fi
  fi

  # 2. Try to detect worktree from $PWD
  local main_common pwd_common main_repo pwd_repo
  main_repo=$(cd "$default_dir" && git rev-parse --show-toplevel 2>/dev/null) || { echo "$default_dir"; return 0; }
  pwd_repo=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "$default_dir"; return 0; }
  main_common=$(cd "$default_dir" && realpath "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null)
  pwd_common=$(realpath "$(git rev-parse --git-common-dir 2>/dev/null)" 2>/dev/null)

  if [[ "$main_common" == "$pwd_common" && "$pwd_repo" != "$main_repo" ]]; then
    echo -e "  ${CYAN}Worktree detected:${NC} $pwd_repo" >&2
    echo "$pwd_repo"
    return 0
  fi

  # 3. Fall back to default
  echo "$default_dir"
}

kill_port() {
  local port=$1
  local pids
  pids=$(lsof -ti :"$port" 2>/dev/null || true)
  if [[ -n "$pids" ]]; then
    echo -e "  ${RED}Killing${NC} port $port (PIDs: $pids)"
    echo "$pids" | xargs kill -9 2>/dev/null || true
  fi
}

kill_ports() {
  local ports=("$@")
  for port in "${ports[@]}"; do
    kill_port "$port"
  done
}

wait_for_port() {
  local port=$1 name=$2 timeout=15
  for ((i=0; i<timeout; i++)); do
    if lsof -ti :"$port" &>/dev/null; then
      echo -e "  ${GREEN}✓${NC} $name ready on port $port"
      return 0
    fi
    sleep 1
  done
  echo -e "  ${RED}✗${NC} $name failed to start on port $port"
  return 1
}

# ── Dashboard launcher helpers (fastapi-cutover, T0.3) ─────────────
# ensure_port_free <port> — return 0 if port is free, 1 if bound. The
# helper does NOT kill the conflicting process (R5 fail-closed); it
# only detects. Detection prefers `lsof -ti` (already in PATH for
# kill_port) and falls back to bash `/dev/tcp` if lsof is missing
# (Risk-E, sandboxed environments).
ensure_port_free() {
  local port=$1
  # Reject non-numeric ports defensively (EC-4 / EC-11 — defends shell-
  # injection vectors at the helper boundary).
  if ! [[ "$port" =~ ^[0-9]+$ ]]; then
    echo -e "${RED}Error:${NC} ensure_port_free: invalid port '$port'" >&2
    return 1
  fi
  local bound=0
  if command -v lsof >/dev/null 2>&1; then
    if lsof -ti :"$port" >/dev/null 2>&1; then
      bound=1
    fi
  else
    if (echo > "/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1; then
      bound=1
    fi
  fi
  if [[ "$bound" -eq 1 ]]; then
    echo "Error: port $port already in use; refusing to start dashboard" >&2
    return 1
  fi
  return 0
}

# wait_for_health <port> <name> — poll http://127.0.0.1:<port>/health
# until 200 OK or timeout. Production timeout is 30s with 0.5s cadence
# (60 iterations). Risk-C: tests override via DASHBOARD_HEALTH_TIMEOUT.
wait_for_health() {
  local port=$1 name=$2
  local timeout=${DASHBOARD_HEALTH_TIMEOUT:-30}
  # 0.5s cadence → iterations = timeout * 2.
  local iterations=$((timeout * 2))
  local i
  for ((i=0; i<iterations; i++)); do
    if curl -sf "http://127.0.0.1:$port/health" >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} $name ready on port $port"
      return 0
    fi
    sleep 0.5
  done
  echo -e "  ${RED}✗${NC} $name failed to become healthy on port $port within ${timeout}s" >&2
  echo -e "    Hint: workspace .venv may be missing fastapi/uvicorn — run: cd \"$REPO_ROOT_HINT\" && uv sync --extra dev" >&2
  return 1
}

# ── Pre-Flight Health Check ──────────────────────────────
check_health() {
  local errors=0
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  Pre-Flight Health Check${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""

  # Git auth
  if git ls-remote --heads "$OIH_DIR" &>/dev/null 2>&1 || \
     git -C "$OIH_DIR" ls-remote --heads origin &>/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Git authentication valid"
  else
    echo -e "  ${RED}✗${NC} Git authentication failed"
    echo -e "    Fix: gh auth login --insecure-storage -h github.com -p https"
    ((errors++))
  fi

  # Docker
  if docker info &>/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} Docker daemon running"
  else
    echo -e "  ${YELLOW}⚠${NC} Docker not available (OIH postgres/langfuse will be skipped)"
  fi

  # Port conflicts
  local conflicts=0
  for port in "${ALL_PORTS[@]}"; do
    if lsof -ti :"$port" &>/dev/null; then
      local proc
      proc=$(lsof -ti :"$port" 2>/dev/null | head -1)
      local name
      name=$(ps -p "$proc" -o comm= 2>/dev/null || echo "unknown")
      echo -e "  ${YELLOW}⚠${NC} Port $port already in use by $name (PID $proc)"
      ((conflicts++))
    fi
  done
  if [[ $conflicts -eq 0 ]]; then
    echo -e "  ${GREEN}✓${NC} All reserved ports free"
  fi

  # Python venvs
  for proj_dir in "$OIH_DIR" "$EULEX_DIR" "$DASHBOARD_DIR"; do
    local proj_name
    proj_name=$(basename "$proj_dir")
    if [[ -x "$proj_dir/.venv/bin/python" ]]; then
      echo -e "  ${GREEN}✓${NC} Python venv: $proj_name"
    elif [[ "$proj_name" == "OIH" ]]; then
      # OIH uses uv, not venv
      if command -v uv &>/dev/null; then
        echo -e "  ${GREEN}✓${NC} uv available for OIH"
      else
        echo -e "  ${RED}✗${NC} uv not found (needed for OIH)"
        ((errors++))
      fi
    else
      echo -e "  ${YELLOW}⚠${NC} No .venv in $proj_name"
    fi
  done

  # Node modules. Suggest the right install command per project — dashboard
  # is on pnpm (a77203e), OIH + EULEX still on npm.
  for ui_dir in "$DASHBOARD_DIR/app" "$OIH_DIR/ui" "$EULEX_DIR/ui_react/frontend"; do
    local proj_name install_hint
    proj_name=$(basename "$(dirname "$ui_dir")")
    if [[ -f "$ui_dir/pnpm-lock.yaml" ]]; then
      install_hint="pnpm install"
    else
      install_hint="npm install"
    fi
    if [[ -d "$ui_dir/node_modules" ]]; then
      echo -e "  ${GREEN}✓${NC} node_modules: $proj_name"
    else
      echo -e "  ${YELLOW}⚠${NC} No node_modules in $proj_name — run $install_hint"
    fi
  done

  echo ""
  if [[ $errors -gt 0 ]]; then
    echo -e "  ${RED}$errors critical issue(s) found — fix before starting${NC}"
    return 1
  else
    echo -e "  ${GREEN}All checks passed${NC}"
    return 0
  fi
}

# ── Start Functions ──────────────────────────────────────
start_dashboard() {
  echo -e "${BOLD}${CYAN}── Claude Agent Dashboard ──${NC}"

  # R13: DASHBOARD_PORT is the canonical name; DASHBOARD_BACKEND remains
  # the registry default. Operator-set DASHBOARD_PORT wins.
  local DASHBOARD_PORT="${DASHBOARD_PORT:-$DASHBOARD_BACKEND}"

  # R5 / AS-6: fail closed on port-in-use. The conflicting process is NOT
  # killed; operator must run `start-system stop` to reclaim ports.
  ensure_port_free "$DASHBOARD_PORT" || return 1

  # Backend (FastAPI via uvicorn — fastapi-cutover, T0.3).
  echo "  Starting backend on :$DASHBOARD_PORT (uvicorn dashboard.server.app:app) ..."
  cd "$DASHBOARD_DIR"
  local py
  if [[ -x "$DASHBOARD_DIR/.venv/bin/python" ]]; then
    py="$DASHBOARD_DIR/.venv/bin/python"
  elif [[ -x "$REPO_ROOT_HINT/.venv/bin/python" ]]; then
    py="$REPO_ROOT_HINT/.venv/bin/python"
  else
    py="python3"
  fi
  local cmd=("$py" -m uvicorn dashboard.server.app:app
             --host 127.0.0.1 --port "$DASHBOARD_PORT")
  # R2 / AS-2: dev mode appends --reload + --reload-dir. Production never
  # reloads; the magic value 'dev' is the documented sentinel.
  if [[ "${DASHBOARD_ENV:-}" == "dev" ]]; then
    cmd+=(--reload --reload-dir dashboard/server)
  fi
  PYTHONPATH="$REPO_ROOT_HINT" "${cmd[@]}" &>/dev/null &

  # Frontend (vite dev). Dashboard migrated to pnpm in a77203e; OIH +
  # EULEX still on npm. Fall back to npm if pnpm missing so this works
  # on machines without pnpm installed.
  echo "  Starting frontend on :$DASHBOARD_FRONTEND ..."
  cd "$DASHBOARD_DIR/app"
  if command -v pnpm >/dev/null 2>&1 && [[ -f pnpm-lock.yaml ]]; then
    pnpm run dev --port "$DASHBOARD_FRONTEND" &>/dev/null &
  else
    npm run dev -- --port "$DASHBOARD_FRONTEND" &>/dev/null &
  fi

  # R4 / AS-5: HTTP /health readiness loop replaces lsof wait_for_port.
  # Returns 1 (NOT exit 1) on timeout so the caller (`set -e`) propagates
  # the failure (Risk-A / EC-10).
  wait_for_health "$DASHBOARD_PORT" "Dashboard API" || return 1
  echo ""
}

start_oih() {
  local dir
  dir=$(resolve_project_dir "$OIH_DIR" "${1:-}")

  echo -e "${BOLD}${CYAN}── OIH ──${NC}"
  [[ "$dir" != "$OIH_DIR" ]] && echo -e "  ${CYAN}Using:${NC} $dir"
  kill_ports "$OIH_BACKEND" "$OIH_FRONTEND"
  sleep 1

  # Docker services (postgres, langfuse)
  echo "  Starting Docker services..."
  cd "$dir"
  docker compose up -d --wait 2>/dev/null || echo "  (Docker services skipped or already running)"

  # Backend (uvicorn)
  echo "  Starting backend on :$OIH_BACKEND ..."
  cd "$dir"
  uv run uvicorn src.main:app --reload --port "$OIH_BACKEND" &>/dev/null &

  # Frontend (vite)
  echo "  Starting frontend on :$OIH_FRONTEND ..."
  cd "$dir/ui"
  VITE_API_PORT="$OIH_BACKEND" VITE_DEV_PORT="$OIH_FRONTEND" npm run dev &>/dev/null &

  wait_for_port "$OIH_BACKEND" "OIH API"
  echo ""
}

start_eulex() {
  local dir
  dir=$(resolve_project_dir "$EULEX_DIR" "${1:-}")

  echo -e "${BOLD}${CYAN}── Eulex RAG ──${NC}"
  [[ "$dir" != "$EULEX_DIR" ]] && echo -e "  ${CYAN}Using:${NC} $dir"
  kill_ports "$EULEX_BACKEND" "$EULEX_FRONTEND"
  sleep 1

  # Backend (uvicorn)
  echo "  Starting backend on :$EULEX_BACKEND ..."
  cd "$dir"
  source .venv/bin/activate 2>/dev/null || true
  API_PORT="$EULEX_BACKEND" uvicorn ui_react.backend.main:app --reload --port "$EULEX_BACKEND" \
    --reload-dir "$dir/src" --reload-dir "$dir/ui_react/backend" &>/dev/null &

  # Frontend (vite)
  echo "  Starting frontend on :$EULEX_FRONTEND ..."
  cd "$dir/ui_react/frontend"
  VITE_API_PORT="$EULEX_BACKEND" VITE_DEV_PORT="$EULEX_FRONTEND" npm run dev &>/dev/null &

  wait_for_port "$EULEX_BACKEND" "Eulex API"
  echo ""
}

start_sonarqube() {
  echo -e "${BOLD}${CYAN}── SonarQube ──${NC}"

  # Smart-detect: if Sonar already responds UP, no-op. Avoids the previous
  # `kill_port` step that confused the Docker container by killing the
  # host-side bind out from under the running container. Container
  # lifecycle is Docker's job — we don't manage it port-by-port.
  if curl -sf -m 3 "http://localhost:$SONARQUBE_PORT/api/system/status" 2>/dev/null \
     | grep -q '"status":"UP"'; then
    echo -e "  ${GREEN}✓${NC} SonarQube already UP — no action needed"
    echo ""
    return 0
  fi

  # Docker daemon required.
  if ! docker info >/dev/null 2>&1; then
    echo -e "  ${RED}✗${NC} Docker daemon not running — start Docker Desktop first"
    return 1
  fi

  echo "  Starting SonarQube on :$SONARQUBE_PORT ..."
  cd "$SONARQUBE_DIR"
  docker compose up -d 2>/dev/null || {
    echo -e "  ${RED}✗${NC} Failed to start SonarQube (docker compose up failed)"
    return 1
  }

  # SonarQube takes a while to start — don't block, just report
  echo -e "  ${YELLOW}⏳${NC} SonarQube starting (takes ~60s). Check: http://localhost:$SONARQUBE_PORT"
  echo ""
}

# ── Per-service stop functions ─────────────────────────────────────
# Each one kills ONLY its own ports. Used by `start-system stop <svc>`
# for surgical service-restarts that don't take down sibling services.
# stop_all calls them all in turn (legacy `start-system stop` path).

stop_dashboard() {
  echo -e "${BOLD}${RED}── Stopping Dashboard ──${NC}"
  kill_ports "$DASHBOARD_BACKEND" "$DASHBOARD_FRONTEND"
}

stop_oih() {
  echo -e "${BOLD}${RED}── Stopping OIH ──${NC}"
  kill_ports "$OIH_BACKEND" "$OIH_FRONTEND"
  # Also bring down the docker compose stack (postgres + langfuse).
  # Without this, `start-system stop` would kill the backend but leave
  # heavy containers running indefinitely — defeating the opt-in design.
  # Same shape as stop_sonarqube: skip if Docker isn't reachable.
  if [[ -f "$OIH_DIR/docker-compose.yml" ]] && docker info >/dev/null 2>&1; then
    cd "$OIH_DIR"
    docker compose stop 2>/dev/null || {
      echo -e "  ${YELLOW}⚠${NC} docker compose stop returned non-zero (container may not exist yet)"
    }
  fi
}

stop_eulex() {
  echo -e "${BOLD}${RED}── Stopping Eulex RAG ──${NC}"
  kill_ports "$EULEX_BACKEND" "$EULEX_FRONTEND"
}

stop_sonarqube() {
  # Sonar runs as a Docker container. Killing the host-side port leaves
  # the container alive but disconnected — confuses Docker's view of
  # state. `docker compose stop` is the graceful equivalent. If Docker
  # daemon is unreachable, fall through with a warning rather than fail
  # (same shape as start-side: don't gate stop on Docker being up).
  echo -e "${BOLD}${RED}── Stopping SonarQube ──${NC}"
  if ! docker info >/dev/null 2>&1; then
    echo -e "  ${YELLOW}⚠${NC} Docker daemon not running — nothing to stop"
    return 0
  fi
  cd "$SONARQUBE_DIR"
  docker compose stop 2>/dev/null || {
    echo -e "  ${YELLOW}⚠${NC} docker compose stop returned non-zero (container may not exist yet)"
  }
}

stop_all() {
  echo -e "${BOLD}${RED}── Stopping all services ──${NC}"
  # Each stop_* tolerates absent state, so use `|| true` so a failure in
  # one branch doesn't abort under set -e.
  stop_dashboard || true
  stop_oih || true
  stop_eulex || true
  stop_sonarqube || true
  echo -e "${GREEN}All reserved ports cleared.${NC}"
}

# ── Status probe (read-only) ───────────────────────────────────────

print_status_probe() {
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  Service Status${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  local spec name port probe_url
  for spec in \
    "Dashboard $DASHBOARD_BACKEND http://localhost:$DASHBOARD_BACKEND/health" \
    "OIH       $OIH_BACKEND       http://localhost:$OIH_BACKEND/" \
    "Eulex     $EULEX_BACKEND     http://localhost:$EULEX_BACKEND/" \
    "SonarQube $SONARQUBE_PORT    http://localhost:$SONARQUBE_PORT/api/system/status"
  do
    name=$(echo "$spec" | awk '{print $1}')
    port=$(echo "$spec" | awk '{print $2}')
    probe_url=$(echo "$spec" | awk '{print $3}')
    if curl -sf -m 2 "$probe_url" >/dev/null 2>&1; then
      echo -e "  ${GREEN}✓${NC} $name (:$port) UP"
    elif lsof -ti :"$port" >/dev/null 2>&1; then
      echo -e "  ${YELLOW}⚠${NC} $name (:$port) port held but health probe failed"
    else
      echo -e "  ${RED}✗${NC} $name (:$port) DOWN"
    fi
  done
  echo ""
}

print_status() {
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo -e "${BOLD}  System Status${NC}"
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
  echo ""
  echo -e "  ${CYAN}Dashboard${NC}"
  echo -e "    API:      http://localhost:$DASHBOARD_BACKEND"
  echo -e "    Frontend: http://localhost:$DASHBOARD_FRONTEND"
  echo ""
  echo -e "  ${CYAN}OIH${NC}"
  echo -e "    API:      http://localhost:$OIH_BACKEND"
  echo -e "    Frontend: http://localhost:$OIH_FRONTEND"
  echo -e "    Langfuse: http://localhost:3000"
  echo ""
  echo -e "  ${CYAN}Eulex RAG${NC}"
  echo -e "    API:      http://localhost:$EULEX_BACKEND"
  echo -e "    Frontend: http://localhost:$EULEX_FRONTEND"
  echo ""
  echo -e "  ${CYAN}SonarQube${NC}"
  echo -e "    Web UI:   http://localhost:$SONARQUBE_PORT"
  echo ""
  echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

# ── Main ─────────────────────────────────────────────────
# DASHBOARD_TEST_NO_DISPATCH=1 lets the bash test harness
# (tests/test_start_system_dashboard.sh) source this file purely for
# helper coverage without executing the start dispatch.
if [[ "${DASHBOARD_TEST_NO_DISPATCH:-0}" != "1" ]]; then
  case "${1:-all}" in
    dashboard)  start_dashboard; print_status ;;
    oih)        start_oih "${2:-}"; print_status ;;
    eulex)      start_eulex "${2:-}"; print_status ;;
    sonarqube)  start_sonarqube; print_status ;;
    stop)
      # `start-system stop` (no second arg) → stop_all (backward compat).
      # `start-system stop <service>` → only that service.
      case "${2:-all}" in
        all)        stop_all ;;
        dashboard)  stop_dashboard ;;
        oih)        stop_oih ;;
        eulex)      stop_eulex ;;
        sonarqube)  stop_sonarqube ;;
        *)
          echo "Usage: $0 stop [all|dashboard|oih|eulex|sonarqube]" >&2
          exit 1
          ;;
      esac
      ;;
    restart)
      # `start-system restart <service>` — surgical stop + start. No
      # `restart all` — that's `start-system stop && start-system`.
      case "${2:-}" in
        dashboard)  stop_dashboard; sleep 2; start_dashboard; print_status ;;
        oih)        stop_oih;       sleep 2; start_oih "${3:-}"; print_status ;;
        eulex)      stop_eulex;     sleep 2; start_eulex "${3:-}"; print_status ;;
        sonarqube)  stop_sonarqube; sleep 2; start_sonarqube; print_status ;;
        *)
          echo "Usage: $0 restart {dashboard|oih|eulex|sonarqube} [worktree-path]" >&2
          exit 1
          ;;
      esac
      ;;
    status)     print_status_probe ;;
    check)      check_health ;;
    all)
      # Defaults only: dashboard + sonarqube. OIH and Eulex are opt-in
      # (heavy: OIH spins postgres + langfuse via docker compose, Eulex
      # rarely needed during dashboard work). Invoke them explicitly:
      #   start-system oih
      #   start-system eulex
      # Lenient: a failing service shouldn't abort the rest. Each
      # start_* call tolerated with `|| true` so set -e doesn't trip.
      start_dashboard || true
      start_sonarqube || true
      print_status
      ;;
    *)
      echo "Usage: $0 {all|dashboard|oih|eulex|sonarqube|stop [svc]|restart <svc>|status|check} [worktree-path]"
      exit 1
      ;;
  esac
fi
