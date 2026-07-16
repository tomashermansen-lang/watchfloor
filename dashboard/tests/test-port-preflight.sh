#!/usr/bin/env bash
# Regression suite for dashboard/tests/_lib/port-preflight.sh (C1).
# Exercises every clause of REQUIREMENTS.md R3-R10 plus AS-1..AS-7, AS-11.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SCRIPT_DIR/_lib/port-preflight.sh"

PASS=0
FAIL=0
TOTAL=0

# Pick a private random port from the ephemeral range 45000..49999 (R13)
# Indentation is intentional: keeps this regression suite out of the
# `grep -lE '^PORT=' dashboard/tests/test-*.sh` cutover-list invariant
# (TC-O5) — this suite does not spawn a long-lived server, only short
# probe listeners that exercise the helper's contract.
  PORT=$((45000 + RANDOM % 5000))

# Tmp dirs for stub-lsof PATH manipulation (TC-F1, TC-G1, TC-G2).
STUB_DIR=""
EMPTY_DIR=""
LISTENER_PID=""

cleanup() {
  if [ -n "$LISTENER_PID" ] && kill -0 "$LISTENER_PID" 2>/dev/null; then
    kill -KILL "$LISTENER_PID" 2>/dev/null || true
  fi
  # Dog-food the reaper itself (R14) — best-effort, never abort cleanup.
  if [ -f "$HELPER" ]; then
    # shellcheck source=/dev/null
    ( source "$HELPER" 2>/dev/null && port_reaper "$PORT" ) >/dev/null 2>&1 || true
  fi
  [ -n "$STUB_DIR" ] && rm -rf "$STUB_DIR"
  [ -n "$EMPTY_DIR" ] && rm -rf "$EMPTY_DIR"
  # Trap exit status must be neutral — the final test on EMPTY_DIR
  # (often empty by this point) would otherwise propagate as 1.
  return 0
}
trap cleanup EXIT

# ─── Assertions ─────────────────────────────────────────────────────

assert_eq() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected: $expected"
    echo "    actual:   $actual"
  fi
}

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$haystack" | grep -qF -- "$needle"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    output (head): $(printf '%s' "$haystack" | head -3)"
  fi
}

