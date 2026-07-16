#!/usr/bin/env bash
# deviation-assess.sh — three-ratio deterministic heuristic library.
#
# Sourced by Phase 2.3 wire integration (assess_phase_deviation inside
# claude-session-lib.sh) and by tests/test_deviation_heuristic.sh.
# Single source of truth for the threshold and ratio formulas.
#
# Public surface:
#   compute_phase_ratios     reads six DEVIATION_* env vars, prints
#                            "aligned" or "flagged\n<name>[\n<name>...]"
#                            (one canonical ratio name per failing
#                            ratio, in canonical order
#                            files → loc → ac_coverage), exits 0
#                            unconditionally.
#   DEVIATION_HEURISTIC_THRESHOLD
#                            single tunable knob, default 1.5; caller
#                            may override via env before sourcing or
#                            per-invocation.
#
# Inputs (env):
#   DEVIATION_DECLARED_FILES      newline list of declared paths
#   DEVIATION_ACTUAL_FILES        newline list of phase-modified paths
#   DEVIATION_LINES_ESTIMATE      integer
#   DEVIATION_ACTUAL_LOC          integer
#   DEVIATION_AC_COUNT            integer
#   DEVIATION_ACTUAL_AC_COUNT     integer
#
# Bash 3.2 compatible — case statements instead of associative arrays;
# no [[ -v ]]; no mapfile/readarray; no process substitution in the
# public function. Pure shell on the aligned-fixture happy path
# (REQ-11): integer-millis scaling for threshold comparison; no
# python/bc/awk/expr.

: "${DEVIATION_HEURISTIC_THRESHOLD:=1.5}"

# Canonical ratio order. Adding a fourth ratio is additive: append a
# name here and a per-name dispatch arm in the two case blocks inside
# compute_phase_ratios.
# shellcheck disable=SC2034
_DH_RATIO_NAMES=("files" "loc" "ac_coverage")

# --- helpers ------------------------------------------------------------------

# Emit the REQ-3 WARNING and the millis form of the default 1.5.
_dh_threshold_default() {
  echo "WARNING: DEVIATION_HEURISTIC_THRESHOLD invalid, using 1.5" >&2
  echo 1500
}

# Parse DEVIATION_HEURISTIC_THRESHOLD into a millis-scaled integer
# (e.g., "1.5" → 1500). Strict format: <int> or <int>.<frac> with
# only ASCII digits 0-9 and at most one '.'. No whitespace, no sign,
# no scientific notation. On any other shape, emit the WARNING and
# fall back to 1500.
_dh_parse_threshold_milli() {
  local raw="${DEVIATION_HEURISTIC_THRESHOLD-}"
  local int_part frac_part

  # Top-level character filter: only digits and at most one dot allowed.
  case "$raw" in
    ''|*[!0-9.]*) _dh_threshold_default; return 0 ;;
  esac

  # At most one dot — reject "1..2", "..", etc.
  case "$raw" in
    *.*.*) _dh_threshold_default; return 0 ;;
  esac

  case "$raw" in
    *.*)
      int_part="${raw%%.*}"
      frac_part="${raw#*.}"
      case "$int_part" in
        ''|*[!0-9]*) _dh_threshold_default; return 0 ;;
      esac
      case "$frac_part" in
        ''|*[!0-9]*) _dh_threshold_default; return 0 ;;
      esac
      # Pad/truncate frac to exactly three digits.
      frac_part="${frac_part}000"
      frac_part="${frac_part:0:3}"
      echo $((10#$int_part * 1000 + 10#$frac_part))
      ;;
    *)
      # Pure integer (no dot).
      echo $((10#$raw * 1000))
      ;;
  esac
}

# Validate a decimal-integer env var. On a non-empty value that is not
# a bare non-negative decimal, emit a WARNING naming the offender and
# echo empty (caller treats empty as "skip this ratio"). Empty input
# is "absent" and produces empty output without warning.
_dh_validate_int() {
  local val="$1"
  local name="$2"

  if [ -z "$val" ]; then
    echo ""
    return 0
  fi

  case "$val" in
    -*)
      echo "WARNING: DEVIATION_${name} negative, treating as zero" >&2
      echo ""
      return 0
      ;;
  esac

  case "$val" in
    *[!0-9]*)
      echo "WARNING: DEVIATION_${name} not an integer, treating as zero" >&2
      echo ""
      return 0
      ;;
  esac

  echo "$val"
}

