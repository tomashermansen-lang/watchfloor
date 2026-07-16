#!/bin/bash
# sonar-preflight.sh — ensures SonarQube is ready before /static-analysis.
#
# Detects whether a project uses SonarQube (via sonar-project.properties in
# the main dir), auto-starts the SonarQube docker-compose if needed, waits
# for it to become reachable, copies the gitignored properties file into the
# worktree, and returns non-zero if SonarQube was required but couldn't be
# brought up. Autopilot invokes this before its /static-analysis phase so
# silent skips become hard-visible failures.
#
# Functions (source this file to use):
#   sonar_required_for <main_dir>  — 0 if <main_dir>/sonar-project.properties exists
#   sonar_reachable                — 0 if SONAR_URL responds OK
#   sonar_start                    — docker compose up -d (returns 0 on success)
#   sonar_wait_ready               — poll until reachable, max SONAR_WAIT_SECONDS
#   sonar_copy_properties <m> <w>  — copy properties main → worktree (no-op if exists)
#   sonar_preflight <m> <w>        — orchestrator: detect + start + wait + copy
#
# Env vars (override before sourcing):
#   SONAR_URL              default http://localhost:9100
#   SONAR_COMPOSE_DIR      default $HOME/Projekter/sonarqube
#   SONAR_WAIT_SECONDS     default 60
#   SONAR_CURL_TIMEOUT     default 2

SONAR_URL="${SONAR_URL:-http://localhost:9100}"
SONAR_COMPOSE_DIR="${SONAR_COMPOSE_DIR:-$HOME/Projekter/sonarqube}"
SONAR_WAIT_SECONDS="${SONAR_WAIT_SECONDS:-60}"
SONAR_CURL_TIMEOUT="${SONAR_CURL_TIMEOUT:-2}"

sonar_required_for() {
    local main_dir="${1:?sonar_required_for requires main_dir}"
    [[ -f "$main_dir/sonar-project.properties" ]]
}

sonar_reachable() {
    curl -sf -m "$SONAR_CURL_TIMEOUT" "$SONAR_URL/api/system/status" >/dev/null 2>&1
}

sonar_start() {
    local compose_file="$SONAR_COMPOSE_DIR/docker-compose.yml"
    [[ -f "$compose_file" ]] || return 1
    command -v docker >/dev/null 2>&1 || return 1
    docker compose -f "$compose_file" up -d >/dev/null 2>&1
}

sonar_wait_ready() {
    local deadline=$((SECONDS + SONAR_WAIT_SECONDS))
    while (( SECONDS < deadline )); do
        sonar_reachable && return 0
        sleep 2
    done
    return 1
}

sonar_copy_properties() {
    local main_dir="${1:?sonar_copy_properties requires main_dir}"
    local workdir="${2:?sonar_copy_properties requires workdir}"
    local src="$main_dir/sonar-project.properties"
    local dst="$workdir/sonar-project.properties"
    [[ -f "$src" ]] || return 1
    [[ -f "$dst" ]] && return 1   # worktree copy already exists; leave it
    cp "$src" "$dst"
}

sonar_export_user_home() {
    # Redirect SonarQube's plugin/cache home to a sandbox-writable path.
    # Default ~/.sonar/_tmp is in the macOS Seatbelt deny list so the
    # scanner JVM fails its plugin-download bootstrap on first invocation.
    # Pinning to <workdir>/.sonar keeps the cache inside the project root
    # where the sandbox grants write access. Preserves operator-set
    # SONAR_USER_HOME (e.g. CI cache mount).
    local workdir="${1:?sonar_export_user_home requires workdir}"
    : "${SONAR_USER_HOME:=$workdir/.sonar}"
    mkdir -p "$SONAR_USER_HOME"
    export SONAR_USER_HOME
}

sonar_preflight() {
    local main_dir="${1:?sonar_preflight requires main_dir}"
    local workdir="${2:?sonar_preflight requires workdir}"

    # Project isn't wired for SonarQube — nothing to do.
    #
    # Guard C of the three-guard anti-ghost-project hardening
    # (2026-05-20): if SonarQube is reachable AND sonar-scanner is on
    # PATH but neither main nor worktree has sonar-project.properties,
    # warn loudly so an operator notices before /static-analysis runs.
    # Without the properties file, sonar-scanner derives sonar.projectKey
    # from $(basename "$PWD") = the worktree name, which spawns a ghost
    # project on every feature scan. We warn (not abort) because
    # projects that legitimately don't use sonar must still be able to
    # pass this preflight — the actual scan-time abort lives in
    # static-analysis.md (Guard A). The warning gives operators a chance
    # to catch the inconsistency before the pipeline gets that far.
    if ! sonar_required_for "$main_dir"; then
        if [[ ! -f "$workdir/sonar-project.properties" ]] \
           && command -v sonar-scanner >/dev/null 2>&1 \
           && sonar_reachable; then
            echo "WARNING: SonarQube is reachable and sonar-scanner is installed, but" >&2
            echo "  no sonar-project.properties exists in $main_dir or $workdir." >&2
            echo "  Skipping sonar wiring — any downstream sonar-scanner invocation" >&2
            echo "  would spawn a ghost project keyed on '$(basename "$workdir")'." >&2
        fi
        return 0
    fi

    if sonar_reachable; then
        sonar_copy_properties "$main_dir" "$workdir" || true
        sonar_export_user_home "$workdir"
        return 0
    fi

    echo "SonarQube not reachable at $SONAR_URL — attempting to start..." >&2
    if ! sonar_start; then
        echo "ERROR: could not start SonarQube. Compose file missing or docker not available at $SONAR_COMPOSE_DIR." >&2
        return 1
    fi

    echo "Waiting up to ${SONAR_WAIT_SECONDS}s for SonarQube to become ready..." >&2
    if ! sonar_wait_ready; then
        echo "ERROR: SonarQube did not become ready within ${SONAR_WAIT_SECONDS}s." >&2
        return 1
    fi

    echo "SonarQube is up." >&2
    sonar_copy_properties "$main_dir" "$workdir" || true
    sonar_export_user_home "$workdir"
    return 0
}
