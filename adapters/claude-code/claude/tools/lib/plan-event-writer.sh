#!/usr/bin/env bash
#
# plan-event-writer.sh — append a single NDJSON event to a plan's
# per-plan event stream during a /plan-project session.
#
# Local file I/O only — no API calls, no `claude -p` invocations, no
# Agent SDK credit consumption. Invoked from /plan-project skill body
# (interactive session) at each documented event boundary in Steps
# 0/1.6/4.5/5T.2/9.6/9.7.
#
# Stream file: docs/INPROGRESS_Plan_<plan-name>/_PLANPROJECT_STREAM.ndjson
#   - Append-only, NDJSON (one JSON object per line)
#   - Auto-created on first event for a plan
#   - Mirrors the convention used by autopilot-chain.sh (chain-events.ndjson)
#     and autopilot.sh (autopilot-stream.ndjson) for cross-tool consistency
#
# Usage:
#   plan-event-writer.sh emit <plan-name> <event-name> [payload-key=value ...]
#
# Examples:
#   plan-event-writer.sh emit autopilot-cost-efficiency literature_preflight_invoked \
#     topics=cache,output-caps,json-mode fetch_count=5
#   plan-event-writer.sh emit autopilot-cost-efficiency specialist_response_invalid \
#     role=performance-engineer missing_sections="proposed_tasks,sequencing"
#
# All payload values are JSON-string-encoded (no embedded shell parsing).
# Reserved fields auto-injected: ts (iso-8601), event, schema_version.
#
# Self-test:
#   plan-event-writer.sh --self-test
#
# Exit codes:
#   0 — event appended successfully (or self-test passed)
#   1 — usage / argument error
#   2 — plan dir does not exist
#   3 — file-system error (permission, disk full)

set -euo pipefail

SCHEMA_VERSION="1.0.0"
STREAM_FILENAME="_PLANPROJECT_STREAM.ndjson"

usage() {
  cat <<'USAGE' >&2
plan-event-writer.sh — append NDJSON event to a plan's event stream

Usage:
  plan-event-writer.sh emit <plan-name> <event-name> [key=value ...]
  plan-event-writer.sh --self-test
  plan-event-writer.sh --help

Stream location:
  docs/INPROGRESS_Plan_<plan-name>/_PLANPROJECT_STREAM.ndjson

Reserved fields (auto-injected):
  ts              ISO-8601 timestamp at write time
  event           the event-name argument
  schema_version  "1.0.0"
USAGE
}

# Auto-detect repo root from script location:
# adapters/claude-code/claude/tools/lib/plan-event-writer.sh -> repo root is 5 levels up
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"

# Allow override via env var (for testing)
REPO_ROOT="${PLAN_EVENT_WRITER_REPO_ROOT:-$REPO_ROOT}"

