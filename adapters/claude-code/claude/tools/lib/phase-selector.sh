#!/bin/bash
# phase-selector.sh — phase-skipping logic for autopilot.sh --from flag.
#
# Source this lib to gain:
#   PHASE_ORDER            — canonical pipeline phase list (ordered)
#   validate_phase_name    — exit 0 if phase is in PHASE_ORDER, non-zero otherwise
#   phase_enabled          — check whether a phase should run given $START_FROM
#   skipped_phases         — print space-separated list of phases before $START_FROM
#
# Reads global: START_FROM (empty string = run all phases)
# No side effects on source.

# Canonical phase names, in pipeline order. Used by --from to compute skips.
# 2026-04-29: static-analysis moved AFTER qa (was between implement and qa).
# Rationale: qa fix loops modify source code; static-analysis must run on the
# final state, not a snapshot that bypasses qa fixes. See dotfiles BACKLOG and
# the plan-schema-2-0-adoption autopilot run for the bypass observation.
# 2026-05-04: testplan moved BEFORE review (was between review and implement).
# Rationale: TESTPLAN.md drives qa coverage verification. If review never sees
# it, missed scenarios slip through to implementation and qa silently passes
# because qa only checks "every TESTPLAN scenario has a test", not whether
# TESTPLAN was complete. Reviewing PLAN+TESTPLAN together breaks that loop.
declare -a PHASE_ORDER=(ba plan testplan review implement qa static-analysis commit)

# validate_phase_name <name>
# Returns 0 if <name> is a valid phase in PHASE_ORDER.
# Emits "Valid: <list>" to stderr when invalid.
validate_phase_name() {
    local candidate="${1:-}"
    local p
    for p in "${PHASE_ORDER[@]}"; do
        [[ "$p" == "$candidate" ]] && return 0
    done
    echo "Invalid phase: '$candidate'" >&2
    echo "Valid phases: ${PHASE_ORDER[*]}" >&2
    return 1
}

# phase_enabled <phase_name>
# Returns 0 when the phase should run, non-zero when it should be skipped.
# When START_FROM is empty, always returns 0. When START_FROM is set, skips
# phases strictly before START_FROM.
# Unknown phase_name → non-zero (treated as "do not run").
phase_enabled() {
    local name="${1:?phase_enabled requires a phase name}"
    local start="${START_FROM:-}"

    [[ -z "$start" ]] && {
        # No --from: only gate unknown phases
        local p
        for p in "${PHASE_ORDER[@]}"; do
            [[ "$p" == "$name" ]] && return 0
        done
        return 1
    }

    local reached=0
    local p
    for p in "${PHASE_ORDER[@]}"; do
        [[ "$p" == "$start" ]] && reached=1
        if [[ "$p" == "$name" ]]; then
            [[ $reached -eq 1 ]] && return 0 || return 1
        fi
    done
    return 1  # name not in PHASE_ORDER
}

# skipped_phases
# Print space-separated list of phases that will be skipped given $START_FROM.
# Empty output when START_FROM is empty.
skipped_phases() {
    local start="${START_FROM:-}"
    [[ -z "$start" ]] && return 0

    local out=()
    local p
    for p in "${PHASE_ORDER[@]}"; do
        [[ "$p" == "$start" ]] && break
        out+=("$p")
    done
    echo "${out[*]}"
}

# should_stop_after_phase <phase-name>
# Returns 0 when STOP_AFTER_PHASE is set and equals <phase-name>.
# Returns 1 otherwise (including when STOP_AFTER_PHASE is unset/empty).
# Reads global STOP_AFTER_PHASE; ${var:-} keeps set -u happy.
# No I/O, no side effects.
should_stop_after_phase() {
    local candidate="${1:-}"
    local stop="${STOP_AFTER_PHASE:-}"
    [[ -n "$stop" && "$stop" == "$candidate" ]]
}

# phase_index <phase-name>
# Echoes the 0-based index of <phase-name> in PHASE_ORDER and returns 0.
# Echoes nothing and returns 1 if <phase-name> is not a PHASE_ORDER member.
# Used by the --from / --stop-after-phase composition check.
phase_index() {
    local candidate="${1:-}"
    local i
    for i in "${!PHASE_ORDER[@]}"; do
        if [[ "${PHASE_ORDER[$i]}" == "$candidate" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}
