#!/usr/bin/env bash
# deviation-phase-slugs.sh — phase-name → canonical slug mapping.
#
# Sourced by claude-session-lib.sh::track_deviation and by
# tests/test_deviation_wire.sh. Single source of truth per REQ-2.
#
# Bash 3.2 compatible — uses case-statement functions instead of
# associative arrays so the file works on macOS's stock /bin/bash.
#
# Slug naming convention (decorative, NOT contract-binding): lowercase,
# spaces become hyphens, parentheses stripped. The explicit map below
# is the only source of truth — REQ-2 binds on the map, not on the
# convention. New phases added here MUST add an explicit row; do not
# rely on derivation rules.

# Canonical slugs for tracked phases (Appendix A of REQUIREMENTS.md).
# Echoes the slug on stdout. Returns 0 on hit, 1 on miss (unknown phase).
deviation_slug_for() {
  case "$1" in
    "Business Analysis") echo "ba" ;;
    "Architecture Plan") echo "architecture-plan" ;;
    "Review")            echo "review" ;;
    "Team Review")       echo "team-review" ;;
    "Test Plan")         echo "test-plan" ;;
    "Implement")         echo "implement" ;;
    "QA")                echo "qa" ;;
    "Team QA")           echo "team-qa" ;;
    "Static Analysis")   echo "static-analysis" ;;
    "Commit")            echo "commit" ;;
    *) return 1 ;;
  esac
}

# Phases that exist in autopilot.sh but are deliberately NOT tracked
# (Appendix A "Out-of-scope phases"). Membership in this set means
# the wrapper SILENTLY skips — no WARNING. Anything in neither set
# emits the unknown-phase WARNING (REQ-4 path).
#
# Audited 2026-05-01 against autopilot.sh `track_phase "..."` call sites.
# Only `Finalize` (line 1138) and `Done` (line 1152) are real
# track_phase first-arg values. `Manual Test`, `Plan Project`,
# `Retro`, `Merge & Cleanup` appear only as `phase_header` arguments
# and never reach this code path; do NOT add them to this set —
# they would be dead config and would obscure a real coverage gap if
# autopilot.sh later started passing one of them to track_phase.
#
# Returns 0 if the phase is in the silently-skipped set, 1 otherwise.
deviation_phase_skipped() {
  case "$1" in
    "Finalize"|"Done") return 0 ;;
    *) return 1 ;;
  esac
}

# Canonical lists for tests (W01) and ops introspection. Indexed arrays
# are bash 3.2 safe. Used by tests/test_deviation_wire.sh after sourcing
# this file, so shellcheck's "appears unused" alert is a false positive.
# shellcheck disable=SC2034
DEVIATION_PHASE_NAMES=(
  "Business Analysis"
  "Architecture Plan"
  "Review"
  "Team Review"
  "Test Plan"
  "Implement"
  "QA"
  "Team QA"
  "Static Analysis"
  "Commit"
)
# shellcheck disable=SC2034
DEVIATION_PHASE_SKIPPED_NAMES=(
  "Finalize"
  "Done"
)