# Count non-empty lines in a multi-line string. Lines are trimmed of
# trailing CR (CRLF tolerance) and surrounding ASCII whitespace
# (spaces and tabs) before the empty check. Pure bash; no external
# commands.
_dh_count_lines() {
  local input="$1"
  local count=0
  local line trimmed

  while IFS= read -r line; do
    line="${line%$'\r'}"
    trimmed="$line"
    while [ "${trimmed# }" != "$trimmed" ] || [ "${trimmed#	}" != "$trimmed" ]; do
      trimmed="${trimmed# }"
      trimmed="${trimmed#	}"
    done
    while [ "${trimmed% }" != "$trimmed" ] || [ "${trimmed%	}" != "$trimmed" ]; do
      trimmed="${trimmed% }"
      trimmed="${trimmed%	}"
    done
    if [ -n "$trimmed" ]; then
      count=$((count + 1))
    fi
  done <<< "$input"

  echo "$count"
}

# Compute (num * 1000) / denom as integer millis. Returns empty string
# if either operand is missing or denom is zero — caller treats empty
# as "skip this ratio".
_dh_ratio_milli() {
  local num="$1"
  local denom="$2"

  if [ -z "$num" ] || [ -z "$denom" ] || [ "$denom" = "0" ]; then
    echo ""
    return 0
  fi

  echo $((num * 1000 / denom))
}

# --- public function ---------------------------------------------------------

compute_phase_ratios() {
  local threshold_milli
  threshold_milli=$(_dh_parse_threshold_milli)

  local lines_estimate actual_loc ac_count actual_ac_count
  lines_estimate=$(_dh_validate_int "${DEVIATION_LINES_ESTIMATE-}" "LINES_ESTIMATE")
  actual_loc=$(_dh_validate_int "${DEVIATION_ACTUAL_LOC-}" "ACTUAL_LOC")
  ac_count=$(_dh_validate_int "${DEVIATION_AC_COUNT-}" "AC_COUNT")
  actual_ac_count=$(_dh_validate_int "${DEVIATION_ACTUAL_AC_COUNT-}" "ACTUAL_AC_COUNT")

  local declared_count actual_count
  declared_count=$(_dh_count_lines "${DEVIATION_DECLARED_FILES-}")
  actual_count=$(_dh_count_lines "${DEVIATION_ACTUAL_FILES-}")

  # Compute three ratios as millis. Empty string means "skipped"
  # (REQ-7 fallback). Per-name dispatch keeps the formula declaration
  # adjacent to its name.
  local files_milli="" loc_milli="" ac_coverage_milli=""
  local name
  for name in "${_DH_RATIO_NAMES[@]}"; do
    case "$name" in
      files)
        if [ "$declared_count" != "0" ] && [ "$actual_count" != "0" ]; then
          files_milli=$(_dh_ratio_milli "$actual_count" "$declared_count")
        fi
        ;;
      loc)
        if [ -n "$lines_estimate" ] && [ "$lines_estimate" != "0" ] && [ -n "$actual_loc" ]; then
          loc_milli=$(_dh_ratio_milli "$actual_loc" "$lines_estimate")
        fi
        ;;
      ac_coverage)
        if [ -n "$ac_count" ] && [ "$ac_count" != "0" ] \
            && [ -n "$actual_ac_count" ] && [ "$actual_ac_count" != "0" ]; then
          ac_coverage_milli=$(_dh_ratio_milli "$ac_count" "$actual_ac_count")
        fi
        ;;
    esac
  done

  # Decide verdict. Iterate in the same canonical order so failing
  # names are appended in canonical order (REQ-6).
  local failing_names="" ratio_milli
  for name in "${_DH_RATIO_NAMES[@]}"; do
    case "$name" in
      files)       ratio_milli="$files_milli" ;;
      loc)         ratio_milli="$loc_milli" ;;
      ac_coverage) ratio_milli="$ac_coverage_milli" ;;
    esac

    if [ -z "$ratio_milli" ]; then
      continue
    fi
    if [ "$ratio_milli" -gt "$threshold_milli" ]; then
      if [ -z "$failing_names" ]; then
        failing_names="$name"
      else
        failing_names="${failing_names}"$'\n'"$name"
      fi
    fi
  done

  if [ -z "$failing_names" ]; then
    echo "aligned"
    return 0
  fi

  echo "flagged"
  echo "$failing_names"
  return 0
}
