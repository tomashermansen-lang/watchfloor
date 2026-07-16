#!/usr/bin/env bash
# Delegator script tests (DEL-01..DEL-13). DEL-14 (byte-equivalence) is
# gated separately on DEL_BYTE_EQUIV=1 because it depends on the canonical
# script's `check` subcommand being deterministic in the host environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DELEGATOR="$PROJECT_ROOT/tools/start-system.sh"

PASS=0
FAIL=0
TOTAL=0

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
    echo "    output: $haystack"
  fi
}

# ─── Sandbox ─────────────────────────────────────────────────────────
SANDBOX="$(mktemp -d "${TMPDIR:-/tmp}/del-sandbox.XXXXXX")"
# Canonicalize for macOS: /tmp is a symlink to /private/tmp, and tools like
# `git rev-parse --show-toplevel` resolve symlinks while shell expansions of
# $TMPDIR/$SANDBOX do not. Without this, DEL-08 fails because the delegator
# emits a /private/-prefixed path while assertions reference the un-prefixed
# env-var.
SANDBOX="$(cd "$SANDBOX" && pwd -P)"
FAKE_HOME="$SANDBOX/home"
FAKE_REPO="$SANDBOX/repo"
mkdir -p "$FAKE_HOME" "$FAKE_REPO"
trap 'rm -rf "$SANDBOX"' EXIT

