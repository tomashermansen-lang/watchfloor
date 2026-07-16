#!/bin/bash
# explain-diff.sh — plain-language explanation for sync.sh diffs.
#
# For settings.json: routes to the heuristic Python parser (deterministic,
# no API call). For other files: calls gpt-4o-mini via OpenAI API with a
# Danish-language summary prompt.
#
# Why a separate model from Claude (the one writing the diffs): cross-LLM
# verification — a prompt-injection targeted at Claude's training is less
# likely to also bypass GPT, raising the bar for an attacker.
#
# NO CACHING. Every diff/file is re-classified on every run. Disk-cache
# would be a tampering vector: a compromised session could write fake
# "NEUTRAL" entries to ~/.cache/dotfiles-sync-explain/ before the user
# inspects, and the cache lookup would happily serve them. Trade-off is
# small (~$0.001-0.008 per sync.sh diff invocation).
#
# Usage:
#   explain_path <repo_path> <home_path> <label>
#   explain_dir  <repo_dir>  <home_dir>  <label>

set -uo pipefail

EXPLAIN_DIFF_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SETTINGS_HEURISTIC="$EXPLAIN_DIFF_LIB_DIR/explain-settings-diff.py"
OPENAI_KEY_LIB="$EXPLAIN_DIFF_LIB_DIR/openai-key.sh"
EXPLAIN_PROMPT_FILE="$EXPLAIN_DIFF_LIB_DIR/explain-prompt.md"
EXPLAIN_FORMATTER="$EXPLAIN_DIFF_LIB_DIR/explain-format.py"
EXPLAIN_MODEL="${EXPLAIN_MODEL:-gpt-4o-mini}"
# Max tokens for the LLM response. Allows DANGER explanations to use the
# full 3-5 sentence detail-level demanded by the prompt.
EXPLAIN_MAX_TOKENS="${EXPLAIN_MAX_TOKENS:-500}"
# Max bytes of source content to send (NEW/DELETED files). 8000 ≈ 2000
# tokens — enough for most config files; longer files are truncated with
# a marker so the LLM knows.
EXPLAIN_MAX_INPUT_BYTES="${EXPLAIN_MAX_INPUT_BYTES:-8000}"

# Trust-chain files: changes here would invalidate LLM-classification by design,
# so when one of these appears in a diff we skip the LLM and emit a CRITICAL
# raw-diff fallback. Hook scripts and other tools are NOT in this list — their
# changes can still be safely classified by an unmodified explainer.
EXPLAIN_TRUST_CHAIN=(
    "claude/tools/lib/explain-prompt.md"
    "claude/tools/lib/explain-diff.sh"
    "claude/tools/lib/explain-settings-diff.py"
)

