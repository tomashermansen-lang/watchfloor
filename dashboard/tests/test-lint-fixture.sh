#!/usr/bin/env bash
# TDD harness for adapters/claude-code/claude/tools/lint/test-fixture-uses-preflight.sh.
#
# CRITICAL: this file matches the linter's test-*.sh glob and will be
# scanned by the linter as suite #1. To stay invisible to the spawn regex
# the harness builds fixture content at write-time from sentinel tokens
# (__UVICORN__, __SERVE__) so no NON-COMMENT line in this file matches
# SPAWN_RE. Comment lines (this header, the helper docstrings below,
# and `# this would spawn …` inside heredocs) are stripped by the
# linter's `^[[:space:]]*#` filter and are therefore safe.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
LINTER_REL="adapters/claude-code/claude/tools/lint/test-fixture-uses-preflight.sh"
LINTER="$REPO_ROOT/$LINTER_REL"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPBASE="$(mktemp -d "${TMPDIR:-/tmp}/lint-fixture.XXXXXX")"
trap 'rm -rf "$TMPBASE"' EXIT

# ── Sentinel substitution helpers ───────────────────────────────
# The two writers emit fixture lines that contain `uvicorn dashboard.server`
# and `python3 dashboard/serve.py` AT FILE-WRITE TIME, but the harness
# source itself only contains the sentinel tokens — keeping suite #1
# (the linter scanning this file) silent.

write_uvicorn_line() {
  # $1 = output file (appended)
  sed 's/__UVICORN__/uvicorn/g' >> "$1" <<'EOF'
python -m __UVICORN__ dashboard.server.app:app
EOF
}

write_serve_py_line() {
  # $1 = output file (appended); $2 = python invocation prefix (e.g. "python3")
  local py="${2:-python3}"
  sed "s|__PY__|$py|g; s|__SERVE__|serve.py|g" >> "$1" <<'EOF'
__PY__ dashboard/__SERVE__
EOF
}

write_source_line() {
  # $1 = output file (appended); $2 = helper rel-path
  printf 'source %s\n' "$2" >> "$1"
}

write_dot_source_line() {
  # $1 = output file (appended); $2 = helper rel-path. POSIX dot-source
  # form (matched by SOURCE_RE's second alternative).
  printf '. %s\n' "$2" >> "$1"
}

write_call_line() {
  # $1 = output file (appended); $2 = port
  printf 'port_preflight %s\n' "$2" >> "$1"
}

# ── Per-case temp tree builder ──────────────────────────────────

setup_case() {
  # $1 = case name → returns TMPCASE on stdout
  local name="$1"
  local tmpcase="$TMPBASE/case-$name"
  mkdir -p "$tmpcase/adapters/claude-code/claude/tools/lint"
  mkdir -p "$tmpcase/dashboard/tests"
  cp "$LINTER" "$tmpcase/$LINTER_REL"
  chmod +x "$tmpcase/$LINTER_REL"
  ( cd "$tmpcase" && \
      git init -q && \
      git -c user.email=x@x -c user.name=x commit -q --allow-empty -m init ) >/dev/null 2>&1
  echo "$tmpcase"
}

invoke_linter() {
  # $1 = TMPCASE directory; runs linter from $TMPCASE, captures rc/stdout/stderr.
  local tmpcase="$1"
  local stdout_file="$tmpcase/.stdout"
  local stderr_file="$tmpcase/.stderr"
  set +e
  ( cd "$tmpcase" && bash "$LINTER_REL" >"$stdout_file" 2>"$stderr_file" )
  local rc=$?
  set -e
  echo "$rc" > "$tmpcase/.rc"
}

rc_of() { cat "$1/.rc"; }
stdout_of() { cat "$1/.stdout"; }
stderr_of() { cat "$1/.stderr"; }

# ── Smoke (T1, T2, T23) ─────────────────────────────────────────

