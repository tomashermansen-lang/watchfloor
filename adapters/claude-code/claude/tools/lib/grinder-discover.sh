#!/usr/bin/env bash
# grinder-discover.sh — Discovery mechanics library for grinder.sh
#
# Sourced by grinder.sh at startup. Provides helper functions for the
# discover subcommand: manifest parsing, file collection, scanner
# execution, and runner resolution.
#
# Depends on: TOOLS_DIR, LIB_DIR, SCHEMA_DIR, PROJECT_DIR, GRINDER_DIR
# (session globals set by grinder.sh main())
#
# Compatible with bash 3.2+ (macOS default). Uses functions instead of
# associative arrays.

# ---------------------------------------------------------------------------
# Scanner extension mapping (single source of truth)
# ---------------------------------------------------------------------------

_scanner_extensions() {
  local scanner="$1"
  case "$scanner" in
    shellcheck) echo "sh" ;;
    ruff|mypy|bandit|semgrep) echo "py" ;;
    eslint|prettier) echo "js ts jsx tsx" ;;
    tsc) echo "ts tsx" ;;
    *) echo "" ;;
  esac
}

_scanner_is_project_wide() {
  local scanner="$1"
  case "$scanner" in
    pip-audit|npm-audit) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Scanner format flag mapping (single source of truth)
# ---------------------------------------------------------------------------

_scanner_format_flags() {
  local scanner="$1"
  case "$scanner" in
    shellcheck) echo "--format=json" ;;
    ruff) echo "check --output-format json" ;;
    eslint) echo "--format json" ;;
    mypy) echo "" ;;
    tsc) echo "--noEmit" ;;
    bandit) echo "-f json -r" ;;
    semgrep) echo "--json" ;;
    pip-audit) echo "--format=json" ;;
    npm-audit) echo "audit --json" ;;
    *) echo "" ;;
  esac
}

# ---------------------------------------------------------------------------
# discover_parse_manifest() — parse grinder block via validate-manifest.py
# ---------------------------------------------------------------------------

discover_parse_manifest() {
  local pipeline_yaml_path="$1"
  python3 "$TOOLS_DIR/validate-manifest.py" --parse-grinder "$pipeline_yaml_path"
}

# ---------------------------------------------------------------------------
# discover_resolve_runner() — runner detection per static-analysis-conventions
# ---------------------------------------------------------------------------

discover_resolve_runner() {
  local scanner="$1"

  # Shellcheck is always bare
  if [[ "$scanner" == "shellcheck" ]]; then
    echo "shellcheck"
    return
  fi

  # Python tools
  case "$scanner" in
    ruff|mypy|bandit|semgrep|pip-audit)
      if [[ -f "$PROJECT_DIR/pyproject.toml" ]] && command -v uv >/dev/null 2>&1; then
        echo "uv run $scanner"
      elif [[ -x "$PROJECT_DIR/.venv/bin/$scanner" ]]; then
        echo "$PROJECT_DIR/.venv/bin/$scanner"
      else
        echo "$scanner"
      fi
      return
      ;;
  esac

  # Node tools
  case "$scanner" in
    eslint|prettier|tsc)
      echo "npx $scanner"
      return
      ;;
    npm-audit)
      echo "npm"
      return
      ;;
  esac

  # Fallback: bare
  echo "$scanner"
}

# ---------------------------------------------------------------------------
# discover_collect_files() — find files matching scanner extensions
# ---------------------------------------------------------------------------