# Plant a fake canonical script that echoes argv as JSON, prints stdin if any,
# and exits with the value of EXIT_CODE (default 0).
plant_fake_canonical() {
  local target="$1"
  cat >"$target" <<'EOF'
#!/usr/bin/env bash
# Fake canonical: dumps argv + stdin to stdout for assertion in the delegator
# test suite. Honors EXIT_CODE env var.
ARGS_JSON="["
sep=""
for a in "$@"; do
  esc=${a//\\/\\\\}
  esc=${esc//\"/\\\"}
  ARGS_JSON+="${sep}\"${esc}\""
  sep=","
done
ARGS_JSON+="]"
printf 'ARGS=%s\n' "$ARGS_JSON"
if ! [ -t 0 ]; then
  STDIN="$(cat)"
  printf 'STDIN=%s\n' "$STDIN"
fi
exit "${EXIT_CODE:-0}"
EOF
  chmod +x "$target"
}

# Initialise FAKE_REPO as a git repo so `git rev-parse --show-toplevel` resolves to it.
( cd "$FAKE_REPO" && git init -q && git config user.email t@e && git config user.name t && touch a && git add a && git commit -q -m i )

# ─── DEL-01: repo-root canonical wins ────────────────────────────────
plant_fake_canonical "$FAKE_REPO/start-system.sh"
mkdir -p "$FAKE_REPO/dashboard/tools"
cp "$DELEGATOR" "$FAKE_REPO/dashboard/tools/start-system.sh"
set +e; out="$(cd "$FAKE_REPO" && HOME="$FAKE_HOME" bash dashboard/tools/start-system.sh check 2>&1)"; set -e
assert_contains "DEL-01: repo-root canonical selected (argv shows 'check')" 'ARGS=["check"]' "$out"

# ─── DEL-02: ~/start-system.sh fallback ──────────────────────────────
rm -f "$FAKE_REPO/start-system.sh"
plant_fake_canonical "$FAKE_HOME/start-system.sh"
set +e; out="$(cd "$FAKE_REPO" && HOME="$FAKE_HOME" bash dashboard/tools/start-system.sh dashboard 2>&1)"; set -e
assert_contains "DEL-02: ~/start-system.sh fallback used" 'ARGS=["dashboard"]' "$out"

# ─── DEL-03: argv passes through (single arg) ────────────────────────
plant_fake_canonical "$FAKE_HOME/start-system.sh"
set +e; out="$(cd "$FAKE_REPO" && HOME="$FAKE_HOME" bash dashboard/tools/start-system.sh check 2>&1)"; set -e
assert_contains "DEL-03: single arg 'check' propagated" 'ARGS=["check"]' "$out"

# ─── DEL-04: argv with spaces preserved ──────────────────────────────
set +e; out="$(cd "$FAKE_REPO" && HOME="$FAKE_HOME" bash dashboard/tools/start-system.sh oih "/path with spaces" 2>&1)"; set -e
assert_contains "DEL-04: spaces preserved in argv element" '"/path with spaces"' "$out"

# ─── DEL-05: no args → empty argv ────────────────────────────────────
set +e; out="$(cd "$FAKE_REPO" && HOME="$FAKE_HOME" bash dashboard/tools/start-system.sh 2>&1)"; set -e
assert_contains "DEL-05: no args → ARGS=[]" 'ARGS=[]' "$out"

# ─── DEL-06: stdin pipes through ─────────────────────────────────────
set +e; out="$(cd "$FAKE_REPO" && HOME="$FAKE_HOME" bash -c 'printf "y\n" | bash dashboard/tools/start-system.sh stop' 2>&1)"; set -e
assert_contains "DEL-06: stdin 'y' reaches canonical" 'STDIN=y' "$out"

# ─── DEL-07: exit code propagation ───────────────────────────────────
for code in 0 1 42 127; do
  EXIT_CODE="$code" plant_fake_canonical "$FAKE_HOME/start-system.sh"
  set +e
  ( cd "$FAKE_REPO" && HOME="$FAKE_HOME" EXIT_CODE="$code" bash dashboard/tools/start-system.sh anything ) >/dev/null 2>&1
  actual=$?
  set -e
  assert_eq "DEL-07: exit code $code propagates" "$code" "$actual"
done
plant_fake_canonical "$FAKE_HOME/start-system.sh"  # restore default

# ─── DEL-08: both copies absent → exit 1 ─────────────────────────────
rm -f "$FAKE_REPO/start-system.sh" "$FAKE_HOME/start-system.sh"
set +e
out="$(cd "$FAKE_REPO" && HOME="$FAKE_HOME" bash dashboard/tools/start-system.sh dashboard 2>&1)"
actual_exit=$?
set -e
assert_eq "DEL-08: exit 1 when both copies absent" "1" "$actual_exit"
assert_contains "DEL-08: stderr names repo-root path" "$FAKE_REPO/start-system.sh" "$out"
assert_contains "DEL-08: stderr names \$HOME path" "$FAKE_HOME/start-system.sh" "$out"

# ─── DEL-09: canonical present but not executable ────────────────────
touch "$FAKE_HOME/start-system.sh"
chmod 644 "$FAKE_HOME/start-system.sh"
set +e
out="$(cd "$FAKE_REPO" && HOME="$FAKE_HOME" bash dashboard/tools/start-system.sh dashboard 2>&1)"
actual_exit=$?
set -e
assert_eq "DEL-09: exit 1 when canonical not executable" "1" "$actual_exit"
assert_contains "DEL-09: stderr names the path" "$FAKE_HOME/start-system.sh" "$out"
chmod +x "$FAKE_HOME/start-system.sh"  # restore for later tests
plant_fake_canonical "$FAKE_HOME/start-system.sh"

# ─── DEL-10: shellcheck clean ────────────────────────────────────────
if command -v shellcheck >/dev/null 2>&1; then
  set +e
  shellcheck "$DELEGATOR" >/dev/null 2>&1
  actual_exit=$?
  set -e
  assert_eq "DEL-10: shellcheck clean" "0" "$actual_exit"
else
  echo "  SKIP: DEL-10 (shellcheck not in PATH)"
fi

# ─── DEL-11: bash header + set -euo pipefail present ─────────────────
first_three="$(head -n 6 "$DELEGATOR")"
assert_contains "DEL-11: shebang #!/usr/bin/env bash" "#!/usr/bin/env bash" "$first_three"
assert_contains "DEL-11: set -euo pipefail present" "set -euo pipefail" "$first_three"

# ─── DEL-12: bounded resolution wallclock + symlink-loop safety ──────
# Stub `git` in PATH that hangs forever to model a symlink loop / hang.
STUB_DIR="$SANDBOX/stub-bin"
mkdir -p "$STUB_DIR"
cat >"$STUB_DIR/git" <<'EOF'
#!/usr/bin/env bash
sleep 30
EOF
chmod +x "$STUB_DIR/git"

# Branch A: no fallback reachable → MUST exit 1 within 1s wallclock.
rm -f "$FAKE_HOME/start-system.sh"
start=$(date +%s)
set +e
( cd "$FAKE_REPO" && PATH="$STUB_DIR:$PATH" HOME="$FAKE_HOME" \
    timeout 5 bash dashboard/tools/start-system.sh check ) >/dev/null 2>&1
actual_exit=$?
set -e
elapsed=$(( $(date +%s) - start ))
assert_eq "DEL-12 (no fallback): exit 1" "1" "$actual_exit"
if [ "$elapsed" -le 2 ]; then PASS=$((PASS+1)); TOTAL=$((TOTAL+1));
else FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: DEL-12 (no fallback) wallclock <= 2s, got ${elapsed}s"; fi

# Branch B: fallback reachable → MUST exec it within 1s.
plant_fake_canonical "$FAKE_HOME/start-system.sh"
start=$(date +%s)
set +e
out="$(cd "$FAKE_REPO" && PATH="$STUB_DIR:$PATH" HOME="$FAKE_HOME" \
    timeout 5 bash dashboard/tools/start-system.sh check 2>&1)"
actual_exit=$?
set -e
elapsed=$(( $(date +%s) - start ))
assert_eq "DEL-12 (fallback reachable): exit 0" "0" "$actual_exit"
assert_contains "DEL-12 (fallback reachable): canonical executed" 'ARGS=["check"]' "$out"
if [ "$elapsed" -le 2 ]; then PASS=$((PASS+1)); TOTAL=$((TOTAL+1));
else FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo "  FAIL: DEL-12 (fallback) wallclock <= 2s, got ${elapsed}s"; fi

# ─── DEL-13: <50 lines AND no per-project port leakage ───────────────
line_count=$(wc -l <"$DELEGATOR" | tr -d ' ')
TOTAL=$((TOTAL+1))
if [ "$line_count" -lt 50 ]; then
  PASS=$((PASS+1))
else
  FAIL=$((FAIL+1))
  echo "  FAIL: DEL-13: delegator must be < 50 lines, got $line_count"
fi

forbidden_strings=("DASHBOARD_BACKEND" "OIH_BACKEND" "start_dashboard" "8787" "8100" "5175" "5174")
for s in "${forbidden_strings[@]}"; do
  TOTAL=$((TOTAL+1))
  if grep -qF -- "$s" "$DELEGATOR"; then
    FAIL=$((FAIL+1))
    echo "  FAIL: DEL-13: delegator must not reference per-project token '$s'"
  else
    PASS=$((PASS+1))
  fi
done

# ─── Summary ─────────────────────────────────────────────────────────
echo ""
printf "Delegator: %d passed, %d failed, %d total\n" "$PASS" "$FAIL" "$TOTAL"
if [ "$FAIL" -gt 0 ]; then exit 1; fi
exit 0
