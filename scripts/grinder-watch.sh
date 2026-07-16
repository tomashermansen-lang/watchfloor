#!/usr/bin/env bash
# grinder-watch.sh — live status panel for grinder.sh run
#
# Refreshes every 3 seconds. Shows:
#   - current pass + batch + progress (X / total)
#   - elapsed time in current batch
#   - last assistant action (tool call or text)
#   - findings counts from completed batches
#
# Usage: bash scripts/grinder-watch.sh

set -uo pipefail

ROOT="${DOTFILES_ROOT:-$HOME/Projekter/dotfiles}"
STATE="$ROOT/docs/grinder/grinder-state.json"
EVENTS="$ROOT/docs/grinder/events.ndjson"
STREAM="$ROOT/docs/grinder/grinder-stream.ndjson"

clear
while true; do
  printf "\033[H\033[2J"   # clear screen
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Grinder Live Status — $(date +%H:%M:%S)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # State
  if [ -f "$STATE" ]; then
    python3 - "$STATE" <<'PY' 2>/dev/null
import json, sys
from datetime import datetime, timezone
with open(sys.argv[1]) as f:
    s = json.load(f)
print(f"  pass:       {s.get('current_pass')}")
print(f"  batch:      {s.get('current_batch')}")
done = s.get('batches_completed', 0)
pending = s.get('batches_pending', 0)
failed = s.get('batches_failed', 0)
total = done + pending + failed + (1 if s.get('current_batch') else 0)
print(f"  progress:   {done} done / {failed} failed / {pending} pending  (~{total} total)")
started = s.get('started_at')
if started:
    try:
        dt = datetime.fromisoformat(started.replace('Z','+00:00'))
        elapsed = (datetime.now(timezone.utc) - dt).total_seconds()
        h, m = int(elapsed // 3600), int((elapsed % 3600) // 60)
        print(f"  elapsed:    {h}h {m}m total")
    except Exception:
        pass
print(f"  paused:     {s.get('paused', False)}")
PY
  else
    echo "  (no state file — grinder not running)"
  fi

  echo ""
  echo "  Last 4 events:"
  echo "  ───────────────"
  if [ -f "$EVENTS" ]; then
    tail -4 "$EVENTS" | python3 -c "
import json, sys
for line in sys.stdin:
    try:
        e = json.loads(line)
    except:
        continue
    ts = e.get('ts','?')[-9:-1]   # HH:MM:SS
    batch = e.get('batch','?')
    event = e.get('event','?')
    extra = ''
    if 'findings_before' in e:
        before = e['findings_before']; after = e.get('findings_after', '?')
        fixed = e.get('files_fixed', '?')
        extra = f'  before={before} after={after} files_fixed={fixed}'
    print(f'  {ts}  {batch:12s} {event}{extra}')
"
  fi

  echo ""
  echo "  Live agent activity (last 3 actions):"
  echo "  ─────────────────────────────────────"
  if [ -f "$STREAM" ]; then
    python3 - "$STREAM" <<'PY' 2>/dev/null
import json, sys
path = sys.argv[1]
try:
    with open(path) as f:
        lines = f.readlines()
except FileNotFoundError:
    sys.exit(0)
found = []
for line in reversed(lines):
    try:
        ev = json.loads(line)
    except:
        continue
    if ev.get("type") == "assistant":
        for c in ev.get("message", {}).get("content", []):
            if c.get("type") == "tool_use":
                inp = c.get("input", {})
                cmd = inp.get("command") or inp.get("file_path") or str(inp)
                cmd = cmd[:80].replace('\n',' ')
                found.append(f"  TOOL {c['name']:8s}  {cmd}")
                break
            elif c.get("type") == "text" and c.get("text", "").strip():
                txt = c['text'][:80].replace('\n',' ')
                found.append(f"  TEXT             {txt}")
                break
    if len(found) >= 3:
        break
for f in reversed(found):
    print(f)
PY
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  Refreshing every 3s. Ctrl-C to exit."

  sleep 3
done
