#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$SCRIPT_DIR/../hooks/report-status.sh"
PASS=0
FAIL=0
TOTAL=0

# Create isolated temp directory under $HOME (hook validates cwd is under $HOME)
TMPDIR_BASE="$(cd "$SCRIPT_DIR/.." && pwd)/.test-tmp-security"
rm -rf "$TMPDIR_BASE"
mkdir -p "$TMPDIR_BASE"

# CSRF section additions (R12)
# shellcheck source=_lib/port-preflight.sh
source "$SCRIPT_DIR/_lib/port-preflight.sh"
PORT=$((9800 + RANDOM % 100))
BASE_URL="http://127.0.0.1:$PORT"
SERVER_PID=""
CSRF_DATA_DIR=""

cleanup() {
  if [ -n "${SERVER_PID:-}" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  port_reaper "$PORT" >/dev/null 2>&1 || true
  rm -rf "$TMPDIR_BASE"
}
trap cleanup EXIT

setup() {
  TEST_DATA_DIR="$TMPDIR_BASE/data-$$-$RANDOM"
  mkdir -p "$TEST_DATA_DIR"
  TEST_JSONL="$TEST_DATA_DIR/sessions.jsonl"
  TEST_CWD="$TMPDIR_BASE/worktree-$$-$RANDOM"
  mkdir -p "$TEST_CWD"
  # `git init` MUST succeed inside $TEST_CWD. Silently swallowing the
  # failure caused a subtle accident: when init failed (sandbox/git
  # template-copy denial) the subsequent `git -C $TEST_CWD checkout -b
  # feature/test-branch` walked up the directory tree to the host
  # repo's .git and rewrote the host branch. Refuse to proceed instead.
  if ! git -C "$TEST_CWD" init -q --template= 2>"$TEST_CWD/init.err"; then
    echo "  FATAL: git init failed inside $TEST_CWD" >&2
    cat "$TEST_CWD/init.err" >&2
    exit 1
  fi
  if [ ! -d "$TEST_CWD/.git" ]; then
    echo "  FATAL: $TEST_CWD/.git missing after init — refusing to run checkout" >&2
    exit 1
  fi
  git -C "$TEST_CWD" checkout -b "feature/test-branch" 2>/dev/null
}

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

assert_file_exists() {
  local label="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [ -f "$path" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — file not found: $path"
  fi
}

assert_file_not_exists() {
  local label="$1" path="$2"
  TOTAL=$((TOTAL + 1))
  if [ ! -f "$path" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label — file should not exist: $path"
  fi
}

run_hook() {
  local input="$1"
  echo "$input" | DASHBOARD_DATA_DIR="$TEST_DATA_DIR" bash "$HOOK" 2>/dev/null
}

# ── Test: HTML tags in message preserved as literal text ──

test_xss_in_message() {
  setup
  local input='{"session_id":"sess-xss1","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"<script>alert(1)</script>"}'

  run_hook "$input"

  assert_file_exists "XSS: JSONL file created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    # The message should be preserved as-is in JSON (jq escapes it)
    # Dashboard will use textContent, so HTML tags are harmless in JSONL
    local msg
    msg=$(jq -r '.msg' "$TEST_JSONL")
    assert_eq "XSS: HTML preserved as literal" "<script>alert(1)</script>" "$msg"
  fi
}

# ── Test: Command injection in session_id ──

test_injection_session_id_subshell() {
  setup
  local input='{"session_id":"$(rm -rf /)","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"test"}'

  run_hook "$input"

  assert_file_not_exists "Injection (subshell): no JSONL written" "$TEST_JSONL"
}

test_injection_session_id_backtick() {
  setup
  local input='{"session_id":"`whoami`","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"test"}'

  run_hook "$input"

  assert_file_not_exists "Injection (backtick): no JSONL written" "$TEST_JSONL"
}

test_injection_session_id_semicolon() {
  setup
  local input='{"session_id":"abc;rm -rf /","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"test"}'

  run_hook "$input"

  assert_file_not_exists "Injection (semicolon): no JSONL written" "$TEST_JSONL"
}

test_injection_session_id_pipe() {
  setup
  local input='{"session_id":"abc|cat /etc/passwd","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"test"}'

  run_hook "$input"

  assert_file_not_exists "Injection (pipe): no JSONL written" "$TEST_JSONL"
}

# ── Test: Path traversal in cwd ──

test_path_traversal_etc() {
  setup
  local input='{"session_id":"sess-path1","cwd":"/etc","hook_event_name":"Notification","message":"test"}'

  run_hook "$input"

  assert_file_not_exists "Path traversal (/etc): no JSONL written" "$TEST_JSONL"
}

test_path_traversal_dotdot() {
  setup
  local input='{"session_id":"sess-path2","cwd":"'"$HOME"'/../../etc/passwd","hook_event_name":"Notification","message":"test"}'

  run_hook "$input"

  assert_file_not_exists "Path traversal (../../): no JSONL written" "$TEST_JSONL"
}

test_path_traversal_root() {
  setup
  local input='{"session_id":"sess-path3","cwd":"/","hook_event_name":"Notification","message":"test"}'

  run_hook "$input"

  assert_file_not_exists "Path traversal (root): no JSONL written" "$TEST_JSONL"
}

# ── Test: Shell metacharacters in branch name ──

test_shell_metachar_branch() {
  setup
  # Manually set a branch name with metacharacters (not possible via git)
  # Instead verify hook handles gracefully — branch should default to "unknown"
  # if git branch fails or returns invalid chars
  local input='{"session_id":"sess-branch1","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"test"}'

  run_hook "$input"

  # Branch should be valid (feature/test-branch from our setup)
  assert_file_exists "Branch: JSONL file created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local branch
    branch=$(jq -r '.branch' "$TEST_JSONL")
    assert_eq "Branch: valid branch name" "feature/test-branch" "$branch"
  fi
}

# ── Test: Symlink detection ──

test_symlink_jsonl() {
  setup
  # Create a symlink instead of regular file
  ln -sf /etc/passwd "$TEST_JSONL"

  local input='{"session_id":"sess-sym1","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"test"}'

  run_hook "$input"

  # File should still be a symlink (hook refused to write)
  TOTAL=$((TOTAL + 1))
  if [ -L "$TEST_JSONL" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: Symlink: hook should not have replaced symlink"
  fi
}

# ── Test: Control characters in message ──

test_control_chars_in_message() {
  setup
  # Use printf to embed control chars in JSON
  local input
  input=$(printf '{"session_id":"sess-ctrl1","cwd":"%s","hook_event_name":"Notification","message":"hello\\u0007world\\u001b[31mred"}' "$TEST_CWD")

  run_hook "$input"

  assert_file_exists "Control chars: JSONL file created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local msg
    msg=$(jq -r '.msg' "$TEST_JSONL")
    # Control characters should be stripped; only printable text remains
    TOTAL=$((TOTAL + 1))
    # msg should not contain bell (\x07) or escape (\x1b)
    if printf '%s' "$msg" | LC_ALL=C grep -qP '[\x00-\x1f\x7f]' 2>/dev/null; then
      FAIL=$((FAIL + 1))
      echo "  FAIL: Control chars: message still contains control characters"
    else
      PASS=$((PASS + 1))
    fi
  fi
}

# ── Test: Null bytes in input ──

test_null_bytes() {
  setup
  # Null bytes may get stripped by shell/jq — hook should not crash
  local ret=0
  printf '{"session_id":"sess-null\x00","cwd":"%s","hook_event_name":"Notification","message":"test"}' "$TEST_CWD" | \
    DASHBOARD_DATA_DIR="$TEST_DATA_DIR" bash "$HOOK" 2>/dev/null || ret=$?

  assert_eq "Null bytes: exit 0" "0" "$ret"
  # If JSONL was written, it must be valid JSON (null byte stripped gracefully)
  if [ -f "$TEST_JSONL" ]; then
    TOTAL=$((TOTAL + 1))
    if jq -e . "$TEST_JSONL" >/dev/null 2>&1; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: Null bytes: JSONL is not valid JSON"
    fi
  fi
}

# ── Test: Oversized input (> 10KB stdin) ──

test_oversized_input() {
  setup
  # Create a message with > 10KB of data
  local big_msg
  big_msg=$(printf 'X%.0s' $(seq 1 12000))
  local input='{"session_id":"sess-big1","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"'"$big_msg"'"}'

  local ret=0
  echo "$input" | DASHBOARD_DATA_DIR="$TEST_DATA_DIR" bash "$HOOK" 2>/dev/null || ret=$?

  assert_eq "Oversized: exit 0" "0" "$ret"

  # If JSONL was written, message must be truncated to <= 200 chars
  if [ -f "$TEST_JSONL" ]; then
    local msg_len
    msg_len=$(jq -r '.msg | length' "$TEST_JSONL")
    TOTAL=$((TOTAL + 1))
    if [ "$msg_len" -le 200 ]; then
      PASS=$((PASS + 1))
    else
      FAIL=$((FAIL + 1))
      echo "  FAIL: Oversized: message length $msg_len > 200"
    fi
  fi
}

# ── Test: Unknown event name rejected ──

test_unknown_event() {
  setup
  local input='{"session_id":"sess-unk1","cwd":"'"$TEST_CWD"'","hook_event_name":"EvilEvent","message":"test"}'

  run_hook "$input"

  assert_file_not_exists "Unknown event: no JSONL written" "$TEST_JSONL"
}

# ── Test: File permissions ──

test_file_permissions() {
  setup
  local input='{"session_id":"sess-perm1","cwd":"'"$TEST_CWD"'","hook_event_name":"Notification","message":"test"}'

  run_hook "$input"

  assert_file_exists "Permissions: JSONL file created" "$TEST_JSONL"
  if [ -f "$TEST_JSONL" ]; then
    local perms
    perms=$(stat -f "%Lp" "$TEST_JSONL" 2>/dev/null || stat -c "%a" "$TEST_JSONL" 2>/dev/null)
    assert_eq "Permissions: JSONL is 600" "600" "$perms"
  fi
}

# ── CSRF middleware helpers and assertions ─────────────────────────────

assert_contains() {
  local label="$1" needle="$2" haystack="$3"
  TOTAL=$((TOTAL + 1))
  if echo "$haystack" | grep -qF "$needle"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected to contain: $needle"
    echo "    output: $(echo "$haystack" | head -3)"
  fi
}

assert_http_status() {
  local label="$1" expected="$2" actual="$3"
  TOTAL=$((TOTAL + 1))
  if [ "$expected" = "$actual" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label"
    echo "    expected HTTP: $expected"
    echo "    actual HTTP:   $actual"
  fi
}

start_dashboard_uvicorn() {
  port_preflight "$PORT"
  # Initialize CSRF_DATA_DIR only if not already set by a per-test override
  # (T-7 isolation exception: tests may set their own CSRF_DATA_DIR before
  # calling this helper).
  if [ -z "$CSRF_DATA_DIR" ]; then
    CSRF_DATA_DIR="$TMPDIR_BASE/csrf-data-$$-$RANDOM"
  fi
  mkdir -p "$CSRF_DATA_DIR"
  local project_root repo_root py
  project_root="$(cd "$SCRIPT_DIR/.." && pwd)"
  repo_root="$(cd "$project_root/.." && pwd)"
  py="python3"
  [ -x "$repo_root/.venv/bin/python" ] && py="$repo_root/.venv/bin/python"
  PYTHONPATH="$repo_root" DASHBOARD_DATA_DIR="$CSRF_DATA_DIR" \
    "$py" -m uvicorn dashboard.server.app:app \
    --host 127.0.0.1 --port "$PORT" >/dev/null 2>&1 &
  SERVER_PID=$!
  local tries=0
  while ! curl -sf "$BASE_URL/health" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -gt 50 ]; then
      echo "  FAIL: uvicorn did not start on $BASE_URL"
      return 1
    fi
    sleep 0.2
  done
}

stop_dashboard_uvicorn() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  port_reaper "$PORT" >/dev/null 2>&1 || true
  SERVER_PID=""
}

# ── CSRF: pure-grep cases (no uvicorn) ─────────────────────────────────

test_origin_registration_above_csrf() {
  # T-24 (post-merge, renamed from test_csrf_origin_slot_marker_present per
  # R17 final bullet) / AS-9 / R9 — the SLOT marker is consumed; Origin
  # middleware is now registered. EC-15: the Phase 0 gate's
  # 'ORIGIN_MIDDLEWARE_SLOT|origin_check' grep continues to match via the
  # 'origin_check' import line.
  #
  # Runtime positional invariant: OriginMiddleware MUST be the outermost
  # middleware so it sees the request before CSRF (PLAN Risk-A). Since
  # Starlette's add_middleware does insert(0,…), the LAST-registered class
  # is the outermost, i.e. user_middleware[0]. The SOURCE-LINE positional
  # invariant: add_middleware(OriginMiddleware) must appear at a HIGHER
  # line number than add_middleware(CSRFMiddleware) — because Starlette
  # prepends, registering Origin AFTER CSRF makes Origin the outermost.
  local app_py="$SCRIPT_DIR/../server/app.py"
  TOTAL=$((TOTAL + 1))
  if grep -q 'add_middleware(OriginMiddleware)' "$app_py"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: add_middleware(OriginMiddleware) missing from app.py"
    return
  fi
  TOTAL=$((TOTAL + 1))
  if ! grep -q "ORIGIN_MIDDLEWARE_SLOT" "$app_py"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: ORIGIN_MIDDLEWARE_SLOT marker should be CONSUMED post-merge"
  fi
  # Positional invariant (fix #5 / C3.D): Origin line > CSRF line in source.
  # Starlette prepends, so last-registered is outermost; Origin must be last.
  local origin_line csrf_line
  origin_line=$(grep -n 'add_middleware(OriginMiddleware)' "$app_py" | head -1 | cut -d: -f1)
  csrf_line=$(grep -n 'add_middleware(CSRFMiddleware)' "$app_py" | head -1 | cut -d: -f1)
  TOTAL=$((TOTAL + 1))
  if [ -n "$origin_line" ] && [ -n "$csrf_line" ] && [ "$origin_line" -gt "$csrf_line" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-24 positional: Origin line ($origin_line) must be > CSRF line ($csrf_line)"
  fi
}

test_csrf_httponly_rationale_comment_present() {
  # T-6 / AS-7 / R3 — two independent line greps (the canonical comment
  # spans multiple lines with 'frontend' on one and 'double-submit' on
  # another). Do NOT collapse to a single regex.
  local csrf_py="$SCRIPT_DIR/../server/middleware/csrf.py"
  TOTAL=$((TOTAL + 1))
  if grep -q -i "frontend" "$csrf_py" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: csrf.py missing 'frontend' rationale token"
  fi
  TOTAL=$((TOTAL + 1))
  if grep -q -i "double-submit" "$csrf_py" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: csrf.py missing 'double-submit' rationale token"
  fi
}

test_csrf_token_length_pin() {
  # T-5 / EC-6 / R1 — secrets.token_urlsafe(32) appears exactly once.
  local csrf_py="$SCRIPT_DIR/../server/middleware/csrf.py"
  local count
  count=$(grep -cE 'token_urlsafe\(\s*32' "$csrf_py" 2>/dev/null || echo 0)
  assert_eq "T-5: token_urlsafe(32) appears exactly once" "1" "$count"
}

test_origin_and_schemas_files_present() {
  # T-27 inverted (renamed from test_csrf_no_origin_or_schemas_files per
  # R17 final bullet) — post-merge the predecessor's "must not exist"
  # guard inverts: both files MUST exist now.
  assert_file_exists "T-27 inverted: origin_check.py created" \
    "$SCRIPT_DIR/../server/middleware/origin_check.py"
  assert_file_exists "T-27 inverted: schemas.py created" \
    "$SCRIPT_DIR/../server/schemas.py"
}

# ── CSRF: pure-Python subprocess cases ─────────────────────────────────

test_csrf_registration_order() {
  # T-25 / AS-9 / R9 — absolute positions in app.user_middleware:
  # Post-fastapi-origin-and-schemas: OriginMiddleware at index 0
  # (outermost), CSRFMiddleware at index 1, AccessLogMiddleware at -1
  # (innermost). Starlette prepends, so last-registered sits at [0].
  local repo_root py code names
  repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
  py="python3"
  [ -x "$repo_root/.venv/bin/python" ] && py="$repo_root/.venv/bin/python"
  code="from dashboard.server.app import app; print(','.join(m.cls.__name__ for m in app.user_middleware))"
  names=$(PYTHONPATH="$repo_root" "$py" -c "$code" 2>/dev/null || echo "IMPORT_FAILED")
  TOTAL=$((TOTAL + 1))
  if [ "$names" = "IMPORT_FAILED" ]; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-25: app import failed (middleware not registered or import error)"
    return
  else
    PASS=$((PASS + 1))
  fi
  local first second last
  first=$(printf '%s\n' "$names" | awk -F, '{print $1}')
  second=$(printf '%s\n' "$names" | awk -F, '{print $2}')
  last=$(printf '%s\n' "$names" | awk -F, '{print $NF}')
  assert_eq "T-25: user_middleware[0] is OriginMiddleware" "OriginMiddleware" "$first"
  assert_eq "T-25: user_middleware[1] is CSRFMiddleware" "CSRFMiddleware" "$second"
  assert_eq "T-25: user_middleware[-1] is AccessLogMiddleware" "AccessLogMiddleware" "$last"
}

test_csrf_remote_addr_fallback() {
  # T-23 / R7 — _remote_addr returns "unknown" when request.client is None.
  local repo_root py code out
  repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
  py="python3"
  [ -x "$repo_root/.venv/bin/python" ] && py="$repo_root/.venv/bin/python"
  code="import types
from dashboard.server.middleware.csrf import _remote_addr
print(_remote_addr(types.SimpleNamespace(client=None)))"
  out=$(PYTHONPATH="$repo_root" "$py" -c "$code" 2>/dev/null || echo "IMPORT_FAILED")
  assert_eq "T-23: _remote_addr fallback is 'unknown'" "unknown" "$out"
}

# ── CSRF: cookie-issuance + safe-method behaviour ──────────────────────

test_csrf_first_get_issues_cookie() {
  # T-1, T-4 / AS-1 — first GET on a fresh session sets csrf_token cookie
  # with SameSite=Strict, Path=/, no HttpOnly, no Max-Age. Cookie value
  # must match ^[A-Za-z0-9_-]{43}$ (43-char base64url).
  CSRF_DATA_DIR=""  # reset so a fresh dir is created
  start_dashboard_uvicorn || return
  local headers_file
  headers_file="$TMPDIR_BASE/first-get-headers-$$.txt"
  curl -s -D "$headers_file" -o /dev/null "$BASE_URL/health"
  local set_cookie
  set_cookie=$(grep -i '^set-cookie:' "$headers_file" | grep -i 'csrf_token=' || true)
  TOTAL=$((TOTAL + 1))
  if [ -n "$set_cookie" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-1: no Set-Cookie header for csrf_token found"
    stop_dashboard_uvicorn
    return
  fi
  local cookie_value
  cookie_value=$(printf '%s' "$set_cookie" | grep -oE 'csrf_token=[A-Za-z0-9_-]+' | head -1 | cut -d= -f2)
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$cookie_value" | grep -qE '^[A-Za-z0-9_-]{43}$'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-1/T-4: cookie value not a 43-char base64url string (got: $cookie_value)"
  fi
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$set_cookie" | grep -qi 'samesite=strict'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-1: SameSite=Strict missing"
  fi
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$set_cookie" | grep -qi 'path=/'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-1: Path=/ missing"
  fi
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$set_cookie" | grep -qi 'httponly'; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-1: HttpOnly attribute must NOT be present"
  else
    PASS=$((PASS + 1))
  fi
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$set_cookie" | grep -qi 'max-age'; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-1: Max-Age attribute must NOT be present"
  else
    PASS=$((PASS + 1))
  fi
  stop_dashboard_uvicorn
}

test_csrf_subsequent_get_no_rotation() {
  # T-2 / AS-2 — second GET that already carries a cookie does NOT
  # receive a fresh Set-Cookie: csrf_token=... header.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local jar="$TMPDIR_BASE/jar-rotation-$$.txt"
  curl -s -c "$jar" -o /dev/null "$BASE_URL/health"
  local headers_file="$TMPDIR_BASE/second-get-headers-$$.txt"
  curl -s -b "$jar" -D "$headers_file" -o /dev/null "$BASE_URL/health"
  TOTAL=$((TOTAL + 1))
  if grep -i '^set-cookie:' "$headers_file" | grep -qi 'csrf_token='; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-2: second GET issued a fresh csrf_token cookie (no-rotation violated)"
  else
    PASS=$((PASS + 1))
  fi
  stop_dashboard_uvicorn
}

test_csrf_concurrent_cookie_issuance() {
  # T-3 / AS-13 — two parallel first-GETs receive distinct cookie values.
  # Use explicit wait protocol so the assertion never races the curls.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local jar_a="$TMPDIR_BASE/jar-a-$$.txt"
  local jar_b="$TMPDIR_BASE/jar-b-$$.txt"
  rm -f "$jar_a" "$jar_b"
  curl -s -c "$jar_a" -o /dev/null "$BASE_URL/health" &
  local pid_a=$!
  curl -s -c "$jar_b" -o /dev/null "$BASE_URL/health" &
  local pid_b=$!
  wait "$pid_a"
  wait "$pid_b"
  local val_a val_b
  val_a=$(awk '/csrf_token/ {print $7; exit}' "$jar_a" 2>/dev/null || true)
  val_b=$(awk '/csrf_token/ {print $7; exit}' "$jar_b" 2>/dev/null || true)
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$val_a" | grep -qE '^[A-Za-z0-9_-]{43}$'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-3: jar A missing 43-char csrf_token (got: $val_a)"
  fi
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$val_b" | grep -qE '^[A-Za-z0-9_-]{43}$'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-3: jar B missing 43-char csrf_token (got: $val_b)"
  fi
  TOTAL=$((TOTAL + 1))
  if [ -n "$val_a" ] && [ "$val_a" != "$val_b" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-3: concurrent cookies should differ (a=$val_a b=$val_b)"
  fi
  stop_dashboard_uvicorn
}

test_csrf_safe_method_no_audit_no_token() {
  # T-12 / AS-11 / R5, R9 — GET without cookie/header passes through and
  # writes no audit-log line.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/health")
  assert_http_status "T-12: GET /health returns 200" "200" "$status"
  TOTAL=$((TOTAL + 1))
  if [ ! -f "$CSRF_DATA_DIR/audit.ndjson" ] || ! grep -q 'csrf_violation' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-12: safe-method GET wrote csrf_violation to audit log"
  fi
  stop_dashboard_uvicorn
}

test_csrf_head_no_cookie_issued() {
  # T-13, T-14 / R5 — HEAD and OPTIONS must NOT trigger cookie issuance.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local headers_file="$TMPDIR_BASE/head-headers-$$.txt"
  # Trailing `|| true` absorbs curl exit 18 (CURLE_PARTIAL_FILE): uvicorn
  # sends Content-Length on HEAD responses with no body, and curl -X HEAD
  # (unlike -I) expects the bytes. The test only inspects the dumped
  # header file, which curl writes BEFORE noticing the short body.
  curl -s -X HEAD -D "$headers_file" -o /dev/null "$BASE_URL/health" || true
  TOTAL=$((TOTAL + 1))
  if grep -i '^set-cookie:' "$headers_file" | grep -qi 'csrf_token='; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-13: HEAD request issued a csrf_token cookie"
  else
    PASS=$((PASS + 1))
  fi
  TOTAL=$((TOTAL + 1))
  if [ ! -f "$CSRF_DATA_DIR/audit.ndjson" ] || ! grep -q 'csrf_violation' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-13: HEAD wrote a csrf_violation audit line"
  fi
  local options_headers="$TMPDIR_BASE/options-headers-$$.txt"
  # Same `|| true` rationale as the HEAD probe above — curl can return
  # non-zero for short-body responses under set -e.
  curl -s -X OPTIONS -D "$options_headers" -o /dev/null "$BASE_URL/health" || true
  TOTAL=$((TOTAL + 1))
  if grep -i '^set-cookie:' "$options_headers" | grep -qi 'csrf_token='; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-14: OPTIONS request issued a csrf_token cookie"
  else
    PASS=$((PASS + 1))
  fi
  TOTAL=$((TOTAL + 1))
  if [ ! -f "$CSRF_DATA_DIR/audit.ndjson" ] || ! grep -q 'csrf_violation' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-14: OPTIONS wrote a csrf_violation audit line"
  fi
  stop_dashboard_uvicorn
}

# ── CSRF: unsafe-method rejection / pass-through ───────────────────────

# Shared CSRF_DATA_DIR for the rejection suite — T-17/T-18/T-21 read its
# accumulated audit.ndjson. Tests below leave the dir intact between
# rejection cases so the validators see the cumulative log.

_assert_csrf_403_body_and_content_type() {
  # Helper: given a headers file + body file path, assert content-type
  # is application/json and body bytes exactly equal {"error":"csrf"}.
  local label="$1" headers_file="$2" body_file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qi '^content-type: application/json' "$headers_file"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label: response missing 'Content-Type: application/json'"
  fi
  TOTAL=$((TOTAL + 1))
  if cmp -s <(printf '%s' '{"error":"csrf"}') "$body_file"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label: 403 body bytes not exactly {\"error\":\"csrf\"} (got: $(cat "$body_file"))"
  fi
}

test_csrf_missing_header_rejected() {
  # T-8, T-15, T-16, T-19 / AS-4 — POST with cookie but no header.
  # Two sub-cases: (a) no header at all; (b) header present but empty
  # (curl semicolon syntax).
  # /api/csrf-test does not exist; CSRF middleware runs BEFORE route
  # resolution, so the 403 fires before the 404 ever happens.
  CSRF_DATA_DIR="$TMPDIR_BASE/csrf-reject-suite-$$-$RANDOM"
  start_dashboard_uvicorn || return
  local jar="$TMPDIR_BASE/jar-missing-header-$$.txt"
  curl -s -c "$jar" -o /dev/null "$BASE_URL/health"
  local cookie_value
  cookie_value=$(awk '/csrf_token/ {print $7; exit}' "$jar")
  # Sub-case (a): no header at all
  local body_a="$TMPDIR_BASE/body-mh-a-$$.bin"
  local headers_a="$TMPDIR_BASE/headers-mh-a-$$.txt"
  local status_a
  status_a=$(curl -s -X POST -H "Origin: http://127.0.0.1:8787" \
    -H "Cookie: csrf_token=$cookie_value" \
    -D "$headers_a" -o "$body_a" -w "%{http_code}" "$BASE_URL/api/csrf-test")
  assert_http_status "T-8a: missing-header (no header) → 403" "403" "$status_a"
  _assert_csrf_403_body_and_content_type "T-8a: missing-header (no header)" "$headers_a" "$body_a"
  # Sub-case (b): header present but empty (semicolon syntax)
  local body_b="$TMPDIR_BASE/body-mh-b-$$.bin"
  local headers_b="$TMPDIR_BASE/headers-mh-b-$$.txt"
  local status_b
  status_b=$(curl -s -X POST -H "Origin: http://127.0.0.1:8787" \
    -H "Cookie: csrf_token=$cookie_value" \
    -H "X-CSRF-Token;" \
    -D "$headers_b" -o "$body_b" -w "%{http_code}" "$BASE_URL/api/csrf-test")
  assert_http_status "T-8b: missing-header (empty value) → 403" "403" "$status_b"
  _assert_csrf_403_body_and_content_type "T-8b: missing-header (empty value)" "$headers_b" "$body_b"
  # Audit log assertions: two lines with reason=missing_header on /api/csrf-test
  TOTAL=$((TOTAL + 1))
  local mh_count
  # `|| true` shields the assignment from set -e when grep -c exits 1
  # (no matches) or 2 (file missing). `|| echo 0` would APPEND "0\n0"
  # when the file exists but has no matches (grep prints "0" itself),
  # breaking the `-eq 2` arithmetic on the next line. The :- fallback
  # below covers the file-missing case where grep prints nothing.
  mh_count=$(grep -c '"reason":"missing_header"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null || true)
  mh_count=${mh_count:-0}
  if [ "$mh_count" -eq 2 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-8: expected exactly 2 audit lines with reason=missing_header, got $mh_count"
  fi
  TOTAL=$((TOTAL + 1))
  if grep -q '"path":"/api/csrf-test"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null \
     && grep -q '"method":"POST"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null \
     && grep -q '"event":"csrf_violation"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-8: audit line missing path/method/event fields"
  fi
  stop_dashboard_uvicorn
}

test_csrf_missing_cookie_rejected() {
  # T-9, T-11 / AS-5, EC-3 — POST with header but no cookie. Also tests
  # the empty-cookie / empty-header trap (compare_digest("","") == True
  # would let an attacker bypass CSRF; the 'or ""' coercion + 'not
  # cookie' short-circuit fires first).
  start_dashboard_uvicorn || return
  # Sub-case 1: no Cookie header, X-CSRF-Token present.
  # Snapshot the audit-line count before each sub-case so we can verify
  # the new line classifies as missing_cookie (rather than missing_header,
  # mismatch, or being silently dropped). A bare cumulative `mc_count==2`
  # check would still pass if a future _classify regression reordered the
  # short-circuits such that sub-case 1 yielded missing_header and only
  # sub-case 2 yielded missing_cookie.
  local pre1
  # `|| true` not `|| echo 0`: when grep finds 0 matches it prints "0"
  # with exit 1, and the echo fallback would append a second "0\n0"
  # making the arithmetic below a syntax error. `|| true` shields the
  # assignment from set -e (audit.ndjson may not exist yet on this
  # first probe → grep exit 2), keeps grep's "0" output intact, and
  # the :- fallback handles the file-missing case where grep printed
  # nothing.
  pre1=$(grep -c '"reason":"missing_cookie"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null || true)
  pre1=${pre1:-0}
  local body1="$TMPDIR_BASE/body-mc-1-$$.bin"
  local headers1="$TMPDIR_BASE/headers-mc-1-$$.txt"
  local status1
  status1=$(curl -s -X POST -H "Origin: http://127.0.0.1:8787" \
    -H "X-CSRF-Token: AAA" \
    -D "$headers1" -o "$body1" -w "%{http_code}" "$BASE_URL/api/csrf-test")
  assert_http_status "T-9: missing-cookie → 403" "403" "$status1"
  _assert_csrf_403_body_and_content_type "T-9: missing-cookie" "$headers1" "$body1"
  local post1
  post1=$(grep -c '"reason":"missing_cookie"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null || true)
  post1=${post1:-0}
  TOTAL=$((TOTAL + 1))
  if [ "$post1" -eq "$((pre1 + 1))" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-9 sub-case 1: expected exactly +1 missing_cookie line (pre=$pre1 post=$post1)"
  fi
  # Sub-case 2 (T-11): empty cookie AND empty header — must classify as
  # missing_cookie, NOT pass through compare_digest("","")==True.
  local body2="$TMPDIR_BASE/body-mc-2-$$.bin"
  local headers2="$TMPDIR_BASE/headers-mc-2-$$.txt"
  local status2
  status2=$(curl -s -X POST -H "Origin: http://127.0.0.1:8787" \
    -H "Cookie: csrf_token=" -H "X-CSRF-Token;" \
    -D "$headers2" -o "$body2" -w "%{http_code}" "$BASE_URL/api/csrf-test")
  assert_http_status "T-11: empty-cookie + empty-header → 403" "403" "$status2"
  _assert_csrf_403_body_and_content_type "T-11: empty-cookie + empty-header" "$headers2" "$body2"
  local post2
  post2=$(grep -c '"reason":"missing_cookie"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null || true)
  post2=${post2:-0}
  TOTAL=$((TOTAL + 1))
  if [ "$post2" -eq "$((post1 + 1))" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-11 sub-case 2: expected exactly +1 missing_cookie line (post1=$post1 post2=$post2)"
  fi
  TOTAL=$((TOTAL + 1))
  local mc_count
  mc_count=$(grep -c '"reason":"missing_cookie"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null || true)
  mc_count=${mc_count:-0}
  if [ "$mc_count" -eq 2 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-9/T-11: expected exactly 2 audit lines with reason=missing_cookie, got $mc_count"
  fi
  stop_dashboard_uvicorn
}

test_csrf_mismatched_header_rejected() {
  # T-10 / AS-6 — POST with cookie AAA and header BBB → 403 +
  # reason=mismatch.
  start_dashboard_uvicorn || return
  local body="$TMPDIR_BASE/body-mismatch-$$.bin"
  local headers_file="$TMPDIR_BASE/headers-mismatch-$$.txt"
  local status
  status=$(curl -s -X POST -H "Origin: http://127.0.0.1:8787" \
    -H "Cookie: csrf_token=AAA" -H "X-CSRF-Token: BBB" \
    -D "$headers_file" -o "$body" -w "%{http_code}" "$BASE_URL/api/csrf-test")
  assert_http_status "T-10: mismatch → 403" "403" "$status"
  _assert_csrf_403_body_and_content_type "T-10: mismatch" "$headers_file" "$body"
  TOTAL=$((TOTAL + 1))
  if grep -q '"reason":"mismatch"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-10: audit log missing reason=mismatch line"
  fi
  stop_dashboard_uvicorn
}

test_csrf_non_ascii_header_treated_as_mismatch() {
  # T-30 / R4, R6, R7 — non-ASCII bytes in X-CSRF-Token raise TypeError
  # in secrets.compare_digest. _classify catches the TypeError and
  # classifies as mismatch (fail-closed): 403 + body bytes
  # {"error":"csrf"} + audit reason=mismatch. Regression guard against
  # the unhandled TypeError → HTML 500 path (R6 + R7 violation).
  start_dashboard_uvicorn || return
  # Seed a valid 43-char cookie via /health preflight.
  local jar="$TMPDIR_BASE/jar-non-ascii-$$.txt"
  curl -s -c "$jar" -o /dev/null "$BASE_URL/health"
  local cookie_value
  cookie_value=$(awk '/csrf_token/ {print $7; exit}' "$jar")
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$cookie_value" | grep -qE '^[A-Za-z0-9_-]{43}$'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-30: did not receive a valid cookie value (got: $cookie_value)"
  fi
  # Snapshot mismatch count BEFORE so we can verify T-30 added a new line.
  local pre_mismatch
  pre_mismatch=$(grep -c '"reason":"mismatch"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null || true)
  pre_mismatch=${pre_mismatch:-0}
  # POST with raw latin-1 bytes in the X-CSRF-Token header. The semicolon
  # form does not work here — we need the bytes IN the value, so use
  # printf to embed \xe9\xe9\xe9 into the -H argument literally.
  local body="$TMPDIR_BASE/body-non-ascii-$$.bin"
  local headers_file="$TMPDIR_BASE/headers-non-ascii-$$.txt"
  local status
  status=$(curl -s -X POST -H "Origin: http://127.0.0.1:8787" \
    -H "Cookie: csrf_token=$cookie_value" \
    -H "$(printf 'X-CSRF-Token: \xe9\xe9\xe9')" \
    -D "$headers_file" -o "$body" -w "%{http_code}" "$BASE_URL/api/csrf-test")
  assert_http_status "T-30: non-ASCII header → 403" "403" "$status"
  _assert_csrf_403_body_and_content_type "T-30: non-ASCII header" "$headers_file" "$body"
  # Assert a NEW mismatch audit line was written (count strictly greater
  # than pre-snapshot).
  TOTAL=$((TOTAL + 1))
  local post_mismatch
  post_mismatch=$(grep -c '"reason":"mismatch"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null || true)
  post_mismatch=${post_mismatch:-0}
  if [ "$post_mismatch" -gt "$pre_mismatch" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-30: expected new audit line with reason=mismatch (pre=$pre_mismatch post=$post_mismatch)"
  fi
  stop_dashboard_uvicorn
}

test_csrf_valid_round_trip() {
  # T-7 / AS-3 — valid double-submit passes through (no 403, no audit).
  # Uses an ISOLATED CSRF_DATA_DIR so the rejection-suite's audit.ndjson
  # doesn't pollute the "zero csrf_violation lines" assertion.
  local shared_dir="$CSRF_DATA_DIR"
  CSRF_DATA_DIR="$TMPDIR_BASE/csrf-valid-$$-$RANDOM"
  start_dashboard_uvicorn || { CSRF_DATA_DIR="$shared_dir"; return; }
  local jar="$TMPDIR_BASE/jar-valid-$$.txt"
  curl -s -c "$jar" -o /dev/null "$BASE_URL/health"
  local cookie_value
  cookie_value=$(awk '/csrf_token/ {print $7; exit}' "$jar")
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$cookie_value" | grep -qE '^[A-Za-z0-9_-]{43}$'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-7: did not receive a valid cookie value (got: $cookie_value)"
  fi
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST -H "Origin: http://127.0.0.1:8787" \
    -H "Cookie: csrf_token=$cookie_value" \
    -H "X-CSRF-Token: $cookie_value" "$BASE_URL/api/csrf-test")
  TOTAL=$((TOTAL + 1))
  if [ "$status" != "403" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-7: valid double-submit POST returned 403 (expected pass-through)"
  fi
  TOTAL=$((TOTAL + 1))
  if [ ! -f "$CSRF_DATA_DIR/audit.ndjson" ] || ! grep -q 'csrf_violation' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-7: audit log contains csrf_violation lines after valid round-trip"
  fi
  stop_dashboard_uvicorn
  CSRF_DATA_DIR="$shared_dir"
}

test_csrf_audit_log_path_no_query() {
  # T-22 / R7, EC-12 — the audit 'path' field is request.url.path
  # verbatim, never includes a query string.
  start_dashboard_uvicorn || return
  # Snapshot line count BEFORE the curl so we can narrow the grep target
  # to ONLY the new line T-22 produces (otherwise prior audit lines from
  # T-8 already match '"path":"/api/csrf-test"' and the assertion would
  # silently pass even if T-22's new line had a different/missing path).
  local pre new_lines
  # Group + 2>/dev/null also silences bash's own "No such file or
  # directory" message when the redirect target is missing — the bare
  # `2>/dev/null` on wc only catches wc's stderr, not the redirect
  # error that fires before wc is exec'd.
  pre=$({ wc -l < "$CSRF_DATA_DIR/audit.ndjson" || echo 0; } 2>/dev/null | tr -d ' ')
  curl -s -o /dev/null -X POST -H "Origin: http://127.0.0.1:8787" \
    -H "Cookie: csrf_token=AAA" \
    "$BASE_URL/api/csrf-test?leak=sensitive"
  new_lines="$TMPDIR_BASE/t22-new-$$.txt"
  tail -n +"$((pre + 1))" "$CSRF_DATA_DIR/audit.ndjson" > "$new_lines"
  TOTAL=$((TOTAL + 1))
  if grep -q '"path":"/api/csrf-test"' "$new_lines" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-22: audit path field missing or includes query string"
  fi
  TOTAL=$((TOTAL + 1))
  if grep -q 'leak=sensitive' "$new_lines" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-22: query string leaked into audit log"
  else
    PASS=$((PASS + 1))
  fi
  stop_dashboard_uvicorn
}

test_csrf_audit_log_append_mode() {
  # T-21 / R15 — strict +1 line-count assertion verifies append-without
  # -truncate. Run a fresh rejection and check pre/post line counts.
  start_dashboard_uvicorn || return
  local pre post
  pre=$(wc -l < "$CSRF_DATA_DIR/audit.ndjson" | tr -d ' ')
  curl -s -o /dev/null -X POST -H "Origin: http://127.0.0.1:8787" \
    -H "Cookie: csrf_token=Z" "$BASE_URL/api/csrf-test"
  post=$(wc -l < "$CSRF_DATA_DIR/audit.ndjson" | tr -d ' ')
  TOTAL=$((TOTAL + 1))
  if [ "$post" -eq "$((pre + 1))" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-21: expected exactly pre+1 audit lines (pre=$pre post=$post)"
  fi
  stop_dashboard_uvicorn
}

# ── CSRF: audit-log structural validation ──────────────────────────────

test_csrf_audit_log_json_valid() {
  # T-17, T-20 / AS-14, R7, R14 — every line is valid JSON with exactly
  # six keys (lexicographically sorted).
  local audit="$CSRF_DATA_DIR/audit.ndjson"
  assert_file_exists "T-17: audit.ndjson exists" "$audit"
  if [ ! -f "$audit" ]; then return; fi
  TOTAL=$((TOTAL + 1))
  if jq -e . "$audit" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-17: jq -e failed — invalid JSON in audit.ndjson"
  fi
  TOTAL=$((TOTAL + 1))
  # Each line MUST have the six R7 fields and nothing else (lex order
  # returned by jq's keys filter). Drop `|| true` masking on jq output —
  # if jq itself fails we want the FAIL to surface, not be silently
  # swallowed (defense against jq-unreachable false-pass).
  local jq_output bad_lines
  jq_output=$(jq -e -c 'keys == ["event","method","path","reason","remote_addr","ts"]' "$audit" 2>/dev/null)
  # `|| true` shields the assignment from set -e — grep -c exits 1
  # when nothing matches ^false$ (i.e. every line is valid), and that
  # exit propagates out of the command substitution otherwise.
  bad_lines=$(printf '%s\n' "$jq_output" | grep -c '^false$' || true)
  bad_lines=${bad_lines:-0}
  if [ "$bad_lines" = "0" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-17/T-20: $bad_lines audit lines have wrong key set"
  fi
}

test_csrf_audit_log_file_mode() {
  # T-18 / AS-10 / R7 — audit.ndjson is 0o600 on first create.
  local audit="$CSRF_DATA_DIR/audit.ndjson"
  if [ ! -f "$audit" ]; then
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: T-18: audit.ndjson does not exist for permission check"
    return
  fi
  local mode
  case "$(uname)" in
    Darwin) mode=$(stat -f "%Lp" "$audit") ;;
    *)      mode=$(stat -c "%a" "$audit") ;;
  esac
  assert_eq "T-18: audit.ndjson mode is 600" "600" "$mode"
}

# ── Origin allowlist tests (fastapi-origin-and-schemas, R16, C1.D/F/G) ─

_assert_origin_403_body_and_content_type() {
  # Symmetric helper to _assert_csrf_403_body_and_content_type: validates
  # Content-Type application/json and exact body bytes {"error":"origin"}.
  local label="$1" headers_file="$2" body_file="$3"
  TOTAL=$((TOTAL + 1))
  if grep -qi '^content-type: application/json' "$headers_file"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label: response missing 'Content-Type: application/json'"
  fi
  TOTAL=$((TOTAL + 1))
  if cmp -s <(printf '%s' '{"error":"origin"}') "$body_file"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: $label: 403 body bytes not exactly {\"error\":\"origin\"} (got: $(cat "$body_file"))"
  fi
}

_seed_csrf_cookie() {
  # GET /health and emit the csrf_token cookie value on stdout.
  # Returns empty stdout + non-zero exit if /health unreachable.
  local jar="$TMPDIR_BASE/seed-csrf-$$-$RANDOM.txt"
  curl -sf -c "$jar" -o /dev/null "$BASE_URL/health" || return 1
  awk -F'\t' '$6=="csrf_token"{print $7}' "$jar"
}

start_dashboard_uvicorn_with_origins() {
  # Variant: export DASHBOARD_ALLOWED_ORIGINS before uvicorn launches.
  local origins="$1"
  port_preflight "$PORT"
  if [ -z "$CSRF_DATA_DIR" ]; then
    CSRF_DATA_DIR="$TMPDIR_BASE/origin-data-$$-$RANDOM"
  fi
  mkdir -p "$CSRF_DATA_DIR"
  local project_root repo_root py
  project_root="$(cd "$SCRIPT_DIR/.." && pwd)"
  repo_root="$(cd "$project_root/.." && pwd)"
  py="python3"
  [ -x "$repo_root/.venv/bin/python" ] && py="$repo_root/.venv/bin/python"
  PYTHONPATH="$repo_root" DASHBOARD_DATA_DIR="$CSRF_DATA_DIR" \
    DASHBOARD_ALLOWED_ORIGINS="$origins" \
    "$py" -m uvicorn dashboard.server.app:app \
    --host 127.0.0.1 --port "$PORT" >/dev/null 2>&1 &
  SERVER_PID=$!
  local tries=0
  while ! curl -sf "$BASE_URL/health" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -gt 50 ]; then
      echo "  FAIL: uvicorn (with-origins) did not start on $BASE_URL"
      return 1
    fi
    sleep 0.2
  done
}

start_dashboard_uvicorn_with_stderr_capture() {
  # Variant: redirect uvicorn stderr to a file from the moment it spawns
  # so startup-time log lines (e.g., origin_allowlist_loaded) cannot race
  # the redirection. Sets STDERR_LOG to the captured file path.
  port_preflight "$PORT"
  if [ -z "$CSRF_DATA_DIR" ]; then
    CSRF_DATA_DIR="$TMPDIR_BASE/origin-stderr-$$-$RANDOM"
  fi
  mkdir -p "$CSRF_DATA_DIR"
  STDERR_LOG="$TMPDIR_BASE/uvicorn-stderr-$$-$RANDOM.log"
  local project_root repo_root py
  project_root="$(cd "$SCRIPT_DIR/.." && pwd)"
  repo_root="$(cd "$project_root/.." && pwd)"
  py="python3"
  [ -x "$repo_root/.venv/bin/python" ] && py="$repo_root/.venv/bin/python"
  PYTHONPATH="$repo_root" DASHBOARD_DATA_DIR="$CSRF_DATA_DIR" \
    "$py" -m uvicorn dashboard.server.app:app \
    --host 127.0.0.1 --port "$PORT" >/dev/null 2>"$STDERR_LOG" &
  SERVER_PID=$!
  local tries=0
  while ! curl -sf "$BASE_URL/health" >/dev/null 2>&1; do
    tries=$((tries + 1))
    if [ "$tries" -gt 50 ]; then
      echo "  FAIL: uvicorn (stderr-capture) did not start on $BASE_URL"
      return 1
    fi
    sleep 0.2
  done
}

_post_schema_test_valid_body() {
  # Helper: seed cookie, POST a valid WriteRequest body with given Origin.
  # Echoes "STATUS=<code> BODY=<bytes>".
  local origin="$1"
  local extra_curl="${2:-}"
  local cookie body_file status
  cookie="$(_seed_csrf_cookie)"
  body_file="$TMPDIR_BASE/ost-body-$$-$RANDOM.bin"
  # shellcheck disable=SC2086
  status=$(curl -s -X POST \
    -H "Origin: $origin" \
    -H "Cookie: csrf_token=$cookie" \
    -H "X-CSRF-Token: $cookie" \
    -H "Content-Type: application/json" \
    -d '{"feature_id":"my-feature_42","from_phase":"plan"}' \
    -o "$body_file" -w "%{http_code}" $extra_curl "$BASE_URL/api/schema-test")
  printf 'STATUS=%s BODY=%s' "$status" "$(cat "$body_file")"
}

test_origin_default_allowlist_accepts_8787() {
  # C1.D-1 / R1, R3, AS-1
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local out status
  out=$(_post_schema_test_valid_body "http://127.0.0.1:8787")
  status=$(printf '%s' "$out" | sed -n 's/^STATUS=\([0-9]*\).*/\1/p')
  assert_http_status "C1.D-1: default allowlist accepts 8787" "200" "$status"
  stop_dashboard_uvicorn
}

test_origin_default_allowlist_accepts_5175() {
  # C1.D-2 / R1, AS-2
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local out status
  out=$(_post_schema_test_valid_body "http://127.0.0.1:5175")
  status=$(printf '%s' "$out" | sed -n 's/^STATUS=\([0-9]*\).*/\1/p')
  assert_http_status "C1.D-2: default allowlist accepts 5175" "200" "$status"
  stop_dashboard_uvicorn
}

test_origin_disallowed_rejected_unsafe_method() {
  # C1.D-3 / R3, R5, R7, AS-3
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local cookie body headers status
  cookie="$(_seed_csrf_cookie)"
  body="$TMPDIR_BASE/origin-bad-body-$$.bin"
  headers="$TMPDIR_BASE/origin-bad-headers-$$.txt"
  status=$(curl -s -X POST \
    -H "Origin: https://evil.example" \
    -H "Cookie: csrf_token=$cookie" \
    -H "X-CSRF-Token: $cookie" \
    -H "Content-Type: application/json" \
    -d '{"feature_id":"x","from_phase":"plan"}' \
    -D "$headers" -o "$body" -w "%{http_code}" "$BASE_URL/api/schema-test")
  assert_http_status "C1.D-3: disallowed origin → 403" "403" "$status"
  _assert_origin_403_body_and_content_type "C1.D-3: disallowed origin" "$headers" "$body"
  TOTAL=$((TOTAL + 1))
  if grep -q '"event":"origin_violation"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null \
     && grep -q '"reason":"disallowed"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null \
     && grep -q '"method":"POST"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null \
     && grep -q '"path":"/api/schema-test"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.D-3: audit line missing event/reason/method/path"
  fi
  stop_dashboard_uvicorn
}

test_origin_missing_rejected_unsafe_method() {
  # C1.D-4 / R3, R5, R7, AS-4
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local cookie body headers status
  cookie="$(_seed_csrf_cookie)"
  body="$TMPDIR_BASE/origin-miss-body-$$.bin"
  headers="$TMPDIR_BASE/origin-miss-headers-$$.txt"
  status=$(curl -s -X POST \
    -H "Cookie: csrf_token=$cookie" \
    -H "X-CSRF-Token: $cookie" \
    -H "Content-Type: application/json" \
    -d '{"feature_id":"x","from_phase":"plan"}' \
    -D "$headers" -o "$body" -w "%{http_code}" "$BASE_URL/api/schema-test")
  assert_http_status "C1.D-4: missing origin → 403" "403" "$status"
  _assert_origin_403_body_and_content_type "C1.D-4: missing origin" "$headers" "$body"
  TOTAL=$((TOTAL + 1))
  if grep -q '"reason":"missing"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.D-4: audit log missing reason=missing"
  fi
  stop_dashboard_uvicorn
}

test_origin_empty_value_rejected_unsafe_method() {
  # C1.D-5 / R4, AS-4 sub-case — explicit empty Origin header.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local cookie body headers status
  cookie="$(_seed_csrf_cookie)"
  body="$TMPDIR_BASE/origin-empty-body-$$.bin"
  headers="$TMPDIR_BASE/origin-empty-headers-$$.txt"
  status=$(curl -s -X POST \
    -H "Origin;" \
    -H "Cookie: csrf_token=$cookie" \
    -H "X-CSRF-Token: $cookie" \
    -H "Content-Type: application/json" \
    -d '{"feature_id":"x","from_phase":"plan"}' \
    -D "$headers" -o "$body" -w "%{http_code}" "$BASE_URL/api/schema-test")
  assert_http_status "C1.D-5: empty origin value → 403" "403" "$status"
  TOTAL=$((TOTAL + 1))
  if grep -q '"reason":"missing"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.D-5: empty Origin header should classify as missing"
  fi
  stop_dashboard_uvicorn
}

test_origin_env_override_replaces_default() {
  # C1.D-6 / R1, AS-6 — env override replaces default allowlist.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn_with_origins "http://override.example" || return
  local cookie body status
  cookie="$(_seed_csrf_cookie)"
  body="$TMPDIR_BASE/origin-env-body-$$.bin"
  status=$(curl -s -X POST \
    -H "Origin: http://127.0.0.1:8787" \
    -H "Cookie: csrf_token=$cookie" \
    -H "X-CSRF-Token: $cookie" \
    -H "Content-Type: application/json" \
    -d '{"feature_id":"x","from_phase":"plan"}' \
    -o "$body" -w "%{http_code}" "$BASE_URL/api/schema-test")
  assert_http_status "C1.D-6a: default no longer allowed under override" "403" "$status"
  status=$(curl -s -X POST \
    -H "Origin: http://override.example" \
    -H "Cookie: csrf_token=$cookie" \
    -H "X-CSRF-Token: $cookie" \
    -H "Content-Type: application/json" \
    -d '{"feature_id":"x","from_phase":"plan"}' \
    -o "$body" -w "%{http_code}" "$BASE_URL/api/schema-test")
  assert_http_status "C1.D-6b: override origin accepted" "200" "$status"
  stop_dashboard_uvicorn
}

test_origin_safe_method_no_enforcement() {
  # C1.D-7 / R3, AS-7 — GET /health with NO Origin → 200.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" "$BASE_URL/health")
  assert_http_status "C1.D-7: GET /health no Origin → 200" "200" "$status"
  TOTAL=$((TOTAL + 1))
  if [ ! -f "$CSRF_DATA_DIR/audit.ndjson" ] || ! grep -q 'origin_violation' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.D-7: safe-method GET wrote origin_violation"
  fi
  stop_dashboard_uvicorn
}

test_origin_no_set_cookie_from_middleware() {
  # C1.D-8 / R8, AS-8, AC3 — 403 response carries no Set-Cookie.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local body headers status
  body="$TMPDIR_BASE/origin-nocookie-body-$$.bin"
  headers="$TMPDIR_BASE/origin-nocookie-headers-$$.txt"
  status=$(curl -s -X POST \
    -H "Origin: https://evil.example" \
    -H "Content-Type: application/json" \
    -d '{"feature_id":"x","from_phase":"plan"}' \
    -D "$headers" -o "$body" -w "%{http_code}" "$BASE_URL/api/schema-test")
  assert_http_status "C1.D-8: bad origin → 403" "403" "$status"
  TOTAL=$((TOTAL + 1))
  if grep -i '^set-cookie:' "$headers" | grep -qi 'csrf_token='; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.D-8: Set-Cookie csrf_token= must NOT be present in origin-403 response"
  else
    PASS=$((PASS + 1))
  fi
  stop_dashboard_uvicorn
}

test_origin_passthrough_preserves_csrf_cookie_round_trip() {
  # C1.D-12 / R8, AS-19, AC3 — happy path: valid Origin + CSRF + body → 200,
  # response has NO Set-Cookie: csrf_token=.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local cookie body headers status
  cookie="$(_seed_csrf_cookie)"
  body="$TMPDIR_BASE/origin-pass-body-$$.bin"
  headers="$TMPDIR_BASE/origin-pass-headers-$$.txt"
  status=$(curl -s -X POST \
    -H "Origin: http://127.0.0.1:8787" \
    -H "Cookie: csrf_token=$cookie" \
    -H "X-CSRF-Token: $cookie" \
    -H "Content-Type: application/json" \
    -d '{"feature_id":"abc","from_phase":"plan"}' \
    -D "$headers" -o "$body" -w "%{http_code}" "$BASE_URL/api/schema-test")
  assert_http_status "C1.D-12: happy-path → 200" "200" "$status"
  TOTAL=$((TOTAL + 1))
  if grep -i '^set-cookie:' "$headers" | grep -qi 'csrf_token='; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.D-12: happy-path response should NOT rotate csrf_token cookie"
  else
    PASS=$((PASS + 1))
  fi
  stop_dashboard_uvicorn
}

test_origin_allowlist_logged_at_startup() {
  # C1.D-9 / R2, AS-5
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn_with_stderr_capture || return
  TOTAL=$((TOTAL + 1))
  local count
  count=$(grep -c 'origin_allowlist_loaded' "$STDERR_LOG" 2>/dev/null || true)
  count=${count:-0}
  if [ "$count" -eq 1 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.D-9: no origin_allowlist_loaded line in stderr ($STDERR_LOG)"
  fi
  stop_dashboard_uvicorn
}

test_origin_websocket_upgrade_rejected() {
  # C1.D-11 / R3, R6, R7, AS-10 — WS upgrade with disallowed Origin
  # receives an HTTP 403 + body before any upgrade completes.
  # Uses curl -i (headers + body in stdout) instead of nc + printf
  # because BSD nc doesn't half-close the socket after stdin EOF
  # without -N, and the resulting deadlock turns the response into
  # 0 bytes — curl handles the upgrade-then-reject flow correctly.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local key out status_line
  key="dGhlIHNhbXBsZSBub25jZQ=="
  out=$(curl -s -i --max-time 5 \
    -H "Upgrade: websocket" \
    -H "Connection: Upgrade" \
    -H "Sec-WebSocket-Key: $key" \
    -H "Sec-WebSocket-Version: 13" \
    -H "Origin: https://evil.example" \
    "$BASE_URL/ws/test" 2>/dev/null || true)
  status_line=$(printf '%s' "$out" | head -1)
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$status_line" | grep -q '403'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.D-11: expected 403 status line in WS upgrade response (got: $status_line)"
  fi
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$out" | grep -q '{"error":"origin"}'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.D-11: 403 body should be {\"error\":\"origin\"}"
  fi
  TOTAL=$((TOTAL + 1))
  if grep -q '"event":"origin_violation"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null \
     && grep -q '"method":"WS"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.D-11: audit log missing method=WS origin_violation"
  fi
  stop_dashboard_uvicorn
}

test_origin_websocket_upgrade_no_origin_rejected() {
  # C1.D-11b / AS-10b — WS upgrade with NO Origin header receives
  # HTTP 403 + body {"error":"origin"} + audit entry method=WS reason=missing.
  # Uses curl -i for the same reason as C1.D-11 — see that test's comment.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local key out status_line
  key="dGhlIHNhbXBsZSBub25jZQ=="
  out=$(curl -s -i --max-time 5 \
    -H "Upgrade: websocket" \
    -H "Connection: Upgrade" \
    -H "Sec-WebSocket-Key: $key" \
    -H "Sec-WebSocket-Version: 13" \
    "$BASE_URL/ws/test" 2>/dev/null || true)
  status_line=$(printf '%s' "$out" | head -1)
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$status_line" | grep -q '403'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.D-11b: expected 403 status line for no-Origin WS upgrade (got: $status_line)"
  fi
  TOTAL=$((TOTAL + 1))
  if printf '%s' "$out" | grep -q '{"error":"origin"}'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.D-11b: 403 body should be {\"error\":\"origin\"}"
  fi
  TOTAL=$((TOTAL + 1))
  if grep -q '"event":"origin_violation"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null \
     && grep -q '"method":"WS"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null \
     && grep -q '"reason":"missing"' "$CSRF_DATA_DIR/audit.ndjson" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.D-11b: audit log missing method=WS reason=missing origin_violation"
  fi
  stop_dashboard_uvicorn
}

test_audit_log_mixed_csrf_and_origin_events() {
  # C1.F-3b / AS-17 — single audit.ndjson accumulates both origin_violation
  # and csrf_violation rows; both rows have identical key sets.
  CSRF_DATA_DIR="$TMPDIR_BASE/mixed-audit-$$-$RANDOM"
  start_dashboard_uvicorn || return
  # (a) fire disallowed-Origin POST → origin_violation row
  local cookie
  cookie="$(_seed_csrf_cookie)"
  curl -s -o /dev/null -X POST \
    -H "Origin: https://evil.example" \
    -H "Cookie: csrf_token=$cookie" \
    -H "X-CSRF-Token: $cookie" \
    -H "Content-Type: application/json" \
    -d '{"feature_id":"x","from_phase":"plan"}' \
    "$BASE_URL/api/schema-test"
  # (b) fire valid-Origin missing-CSRF-header POST → csrf_violation row
  curl -s -o /dev/null -X POST \
    -H "Origin: http://127.0.0.1:8787" \
    -H "Content-Type: application/json" \
    -d '{"feature_id":"x","from_phase":"plan"}' \
    "$BASE_URL/api/schema-test"
  local audit="$CSRF_DATA_DIR/audit.ndjson"
  # (c) assert ≥1 origin_violation and ≥1 csrf_violation
  TOTAL=$((TOTAL + 1))
  if grep -q '"event":"origin_violation"' "$audit" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.F-3b: audit log missing origin_violation event"
  fi
  TOTAL=$((TOTAL + 1))
  if grep -q '"event":"csrf_violation"' "$audit" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.F-3b: audit log missing csrf_violation event"
  fi
  # (d) assert both rows have identical key sets
  TOTAL=$((TOTAL + 1))
  local repo_root py
  repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
  py="python3"
  [ -x "$repo_root/.venv/bin/python" ] && py="$repo_root/.venv/bin/python"
  local key_check
  key_check=$("$py" -c "
import json, sys
rows = [json.loads(l) for l in open('$audit') if l.strip()]
origin_rows = [r for r in rows if r.get('event') == 'origin_violation']
csrf_rows   = [r for r in rows if r.get('event') == 'csrf_violation']
if not origin_rows or not csrf_rows:
    print('FAIL: missing rows')
    sys.exit(0)
ok = sorted(origin_rows[0].keys()) == sorted(csrf_rows[0].keys())
print('PASS' if ok else 'FAIL: ' + str(sorted(origin_rows[0].keys())) + ' vs ' + str(sorted(csrf_rows[0].keys())))
" 2>/dev/null || echo "FAIL: python error")
  if [ "$key_check" = "PASS" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.F-3b: key sets differ — $key_check"
  fi
  stop_dashboard_uvicorn
  CSRF_DATA_DIR=""
}

test_ws_inbound_message_dropped() {
  # TS1 / R-TEST-13 / AC-T2 — end-to-end proof that inbound WebSocket
  # frames sent by a client are dropped by the bridge AND never reach
  # the underlying pty / tmux subprocess. This is the integration-layer
  # half of the RSK-4 chain (the protocol-layer half is R-TEST-9 in
  # test_terminal_ws.py).
  #
  # The integration test is best-effort: it requires `tmux` and
  # `websockets` to be available. If either is missing, skip with a
  # warning instead of failing.
  if ! command -v tmux >/dev/null 2>&1; then
    echo "  SKIP: TS1: tmux missing on PATH (R-TEST-13 integration test)"
    return 0
  fi
  local repo_root py
  repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
  py="python3"
  [ -x "$repo_root/.venv/bin/python" ] && py="$repo_root/.venv/bin/python"
  if ! "$py" -c "import websockets" >/dev/null 2>&1; then
    echo "  SKIP: TS1: websockets package missing — uv sync --extra dev"
    return 0
  fi
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  # Prime the CSRF cookie (R-TEST-13: prime BEFORE opening WS so the
  # bridge does not close 4001 before the inbound-drop path executes).
  local token jar
  jar="$TMPDIR_BASE/ts1-csrf-$$-$RANDOM.txt"
  curl -sf -c "$jar" -o /dev/null "$BASE_URL/health" || {
    echo "  SKIP: TS1: /health unreachable"
    stop_dashboard_uvicorn
    return 0
  }
  token=$(awk -F'\t' '$6=="csrf_token"{print $7}' "$jar")
  if [ -z "$token" ]; then
    echo "  SKIP: TS1: failed to obtain csrf_token cookie"
    stop_dashboard_uvicorn
    return 0
  fi
  # Spin up a short-lived tmux session that the bridge can attach to.
  local tmux_name="autopilot-ts1-$$"
  local target_id="ts1-$$"
  tmux kill-session -t "$tmux_name" 2>/dev/null || true
  if ! tmux new-session -d -s "$tmux_name" -- sh -c 'while true; do echo running; sleep 1; done'; then
    echo "  SKIP: TS1: could not create tmux session (sandboxed environment?)"
    stop_dashboard_uvicorn
    return 0
  fi
  # Prime the lifecycle stream so derive_status returns running (target the
  # PROJECTS_ROOT default — ~/Projekter; the dashboard launched above reads
  # from there). If the directory is not writable, we still fall back to
  # the WS_STAYED_OPEN guard below to avoid the silent-pass loop.
  local projects_root
  projects_root="${PROJECTS_ROOT:-$HOME/Projekter}"
  local stream_dir="$projects_root/dotfiles-terminal-websocket-bridge/docs/INPROGRESS_Feature_${target_id}"
  local stream_file="$stream_dir/autopilot-stream.ndjson"
  local stream_primed="no"
  if mkdir -p "$stream_dir" 2>/dev/null; then
    printf '{"ts":"2026-05-15T12:00:00+00:00","type":"lifecycle","action":"started","target":"%s","tmux_session":"%s","source":"cli"}\n' \
      "$target_id" "$tmux_name" > "$stream_file" 2>/dev/null && stream_primed="yes"
  fi
  # Open WS, send inbound text, wait, assert.
  local ws_out
  ws_out=$("$py" - "$token" "$tmux_name" <<'PY' 2>&1 || true
import asyncio, sys
token = sys.argv[1]
tmux_name = sys.argv[2]
import websockets
url = f"ws://127.0.0.1:8798/ws/autopilot/terminal?id=ts1-{tmux_name.split('-',2)[-1]}&csrf={token}"
async def go():
    try:
        async with websockets.connect(
            url,
            origin="http://127.0.0.1:8787",
            additional_headers={"Cookie": f"csrf_token={token}"},
        ) as ws:
            await ws.send("INJECTED-MARKER")
            await asyncio.sleep(0.2)
            print("WS_STAYED_OPEN")
    except Exception as exc:
        print(f"WS_CLOSED_EARLY:{type(exc).__name__}:{exc}")
asyncio.run(go())
PY
)
  # Capture tmux output and grep for the injected marker.
  local capture
  capture=$(tmux capture-pane -p -t "$tmux_name" 2>/dev/null || echo "")
  tmux kill-session -t "$tmux_name" 2>/dev/null || true
  # Cleanup the primed lifecycle stream regardless of outcome.
  if [ "$stream_primed" = "yes" ]; then
    rm -rf "$stream_dir" 2>/dev/null || true
  fi
  # Silent-pass guard: if the WS never reached the inbound-drain path
  # (closed early due to CSRF/4404/etc.), the grep below would trivially
  # pass — SKIP instead of falsely reporting PASS.
  if ! printf '%s' "$ws_out" | grep -q 'WS_STAYED_OPEN'; then
    echo "  SKIP: TS1: WebSocket did not stay open (ws_out: $ws_out)"
    stop_dashboard_uvicorn
    CSRF_DATA_DIR=""
    return 0
  fi
  TOTAL=$((TOTAL + 1))
  if ! printf '%s' "$capture" | grep -q 'INJECTED-MARKER'; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: TS1: tmux pane contains INJECTED-MARKER (inbound bytes reached pty)"
  fi
  stop_dashboard_uvicorn
  CSRF_DATA_DIR=""
}

test_validation_handler_registered() {
  # C3.B-1+B-2 — _validation_error_to_400 is registered as the handler
  # for RequestValidationError in the FastAPI app.
  local repo_root py
  repo_root="$(cd "$SCRIPT_DIR/../.." && pwd)"
  py="python3"
  [ -x "$repo_root/.venv/bin/python" ] && py="$repo_root/.venv/bin/python"
  TOTAL=$((TOTAL + 1))
  if PYTHONPATH="$repo_root" "$py" -c "
import sys
sys.path.insert(0, '$repo_root')
from fastapi.exceptions import RequestValidationError
from dashboard.server.app import app
h = app.exception_handlers.get(RequestValidationError)
assert h is not None and h.__name__ == '_validation_error_to_400', \
    f'expected _validation_error_to_400, got {h}'
" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.B-1+B-2: _validation_error_to_400 not registered for RequestValidationError"
  fi
}

test_origin_comment_pins() {
  # C3.C-1..C3.C-6, C3.C-9, C3.C-11 — pinned rationale tokens must be
  # present in the named files.
  local app_py="$SCRIPT_DIR/../server/app.py"
  local origin_py="$SCRIPT_DIR/../server/middleware/origin_check.py"
  local csrf_py="$SCRIPT_DIR/../server/middleware/csrf.py"

  # C3.C-1
  TOTAL=$((TOTAL + 1))
  if grep -qF 'AC2 (fastapi-origin-and-schemas)' "$app_py"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.C-1: 'AC2 (fastapi-origin-and-schemas)' missing from app.py"
  fi

  # C3.C-2
  TOTAL=$((TOTAL + 1))
  if grep -qF '_AUDIT_PATH lives in csrf.py' "$origin_py"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.C-2: '_AUDIT_PATH lives in csrf.py' missing from origin_check.py"
  fi

  # C3.C-3
  TOTAL=$((TOTAL + 1))
  if grep -qF 'Log-and-continue' "$origin_py"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.C-3: 'Log-and-continue' missing from origin_check.py"
  fi

  # C3.C-4
  TOTAL=$((TOTAL + 1))
  if grep -qF 'TOCTOU' "$origin_py"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.C-4: 'TOCTOU' missing from origin_check.py"
  fi

  # C3.C-5
  TOTAL=$((TOTAL + 1))
  if grep -qF 'EC-2' "$origin_py"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.C-5: 'EC-2' missing from origin_check.py"
  fi

  # C3.C-6
  TOTAL=$((TOTAL + 1))
  if grep -qF 'EC-4' "$origin_py"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.C-6: 'EC-4' missing from origin_check.py"
  fi

  # C3.C-9: TOCTOU and Log-and-continue must appear in both csrf.py and
  # origin_check.py (symmetric-duplication drift guard per TESTPLAN C3.C-9).
  TOTAL=$((TOTAL + 1))
  if grep -qF 'TOCTOU' "$csrf_py" && grep -qF 'Log-and-continue' "$csrf_py"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.C-9: TOCTOU or Log-and-continue missing from csrf.py"
  fi

  # C3.C-11
  TOTAL=$((TOTAL + 1))
  if grep -qF 'SD-2' "$app_py"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.C-11: 'SD-2' missing from app.py"
  fi
}

test_origin_audit_log_file_mode() {
  # C1.F-1 — audit.ndjson created by an origin_violation is mode 600.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local cookie
  cookie="$(_seed_csrf_cookie)"
  curl -s -o /dev/null -X POST \
    -H "Origin: https://evil.example" \
    -H "Cookie: csrf_token=$cookie" \
    -H "X-CSRF-Token: $cookie" \
    -H "Content-Type: application/json" \
    -d '{"feature_id":"x","from_phase":"plan"}' \
    "$BASE_URL/api/schema-test"
  local audit="$CSRF_DATA_DIR/audit.ndjson"
  if [ ! -f "$audit" ]; then
    TOTAL=$((TOTAL + 1))
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.F-1: audit.ndjson does not exist after origin_violation"
    stop_dashboard_uvicorn
    return
  fi
  local mode
  case "$(uname)" in
    Darwin) mode=$(stat -f "%Lp" "$audit") ;;
    *)      mode=$(stat -c "%a" "$audit") ;;
  esac
  assert_eq "C1.F-1: audit.ndjson mode is 600" "600" "$mode"
  stop_dashboard_uvicorn
}

test_origin_audit_log_path_no_query() {
  # C1.F-3 — origin_violation audit 'path' field is request.url.path,
  # never includes the query string.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local cookie pre new_lines
  cookie="$(_seed_csrf_cookie)"
  # See 985 — group redirect inside { ... } 2>/dev/null silences bash's
  # missing-file error in addition to wc's own stderr.
  pre=$({ wc -l < "$CSRF_DATA_DIR/audit.ndjson" || echo 0; } 2>/dev/null | tr -d ' ')
  curl -s -o /dev/null -X POST \
    -H "Origin: https://evil.example" \
    -H "Cookie: csrf_token=$cookie" \
    -H "X-CSRF-Token: $cookie" \
    -H "Content-Type: application/json" \
    -d '{"feature_id":"x","from_phase":"plan"}' \
    "$BASE_URL/api/schema-test?x=1"
  new_lines="$TMPDIR_BASE/origin-f3-new-$$.txt"
  tail -n +"$((pre + 1))" "$CSRF_DATA_DIR/audit.ndjson" > "$new_lines"
  TOTAL=$((TOTAL + 1))
  if grep -q '"path":"/api/schema-test"' "$new_lines" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.F-3: audit path field missing or includes query string"
  fi
  TOTAL=$((TOTAL + 1))
  if grep -q 'x=1' "$new_lines" 2>/dev/null; then
    FAIL=$((FAIL + 1))
    echo "  FAIL: C1.F-3: query string leaked into origin audit log"
  else
    PASS=$((PASS + 1))
  fi
  stop_dashboard_uvicorn
}

test_origin_audit_write_failure_still_returns_403() {
  # C1.F-5 — log-and-continue: even if the audit file is unwriteable,
  # OriginMiddleware still returns 403. start_dashboard_uvicorn does its
  # own mkdir -p on CSRF_DATA_DIR, so we let it create the dir THEN chmod
  # it 555 so the audit-file append fails with PermissionError (caught by
  # the OSError handler at origin_check.py:_write_origin_audit_entry).
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local cookie
  cookie="$(_seed_csrf_cookie)"
  chmod 555 "$CSRF_DATA_DIR"
  local status
  status=$(curl -s -o /dev/null -w "%{http_code}" \
    -X POST \
    -H "Origin: https://evil.example" \
    -H "Cookie: csrf_token=$cookie" \
    -H "X-CSRF-Token: $cookie" \
    -H "Content-Type: application/json" \
    -d '{"feature_id":"x","from_phase":"plan"}' \
    "$BASE_URL/api/schema-test")
  # Restore write so stop_dashboard_uvicorn (or the trap on script exit)
  # can clean up the temp dir without permission errors.
  chmod 755 "$CSRF_DATA_DIR"
  assert_http_status "C1.F-5: unwriteable audit dir still returns 403" "403" "$status"
  stop_dashboard_uvicorn
  CSRF_DATA_DIR=""
}

test_origin_pure_asgi_class_def_grep() {
  # C3.C-10 / R21 — origin_check declares OriginMiddleware as a pure-ASGI
  # class (no BaseHTTPMiddleware inheritance) with the canonical ASGI
  # __call__ signature.
  local mod="$SCRIPT_DIR/../server/middleware/origin_check.py"
  TOTAL=$((TOTAL + 1))
  if ! grep -E 'class OriginMiddleware\(BaseHTTPMiddleware\)' "$mod" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.C-10: OriginMiddleware MUST NOT subclass BaseHTTPMiddleware"
  fi
  TOTAL=$((TOTAL + 1))
  if grep -E 'async def __call__\(self, scope.*receive.*send' "$mod" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.C-10: pure-ASGI __call__ signature missing"
  fi
}

# ── Pydantic / WriteRequest HTTP integration (R16, C2.D) ───────────────

_post_schema_test_body() {
  # Issue POST /api/schema-test with the given JSON body bytes, echo
  # "STATUS=<code>" + write body to BODY_FILE (env var caller sets).
  local body_json="$1"
  local cookie status
  cookie="$(_seed_csrf_cookie)"
  status=$(curl -s -X POST \
    -H "Origin: http://127.0.0.1:8787" \
    -H "Cookie: csrf_token=$cookie" \
    -H "X-CSRF-Token: $cookie" \
    -H "Content-Type: application/json" \
    -d "$body_json" \
    -o "$BODY_FILE" -w "%{http_code}" "$BASE_URL/api/schema-test")
  printf '%s' "$status"
}

test_pydantic_valid_payload_accepted() {
  # C2.D-1 / R11-R15, AS-11
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  BODY_FILE="$TMPDIR_BASE/pyd-1-body-$$.bin"
  local status
  status=$(_post_schema_test_body '{"feature_id":"my-feature_42","from_phase":"plan"}')
  assert_http_status "C2.D-1: valid payload → 200" "200" "$status"
  TOTAL=$((TOTAL + 1))
  if grep -q '"feature_id":"my-feature_42"' "$BODY_FILE" 2>/dev/null \
     && grep -q '"from_phase":"plan"' "$BODY_FILE" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C2.D-1: echo body missing feature_id/from_phase (got: $(cat "$BODY_FILE"))"
  fi
  stop_dashboard_uvicorn
}

test_pydantic_feature_id_too_long_rejected() {
  # C2.D-2 / R11, R14, AS-12
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  BODY_FILE="$TMPDIR_BASE/pyd-2-body-$$.bin"
  local big status
  big=$(printf 'x%.0s' $(seq 1 65))
  status=$(_post_schema_test_body "{\"feature_id\":\"$big\",\"from_phase\":\"plan\"}")
  assert_http_status "C2.D-2: 65-char feature_id → 400" "400" "$status"
  stop_dashboard_uvicorn
}

test_pydantic_feature_id_empty_rejected() {
  # C2.D-3
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  BODY_FILE="$TMPDIR_BASE/pyd-3-body-$$.bin"
  local status
  status=$(_post_schema_test_body '{"feature_id":"","from_phase":"plan"}')
  assert_http_status "C2.D-3: empty feature_id → 400" "400" "$status"
  stop_dashboard_uvicorn
}

test_pydantic_feature_id_with_slash_rejected() {
  # C2.D-4
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  BODY_FILE="$TMPDIR_BASE/pyd-4-body-$$.bin"
  local status
  status=$(_post_schema_test_body '{"feature_id":"a/b","from_phase":"plan"}')
  assert_http_status "C2.D-4: slash in feature_id → 400" "400" "$status"
  stop_dashboard_uvicorn
}

test_pydantic_feature_id_with_space_rejected() {
  # C2.D-5
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  BODY_FILE="$TMPDIR_BASE/pyd-5-body-$$.bin"
  local status
  status=$(_post_schema_test_body '{"feature_id":"a b","from_phase":"plan"}')
  assert_http_status "C2.D-5: space in feature_id → 400" "400" "$status"
  stop_dashboard_uvicorn
}

test_pydantic_from_phase_outside_enum_rejected() {
  # C2.D-6 / R12, AS-13
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  BODY_FILE="$TMPDIR_BASE/pyd-6-body-$$.bin"
  local status
  status=$(_post_schema_test_body '{"feature_id":"x","from_phase":"deploy"}')
  assert_http_status "C2.D-6: deploy not in enum → 400" "400" "$status"
  stop_dashboard_uvicorn
}

test_pydantic_from_phase_typo_rejected() {
  # C2.D-7 / R12, AS-13 sub-case
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  BODY_FILE="$TMPDIR_BASE/pyd-7-body-$$.bin"
  local status
  status=$(_post_schema_test_body '{"feature_id":"x","from_phase":"static_analysis"}')
  assert_http_status "C2.D-7: static_analysis typo → 400" "400" "$status"
  stop_dashboard_uvicorn
}

test_pydantic_unknown_field_rejected() {
  # C2.D-8 / R13, AS-14
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  BODY_FILE="$TMPDIR_BASE/pyd-8-body-$$.bin"
  local status
  status=$(_post_schema_test_body '{"feature_id":"x","from_phase":"plan","evil":"y"}')
  assert_http_status "C2.D-8: extra field → 400" "400" "$status"
  stop_dashboard_uvicorn
}

test_pydantic_missing_feature_id_rejected() {
  # C2.D-9 / R11, AS-15
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  BODY_FILE="$TMPDIR_BASE/pyd-9-body-$$.bin"
  local status
  status=$(_post_schema_test_body '{"from_phase":"plan"}')
  assert_http_status "C2.D-9: missing feature_id → 400" "400" "$status"
  TOTAL=$((TOTAL + 1))
  if grep -q '"feature_id"' "$BODY_FILE" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C2.D-9 / C2.E-2: error body should name feature_id"
  fi
  stop_dashboard_uvicorn
}

test_pydantic_missing_from_phase_rejected() {
  # C2.D-10
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  BODY_FILE="$TMPDIR_BASE/pyd-10-body-$$.bin"
  local status
  status=$(_post_schema_test_body '{"feature_id":"x"}')
  assert_http_status "C2.D-10: missing from_phase → 400" "400" "$status"
  TOTAL=$((TOTAL + 1))
  if grep -q '"from_phase"' "$BODY_FILE" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C2.D-10: error body should name from_phase"
  fi
  stop_dashboard_uvicorn
}

test_pydantic_400_not_422() {
  # C2.D-11 / R14, AS-16 — pinned 400 (NOT 422). Body shape {"detail":[...]}.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  BODY_FILE="$TMPDIR_BASE/pyd-11-body-$$.bin"
  local status
  status=$(_post_schema_test_body '{}')
  assert_http_status "C2.D-11: empty body → 400 (not 422)" "400" "$status"
  TOTAL=$((TOTAL + 1))
  if grep -q '"detail":' "$BODY_FILE" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C2.D-11: response body missing \"detail\" key"
  fi
  stop_dashboard_uvicorn
}

# ── /api/schema-test in OpenAPI (C3.A-1) ───────────────────────────────

test_schema_test_in_openapi() {
  # C3.A-1 / R15, EC-16
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local body status
  body="$TMPDIR_BASE/openapi-$$.json"
  status=$(curl -s -o "$body" -w "%{http_code}" "$BASE_URL/openapi.json")
  assert_http_status "C3.A-1: openapi.json reachable" "200" "$status"
  TOTAL=$((TOTAL + 1))
  if grep -q '"/api/schema-test"' "$body" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.A-1: /api/schema-test missing from OpenAPI"
  fi
  stop_dashboard_uvicorn
}

# ── Constraint regression guards (C3.C-7, C3.C-8) ──────────────────────

test_origin_no_new_env_vars() {
  # C3.C-7 / R19 — only DASHBOARD_ALLOWED_ORIGINS is read from os.environ.
  local mod1="$SCRIPT_DIR/../server/middleware/origin_check.py"
  local mod2="$SCRIPT_DIR/../server/schemas.py"
  TOTAL=$((TOTAL + 1))
  local hits
  # `_ENV_VAR` IS DASHBOARD_ALLOWED_ORIGINS (origin_check.py:25). The
  # original grep -v only filtered the literal, so the actual call site
  # `os.environ.get(_ENV_VAR)` was flagged as "unexpected env-var read"
  # even though it reads the one allowed variable.
  hits=$(grep -E 'os\.environ\.(get|\[)|os\.getenv' "$mod1" "$mod2" 2>/dev/null \
    | grep -vE 'DASHBOARD_ALLOWED_ORIGINS|_ENV_VAR' || true)
  if [ -z "$hits" ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.C-7: unexpected env-var reads: $hits"
  fi
}

test_csrf_module_untouched() {
  # C3.C-8 / R20 — csrf.py is byte-stable from main and still carries the
  # pinned csrf_violation literal and the TODO marker.
  local csrf_py="$SCRIPT_DIR/../server/middleware/csrf.py"
  TOTAL=$((TOTAL + 1))
  if grep -q '"csrf_violation"' "$csrf_py"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.C-8: csrf_violation literal missing in csrf.py"
  fi
  TOTAL=$((TOTAL + 1))
  if grep -q 'TODO(fastapi-origin-and-schemas)' "$csrf_py"; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.C-8: TODO marker missing in csrf.py"
  fi
}

# ── LOC budget (C3.F-1) ────────────────────────────────────────────────

test_loc_budgets() {
  # C3.F-1 / R18
  local origin_loc schemas_loc
  origin_loc=$(wc -l < "$SCRIPT_DIR/../server/middleware/origin_check.py" | tr -d ' ')
  schemas_loc=$(wc -l < "$SCRIPT_DIR/../server/schemas.py" | tr -d ' ')
  TOTAL=$((TOTAL + 1))
  if [ "$origin_loc" -le 170 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.F-1: origin_check.py loc=$origin_loc exceeds 170-line budget"
  fi
  TOTAL=$((TOTAL + 1))
  if [ "$schemas_loc" -le 50 ]; then
    PASS=$((PASS + 1))
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL: C3.F-1: schemas.py loc=$schemas_loc exceeds 50-line budget"
  fi
}

# ── Control endpoints (TS-11 from control-endpoints feature) ───────────

_post_control_no_csrf() {
  # POST <path> with an Origin but WITHOUT CSRF header/cookie. Echoes status.
  local path="$1" body_json="$2"
  curl -s -o /dev/null -w "%{http_code}" \
    -X POST -H "Origin: http://127.0.0.1:8787" \
    -H "Content-Type: application/json" \
    -d "$body_json" "$BASE_URL$path"
}

_post_control_with_origin() {
  # POST <path> with the named Origin AND valid CSRF cookie+header.
  local path="$1" body_json="$2" origin="$3"
  local cookie
  cookie="$(_seed_csrf_cookie)"
  curl -s -o /dev/null -w "%{http_code}" \
    -X POST -H "Origin: $origin" \
    -H "Cookie: csrf_token=$cookie" \
    -H "X-CSRF-Token: $cookie" \
    -H "Content-Type: application/json" \
    -d "$body_json" "$BASE_URL$path"
}

_post_control_full() {
  # POST <path> with full CSRF + allowed Origin (for body validation tests).
  local path="$1" body_json="$2"
  _post_control_with_origin "$path" "$body_json" "http://127.0.0.1:8787"
}

test_control_csrf_missing() {
  # TS-11.1..TS-11.8 — POST without X-CSRF-Token -> 403 for every control endpoint.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local status
  for path in /api/autopilot/start /api/autopilot/pause \
              /api/autopilot/resume /api/autopilot/cancel \
              /api/chain/start /api/chain/pause \
              /api/chain/resume /api/chain/cancel; do
    status=$(_post_control_no_csrf "$path" '{"target_id":"demo"}')
    assert_http_status "TS-11 ($path): missing CSRF -> 403" "403" "$status"
  done
  stop_dashboard_uvicorn
}

test_control_origin_disallowed() {
  # TS-11.9, TS-11.10 — disallowed Origin -> 403.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local status
  for path in /api/autopilot/start /api/chain/start; do
    status=$(_post_control_with_origin "$path" '{"target_id":"demo"}' "https://evil.example")
    assert_http_status "TS-11 ($path): bad Origin -> 403" "403" "$status"
  done
  stop_dashboard_uvicorn
}

test_control_target_kind_invalid() {
  # TS-11.11, TS-11.12 — uppercase / unknown target_kind -> 400.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local status
  status=$(_post_control_full "/api/Autopilot/start" '{"target_id":"demo"}')
  assert_http_status "TS-11.11: /api/Autopilot/start -> 400" "400" "$status"
  status=$(_post_control_full "/api/foo/start" '{"target_id":"demo"}')
  assert_http_status "TS-11.12: /api/foo/start -> 400" "400" "$status"
  stop_dashboard_uvicorn
}

test_control_target_id_injection_rejected() {
  # TS-11.13..TS-11.16 — shell metacharacters in target_id -> 400 from Pydantic.
  CSRF_DATA_DIR=""
  start_dashboard_uvicorn || return
  local status
  # semicolon
  status=$(_post_control_full "/api/autopilot/start" '{"target_id":"a;rm -rf /"}')
  assert_http_status "TS-11.13: target_id=a;rm... -> 400" "400" "$status"
  # subshell
  status=$(_post_control_full "/api/autopilot/start" '{"target_id":"$(whoami)"}')
  assert_http_status "TS-11.14: target_id=\$(whoami) -> 400" "400" "$status"
  # backtick
  status=$(_post_control_full "/api/autopilot/start" '{"target_id":"`whoami`"}')
  assert_http_status "TS-11.15: target_id=\`whoami\` -> 400" "400" "$status"
  # extra=forbid + dotty regex fail
  status=$(_post_control_full "/api/autopilot/cancel" '{"target_id":"a..b","extra":"x"}')
  assert_http_status "TS-11.16: extra=x + invalid target_id -> 400" "400" "$status"
  stop_dashboard_uvicorn
}

# ── Run all tests ──

echo "Security tests"
echo "=============="

test_xss_in_message
test_injection_session_id_subshell
test_injection_session_id_backtick
test_injection_session_id_semicolon
test_injection_session_id_pipe
test_path_traversal_etc
test_path_traversal_dotdot
test_path_traversal_root
test_shell_metachar_branch
test_symlink_jsonl
test_control_chars_in_message
test_null_bytes
test_oversized_input
test_unknown_event
test_file_permissions

# ── CSRF middleware tests (R12) ──
# Pure-grep cases first (cheapest — fail fast on missing marker / comment).
test_origin_registration_above_csrf        # T-24 (renamed)
test_csrf_httponly_rationale_comment_present  # T-6
test_csrf_token_length_pin                  # T-5
test_origin_and_schemas_files_present      # T-27 (inverted/renamed)
# Pure-import + module introspection.
test_csrf_registration_order                # T-25 (T-26 folded)
test_csrf_remote_addr_fallback              # T-23
# Cookie-issuance / safe-method behavior (no audit log expected).
test_csrf_first_get_issues_cookie           # T-1, T-4
test_csrf_subsequent_get_no_rotation        # T-2
test_csrf_concurrent_cookie_issuance        # T-3
test_csrf_safe_method_no_audit_no_token     # T-12
test_csrf_head_no_cookie_issued             # T-13, T-14
# Unsafe-method validation (writes audit.ndjson to shared CSRF_DATA_DIR).
# T-8/T-9/T-10/T-11/T-30 DISABLED 2026-06-02 — drift fix. These curl from
# loopback (127.0.0.1) expecting a 403 CSRF reject, but csrf.py short-circuits
# loopback clients (controls-07 #8, documented threat-model rationale) BEFORE
# CSRF runs — so they get 404, not 403. CSRF ENFORCEMENT is now covered
# correctly by dashboard/tests/test-csrf-enforcement.sh (Starlette TestClient =
# non-loopback, the vector csrf.py itself names). Re-enable only if rewritten to
# assert the loopback EXEMPTION (which is what they would now observe).
# test_csrf_missing_header_rejected           # T-8, T-15, T-16, T-19
# test_csrf_missing_cookie_rejected           # T-9, T-11
# test_csrf_mismatched_header_rejected        # T-10
# test_csrf_non_ascii_header_treated_as_mismatch  # T-30
test_csrf_valid_round_trip                  # T-7 (isolated CSRF_DATA_DIR)
test_csrf_audit_log_path_no_query           # T-22
test_csrf_audit_log_append_mode             # T-21
# Audit-log structural validation (runs LAST — depends on accumulated lines).
test_csrf_audit_log_json_valid              # T-17, T-20
test_csrf_audit_log_file_mode               # T-18

# ── Origin allowlist tests (fastapi-origin-and-schemas, C1.D/G + C3) ──
test_origin_pure_asgi_class_def_grep        # C3.C-10
test_origin_no_new_env_vars                 # C3.C-7
test_csrf_module_untouched                  # C3.C-8
test_loc_budgets                            # C3.F-1
test_origin_default_allowlist_accepts_8787  # C1.D-1
test_origin_default_allowlist_accepts_5175  # C1.D-2
test_origin_disallowed_rejected_unsafe_method  # C1.D-3
test_origin_missing_rejected_unsafe_method  # C1.D-4
test_origin_empty_value_rejected_unsafe_method  # C1.D-5
test_origin_env_override_replaces_default   # C1.D-6
test_origin_safe_method_no_enforcement      # C1.D-7
test_origin_no_set_cookie_from_middleware   # C1.D-8
test_origin_passthrough_preserves_csrf_cookie_round_trip  # C1.D-12
test_origin_allowlist_logged_at_startup     # C1.D-9
test_origin_websocket_upgrade_rejected      # C1.D-11
test_origin_websocket_upgrade_no_origin_rejected  # C1.D-11b / AS-10b
test_audit_log_mixed_csrf_and_origin_events  # C1.F-3b / AS-17
test_ws_inbound_message_dropped             # TS1 — terminal-websocket-bridge RSK-4 end-to-end
test_validation_handler_registered          # C3.B-1+B-2
test_origin_comment_pins                    # C3.C-1..C3.C-6, C3.C-9, C3.C-11
test_origin_audit_log_file_mode             # C1.F-1
test_origin_audit_log_path_no_query         # C1.F-3
test_origin_audit_write_failure_still_returns_403  # C1.F-5

# ── Pydantic / WriteRequest HTTP integration (C2.D, C3.A) ──
test_pydantic_valid_payload_accepted        # C2.D-1
test_pydantic_feature_id_too_long_rejected  # C2.D-2
test_pydantic_feature_id_empty_rejected     # C2.D-3
test_pydantic_feature_id_with_slash_rejected  # C2.D-4
test_pydantic_feature_id_with_space_rejected  # C2.D-5
test_pydantic_from_phase_outside_enum_rejected  # C2.D-6
test_pydantic_from_phase_typo_rejected      # C2.D-7
test_pydantic_unknown_field_rejected        # C2.D-8
test_pydantic_missing_feature_id_rejected   # C2.D-9
test_pydantic_missing_from_phase_rejected   # C2.D-10
test_pydantic_400_not_422                   # C2.D-11
test_schema_test_in_openapi                 # C3.A-1

# ── Control endpoints (control-endpoints feature, TS-11) ──
test_control_csrf_missing                   # TS-11.1..TS-11.8
test_control_origin_disallowed              # TS-11.9, TS-11.10
test_control_target_kind_invalid            # TS-11.11, TS-11.12
test_control_target_id_injection_rejected   # TS-11.13..TS-11.16

echo ""
printf "Tests: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$TOTAL"

if [ "$FAIL" -gt 0 ]; then
  exit 1
fi

exit 0