# Internal: call OpenAI for a plain-language explanation.
# kind: MODIFIED | NEW | DELETED  (controls how content is framed)
# content: unified diff (for MODIFIED) or full file content (for NEW/DELETED)
_explain_via_llm() {
    local kind="$1" content="$2" file_label="$3"
    if ! source "$OPENAI_KEY_LIB" 2>/dev/null || ! load_openai_key 2>/dev/null; then
        echo "  (LLM-forklaring utilgængelig — kør 'bash claude/tools/lib/openai-key.sh' for setup-besked)"
        return
    fi

    # Load system prompt from external file so it can be modified independently
    # of the orchestrator script. If the file is missing or empty, the LLM call
    # is unsafe and we abort.
    if [[ ! -f "$EXPLAIN_PROMPT_FILE" ]] || [[ ! -s "$EXPLAIN_PROMPT_FILE" ]]; then
        echo "  ⚠ Prompt-fil mangler eller er tom: $EXPLAIN_PROMPT_FILE"
        echo "  (LLM-forklaring afbrudt for at undgå udokumenteret klassifikation)"
        return
    fi

    # Build JSON payload via python3 (safe quoting + UTF-8 handling)
    local payload
    payload=$(EXPLAIN_KIND="$kind" \
              EXPLAIN_FILE="$file_label" \
              EXPLAIN_CONTENT="$content" \
              EXPLAIN_MODEL="$EXPLAIN_MODEL" \
              EXPLAIN_MAX_TOKENS="$EXPLAIN_MAX_TOKENS" \
              EXPLAIN_MAX_BYTES="$EXPLAIN_MAX_INPUT_BYTES" \
              EXPLAIN_PROMPT_PATH="$EXPLAIN_PROMPT_FILE" python3 - <<'PY'
import json, os
kind = os.environ["EXPLAIN_KIND"]
fn = os.environ["EXPLAIN_FILE"]
raw = os.environ["EXPLAIN_CONTENT"]
model = os.environ["EXPLAIN_MODEL"]
max_tokens = int(os.environ["EXPLAIN_MAX_TOKENS"])
max_bytes = int(os.environ["EXPLAIN_MAX_BYTES"])

with open(os.environ["EXPLAIN_PROMPT_PATH"], encoding="utf-8") as f:
    system = f.read()

# Truncate with a marker so the LLM knows context was cut
if len(raw) > max_bytes:
    truncated_marker = f"\n\n[... afkortet — {len(raw) - max_bytes} bytes mere ikke vist ...]"
    raw = raw[:max_bytes] + truncated_marker

if kind == "MODIFIED":
    user = f"Ændringstype: MODIFIED (en eksisterende fil bliver opdateret)\nFilsti: {fn}\n\nUnified diff:\n{raw}"
elif kind == "NEW":
    user = f"Ændringstype: NEW (ny fil bliver oprettet ved deploy — analyser hvad denne fil GØR når den kører/læses)\nFilsti: {fn}\n\nFuldt indhold:\n{raw}"
elif kind == "DELETED":
    user = f"Ændringstype: DELETED (denne fil bliver fjernet ved deploy — analyser hvad der MISTES når den fjernes)\nFilsti: {fn}\n\nNuværende indhold (vil blive slettet):\n{raw}"
else:
    user = f"Filsti: {fn}\n\nIndhold:\n{raw}"

print(json.dumps({
    "model": model,
    "messages": [
        {"role": "system", "content": system},
        {"role": "user", "content": user},
    ],
    "max_tokens": max_tokens,
    "temperature": 0,
}))
PY
)

    local response
    response=$(curl -sS -X POST https://api.openai.com/v1/chat/completions \
        -H "Authorization: Bearer $OPENAI_API_KEY" \
        -H "Content-Type: application/json" \
        --data "$payload" \
        --max-time 60 2>/dev/null)

    if [[ -z "$response" ]]; then
        echo "  (LLM-forklaring utilgængelig — netværksfejl eller timeout)"
        return
    fi

    # Extract content
    local llm_text
    llm_text=$(echo "$response" | python3 -c "
import json, sys
try:
    r = json.load(sys.stdin)
    if 'error' in r:
        print(f\"(API-fejl: {r['error'].get('message', 'ukendt')})\")
    else:
        print(r['choices'][0]['message']['content'].strip())
except Exception as e:
    print(f'(parse-fejl: {e})')
")
    # Pass through deterministic formatter so output shape is canonical
    # regardless of LLM compliance with the prompt's strict format.
    local normalised
    normalised=$(printf '%s\n' "$llm_text" | python3 "$EXPLAIN_FORMATTER" 2>/dev/null || printf '%s\n' "$llm_text")
    # Indent for readable bullet output
    printf '%s\n' "$normalised" | sed 's/^/  /'
}

# Internal: is this label a trust-chain file (prompt, orchestrator, heuristic)?
_explain_is_trust_chain() {
    local label="$1"
    for trusted in "${EXPLAIN_TRUST_CHAIN[@]}"; do
        if [[ "$label" == "$trusted" ]] || [[ "$label" == */"$trusted" ]]; then
            return 0
        fi
    done
    return 1
}

# Internal: emit CRITICAL banner + raw content for trust-chain files. Used for
# both MODIFIED (raw diff) and NEW/DELETED (raw file content).
_explain_trust_chain_critical() {
    local label="$1" raw="$2"
    cat <<EOF
⚠⚠⚠ CRITICAL: trust-chain file modification detected.
    File: $label
    LLM-explanation IS DISABLED for this file because the explainer
    cannot reliably classify changes to its own trust chain (prompt,
    orchestrator, or heuristic). A modified explainer could gaslight
    you about its own modification.
    Manual review required. Raw content:
EOF
    printf '%s\n' "$raw" | head -200 | sed 's/^/    /'
}

# Public: explain a single file diff (MODIFIED case).
# explain_path <repo_path> <home_path> <label>
# Internal: list pending commits on a file since the version that matches
# the deployed copy in $home_path. Walks up to 100 recent commits touching
# the file, hashes the file at each version, and finds the SHA where the
# tree entry matches home's blob hash. Then prints commits since that SHA.
#
# Output format (only when ≥1 pending commit found):
#   Pending commits (N on this file since deployed version):
#     <sha>  <commit subject>
#     ...
#
# Silent when:
#   - home file's blob hash doesn't match any of the last 100 commits (very
#     stale deploy or operator made local edits) → would be misleading
#   - file is not in a git repo
#   - only 1 pending commit (no enumeration value over LLM summary)
_explain_pending_commits() {
    local repo_path="$1" home_path="$2"

    [[ -f "$home_path" ]] || return 0
    [[ -f "$repo_path" ]] || return 0

    local home_hash
    home_hash=$(git hash-object "$home_path" 2>/dev/null) || return 0

    local repo_dir
    repo_dir=$(cd "$(dirname "$repo_path")" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null) || return 0
    local rel_path="${repo_path#"$repo_dir"/}"

    local deployed_sha=""
    local sha
    while IFS= read -r sha; do
        [[ -z "$sha" ]] && continue
        local blob_at_sha
        blob_at_sha=$(cd "$repo_dir" && git ls-tree "$sha" -- "$rel_path" 2>/dev/null | awk '{print $3}')
        if [[ "$blob_at_sha" == "$home_hash" ]]; then
            deployed_sha="$sha"
            break
        fi
    done < <(cd "$repo_dir" && git log --pretty=format:%H -100 -- "$rel_path" 2>/dev/null; echo "")

    [[ -z "$deployed_sha" ]] && return 0

    local pending
    pending=$(cd "$repo_dir" && git log --oneline "${deployed_sha}..HEAD" -- "$rel_path" 2>/dev/null)
    [[ -z "$pending" ]] && return 0

    local count
    count=$(printf '%s\n' "$pending" | wc -l | tr -d ' ')
    [[ "$count" -lt 2 ]] && return 0

    printf 'Pending commits (%s on this file since deployed version):\n' "$count"
    printf '%s\n' "$pending" | sed 's/^/  /'
}

explain_path() {
    local repo_path="$1" home_path="$2" label="$3"

    if [[ ! -f "$home_path" ]]; then
        echo "  (ny fil — vil blive oprettet ved restore)"
        return
    fi

    if diff -q "$repo_path" "$home_path" &>/dev/null; then
        return  # no diff
    fi

    # CRITICAL: trust-chain files (the explainer's own prompt + orchestrator +
    # heuristic). LLM-classification cannot be trusted when the source-of-trust
    # itself is the thing being modified. Show raw diff + warning instead.
    if _explain_is_trust_chain "$label"; then
        local raw
        raw=$(diff -u "$home_path" "$repo_path" 2>/dev/null || true)
        _explain_trust_chain_critical "$label" "$raw"
        return
    fi

    # Special-case: settings.json → use heuristic, no LLM call.
    case "$label" in
        *settings.json*)
            python3 "$SETTINGS_HEURISTIC" "$home_path" "$repo_path"
            return
            ;;
    esac

    # Show pending commits BEFORE the LLM summary so the operator sees the
    # full enumeration of logical changes (LLM collapses multiple commits on
    # one file to a single one-liner).
    local pending_commits
    pending_commits=$(_explain_pending_commits "$repo_path" "$home_path")
    if [[ -n "$pending_commits" ]]; then
        printf '%s\n' "$pending_commits"
    fi

    # Generic MODIFIED: produce diff, send to LLM
    local diff_content
    diff_content=$(diff -u "$home_path" "$repo_path" 2>/dev/null || true)

    local explanation
    explanation=$(_explain_via_llm "MODIFIED" "$diff_content" "$label")
    printf 'LLM:\n%s\n' "$explanation"
}

# Public: explain a NEW file (only exists in source, will be created on deploy).
# explain_new_file <repo_path> <label>
explain_new_file() {
    local repo_path="$1" label="$2"

    if [[ ! -f "$repo_path" ]]; then
        echo "  (kunne ikke læse $repo_path)"
        return
    fi

    if _explain_is_trust_chain "$label"; then
        local raw
        raw=$(cat "$repo_path" 2>/dev/null || echo "")
        _explain_trust_chain_critical "$label" "$raw"
        return
    fi

    case "$label" in
        *settings.json*)
            # New settings.json without prior version → diff against empty {}
            local tmp_empty
            tmp_empty=$(mktemp -t empty-settings.XXXXXX)
            echo '{}' > "$tmp_empty"
            python3 "$SETTINGS_HEURISTIC" "$tmp_empty" "$repo_path"
            rm -f "$tmp_empty"
            return
            ;;
    esac

    local content
    content=$(cat "$repo_path" 2>/dev/null || echo "")

    local explanation
    explanation=$(_explain_via_llm "NEW" "$content" "$label")
    printf 'LLM:\n%s\n' "$explanation"
}