smoke_checks() {
  if [ -x "$LINTER" ]; then pass "T1: linter exists and is executable"; else fail "T1: linter missing/not executable: $LINTER"; fi
  if head -15 "$LINTER" | grep -q 'set -euo pipefail'; then pass "T2: linter sets -euo pipefail in head"; else fail "T2: linter missing 'set -euo pipefail' in head"; fi
  local missing=0
  for var in HELPER SCAN_DIR SCAN_GLOB SPAWN_RE SOURCE_RE CALL_RE; do
    if head -40 "$LINTER" | grep -qE "^[[:space:]]*${var}="; then
      :
    else
      fail "T23: linter missing top-level constant: $var"
      missing=$((missing + 1))
    fi
  done
  [ "$missing" -eq 0 ] && pass "T23: all six tunable constants declared at top of linter"
}

# ── Case A — helper missing → exit 0 + skip warning (T3, T4) ────

case_a_helper_missing() {
  local tmpcase
  tmpcase="$(setup_case a)"
  # No _lib/ created. Five spawning files to prove the skip path
  # short-circuits before any directory scan (T4).
  for n in 1 2 3 4 5; do
    write_uvicorn_line "$tmpcase/dashboard/tests/test-spawner-$n.sh"
  done
  invoke_linter "$tmpcase"

  local rc; rc=$(rc_of "$tmpcase")
  local err; err=$(stderr_of "$tmpcase")
  local out; out=$(stdout_of "$tmpcase")
  local err_lines; err_lines=$(printf "%s" "$err" | grep -c '' || true)

  [ "$rc" = "0" ] && pass "T3a: case-a exit code 0" || fail "T3a: case-a exit code expected 0, got $rc"
  if printf "%s" "$err" | grep -q 'helper dashboard/tests/_lib/port-preflight.sh not found'; then
    pass "T3b: case-a stderr names missing helper"
  else
    fail "T3b: case-a stderr missing 'helper ... not found' fragment; got: $err"
  fi
  if printf "%s" "$err" | grep -q 'skipping'; then
    pass "T3c: case-a stderr contains 'skipping'"
  else
    fail "T3c: case-a stderr missing 'skipping'; got: $err"
  fi
  [ -z "$out" ] && pass "T3d: case-a stdout empty" || fail "T3d: case-a stdout non-empty: $out"
  [ "$err_lines" = "1" ] && pass "T4: case-a stderr is exactly one line (skip short-circuits before scan)" || \
    fail "T4: case-a stderr line count expected 1, got $err_lines"
}

# ── Case B — helper present + every spawn fixture compliant (T5, T9, T11..T14, T17, T18, T19) ──