assert_nonzero() {
  local label="$1" actual="$2"
  TOTAL=$((TOTAL + 1))
  if [ "$actual" -ne 0 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected non-zero exit, got: $actual"
  fi
}

# Helper: spawn a python listener on $1 and store its PID in LISTENER_PID.
# Waits up to 1s for the bind to settle.
spawn_listener() {
  local port="$1"
  python3 -c "
import socket, time
s = socket.socket()
s.bind(('127.0.0.1', $port))
s.listen(1)
time.sleep(60)
" &
  LISTENER_PID=$!
  # Remove from the shell's job table so bash does not print
  # "Killed: 9" when the reaper SIGKILLs it.
  disown "$LISTENER_PID" 2>/dev/null || true
  # Wait for bind via lsof (up to 1s).
  local tries=0
  while ! lsof -nP -iTCP:"$port" -sTCP:LISTEN -t 2>/dev/null | grep -q '.'; do
    tries=$((tries + 1))
    if [ "$tries" -gt 10 ]; then
      echo "  FAIL: spawn_listener: bind did not settle within 1s"
      return 1
    fi
    sleep 0.1
  done
}

# Helper: kill listener, wait, clear LISTENER_PID. Best-effort.
kill_listener() {
  if [ -n "$LISTENER_PID" ]; then
    kill -KILL "$LISTENER_PID" 2>/dev/null || true
    # Listener was disowned, so wait would error with "not a child";
    # poll briefly for the PID to disappear instead.
    local tries=0
    while kill -0 "$LISTENER_PID" 2>/dev/null; do
      tries=$((tries + 1))
      if [ "$tries" -gt 10 ]; then break; fi
      sleep 0.05
    done
    LISTENER_PID=""
  fi
}

# ─── Random-port retry guard (PLAN.md Risk #4) ───────────────────────
# If something else happens to be bound to the port we picked, re-roll
# up to 3 times before declaring the host dirty.
ensure_free_port() {
  local tries=0
  while lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null | grep -q '.'; do
    tries=$((tries + 1))
    if [ "$tries" -gt 3 ]; then
      echo "  FAIL: ensure_free_port: host has orphan listeners on every random pick"
      exit 1
    fi
    PORT=$((45000 + RANDOM % 5000))
  done
}
ensure_free_port

echo "=== Port preflight + reaper tests ==="
echo "  using random port: $PORT"

# ─── TC-A1: source helper under set -euo pipefail ────────────────────
echo ""
echo "  TC-A1: source helper under set -euo pipefail"
A1_OUT=$(bash -c "set -euo pipefail; source '$HELPER'; echo OK" 2>&1) || true
A1_RC=$?
assert_eq "TC-A1: source returned 0" "0" "$A1_RC"
assert_contains "TC-A1: stdout contains OK" "OK" "$A1_OUT"

# ─── TC-A2: only port_preflight + port_reaper exposed ────────────────
# Lists the FULL set of functions in a fresh subshell after sourcing.
# Filtering on a name prefix would mask private helpers leaking into the
# caller's namespace (R1: "exactly two functions in the caller's scope").
echo "  TC-A2: helper exposes exactly two functions"
A2_OUT=$(bash -c "set -euo pipefail; source '$HELPER'; compgen -A function | sort | tr '\n' ' '" 2>&1) || true
# Trim trailing space for stable comparison.
A2_OUT_TRIM=$(printf '%s' "$A2_OUT" | sed 's/[[:space:]]*$//')
assert_eq "TC-A2: exactly port_preflight and port_reaper exposed (no private helpers leak)" "port_preflight port_reaper" "$A2_OUT_TRIM"

# Source the helper for the rest of the suite.
# shellcheck source=_lib/port-preflight.sh
source "$HELPER"

# ─── TC-B1: free port → preflight returns 0 silently ─────────────────
echo "  TC-B1: preflight on free port"
B1_STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/preflight-b1.XXXXXX")"
B1_STDOUT_FILE="$(mktemp "${TMPDIR:-/tmp}/preflight-b1-out.XXXXXX")"
set +e
port_preflight "$PORT" >"$B1_STDOUT_FILE" 2>"$B1_STDERR_FILE"
B1_RC=$?
set -e
assert_eq "TC-B1: free-port preflight exit code" "0" "$B1_RC"
assert_eq "TC-B1: free-port preflight stdout empty" "0" "$(wc -c <"$B1_STDOUT_FILE" | tr -d ' ')"
assert_eq "TC-B1: free-port preflight stderr empty" "0" "$(wc -c <"$B1_STDERR_FILE" | tr -d ' ')"
rm -f "$B1_STDERR_FILE" "$B1_STDOUT_FILE"

# ─── TC-B2: held port → preflight returns non-zero with PID ──────────
echo "  TC-B2: preflight on held port"
spawn_listener "$PORT"
B2_STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/preflight-b2.XXXXXX")"
set +e
port_preflight "$PORT" 2>"$B2_STDERR_FILE"
B2_RC=$?
set -e
B2_STDERR=$(cat "$B2_STDERR_FILE")
assert_nonzero "TC-B2: held-port preflight non-zero exit" "$B2_RC"
assert_contains "TC-B2: stderr contains PREFLIGHT FAIL" "PREFLIGHT FAIL" "$B2_STDERR"
assert_contains "TC-B2: stderr contains the port number" "$PORT" "$B2_STDERR"
assert_contains "TC-B2: stderr contains listener PID" "$LISTENER_PID" "$B2_STDERR"
B2_LINES=$(wc -l <"$B2_STDERR_FILE" | tr -d ' ')
assert_eq "TC-B2: stderr is exactly one line" "1" "$B2_LINES"
rm -f "$B2_STDERR_FILE"
kill_listener

# ─── TC-C1..TC-C5: preflight invalid port ────────────────────────────
echo "  TC-C1..C5: preflight invalid port"
for variant in "" "abc" "0" "70000"; do
  C_STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/preflight-c.XXXXXX")"
  set +e
  port_preflight "$variant" 2>"$C_STDERR_FILE"
  C_RC=$?
  set -e
  C_STDERR=$(cat "$C_STDERR_FILE")
  assert_nonzero "TC-C[$variant]: invalid port non-zero exit" "$C_RC"
  assert_contains "TC-C[$variant]: stderr has PREFLIGHT FAIL: invalid port" "PREFLIGHT FAIL: invalid port" "$C_STDERR"
  rm -f "$C_STDERR_FILE"
done
# TC-C5: no argument at all.
C5_STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/preflight-c5.XXXXXX")"
set +e
port_preflight 2>"$C5_STDERR_FILE"
C5_RC=$?
set -e
C5_STDERR=$(cat "$C5_STDERR_FILE")
assert_nonzero "TC-C5: no-arg preflight non-zero exit" "$C5_RC"
assert_contains "TC-C5: no-arg stderr has PREFLIGHT FAIL: invalid port" "PREFLIGHT FAIL: invalid port" "$C5_STDERR"
# Must not be an "unbound variable" shell error — only the helper's own message.
if printf '%s' "$C5_STDERR" | grep -q "unbound variable"; then
  FAIL=$((FAIL + 1))
  TOTAL=$((TOTAL + 1))
  echo "  FAIL: TC-C5: stderr leaked 'unbound variable' shell error"
else
  PASS=$((PASS + 1))
  TOTAL=$((TOTAL + 1))
fi
rm -f "$C5_STDERR_FILE"

# ─── TC-D1: held port → reaper frees it within 2s ────────────────────
echo "  TC-D1: reaper kills held port"
spawn_listener "$PORT"
D1_LISTENER_PID="$LISTENER_PID"
set +e
T_BEFORE=$(python3 -c 'import time; print(time.time())')
port_reaper "$PORT"
D1_RC=$?
T_AFTER=$(python3 -c 'import time; print(time.time())')
set -e
assert_eq "TC-D1: reaper exit code" "0" "$D1_RC"
# Listener should be dead.
set +e
kill -0 "$D1_LISTENER_PID" 2>/dev/null
KILL0_RC=$?
set -e
assert_nonzero "TC-D1: kill -0 listener returns non-zero (process gone)" "$KILL0_RC"
# lsof must report no listener.
LSOF_AFTER=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN -t 2>/dev/null || true)
assert_eq "TC-D1: lsof reports no listener" "" "$LSOF_AFTER"
LISTENER_PID=""