# Public: explain a DELETED file (only exists in deployed home, will be removed).
# explain_deleted_file <home_path> <label>
explain_deleted_file() {
    local home_path="$1" label="$2"

    if [[ ! -f "$home_path" ]]; then
        echo "  (kunne ikke læse $home_path)"
        return
    fi

    if _explain_is_trust_chain "$label"; then
        local raw
        raw=$(cat "$home_path" 2>/dev/null || echo "")
        _explain_trust_chain_critical "$label" "$raw"
        return
    fi

    local content
    content=$(cat "$home_path" 2>/dev/null || echo "")

    local explanation
    explanation=$(_explain_via_llm "DELETED" "$content" "$label")
    printf 'LLM:\n%s\n' "$explanation"
}

# Public: explain a directory diff (summary of changed files within)
# explain_dir <repo_dir> <home_dir> <label>
explain_dir() {
    local repo_dir="$1" home_dir="$2" label="$3"

    if [[ ! -d "$home_dir" ]]; then
        echo "  (ny mappe — vil blive oprettet ved restore)"
        return
    fi

    # List of files that differ. `|| true` masks diff's exit-1 (dirs differ)
    # so set -euo pipefail in the calling shell doesn't silently kill us.
    # Excludes mirror sync.sh copy_dir's rsync --exclude list — these files
    # never deploy, so showing them in diff is misleading noise.
    local diffs
    diffs=$(diff -rq \
        -x '__pycache__' -x '*.pyc' -x '*.pyo' \
        -x '.pytest_cache' -x '.mypy_cache' -x '.ruff_cache' \
        -x '.DS_Store' \
        "$repo_dir" "$home_dir" 2>/dev/null | head -20 || true)
    if [[ -z "$diffs" ]]; then
        return  # no diff
    fi

    # ANSI sequences for prettier per-file headers. Bold marker + dim separator.
    local _bold='\033[1m' _dim='\033[2m' _nc='\033[0m'

    # For each changed file in the dir, recurse
    local file_index=0
    while IFS= read -r line; do
        # Visual separator between files (skip before first)
        if (( file_index > 0 )); then
            printf '  %s────────────────────────────────────%s\n' "$_dim" "$_nc"
        fi
        file_index=$((file_index + 1))

        # Format: "Files <a> and <b> differ" or "Only in <dir>: <file>"
        case "$line" in
            "Files "*" differ")
                local a b
                a=$(echo "$line" | sed -E 's/^Files (.*) and (.*) differ$/\1/')
                b=$(echo "$line" | sed -E 's/^Files (.*) and (.*) differ$/\2/')
                local rel="${b#"$home_dir"/}"
                printf "  ${_bold}MODIFIED${_nc}  %s\n" "$rel"
                explain_path "$a" "$b" "$label/$rel" | sed 's/^/    /'
                ;;
            "Only in $repo_dir"*)
                local raw_path rel
                raw_path=$(echo "$line" | sed -E "s|^Only in (.*): (.*)$|\1/\2|")
                rel="${raw_path#"$repo_dir"/}"
                printf "  ${_bold}NEW${_nc}       %s ${_dim}(vil blive oprettet)${_nc}\n" "$rel"
                explain_new_file "$raw_path" "$label/$rel" | sed 's/^/    /'
                ;;
            "Only in $home_dir"*)
                local raw_path rel
                raw_path=$(echo "$line" | sed -E "s|^Only in (.*): (.*)$|\1/\2|")
                rel="${raw_path#"$home_dir"/}"
                printf "  ${_bold}DELETE${_nc}    %s ${_dim}(vil blive slettet)${_nc}\n" "$rel"
                explain_deleted_file "$raw_path" "$label/$rel" | sed 's/^/    /'
                ;;
        esac
    done <<< "$diffs"
}