case_b_compliant() {
  local tmpcase
  tmpcase="$(setup_case b)"
  mkdir -p "$tmpcase/dashboard/tests/_lib"
  : > "$tmpcase/dashboard/tests/_lib/port-preflight.sh"

  # Compliant fixture: source + call + spawn line.
  local f1="$tmpcase/dashboard/tests/test-foo.sh"
  : > "$f1"
  write_source_line "$f1" "dashboard/tests/_lib/port-preflight.sh"
  write_call_line "$f1" "9999"
  write_uvicorn_line "$f1"

  # T9 — comment-only mention: no spawn detection.
  local f_comment="$tmpcase/dashboard/tests/test-comment.sh"
  cat > "$f_comment" <<'EOF'
# this would spawn uvicorn dashboard.server.app:app if asked
echo "no real spawn"
EOF

  # T14 — file with no spawn line, no source/call: must not be flagged.
  local f_quiet="$tmpcase/dashboard/tests/test-quiet.sh"
  cat > "$f_quiet" <<'EOF'
echo "no server here"
EOF

  # T17 — multiple spawns + one source + one call: still compliant.
  local f_multi="$tmpcase/dashboard/tests/test-multi.sh"
  : > "$f_multi"
  write_source_line "$f_multi" "dashboard/tests/_lib/port-preflight.sh"
  write_call_line "$f_multi" "8798"
  write_uvicorn_line "$f_multi"
  write_uvicorn_line "$f_multi"

  # W1 — dot-source form (POSIX `.`) also satisfies SOURCE_RE.
  local f_dot="$tmpcase/dashboard/tests/test-dot-source.sh"
  : > "$f_dot"
  write_dot_source_line "$f_dot" "dashboard/tests/_lib/port-preflight.sh"
  write_call_line "$f_dot" "9000"
  write_uvicorn_line "$f_dot"

  # T19 — files outside dashboard/tests/test-*.sh must NOT be flagged.
  mkdir -p "$tmpcase/tests"
  write_uvicorn_line "$tmpcase/tests/test-foo.sh"               # root tests/ — out of scope.
  write_uvicorn_line "$tmpcase/dashboard/tests/_lib/test-helper.sh"  # _lib/ — out of scope.
  mkdir -p "$tmpcase/dashboard/tests/integration-tests"
  write_uvicorn_line "$tmpcase/dashboard/tests/integration-tests/test-foo.sh"  # deeper subdir — out of scope.

  invoke_linter "$tmpcase"
  local rc; rc=$(rc_of "$tmpcase")
  local out; out=$(stdout_of "$tmpcase")
  local err; err=$(stderr_of "$tmpcase")
  [ "$rc" = "0" ] && pass "T5/T9/T14/T17/T19: case-b exit code 0" || fail "T5: case-b exit expected 0, got $rc; stderr=$err"
  [ -z "$out" ] && pass "T5: case-b stdout empty" || fail "T5: case-b stdout non-empty: $out"
  [ -z "$err" ] && pass "T5: case-b stderr empty" || fail "T5: case-b stderr non-empty: $err"

  # T20 — no file modifications by the linter inside dashboard/tests/.
  local stamp; stamp=$(stat -f %m "$f1" 2>/dev/null || stat -c %Y "$f1")
  invoke_linter "$tmpcase"
  local stamp2; stamp2=$(stat -f %m "$f1" 2>/dev/null || stat -c %Y "$f1")
  [ "$stamp" = "$stamp2" ] && pass "T20: linter does not modify input fixtures" || fail "T20: fixture mtime changed across runs"

  # T21 — idempotency: byte-identical output on two consecutive runs.
  cp "$tmpcase/.stdout" "$tmpcase/.stdout1"; cp "$tmpcase/.stderr" "$tmpcase/.stderr1"
  invoke_linter "$tmpcase"
  if diff -q "$tmpcase/.stdout1" "$tmpcase/.stdout" >/dev/null && diff -q "$tmpcase/.stderr1" "$tmpcase/.stderr" >/dev/null; then
    pass "T21: case-b is byte-idempotent across two runs"
  else
    fail "T21: case-b output drifted between runs"
  fi

  # T24 — invoking from a sub-directory still works.
  set +e
  ( cd "$tmpcase/dashboard/tests" && bash "$LINTER" >/dev/null 2>"$tmpcase/.subcwd_err" )
  local sub_rc=$?
  set -e
  [ "$sub_rc" = "0" ] && [ ! -s "$tmpcase/.subcwd_err" ] && pass "T24: linter exits 0 silent when invoked from a subdir" || \
    fail "T24: subdir invocation expected rc=0 silent, got rc=$sub_rc, err=$(cat "$tmpcase/.subcwd_err")"
}

# ── Case B variant — broken-but-existing helper still treated as present (T18) ──

case_b2_broken_helper() {
  local tmpcase
  tmpcase="$(setup_case b2)"
  mkdir -p "$tmpcase/dashboard/tests/_lib"
  cat > "$tmpcase/dashboard/tests/_lib/port-preflight.sh" <<'EOF'
this is not bash &&||
EOF
  local f="$tmpcase/dashboard/tests/test-foo.sh"
  : > "$f"
  write_source_line "$f" "dashboard/tests/_lib/port-preflight.sh"
  write_call_line "$f" "9999"
  write_uvicorn_line "$f"
  invoke_linter "$tmpcase"
  local rc; rc=$(rc_of "$tmpcase")
  [ "$rc" = "0" ] && pass "T18: empty/broken helper file treated as 'present' (existence-only check)" || \
    fail "T18: broken helper expected rc=0, got $rc; stderr=$(stderr_of "$tmpcase")"
}