discover_collect_files() {
  local scanner="$1"
  local paths_json="$2"
  local never_touch_json="$3"

  # Project-wide scanners don't need file collection
  if _scanner_is_project_wide "$scanner"; then
    return 0
  fi

  local extensions
  extensions=$(_scanner_extensions "$scanner")
  if [[ -z "$extensions" ]]; then
    return 0
  fi

  # Parse paths array from JSON
  local paths
  paths=$(echo "$paths_json" | python3 -c "import json,sys; [print(p) for p in json.load(sys.stdin)]" 2>/dev/null)

  # Parse never_touch_files patterns
  local never_touch_patterns=""
  if [[ -n "$never_touch_json" && "$never_touch_json" != "[]" && "$never_touch_json" != "null" ]]; then
    never_touch_patterns=$(echo "$never_touch_json" | python3 -c "import json,sys; [print(p) for p in json.load(sys.stdin)]" 2>/dev/null)
  fi

  # If no paths declared, scan entire project
  if [[ -z "$paths" ]]; then
    paths="."
  fi

  local find_args=()
  local first_ext=true
  for ext in $extensions; do
    if [[ "$first_ext" == "true" ]]; then
      find_args+=("(" "-name" "*.${ext}")
      first_ext=false
    else
      find_args+=("-o" "-name" "*.${ext}")
    fi
  done
  find_args+=(")")

  while IFS= read -r scan_path; do
    [[ -z "$scan_path" ]] && continue
    local abs_path="$PROJECT_DIR/$scan_path"

    # Check path exists (EC-9.1)
    if [[ ! -e "$abs_path" ]]; then
      echo "discover: path $scan_path does not exist -- skipping" >&2
      continue
    fi

    # If path is a file, check extension match and emit directly (EC-9.3)
    if [[ -f "$abs_path" ]]; then
      local matched=false
      for ext in $extensions; do
        if [[ "$abs_path" == *".${ext}" ]]; then
          matched=true
          break
        fi
      done
      if [[ "$matched" == "true" ]]; then
        local rel_path="${abs_path#"$PROJECT_DIR/"}"
        echo "$rel_path"
      fi
      continue
    fi

    # Find files, excluding .git/ and node_modules/ (EC-9.2)
    find "$abs_path" \
      -not -path '*/.git/*' \
      -not -path '*/node_modules/*' \
      -type f \
      "${find_args[@]}" \
      2>/dev/null | while IFS= read -r file; do
        # Make relative to PROJECT_DIR
        local rel="${file#"$PROJECT_DIR/"}"

        # Check never_touch_files exclusion (REQ-9.3)
        local excluded=false
        if [[ -n "$never_touch_patterns" ]]; then
          while IFS= read -r pattern; do
            [[ -z "$pattern" ]] && continue
            # Simple glob matching using bash pattern
            # shellcheck disable=SC2254
            case "$rel" in
              $pattern) excluded=true; break ;;
            esac
          done <<< "$never_touch_patterns"
        fi

        if [[ "$excluded" == "false" ]]; then
          echo "$rel"
        fi
      done
  done <<< "$paths"
}

# ---------------------------------------------------------------------------
# discover_run_scanner() — run scanner with format flags
# ---------------------------------------------------------------------------

discover_run_scanner() {
  local scanner="$1"
  shift
  local -a files=("$@")

  local runner
  runner=$(discover_resolve_runner "$scanner")

  local format_flags
  format_flags=$(_scanner_format_flags "$scanner")

  # Build command
  local -a cmd
  # shellcheck disable=SC2206
  cmd=($runner $format_flags)

  # Add files (unless project-wide scanner)
  if ! _scanner_is_project_wide "$scanner"; then
    cmd+=("${files[@]}")
  fi

  # Execute — caller handles stdout redirection and exit code
  "${cmd[@]}"
}

# ---------------------------------------------------------------------------
# _archive_prior_cycle_logs() — preserve prior-cycle event/stream logs
# ---------------------------------------------------------------------------
# events.ndjson and grinder-stream.ndjson are append-only across discover
# cycles, but their consumers (dashboard's GrinderDetail/GrinderEventsList,
# any grep-based diagnostic) generally want CURRENT-cycle data. When
# discover starts a new cycle (current_sha \!= prior plan_sha), archive the
# prior logs to *.<prior-short-sha>.bak and truncate the live files so
# downstream consumers see only the new cycle's data. The .bak preserves
# history for retroactive analysis.
#
# Reads (session): GRINDER_DIR
# Tag: short-sha (first 7 chars) extracted from prior grinder-state.json's
#      git_sha_at_start, or "unknown" if state.json is absent/malformed.
# Skip: empty live files (avoids creating empty .bak files on first discover).
_archive_prior_cycle_logs() {
  local stream_file="$GRINDER_DIR/grinder-stream.ndjson"
  local events_file="$GRINDER_DIR/events.ndjson"
  local state_file="$GRINDER_DIR/grinder-state.json"

  local prior_sha=""
  if [[ -f "$state_file" ]]; then
    prior_sha=$(python3 -c "
import json, sys
try:
    d = json.load(open('$state_file'))
    sha = d.get('git_sha_at_start', '') if isinstance(d, dict) else ''
    print(sha[:7] if sha else '')
except Exception:
    pass
" 2>/dev/null || true)
  fi
  [[ -z "$prior_sha" ]] && prior_sha="unknown"

  local f
  for f in "$events_file" "$stream_file"; do
    if [[ -s "$f" ]]; then
      mv "$f" "${f}.${prior_sha}.bak"
      : > "$f"   # touch empty so downstream code can append immediately
    fi
  done
}