iso_now() {
  # Portable: macOS `date` and Linux GNU `date` both accept -u with these flags
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

json_string_escape() {
  # Escape a string for inclusion in a JSON string literal.
  # Replaces: \  ->  \\
  #           "  ->  \"
  #           tab, newline, CR -> escape sequences
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  printf '%s' "$s"
}

build_json() {
  # Args: plan_name event_name [key=value ...]
  local plan_name="$1"; shift
  local event_name="$1"; shift
  local ts
  ts="$(iso_now)"

  # Start with reserved fields
  printf '{'
  printf '"ts":"%s","event":"%s","schema_version":"%s","plan":"%s"' \
    "$(json_string_escape "$ts")" \
    "$(json_string_escape "$event_name")" \
    "$(json_string_escape "$SCHEMA_VERSION")" \
    "$(json_string_escape "$plan_name")"

  # Append payload fields (key=value pairs)
  local kv key val
  for kv in "$@"; do
    # Split on first =
    if [[ "$kv" != *=* ]]; then
      echo "ERROR: payload arg must be key=value, got: $kv" >&2
      return 1
    fi
    key="${kv%%=*}"
    val="${kv#*=}"
    # Sanity-check key matches [a-zA-Z0-9_]+
    if [[ ! "$key" =~ ^[a-zA-Z0-9_]+$ ]]; then
      echo "ERROR: invalid payload key: $key" >&2
      return 1
    fi
    printf ',"%s":"%s"' "$key" "$(json_string_escape "$val")"
  done

  printf '}\n'
}

emit() {
  if [[ $# -lt 2 ]]; then
    echo "ERROR: emit requires <plan-name> <event-name>" >&2
    usage
    return 1
  fi
  local plan_name="$1"; shift
  local event_name="$1"; shift

  if [[ -z "$plan_name" || "$plan_name" =~ [[:space:]] ]]; then
    echo "ERROR: plan-name must be a non-empty single-token slug" >&2
    return 1
  fi
  if [[ -z "$event_name" || ! "$event_name" =~ ^[a-z0-9_]+$ ]]; then
    echo "ERROR: event-name must match ^[a-z0-9_]+\$" >&2
    return 1
  fi

  local plan_dir="${REPO_ROOT}/docs/INPROGRESS_Plan_${plan_name}"
  if [[ ! -d "$plan_dir" ]]; then
    echo "ERROR: plan dir not found: $plan_dir" >&2
    return 2
  fi

  local stream_file="${plan_dir}/${STREAM_FILENAME}"
  local line
  line="$(build_json "$plan_name" "$event_name" "$@")" || return 1

  # Note: $(...) strips trailing newlines from build_json output, so we
  # explicitly append \n here to keep the NDJSON one-event-per-line invariant.
  # Single atomic >> append of "$line\n".
  if ! printf '%s\n' "$line" >> "$stream_file"; then
    echo "ERROR: failed to append to $stream_file" >&2
    return 3
  fi
  return 0
}

self_test() {
  # Sandbox the test in a temp dir under $TMPDIR or /tmp (both
  # explicitly allowed under the project sandbox); avoid default
  # mktemp paths which can fail on macOS Seatbelt restrictions.
  local tmpbase="${TMPDIR:-/tmp}"
  local tmpdir
  tmpdir="${tmpbase%/}/plan-event-writer-selftest-$$"
  mkdir -p "$tmpdir" || { echo "FAIL: could not create tmpdir $tmpdir" >&2; return 1; }
  trap "rm -rf $tmpdir" EXIT

  local plan="self-test-fixture"
  mkdir -p "${tmpdir}/docs/INPROGRESS_Plan_${plan}"

  # Run emit in subprocess with overridden REPO_ROOT
  PLAN_EVENT_WRITER_REPO_ROOT="$tmpdir" \
    bash "$0" emit "$plan" "test_event" "key1=value with spaces" "key2=quoted\"value"

  local stream_file="${tmpdir}/docs/INPROGRESS_Plan_${plan}/_PLANPROJECT_STREAM.ndjson"
  if [[ ! -f "$stream_file" ]]; then
    echo "FAIL: stream file not created" >&2
    return 1
  fi

  # Verify it's parseable JSON with python3
  if ! python3 -c "
import json, sys
with open('$stream_file') as f:
    lines = f.readlines()
assert len(lines) == 1, f'expected 1 line, got {len(lines)}'
event = json.loads(lines[0])
required = {'ts', 'event', 'schema_version', 'plan', 'key1', 'key2'}
missing = required - set(event.keys())
assert not missing, f'missing fields: {missing}'
assert event['event'] == 'test_event'
assert event['plan'] == 'self-test-fixture'
assert event['schema_version'] == '1.0.0'
assert event['key1'] == 'value with spaces'
assert event['key2'] == 'quoted\"value'
print('  parsed OK')
"; then
    echo "FAIL: stream not valid NDJSON or missing fields" >&2
    return 1
  fi

  # Append another event and verify
  PLAN_EVENT_WRITER_REPO_ROOT="$tmpdir" \
    bash "$0" emit "$plan" "another_event"
  local line_count
  line_count="$(wc -l < "$stream_file" | tr -d ' ')"
  if [[ "$line_count" != "2" ]]; then
    echo "FAIL: expected 2 lines after second emit, got $line_count" >&2
    return 1
  fi

  echo "self-test: OK"
  return 0
}

# --- Main dispatch ---

case "${1:-}" in
  emit)
    shift
    emit "$@"
    ;;
  --self-test)
    self_test
    ;;
  --help|-h|"")
    usage
    exit 1
    ;;
  *)
    echo "ERROR: unknown subcommand: $1" >&2
    usage
    exit 1
    ;;
esac