# ── Case B3 — fallback REPO_ROOT when no .git is present (T25) ──
# This case deliberately does NOT call setup_case because the whole
# point is to invoke the linter from a tree that has no .git/. If
# setup_case ever grows to add shared fixture files, mirror those
# additions here too — they would not be picked up automatically.

case_b3_no_git() {
  local tmpcase="$TMPBASE/case-b3"
  mkdir -p "$tmpcase/adapters/claude-code/claude/tools/lint"
  mkdir -p "$tmpcase/dashboard/tests/_lib"
  cp "$LINTER" "$tmpcase/$LINTER_REL"
  chmod +x "$tmpcase/$LINTER_REL"
  : > "$tmpcase/dashboard/tests/_lib/port-preflight.sh"
  local f="$tmpcase/dashboard/tests/test-foo.sh"
  : > "$f"
  write_source_line "$f" "dashboard/tests/_lib/port-preflight.sh"
  write_call_line "$f" "9999"
  write_uvicorn_line "$f"
  set +e
  ( cd "$tmpcase" && bash "$LINTER_REL" >"$tmpcase/.stdout" 2>"$tmpcase/.stderr" )
  local rc=$?
  set -e
  [ "$rc" = "0" ] && pass "T25: linter falls back to dirname-climb when no .git is present" || \
    fail "T25: no-git fallback expected rc=0, got $rc; stderr=$(cat "$tmpcase/.stderr")"
}

# ── Case C — non-compliant variants (T6..T8, T10, T11, T12, T13, T15, T16) ──

