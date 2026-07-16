#!/usr/bin/env bash
# hooks/report-status.sh — Claude Code async hook
# Appends one JSONL line per event to data/sessions.jsonl
# Exits 0 on ALL errors (R18: never block Claude Code)

# Resolve data directory (overridable for tests)
DATA_DIR="${DASHBOARD_DATA_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/data}"
JSONL="$DATA_DIR/sessions.jsonl"

# Require jq
command -v jq >/dev/null 2>&1 || exit 0

# Read stdin
input=$(cat) || exit 0
[ -z "$input" ] && exit 0

# Extract all fields via single jq call (unit separator \x1f for robust parsing)
sep=$'\x1f'
fields=$(echo "$input" | jq -r '
  [
    (.session_id // ""),
    (.cwd // ""),
    (.hook_event_name // ""),
    (.notification_type // .tool_name // ""),
    (.message // .task_subject // .last_assistant_message // (.tool_input | if type == "object" then tostring else . end) // ""),
    (.tool_use_id // ""),
    (.model // ""),
    (.source // ""),
    (.reason // ""),
    (.agent_type // ""),
    (.agent_id // ""),
    (.error // ""),
    (if .is_interrupt == true then "true" elif .is_interrupt == false then "false" else "" end),
    (if (.tool_input | type) == "object" then .tool_input.file_path // "" else "" end),
    (.task_subject // ""),
    (.task_id // ""),
    (.permission_mode // "")
  ] | join("\u001f")
' 2>/dev/null) || exit 0
[ -z "$fields" ] && exit 0

IFS="$sep" read -r sid cwd event type msg tuid model src rsn \
  atype aid err intr fp tsub tid pmode <<< "$fields"

# Validate session_id: alphanumeric, hyphens, underscores only
[[ "$sid" =~ ^[a-zA-Z0-9_-]+$ ]] || exit 0

# Validate cwd: must exist and be under $HOME
[ -d "$cwd" ] || exit 0
case "$cwd" in
  "$HOME"/*) ;; # valid
  "$HOME") ;;   # valid (home itself)
  *) exit 0 ;;  # reject
esac
# Reject path traversal
case "$cwd" in
  *..* ) exit 0 ;;
esac

# Validate event name: known events only (H1: added PostToolUseFailure)
case "$event" in
  Notification|Stop|TaskCompleted|SubagentStop|SubagentStart|PermissionRequest|PreToolUse|PostToolUse|PostToolUseFailure|UserPromptSubmit|SessionStart|SessionEnd) ;;
  *) exit 0 ;;
esac

# Get branch name from cwd
branch=$(git -C "$cwd" branch --show-current 2>/dev/null) || branch="unknown"
# Validate branch: no shell metacharacters
[[ "$branch" =~ ^[a-zA-Z0-9_./-]+$ ]] || branch="unknown"

# Validate type: alphanumeric and underscores only (or empty)
if [ -n "$type" ]; then
  [[ "$type" =~ ^[a-zA-Z0-9_]+$ ]] || type=""
fi

# ── Validate new fields (H12) ──

# tuid, aid: alphanumeric, hyphens, underscores only
if [ -n "$tuid" ]; then
  [[ "$tuid" =~ ^[a-zA-Z0-9_-]+$ ]] || tuid=""
fi
if [ -n "$aid" ]; then
  [[ "$aid" =~ ^[a-zA-Z0-9_-]+$ ]] || aid=""
fi

# model, src, rsn: alphanumeric, hyphens, dots only
if [ -n "$model" ]; then
  [[ "$model" =~ ^[a-zA-Z0-9._-]+$ ]] || model=""
fi
if [ -n "$src" ]; then
  [[ "$src" =~ ^[a-zA-Z0-9._-]+$ ]] || src=""
fi
if [ -n "$rsn" ]; then
  [[ "$rsn" =~ ^[a-zA-Z0-9._-]+$ ]] || rsn=""
fi

# atype: alphanumeric, underscores, hyphens only
if [ -n "$atype" ]; then
  [[ "$atype" =~ ^[a-zA-Z0-9_-]+$ ]] || atype=""
fi

# err: strip control characters, truncate to 100 chars
if [ -n "$err" ]; then
  err=$(printf '%s' "$err" | tr -d '\000-\037\177' | head -c 100)
fi

# fp: must be under $HOME, no path traversal (..), truncate to 120 chars
if [ -n "$fp" ]; then
  case "$fp" in
    *..* ) fp="" ;;
  esac
fi
if [ -n "$fp" ]; then
  case "$fp" in
    "$HOME"/*) ;; # valid
    *) fp="" ;;   # reject paths not under $HOME
  esac
fi
if [ -n "$fp" ] && [ ${#fp} -gt 120 ]; then
  # Truncate from left, preserving filename
  fp="...${fp: -117}"
fi

# intr: must be literal true or false
if [ -n "$intr" ]; then
  case "$intr" in
    true|false) ;;
    *) intr="" ;;
  esac
fi

# tsub, tid: alphanumeric, hyphens, underscores, spaces only; truncate to 100
if [ -n "$tsub" ]; then
  [[ "$tsub" =~ ^[a-zA-Z0-9\ _-]+$ ]] || tsub=""
  tsub=$(printf '%s' "$tsub" | head -c 100)
fi
if [ -n "$tid" ]; then
  [[ "$tid" =~ ^[a-zA-Z0-9\ _-]+$ ]] || tid=""
  tid=$(printf '%s' "$tid" | head -c 100)
fi

# pmode: must be one of known values
if [ -n "$pmode" ]; then
  case "$pmode" in
    default|plan|acceptEdits|dontAsk|bypassPermissions) ;;
    *) pmode="" ;;
  esac
fi

# ── Tiered msg truncation (H10) ──
# Different msg limits based on event type to fit within 512-byte budget

msg_limit=200
case "$event" in
  SessionEnd|PermissionRequest)
    msg_limit=170 ;;
  SessionStart|SubagentStart|SubagentStop)
    msg_limit=130 ;;
  PostToolUseFailure)
    msg_limit=60 ;;
  PreToolUse|PostToolUse)
    # Reduced limit when fp is present
    if [ -n "$fp" ]; then
      msg_limit=60
    fi ;;
  TaskCompleted)
    # msg is redundant (tsub carries the content)
    msg_limit=0 ;;
esac

if [ "$msg_limit" -eq 0 ]; then
  msg=""
else
  msg=$(printf '%s' "$msg" | head -c "$msg_limit" | tr -d '\000-\037\177')
fi

# Generate timestamp
ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# Ensure data directory exists
mkdir -p "$DATA_DIR" 2>/dev/null || exit 0
chmod 700 "$DATA_DIR" 2>/dev/null

# Check sessions.jsonl is not a symlink (E7)
if [ -L "$JSONL" ]; then
  exit 0
fi

# Rotate at 1MB (R25)
if [ -f "$JSONL" ]; then
  size=$(wc -c < "$JSONL" 2>/dev/null | tr -d ' ')
  if [ "${size:-0}" -gt 1048576 ]; then
    mv -f "$JSONL" "$JSONL.1" 2>/dev/null || true
  fi
fi

# ── Construct JSONL line via jq with conditional fields (H10) ──

# Build jq args and expression based on event type
jq_args=(--arg sid "$sid" --arg cwd "$cwd" --arg branch "$branch"
  --arg event "$event" --arg type "$type" --arg msg "$msg" --arg ts "$ts")
jq_expr='{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts}'

# Add event-specific fields conditionally
case "$event" in
  PreToolUse|PostToolUse)
    if [ -n "$tuid" ]; then
      jq_args+=(--arg tuid "$tuid")
      jq_expr='{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts,tuid:$tuid}'
    fi
    if [ -n "$fp" ]; then
      jq_args+=(--arg fp "$fp")
      if [ -n "$tuid" ]; then
        jq_expr='{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts,tuid:$tuid,fp:$fp}'
      else
        jq_expr='{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts,fp:$fp}'
      fi
    fi
    ;;
  PostToolUseFailure)
    if [ -n "$tuid" ]; then
      jq_args+=(--arg tuid "$tuid")
    fi
    if [ -n "$err" ]; then
      jq_args+=(--arg err "$err")
    fi
    if [ -n "$intr" ]; then
      jq_args+=(--arg intr "$intr")
    fi
    # Build expression with available fields
    local_expr='{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts'
    [ -n "$tuid" ] && local_expr="$local_expr,tuid:\$tuid"
    [ -n "$err" ] && local_expr="$local_expr,err:\$err"
    [ -n "$intr" ] && local_expr="$local_expr,intr:\$intr"
    local_expr="$local_expr}"
    jq_expr="$local_expr"
    ;;
  SessionStart)
    local_expr='{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts'
    if [ -n "$model" ]; then
      jq_args+=(--arg model "$model")
      local_expr="$local_expr,model:\$model"
    fi
    if [ -n "$src" ]; then
      jq_args+=(--arg src "$src")
      local_expr="$local_expr,src:\$src"
    fi
    if [ -n "$pmode" ]; then
      jq_args+=(--arg pmode "$pmode")
      local_expr="$local_expr,pmode:\$pmode"
    fi
    local_expr="$local_expr}"
    jq_expr="$local_expr"
    ;;
  SessionEnd)
    if [ -n "$rsn" ]; then
      jq_args+=(--arg rsn "$rsn")
      jq_expr='{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts,rsn:$rsn}'
    fi
    ;;
  SubagentStart|SubagentStop)
    local_expr='{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts'
    if [ -n "$atype" ]; then
      jq_args+=(--arg atype "$atype")
      local_expr="$local_expr,atype:\$atype"
    fi
    if [ -n "$aid" ]; then
      jq_args+=(--arg aid "$aid")
      local_expr="$local_expr,aid:\$aid"
    fi
    local_expr="$local_expr}"
    jq_expr="$local_expr"
    ;;
  TaskCompleted)
    local_expr='{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts'
    if [ -n "$tsub" ]; then
      jq_args+=(--arg tsub "$tsub")
      local_expr="$local_expr,tsub:\$tsub"
    fi
    if [ -n "$tid" ]; then
      jq_args+=(--arg tid "$tid")
      local_expr="$local_expr,tid:\$tid"
    fi
    local_expr="$local_expr}"
    jq_expr="$local_expr"
    ;;
  PermissionRequest)
    if [ -n "$pmode" ]; then
      jq_args+=(--arg pmode "$pmode")
      jq_expr='{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts,pmode:$pmode}'
    fi
    ;;
esac

line=$(jq -n -c "${jq_args[@]}" "$jq_expr") || exit 0

# ── Field-dropping fallback (H10 defense in depth) ──
# If line > 512 bytes, drop fields in order: msg, fp, err

if [ ${#line} -gt 512 ]; then
  # Rebuild with msg=""
  msg=""
  jq_args=()
  case "$event" in
    PostToolUseFailure)
      jq_args=(--arg sid "$sid" --arg cwd "$cwd" --arg branch "$branch"
        --arg event "$event" --arg type "$type" --arg msg "" --arg ts "$ts")
      local_expr='{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts'
      [ -n "$tuid" ] && { jq_args+=(--arg tuid "$tuid"); local_expr="$local_expr,tuid:\$tuid"; }
      [ -n "$err" ] && { jq_args+=(--arg err "$err"); local_expr="$local_expr,err:\$err"; }
      [ -n "$intr" ] && { jq_args+=(--arg intr "$intr"); local_expr="$local_expr,intr:\$intr"; }
      local_expr="$local_expr}"
      line=$(jq -n -c "${jq_args[@]}" "$local_expr") || exit 0
      ;;
    PreToolUse|PostToolUse)
      jq_args=(--arg sid "$sid" --arg cwd "$cwd" --arg branch "$branch"
        --arg event "$event" --arg type "$type" --arg msg "" --arg ts "$ts")
      local_expr='{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts'
      [ -n "$tuid" ] && { jq_args+=(--arg tuid "$tuid"); local_expr="$local_expr,tuid:\$tuid"; }
      [ -n "$fp" ] && { jq_args+=(--arg fp "$fp"); local_expr="$local_expr,fp:\$fp"; }
      local_expr="$local_expr}"
      line=$(jq -n -c "${jq_args[@]}" "$local_expr") || exit 0
      ;;
    *)
      # For other events, rebuild with msg=""
      jq_args=(--arg sid "$sid" --arg cwd "$cwd" --arg branch "$branch"
        --arg event "$event" --arg type "$type" --arg msg "" --arg ts "$ts")
      line=$(jq -n -c "${jq_args[@]}" '{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts}') || exit 0
      ;;
  esac
fi

# Drop fp if still over 512
if [ ${#line} -gt 512 ]; then
  fp=""
  case "$event" in
    PreToolUse|PostToolUse)
      jq_args=(--arg sid "$sid" --arg cwd "$cwd" --arg branch "$branch"
        --arg event "$event" --arg type "$type" --arg msg "" --arg ts "$ts")
      local_expr='{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts'
      [ -n "$tuid" ] && { jq_args+=(--arg tuid "$tuid"); local_expr="$local_expr,tuid:\$tuid"; }
      local_expr="$local_expr}"
      line=$(jq -n -c "${jq_args[@]}" "$local_expr") || exit 0
      ;;
  esac
fi

# Drop err if still over 512
if [ ${#line} -gt 512 ]; then
  err=""
  case "$event" in
    PostToolUseFailure)
      jq_args=(--arg sid "$sid" --arg cwd "$cwd" --arg branch "$branch"
        --arg event "$event" --arg type "$type" --arg msg "" --arg ts "$ts")
      local_expr='{sid:$sid,cwd:$cwd,branch:$branch,event:$event,type:$type,msg:$msg,ts:$ts'
      [ -n "$tuid" ] && { jq_args+=(--arg tuid "$tuid"); local_expr="$local_expr,tuid:\$tuid"; }
      [ -n "$intr" ] && { jq_args+=(--arg intr "$intr"); local_expr="$local_expr,intr:\$intr"; }
      local_expr="$local_expr}"
      line=$(jq -n -c "${jq_args[@]}" "$local_expr") || exit 0
      ;;
  esac
fi

# Append atomically (O_APPEND, < 512 bytes)
echo "$line" >> "$JSONL" 2>/dev/null || exit 0

# Set file permissions (R17)
chmod 600 "$JSONL" 2>/dev/null

exit 0
