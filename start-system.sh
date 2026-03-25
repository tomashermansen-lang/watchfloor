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
#    start-system                       # start all
#    start-system dashboard             # start only dashboard
#    start-system oih                   # start only OIH
#    start-system oih /path/to/worktree # start OIH from specific worktree
#    start-system eulex                 # start only Eulex RAG
#    start-system sonarqube             # start only SonarQube
#    start-system stop                  # kill all reserved ports
#    start-system check                 # pre-flight health check
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
DASHBOARD_DIR="${DASHBOARD_DIR:-$PROJECTS_ROOT/claude-agent-dashboard}"
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

  # Node modules
  for ui_dir in "$DASHBOARD_DIR/app" "$OIH_DIR/ui" "$EULEX_DIR/ui_react/frontend"; do
    local proj_name
    proj_name=$(basename "$(dirname "$ui_dir")")
    if [[ -d "$ui_dir/node_modules" ]]; then
      echo -e "  ${GREEN}✓${NC} node_modules: $proj_name"
    else
      echo -e "  ${YELLOW}⚠${NC} No node_modules in $proj_name — run npm install"
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
  kill_ports "$DASHBOARD_BACKEND" "$DASHBOARD_FRONTEND"
  sleep 1

  # Backend (serve.py) — use venv for pyyaml dependency
  echo "  Starting backend on :$DASHBOARD_BACKEND ..."
  cd "$DASHBOARD_DIR"
  if [[ -x "$DASHBOARD_DIR/.venv/bin/python" ]]; then
    "$DASHBOARD_DIR/.venv/bin/python" serve.py &>/dev/null &
  else
    python3 serve.py &>/dev/null &
  fi

  # Frontend (vite dev)
  echo "  Starting frontend on :$DASHBOARD_FRONTEND ..."
  cd "$DASHBOARD_DIR/app"
  npm run dev -- --port "$DASHBOARD_FRONTEND" &>/dev/null &

  wait_for_port "$DASHBOARD_BACKEND" "Dashboard API"
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
  kill_port "$SONARQUBE_PORT"
  sleep 1

  echo "  Starting SonarQube on :$SONARQUBE_PORT ..."
  cd "$SONARQUBE_DIR"
  docker compose up -d 2>/dev/null || {
    echo -e "  ${RED}✗${NC} Failed to start SonarQube (is Docker running?)"
    return 1
  }

  # SonarQube takes a while to start — don't block, just report
  echo -e "  ${YELLOW}⏳${NC} SonarQube starting (takes ~60s). Check: http://localhost:$SONARQUBE_PORT"
  echo ""
}

stop_all() {
  echo -e "${BOLD}${RED}── Stopping all services ──${NC}"
  kill_ports "${ALL_PORTS[@]}"
  echo -e "${GREEN}All reserved ports cleared.${NC}"
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
case "${1:-all}" in
  dashboard)  start_dashboard; print_status ;;
  oih)        start_oih "${2:-}"; print_status ;;
  eulex)      start_eulex "${2:-}"; print_status ;;
  sonarqube)  start_sonarqube; print_status ;;
  stop)       stop_all ;;
  check)      check_health ;;
  all)
    start_dashboard
    start_oih
    start_eulex
    start_sonarqube
    print_status
    ;;
  *)
    echo "Usage: $0 {all|dashboard|oih|eulex|sonarqube|stop|check} [worktree-path]"
    exit 1
    ;;
esac
