#!/bin/bash
# grinder-check.sh — Verify all scanner tools required by the grinder pipeline.
#
# Reads each test-target project's CLAUDE.md pipeline.toolchain manifest,
# resolves declared tools through project-specific runners (uv, .venv, npx,
# bare), and prints a structured availability report.
#
# Usage:
#   bash grinder-check.sh                    # Tool availability check
#   bash grinder-check.sh --sandbox-write-test  # Verify sandbox write access
#
# Exit codes:
#   0 — All tools present / all sandbox writes pass
#   1 — Any tool missing / any sandbox write denied / parse error
#
# Override project list via GRINDER_CHECK_PROJECTS env var:
#   export GRINDER_CHECK_PROJECTS="name1|/path1,name2|/path2"

set -euo pipefail

# --- C6: Project Registry ---------------------------------------------------

PROJECTS_ROOT="${PROJECTS_ROOT:-$HOME/Projekter}"

# Default project registry (overridable via GRINDER_CHECK_PROJECTS)
_load_projects() {
    PROJECT_NAMES=()
    PROJECT_PATHS=()

    if [[ -n "${GRINDER_CHECK_PROJECTS:-}" ]]; then
        # Parse comma-separated "name|path" pairs
        IFS=',' read -ra entries <<< "$GRINDER_CHECK_PROJECTS"
        for entry in "${entries[@]}"; do
            local name="${entry%%|*}"
            local path="${entry#*|}"
            PROJECT_NAMES+=("$name")
            PROJECT_PATHS+=("$path")
        done
    else
        PROJECT_NAMES=("dotfiles" "OIH" "RAG framework")
        PROJECT_PATHS=(
            "$PROJECTS_ROOT/dotfiles"
            "$PROJECTS_ROOT/OIH"
            "$PROJECTS_ROOT/RAG framework"
        )
    fi
}

# --- C5: Report Formatter ----------------------------------------------------

print_report_line() {
    local project="$1"
    local tool="$2"
    local status="$3"
    local detail="${4:-}"

    if [[ "$status" == "AVAILABLE" ]]; then
        printf "%s  %s: AVAILABLE [%s]\n" "$project" "$tool" "$detail"
    elif [[ "$status" == "MISSING" ]]; then
        printf "%s  %s: MISSING [%s]\n" "$project" "$tool" "$detail"
    elif [[ "$status" == "NO_MANIFEST" ]]; then
        printf "%s  NO MANIFEST\n" "$project"
    elif [[ "$status" == "PARSE_ERROR" ]]; then
        printf "%s  PARSE ERROR\n" "$project"
    elif [[ "$status" == "PASS" ]]; then
        printf "%s  sandbox-write: PASS\n" "$project"
    elif [[ "$status" == "FAIL" ]]; then
        printf "%s  sandbox-write: FAIL [%s]\n" "$project" "$detail"
    fi
}

# --- C2: Manifest Parser -----------------------------------------------------

# Parses pipeline.toolchain block from pipeline.yaml at the project root.
# Outputs lines: <category>|<tool>
# Special stdout markers: NO_MANIFEST, PARSE_ERROR
# Exit 0 on success (including NO_MANIFEST), non-zero on parse error.
#
# Migrated 2026-04-29 from CLAUDE.md regex parsing — pipeline manifest now
# lives in standalone pipeline.yaml at project root.
parse_manifest() {
    local arg="$1"

    # Accept either pipeline.yaml path or project directory
    local pipeline_yaml="$arg"
    if [[ -d "$arg" ]]; then
        pipeline_yaml="$arg/pipeline.yaml"
    fi

    if [[ ! -f "$pipeline_yaml" ]]; then
        echo "NO_MANIFEST"
        return 0
    fi

    python3 - "$pipeline_yaml" << 'PYEOF'
import sys
import yaml

pipeline_yaml = sys.argv[1]
with open(pipeline_yaml) as f:
    try:
        manifest = yaml.safe_load(f)
    except yaml.YAMLError:
        print("PARSE_ERROR")
        sys.exit(1)

if not isinstance(manifest, dict):
    print("NO_MANIFEST")
    sys.exit(0)

toolchain = manifest.get("toolchain")
if not isinstance(toolchain, dict):
    print("NO_MANIFEST")
    sys.exit(0)

# Categories that contain executable tools
EXECUTABLE_CATEGORIES = {"python", "node", "infra"}

for category, tools in toolchain.items():
    if category not in EXECUTABLE_CATEGORIES:
        # Skip non-executable categories (imports, etc.) silently
        continue
    if not isinstance(tools, list):
        continue
    for tool in tools:
        if isinstance(tool, str) and tool:
            print(f"{category}|{tool}")
PYEOF
}