case_c_non_compliant() {
  local tmpcase
  tmpcase="$(setup_case c)"
  mkdir -p "$tmpcase/dashboard/tests/_lib"
  : > "$tmpcase/dashboard/tests/_lib/port-preflight.sh"

  # T6 baseline — only a spawn line, no source, no call.
  local f_bad="$tmpcase/dashboard/tests/test-foo.sh"
  : > "$f_bad"
  write_uvicorn_line "$f_bad"

  # T7 — second offender to verify ordering of stderr (header → offenders → hint).
  local f_bar="$tmpcase/dashboard/tests/test-bar.sh"
  : > "$f_bar"
  write_uvicorn_line "$f_bar"

  # T8 — compliant sibling MUST NOT appear in the failure listing.
  local f_good="$tmpcase/dashboard/tests/test-good.sh"
  : > "$f_good"
  write_source_line "$f_good" "dashboard/tests/_lib/port-preflight.sh"
  write_call_line "$f_good" "8000"
  write_uvicorn_line "$f_good"

  # T10 — inline `#` comment after a spawn line is still a spawn line.
  local f_inline="$tmpcase/dashboard/tests/test-inline.sh"
  cat > "$f_inline" <<'EOF'
echo "non-compliant inline-comment fixture"
EOF
  sed 's|__PY__|python3|g; s|__SERVE__|serve.py|g' >> "$f_inline" <<'EOF'
__PY__ dashboard/__SERVE__ & # background
EOF

  # T11 — leading/trailing whitespace on the spawn line.
  local f_ws="$tmpcase/dashboard/tests/test-ws.sh"
  sed 's|__PY__|python3|g; s|__SERVE__|serve.py|g' > "$f_ws" <<'EOF'
   __PY__ dashboard/__SERVE__
EOF

  # T12 — python / python3 / python3.12 variants all match.
  local f_py="$tmpcase/dashboard/tests/test-py.sh"
  : > "$f_py"
  write_serve_py_line "$f_py" "python"
  local f_py3="$tmpcase/dashboard/tests/test-py3.sh"
  : > "$f_py3"
  write_serve_py_line "$f_py3" "python3"
  local f_py312="$tmpcase/dashboard/tests/test-py312.sh"
  : > "$f_py312"
  write_serve_py_line "$f_py312" "python3.12"

  # T13 — second uvicorn invocation form.
  local f_uv2="$tmpcase/dashboard/tests/test-uv2.sh"
  sed 's|__UVICORN__|uvicorn|g' > "$f_uv2" <<'EOF'
__UVICORN__ dashboard.server.app:app --host 127.0.0.1
EOF

  # T15 — sourced but never called.
  local f_src_only="$tmpcase/dashboard/tests/test-source-only.sh"
  : > "$f_src_only"
  write_source_line "$f_src_only" "dashboard/tests/_lib/port-preflight.sh"
  write_uvicorn_line "$f_src_only"

  # T16 — called but never sourced.
  local f_call_only="$tmpcase/dashboard/tests/test-call-only.sh"
  : > "$f_call_only"
  write_call_line "$f_call_only" "9999"
  write_uvicorn_line "$f_call_only"

  # W1 — dot-source-only (no call): SOURCE_RE's second alternative
  # matches but compliance still requires CALL_RE → must be flagged.
  local f_dot_only="$tmpcase/dashboard/tests/test-dot-only.sh"
  : > "$f_dot_only"
  write_dot_source_line "$f_dot_only" "dashboard/tests/_lib/port-preflight.sh"
  write_uvicorn_line "$f_dot_only"

  invoke_linter "$tmpcase"
  local rc; rc=$(rc_of "$tmpcase")
  local err; err=$(stderr_of "$tmpcase")

  [ "$rc" = "1" ] && pass "T6/T22: case-c exit code 1" || fail "T6: case-c exit expected 1, got $rc"
  if printf "%s" "$err" | grep -q '^LINT FAIL: tests spawn a server without preflight:$'; then
    pass "T6: case-c stderr starts with header"
  else
    fail "T6: case-c stderr missing header line; got: $err"
  fi
  if printf "%s" "$err" | grep -q '^  dashboard/tests/test-foo.sh$'; then
    pass "T6: case-c stderr lists offending path"
  else
    fail "T6: case-c stderr missing '  dashboard/tests/test-foo.sh' line; got: $err"
  fi
  # shellcheck disable=SC2016 # $PORT is a literal in the diagnostic message — assert it byte-for-byte.
  if printf "%s" "$err" | grep -qF '  Source dashboard/tests/_lib/port-preflight.sh and call port_preflight $PORT before spawn.'; then
    pass "T6: case-c stderr contains remediation hint"
  else
    fail "T6: case-c remediation hint missing; got: $err"
  fi

  # T7 — order: header line < offender lines < remediation line.
  local hdr_ln off_ln hint_ln
  hdr_ln=$(printf "%s\n" "$err" | grep -n '^LINT FAIL:' | head -1 | cut -d: -f1)
  off_ln=$(printf "%s\n" "$err" | grep -n '^  dashboard/tests/test-bar.sh$' | head -1 | cut -d: -f1)
  hint_ln=$(printf "%s\n" "$err" | grep -nF '  Source dashboard/tests/_lib/port-preflight.sh' | head -1 | cut -d: -f1)
  if [ -n "$hdr_ln" ] && [ -n "$off_ln" ] && [ -n "$hint_ln" ] && [ "$hdr_ln" -lt "$off_ln" ] && [ "$off_ln" -lt "$hint_ln" ]; then
    pass "T7: stderr ordering header → offender → remediation"
  else
    fail "T7: stderr ordering wrong: hdr=$hdr_ln off=$off_ln hint=$hint_ln"
  fi

  # T8 — compliant sibling absent from listing.
  if printf "%s" "$err" | grep -q 'test-good.sh'; then
    fail "T8: compliant sibling appeared in failure listing"
  else
    pass "T8: compliant sibling absent from failure listing"
  fi

  # T10 — inline-comment spawn line flagged.
  if printf "%s" "$err" | grep -q 'test-inline.sh'; then
    pass "T10: inline-comment-after-spawn flagged"
  else
    fail "T10: inline-comment fixture missed"
  fi

  # T11 — whitespace-padded spawn line flagged.
  if printf "%s" "$err" | grep -q 'test-ws.sh'; then
    pass "T11: leading/trailing whitespace spawn flagged"
  else
    fail "T11: whitespace spawn fixture missed"
  fi

  # T12 — python / python3 / python3.12 variants flagged.
  local missing12=0
  for tag in test-py.sh test-py3.sh test-py312.sh; do
    if ! printf "%s" "$err" | grep -q "$tag"; then
      missing12=$((missing12 + 1))
      fail "T12: missing python-variant fixture: $tag"
    fi
  done
  [ "$missing12" -eq 0 ] && pass "T12: python / python3 / python3.12 spawn variants all flagged"

  # T13 — alternative uvicorn invocation form flagged.
  if printf "%s" "$err" | grep -q 'test-uv2.sh'; then
    pass "T13: alternative uvicorn invocation form flagged"
  else
    fail "T13: alternative uvicorn invocation missed"
  fi

  # T15 / T16 — partial-compliance sub-cases flagged.
  if printf "%s" "$err" | grep -q 'test-source-only.sh'; then
    pass "T15: sourced-but-not-called flagged (EC-R3.1)"
  else
    fail "T15: sourced-but-not-called missed"
  fi
  if printf "%s" "$err" | grep -q 'test-call-only.sh'; then
    pass "T16: called-but-not-sourced flagged (EC-R3.2)"
  else
    fail "T16: called-but-not-sourced missed"
  fi

  # W1 — dot-source-only (no call) flagged as non-compliant.
  if printf "%s" "$err" | grep -q 'test-dot-only.sh'; then
    pass "W1: dot-sourced-but-not-called flagged (SOURCE_RE second alternative + missing CALL_RE)"
  else
    fail "W1: dot-source-only fixture missed; got: $err"
  fi

  # T20 (case-c arm) — no stdout under failure path.
  local out; out=$(stdout_of "$tmpcase")
  [ -z "$out" ] && pass "T20 (case-c): stdout empty under failure path" || fail "T20 (case-c): stdout non-empty: $out"

  # T21 (case-c arm) — idempotency.
  cp "$tmpcase/.stdout" "$tmpcase/.stdout1"; cp "$tmpcase/.stderr" "$tmpcase/.stderr1"
  invoke_linter "$tmpcase"
  if diff -q "$tmpcase/.stdout1" "$tmpcase/.stdout" >/dev/null && diff -q "$tmpcase/.stderr1" "$tmpcase/.stderr" >/dev/null; then
    pass "T21 (case-c): byte-identical output on consecutive runs"
  else
    fail "T21 (case-c): output drifted across runs"
  fi
}

# ── Run cases ───────────────────────────────────────────────────

smoke_checks
case_a_helper_missing
case_b_compliant
case_b2_broken_helper
case_b3_no_git
case_c_non_compliant

# ── T26 — verify the cleanup trap is wired ──────────────────────
# `trap -p EXIT` prints the registered trap body. Asserting on it
# (instead of registering a SECOND trap that replaces the first and
# self-validates its own rm) catches the regression "someone deleted
# the trap on line 24" without producing a tautology.
trap_body="$(trap -p EXIT 2>/dev/null || true)"
if printf '%s' "$trap_body" | grep -q 'rm -rf' && printf '%s' "$trap_body" | grep -q 'TMPBASE'; then
  pass "T26: EXIT trap is registered and references TMPBASE cleanup"
else
  fail "T26: EXIT trap missing or does not call rm -rf on TMPBASE; trap=$trap_body"
fi

TOTAL=$((PASS + FAIL))
echo "Total: $TOTAL / $PASS PASS"
[ "$FAIL" -eq 0 ]