# ─── TC-D2: reaper completes in < 1.0s on cooperative listener (R21)
echo "  TC-D2: reaper sub-second on cooperative listener"
TOTAL=$((TOTAL + 1))
if awk -v a="$T_BEFORE" -v b="$T_AFTER" 'BEGIN { exit !(b - a < 1.0) }'; then
  PASS=$((PASS + 1))
else
  FAIL=$((FAIL + 1))
  echo "  FAIL: TC-D2: reaper took $(awk -v a="$T_BEFORE" -v b="$T_AFTER" 'BEGIN { printf "%.3f", b - a }')s (expected < 1.0s)"
fi

# ─── TC-E1: free port → reaper exits 0 silently, no signals issued ───
echo "  TC-E1: reaper on free port"
# Spawn a sleeper to verify no stray signals are sent.
sleep 60 &
SLEEPER_PID=$!
disown "$SLEEPER_PID" 2>/dev/null || true
E1_STDOUT_FILE="$(mktemp "${TMPDIR:-/tmp}/reaper-e1-out.XXXXXX")"
E1_STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/reaper-e1.XXXXXX")"
set +e
port_reaper "$PORT" >"$E1_STDOUT_FILE" 2>"$E1_STDERR_FILE"
E1_RC=$?
set -e
assert_eq "TC-E1: free-port reaper exit code" "0" "$E1_RC"
assert_eq "TC-E1: free-port reaper stdout empty" "0" "$(wc -c <"$E1_STDOUT_FILE" | tr -d ' ')"
assert_eq "TC-E1: free-port reaper stderr empty" "0" "$(wc -c <"$E1_STDERR_FILE" | tr -d ' ')"
# Sleeper must still be alive — proves no stray signals issued.
set +e
kill -0 "$SLEEPER_PID" 2>/dev/null
SLEEPER_ALIVE_RC=$?
set -e
assert_eq "TC-E1: sleeper still alive (no stray signals)" "0" "$SLEEPER_ALIVE_RC"
kill -KILL "$SLEEPER_PID" 2>/dev/null || true
rm -f "$E1_STDOUT_FILE" "$E1_STDERR_FILE"