# --- C3: Tool Resolver -------------------------------------------------------

# Resolves a single tool. Outputs: AVAILABLE|<version> or MISSING|<reason>
resolve_tool() {
    local project_dir="$1"
    local category="$2"
    local tool="$3"

    local version=""
    local exit_code=0

    case "$category" in
        python)
            if [[ -f "$project_dir/pyproject.toml" ]] && command -v uv &>/dev/null; then
                # Try uv run <tool> --version (CLI tools like ruff, mypy)
                version=$(cd "$project_dir" && uv run "$tool" --version 2>&1) && exit_code=0 || exit_code=$?
                # Fallback: pytest plugins (pytest_cov etc) have no CLI — try import
                if [[ $exit_code -ne 0 ]]; then
                    version=$(cd "$project_dir" && uv run python -c "import $tool; print(getattr($tool, '__version__', 'installed'))" 2>&1) && exit_code=0 || exit_code=$?
                fi
            elif [[ -x "$project_dir/.venv/bin/$tool" ]]; then
                version=$("$project_dir/.venv/bin/$tool" --version 2>&1) && exit_code=0 || exit_code=$?
            else
                # Bare fallback: try --version first, then import
                version=$("$tool" --version 2>&1) && exit_code=0 || exit_code=$?
                if [[ $exit_code -ne 0 ]]; then
                    version=$(python3 -c "import $tool; print(getattr($tool, '__version__', 'installed'))" 2>&1) && exit_code=0 || exit_code=$?
                fi
            fi
            ;;
        node)
            if ! command -v npx &>/dev/null; then
                echo "MISSING|npx not found"
                return 0
            fi
            # Search frontend subdirectories (same pattern as autopilot.sh preflight).
            # `dashboard/app` covers the dotfiles+dashboard monorepo layout; the
            # remaining entries cover OIH/RAG and pre-merge dashboard layouts.
            local node_found=false
            for frontend_dir in "$project_dir/ui" "$project_dir/ui_react/frontend" "$project_dir/dashboard/app" "$project_dir/app" "$project_dir/frontend" "$project_dir"; do
                if [[ -d "$frontend_dir/node_modules" ]]; then
                    version=$(cd "$frontend_dir" && npx "$tool" --version 2>&1) && exit_code=0 || exit_code=$?
                    if [[ $exit_code -eq 0 ]]; then
                        node_found=true
                        break
                    fi
                fi
            done
            if [[ "$node_found" == false ]]; then
                # Last resort: bare npx from project root
                version=$(cd "$project_dir" && npx "$tool" --version 2>&1) && exit_code=0 || exit_code=$?
            fi
            ;;
        infra)
            version=$("$tool" --version 2>&1) && exit_code=0 || exit_code=$?
            ;;
        *)
            echo "MISSING|unknown category $category"
            return 0
            ;;
    esac

    if [[ $exit_code -ne 0 ]]; then
        echo "MISSING|--version exited $exit_code"
    else
        # Capture first line, trim whitespace
        local first_line
        first_line=$(echo "$version" | head -1 | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        echo "AVAILABLE|$first_line"
    fi
}

# --- C4: Sandbox Write Tester ------------------------------------------------

sandbox_write_test() {
    local project_dir="$1"
    local target="$project_dir/docs/grinder/.sandbox-test"
    local grinder_dir
    grinder_dir="$(dirname "$target")"

    # EC-7.1: Create directory if it doesn't exist
    if ! mkdir -p "$grinder_dir" 2>/dev/null; then
        echo "FAIL|mkdir failed"
        return 0
    fi

    # EC-7.2: Remove stale file
    rm -f "$target" 2>/dev/null || true

    # Write test file
    if ! echo "sandbox-write-test" > "$target" 2>/dev/null; then
        echo "FAIL|creation failed"
        return 0
    fi

    # Verify creation
    if [[ ! -f "$target" ]]; then
        echo "FAIL|creation failed"
        return 0
    fi

    # Remove test file
    if ! rm "$target" 2>/dev/null; then
        echo "FAIL|removal failed"
        return 0
    fi

    # EC-7.3: Verify removal succeeded
    if [[ -f "$target" ]]; then
        echo "FAIL|removal failed"
        return 0
    fi

    # Clean up empty directory
    rmdir "$grinder_dir" 2>/dev/null || true

    echo "PASS"
}

# --- C1: Main Script ---------------------------------------------------------

main() {
    local mode="tool-check"

    # Parse arguments
    if [[ "${1:-}" == "--sandbox-write-test" ]]; then
        mode="sandbox"
    fi

    _load_projects

    local any_failed=false

    for i in "${!PROJECT_NAMES[@]}"; do
        local name="${PROJECT_NAMES[$i]}"
        local path="${PROJECT_PATHS[$i]}"

        # Validate project dir exists
        if [[ ! -d "$path" ]]; then
            print_report_line "$name" "" "MISSING" "project directory not found: $path"
            any_failed=true
            continue
        fi

        if [[ "$mode" == "sandbox" ]]; then
            local result
            result=$(sandbox_write_test "$path")
            local status="${result%%|*}"
            local detail="${result#*|}"
            if [[ "$status" == "PASS" ]]; then
                print_report_line "$name" "" "PASS"
            else
                print_report_line "$name" "" "FAIL" "$detail"
                any_failed=true
            fi
            continue
        fi

        # Tool-check mode
        local manifest_output manifest_exit
        manifest_output=$(parse_manifest "$path") && manifest_exit=0 || manifest_exit=$?

        # Check for parse error
        if [[ $manifest_exit -ne 0 ]]; then
            print_report_line "$name" "" "PARSE_ERROR"
            any_failed=true
            continue
        fi

        # Check for NO_MANIFEST marker
        if [[ "$manifest_output" == "NO_MANIFEST" ]]; then
            print_report_line "$name" "" "NO_MANIFEST"
            continue
        fi

        # Check for PARSE_ERROR on stdout (with exit 0 — shouldn't happen but guard)
        if [[ "$manifest_output" == "PARSE_ERROR" ]]; then
            print_report_line "$name" "" "PARSE_ERROR"
            any_failed=true
            continue
        fi

        # Empty output = empty toolchain block → success, no tools to check
        if [[ -z "$manifest_output" ]]; then
            continue
        fi

        # Iterate category|tool lines
        while IFS='|' read -r category tool; do
            local result
            result=$(resolve_tool "$path" "$category" "$tool")
            local status="${result%%|*}"
            local detail="${result#*|}"

            if [[ "$status" == "AVAILABLE" ]]; then
                print_report_line "$name" "$tool" "AVAILABLE" "$detail"
            else
                print_report_line "$name" "$tool" "MISSING" "$detail"
                any_failed=true
            fi
        done <<< "$manifest_output"
    done

    if [[ "$any_failed" == "true" ]]; then
        exit 1
    fi
    exit 0
}

main "$@"