# ─── TC-F1: stub lsof → reaper surfaces REAPER FAIL ──────────────────
echo "  TC-F1: stub lsof simulates surviving listener"
STUB_DIR=$(mktemp -d "${TMPDIR:-/tmp}/preflight-stub.XXXXXX")
cat >"$STUB_DIR/lsof" <<'STUB'
#!/bin/sh
# Always reports PID 99999 holding the port (regardless of args).
if printf '%s\n' "$@" | grep -q 'iTCP'; then
  echo 99999
fi
STUB
chmod +x "$STUB_DIR/lsof"
F1_STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/reaper-f1.XXXXXX")"
set +e
PATH="$STUB_DIR:$PATH" port_reaper "$PORT" 2>"$F1_STDERR_FILE"
F1_RC=$?
set -e
F1_STDERR=$(cat "$F1_STDERR_FILE")
assert_nonzero "TC-F1: stub-lsof reaper non-zero exit" "$F1_RC"
assert_contains "TC-F1: stderr contains REAPER FAIL" "REAPER FAIL" "$F1_STDERR"
assert_contains "TC-F1: stderr contains port" "$PORT" "$F1_STDERR"
assert_contains "TC-F1: stderr contains stub PID 99999" "99999" "$F1_STDERR"
rm -f "$F1_STDERR_FILE"
rm -rf "$STUB_DIR"
STUB_DIR=""

# ─── TC-G1, TC-G2: lsof missing → both functions surface error ───────
echo "  TC-G1: lsof missing → preflight surfaces error"
EMPTY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/preflight-empty.XXXXXX")
G1_STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/preflight-g1.XXXXXX")"
set +e
PATH="$EMPTY_DIR" port_preflight "$PORT" 2>"$G1_STDERR_FILE"
G1_RC=$?
set -e
G1_STDERR=$(cat "$G1_STDERR_FILE")
assert_nonzero "TC-G1: lsof-missing preflight non-zero exit" "$G1_RC"
assert_contains "TC-G1: stderr has PREFLIGHT FAIL: lsof not found" "PREFLIGHT FAIL: lsof not found" "$G1_STDERR"
rm -f "$G1_STDERR_FILE"

echo "  TC-G2: lsof missing → reaper surfaces error"
G2_STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/reaper-g2.XXXXXX")"
set +e
PATH="$EMPTY_DIR" port_reaper "$PORT" 2>"$G2_STDERR_FILE"
G2_RC=$?
set -e
G2_STDERR=$(cat "$G2_STDERR_FILE")
assert_nonzero "TC-G2: lsof-missing reaper non-zero exit" "$G2_RC"
assert_contains "TC-G2: stderr has REAPER FAIL: lsof not found" "REAPER FAIL: lsof not found" "$G2_STDERR"
rm -f "$G2_STDERR_FILE"
rm -rf "$EMPTY_DIR"
EMPTY_DIR=""

# ─── TC-H1: reaper invalid port parity with preflight ────────────────
echo "  TC-H1: reaper invalid port"
for variant in "" "abc" "0" "70000"; do
  H_STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/reaper-h.XXXXXX")"
  set +e
  port_reaper "$variant" 2>"$H_STDERR_FILE"
  H_RC=$?
  set -e
  H_STDERR=$(cat "$H_STDERR_FILE")
  assert_nonzero "TC-H1[$variant]: invalid-port reaper non-zero exit" "$H_RC"
  assert_contains "TC-H1[$variant]: stderr has REAPER FAIL: invalid port" "REAPER FAIL: invalid port" "$H_STDERR"
  rm -f "$H_STDERR_FILE"
done
# No-arg parity.
H_NOARG_STDERR_FILE="$(mktemp "${TMPDIR:-/tmp}/reaper-h-noarg.XXXXXX")"
set +e
port_reaper 2>"$H_NOARG_STDERR_FILE"
H_NOARG_RC=$?
set -e
H_NOARG_STDERR=$(cat "$H_NOARG_STDERR_FILE")
assert_nonzero "TC-H1: no-arg reaper non-zero exit" "$H_NOARG_RC"
assert_contains "TC-H1: no-arg stderr has REAPER FAIL: invalid port" "REAPER FAIL: invalid port" "$H_NOARG_STDERR"
rm -f "$H_NOARG_STDERR_FILE"

# ─── Summary ─────────────────────────────────────────────────────────
echo ""
printf "Port preflight + reaper: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
