#!/usr/bin/env bash
# grinder-static.sh — Static-analysis-pass-specific functions for grinder.sh
#
# Sourced by grinder.sh at startup. Provides the static-analysis pass
# logic: allowlist-based fix decision, never_touch_files exclusion,
# proposals.md accumulation, diff-based inline suppression rejection,
# and batch orchestration.
#
# Depends on: TOOLS_DIR, LIB_DIR, SCHEMA_DIR, PROJECT_DIR, GRINDER_DIR
# (session globals set by grinder.sh main())
#
# Also depends on grinder-mechanical.sh being sourced first (provides
# resolve_test_command, run_tests_for_project, _mechanical_revert_batch,
# _unique_batch_dirs, rerun_scanner, _grinder_warn_on_turns_exhaustion).
#
# Compatible with bash 3.2+ (macOS default).

# ---------------------------------------------------------------------------
# Globals (session-scoped, cached on first batch)
# ---------------------------------------------------------------------------

_STATIC_ALLOWLIST=""
_STATIC_NEVER_TOUCH=""
_STATIC_MANIFEST_LOADED=""

# ---------------------------------------------------------------------------
# _static_load_manifest() — Load allowlist and never_touch from manifest
# Reads: PROJECT_DIR, TOOLS_DIR
# Writes: _STATIC_ALLOWLIST, _STATIC_NEVER_TOUCH, _STATIC_MANIFEST_LOADED
# ---------------------------------------------------------------------------

_static_load_manifest() {
    if [[ "$_STATIC_MANIFEST_LOADED" == "true" ]]; then
        return 0
    fi

    local manifest_json=""
    manifest_json=$(python3 "$TOOLS_DIR/validate-manifest.py" --parse-grinder "$PROJECT_DIR/pipeline.yaml" 2>/dev/null) || true

    if [[ -z "$manifest_json" ]]; then
        echo "static: no manifest found -- all findings will be proposed" >&2
        _STATIC_ALLOWLIST=""
        _STATIC_NEVER_TOUCH=""
        _STATIC_MANIFEST_LOADED="true"
        return 0
    fi

    # Extract fix_rules_allowlist as newline-separated list
    _STATIC_ALLOWLIST=$(echo "$manifest_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for r in d.get('findings', {}).get('fix_rules_allowlist', []):
    print(r)
" 2>/dev/null) || _STATIC_ALLOWLIST=""

    # Extract never_touch_files as newline-separated list
    _STATIC_NEVER_TOUCH=$(echo "$manifest_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for p in d.get('findings', {}).get('never_touch_files', []):
    print(p)
" 2>/dev/null) || _STATIC_NEVER_TOUCH=""

    _STATIC_MANIFEST_LOADED="true"
}

# ---------------------------------------------------------------------------
# _static_match_allowlist(rule) — Check if rule is in fix_rules_allowlist
# Returns: 0 if match, 1 if no match
# ---------------------------------------------------------------------------

_static_match_allowlist() {
    local rule="$1"
    if [[ -z "$_STATIC_ALLOWLIST" ]]; then
        return 1
    fi
    echo "$_STATIC_ALLOWLIST" | grep -qxF "$rule"
}

# ---------------------------------------------------------------------------
# _static_match_never_touch(file) — Check if file matches never_touch_files
# Uses Python fnmatch for glob matching (REQ-2)
# Returns: 0 if match, 1 if no match
# ---------------------------------------------------------------------------

_static_match_never_touch() {
    local file="$1"
    if [[ -z "$_STATIC_NEVER_TOUCH" ]]; then
        return 1
    fi
    python3 -c "
import sys
from fnmatch import fnmatch
f = sys.argv[1]
patterns = sys.argv[2].strip().split('\n')
for p in patterns:
    p = p.strip()
    if p and fnmatch(f, p):
        sys.exit(0)
sys.exit(1)
" "$file" "$_STATIC_NEVER_TOUCH"
}

# ---------------------------------------------------------------------------
# _static_check_diff_suppressions() — Scan staged diff for suppressions
# Returns: 0 if clean, 1 if suppression found
# Reads: PROJECT_DIR
# ---------------------------------------------------------------------------

_static_check_diff_suppressions() {
    cd "$PROJECT_DIR" || return 1

    # Get added lines from staged diff
    local diff_added
    diff_added=$(git diff --cached --diff-filter=AM -U0 2>/dev/null | grep '^+' | grep -v '^+++' || true)

    # If no staged diff, check unstaged
    if [[ -z "$diff_added" ]]; then
        diff_added=$(git diff --diff-filter=AM -U0 2>/dev/null | grep '^+' | grep -v '^+++' || true)
    fi

    if [[ -z "$diff_added" ]]; then
        return 0
    fi

    # Check for suppression patterns on added lines
    local pattern='# noqa|// eslint-disable|# type: ignore|/\* istanbul ignore|# pragma: no cover|// @ts-ignore|// @ts-expect-error|# shellcheck disable='
    if echo "$diff_added" | grep -qE "$pattern"; then
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# _static_append_proposal(finding_json, batch_id) — Append to proposals.md
# Args: $1 = JSON object, $2 = batch ID
# Reads: PROJECT_DIR
# ---------------------------------------------------------------------------

_static_append_proposal() {
    local finding_json="$1"
    local batch_id="$2"
    local proposals_file="$PROJECT_DIR/docs/grinder/proposals.md"

    # Create file with header if absent
    if [[ ! -f "$proposals_file" ]]; then
        mkdir -p "$(dirname "$proposals_file")"
        printf '# Grinder Proposals\n\n' > "$proposals_file"
    fi

    # Destructure finding JSON
    local tool rule file line severity message
    tool=$(echo "$finding_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['tool'])")
    rule=$(echo "$finding_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['rule'])")
    file=$(echo "$finding_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['file'])")
    line=$(echo "$finding_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['line'])")
    severity=$(echo "$finding_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['severity'])")
    message=$(echo "$finding_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['message'])")

    local date_iso
    date_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    cat >> "$proposals_file" << EOF
### $rule — $file:$line
- **Tool:** $tool
- **Severity:** $severity
- **Message:** $message
- **Batch:** $batch_id
- **Date:** $date_iso

EOF
}

# ---------------------------------------------------------------------------
# _static_determine_primary_tool(findings_json) — Scanner with most findings
# Args: $1 = JSON array of findings
# Output: tool name string
# ---------------------------------------------------------------------------

_static_determine_primary_tool() {
    local findings_json="$1"
    echo "$findings_json" | python3 -c "
import json, sys
from collections import Counter
findings = json.load(sys.stdin)
if not findings:
    print('unknown')
    sys.exit(0)
counts = Counter(f.get('tool', 'unknown') for f in findings)
print(counts.most_common(1)[0][0])
"
}

# ---------------------------------------------------------------------------
# _static_build_prompt(fix_findings_json) — Build claude -p session prompt
# Args: $1 = JSON array of fixable findings
# Output: prompt string on stdout
# ---------------------------------------------------------------------------

_static_build_prompt() {
    local fix_json="$1"

    cat << 'PROMPT_HEADER'
Fix the following static-analysis findings. Each finding has been pre-approved
for automated fixing (rule is in the project's fix_rules_allowlist). Apply
targeted fixes only.

Constraints:
- Fix only the listed findings. Do not refactor surrounding code.
- Do not add `# noqa`, `# type: ignore`, `// eslint-disable`,
  `/* istanbul ignore */`, `# pragma: no cover`, `// @ts-ignore`,
  `// @ts-expect-error`, `# shellcheck disable=`, or any inline suppression.
- Do not modify files outside the batch file list.
- Do not add new dependencies.

Findings to fix:
PROMPT_HEADER

    echo "$fix_json"
}

# ---------------------------------------------------------------------------
# _static_partition_findings(files_json) — Partition via Python module
# Args: $1 = files_json array
# Sets: _STATIC_FIX_JSON, _STATIC_PROPOSE_JSON,
#       _STATIC_SKIP_COUNT, _STATIC_PROPOSE_COUNT, _STATIC_FIX_COUNT
# ---------------------------------------------------------------------------

_static_partition_findings() {
    local files_json="$1"

    # Collect all scanner output files
    local scanner_dir="$GRINDER_DIR/scanner-output"
    local all_findings="[]"
    if [[ -d "$scanner_dir" ]]; then
        for f in "$scanner_dir"/*.json; do
            [[ -f "$f" ]] || continue
            local scanner_findings
            scanner_findings=$(cat "$f" 2>/dev/null) || continue
            if [[ -n "$scanner_findings" && "$scanner_findings" != "[]" ]]; then
                all_findings=$(python3 -c "
import json, sys
a = json.loads(sys.argv[1])
b = json.loads(sys.argv[2])
print(json.dumps(a + b))
" "$all_findings" "$scanner_findings" 2>/dev/null) || true
            fi
        done
    fi

    local result
    result=$(python3 "$LIB_DIR/grinder-static-partition.py" \
        --files-json "$files_json" \
        --allowlist "$_STATIC_ALLOWLIST" \
        --never-touch "$_STATIC_NEVER_TOUCH" \
        --findings-json <(echo "$all_findings") 2>/dev/null) || true

    if [[ -z "$result" ]]; then
        _STATIC_FIX_JSON="[]"
        _STATIC_PROPOSE_JSON="[]"
        _STATIC_SKIP_COUNT=0
        _STATIC_PROPOSE_COUNT=0
        _STATIC_FIX_COUNT=0
        return 0
    fi

    _STATIC_FIX_JSON=$(echo "$result" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['fix']))")
    _STATIC_PROPOSE_JSON=$(echo "$result" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['propose']))")
    _STATIC_SKIP_COUNT=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['skip_count'])")
    _STATIC_PROPOSE_COUNT=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['propose_count'])")
    _STATIC_FIX_COUNT=$(echo "$result" | python3 -c "import json,sys; print(json.load(sys.stdin)['fix_count'])")
}

# ---------------------------------------------------------------------------
# execute_static_batch() — Main entry point for static-analysis batches
# Args: $1=batch_id, $2=pass_kind, $3=files_json, $4=estimated_turns
# Returns: 0 on success, 1 on failure
# Output: key=value lines on stdout for event enrichment
# ---------------------------------------------------------------------------

execute_static_batch() {
    local batch_id="$1"
    local _pass_kind="$2"
    local files_json="$3"
    local estimated_turns="$4"

    # Parse batch files into array
    local -a batch_files=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && batch_files+=("$f")
    done < <(echo "$files_json" | jq -r '.[]' 2>/dev/null)

    if [[ ${#batch_files[@]} -eq 0 ]]; then
        echo "static: batch $batch_id has no files" >&2
        return 1
    fi

    # Validate no path traversal
    for f in "${batch_files[@]}"; do
        if [[ "$f" == *".."* ]]; then
            echo "static: batch $batch_id rejected — path traversal in file: $f" >&2
            return 1
        fi
    done

    # Step 1: Load manifest (cached)
    _static_load_manifest

    # Step 2: Partition findings
    _static_partition_findings "$files_json"

    # Log skipped files
    if [[ "$_STATIC_SKIP_COUNT" -gt 0 ]]; then
        echo "static: skipped $_STATIC_SKIP_COUNT findings (never_touch_files)" >&2
    fi

    # Step 3: Write proposals for non-allowlisted findings
    if [[ "$_STATIC_PROPOSE_COUNT" -gt 0 ]]; then
        local num_proposals
        num_proposals=$(echo "$_STATIC_PROPOSE_JSON" | jq 'length' 2>/dev/null) || num_proposals=0
        for ((i=0; i<num_proposals; i++)); do
            local finding
            finding=$(echo "$_STATIC_PROPOSE_JSON" | jq ".[$i]" 2>/dev/null)
            _static_append_proposal "$finding" "$batch_id"
        done
    fi

    # Step 4: If no fixable findings, output metrics and return
    if [[ "$_STATIC_FIX_COUNT" -eq 0 ]]; then
        local total=$(( _STATIC_FIX_COUNT + _STATIC_PROPOSE_COUNT + _STATIC_SKIP_COUNT ))
        echo "findings_before=$total"
        echo "findings_after=$total"
        echo "files_fixed=0"
        echo "files_skipped=$_STATIC_SKIP_COUNT"
        echo "files_proposed=$_STATIC_PROPOSE_COUNT"
        return 0
    fi

    # Step 5: Record pre-batch untracked files
    local pre_untracked=""
    while IFS= read -r d; do
        [[ -z "$d" ]] && continue
        local dir_untracked
        dir_untracked=$(cd "$PROJECT_DIR" && git ls-files --others --exclude-standard "$d" 2>/dev/null || true)
        pre_untracked="$pre_untracked
$dir_untracked"
    done < <(_unique_batch_dirs "${batch_files[@]}")

    # Step 6: Pre-batch test snapshot
    resolve_test_command >/dev/null 2>&1
    local pre_test_exit=0
    local skip_test_verification=false
    run_tests_for_project || pre_test_exit=$?
    if [[ $pre_test_exit -ne 0 ]]; then
        echo "static: pre-batch tests already failing (exit $pre_test_exit) -- skipping test verification" >&2
        skip_test_verification=true
    fi

    # Step 7: Count pre-fix findings
    local pre_findings
    pre_findings=$(echo "$_STATIC_FIX_JSON" | jq 'length' 2>/dev/null) || pre_findings=0

    # Step 8: Determine primary tool
    local primary_tool
    primary_tool=$(_static_determine_primary_tool "$_STATIC_FIX_JSON")

    # Step 9: Build prompt and run claude -p session
    local prompt
    prompt=$(_static_build_prompt "$_STATIC_FIX_JSON")
    export EXTRA_SYSTEM_PROMPT="$prompt"
    export PHASE_TIMEOUT="${GRINDER_BATCH_TIMEOUT:-1800}"
    export MAX_TURNS_PHASE="$estimated_turns"

    local files_list
    files_list=$(printf '%s\n' "${batch_files[@]}")

    local batch_prompt="You are running a grinder batch (static-analysis pass, batch $batch_id).

Files to process:
$files_list

Fix the allowlisted static-analysis findings in these files."

    run_phase "$batch_prompt" "grinder-$batch_id" "$PROJECT_DIR" || true
    _grinder_warn_on_turns_exhaustion "$batch_id"

    # Step 10: Check inline suppressions in diff (REQ-5)
    if ! _static_check_diff_suppressions; then
        echo "static: batch $batch_id reverted -- inline suppression in fix" >&2
        _mechanical_revert_batch "${batch_files[@]}" "$pre_untracked"
        return 1
    fi

    # Step 11: Detect out-of-batch file changes (EC-8.2)
    cd "$PROJECT_DIR" || return 1
    local changed_files
    changed_files=$(git diff --name-only 2>/dev/null || true)
    if [[ -n "$changed_files" ]]; then
        while IFS= read -r cf; do
            [[ -z "$cf" ]] && continue
            local in_batch=false
            for bf in "${batch_files[@]}"; do
                if [[ "$cf" == "$bf" ]]; then
                    in_batch=true
                    break
                fi
            done
            if [[ "$in_batch" == "false" ]]; then
                echo "static: reverting out-of-batch change: $cf" >&2
                git checkout -- "$cf" 2>/dev/null || true
            fi
        done <<< "$changed_files"
    fi

    # Step 12: Re-scan verification (REQ-4)
    RERUN_FINDINGS_AFTER=0
    if ! rerun_scanner "$primary_tool" "$pre_findings" "$batch_id" "${batch_files[@]}"; then
        echo "static: batch $batch_id reverted -- allowlisted finding not resolved" >&2
        _mechanical_revert_batch "${batch_files[@]}" "$pre_untracked"
        return 1
    fi

    # Step 13: Post-batch test verification (REQ-6)
    if [[ "$skip_test_verification" == "false" ]]; then
        local post_test_exit=0
        run_tests_for_project || post_test_exit=$?
        if [[ $pre_test_exit -eq 0 && $post_test_exit -ne 0 ]]; then
            echo "static: batch $batch_id reverted -- test regression" >&2
            _mechanical_revert_batch "${batch_files[@]}" "$pre_untracked"
            return 1
        fi
    fi

    # Step 14: Check if anything changed
    cd "$PROJECT_DIR" || return 1
    local changed_count=0
    for f in "${batch_files[@]}"; do
        if ! git diff --quiet -- "$f" 2>/dev/null; then
            changed_count=$((changed_count + 1))
        fi
    done

    if [[ $changed_count -eq 0 ]]; then
        local total=$(( _STATIC_FIX_COUNT + _STATIC_PROPOSE_COUNT + _STATIC_SKIP_COUNT ))
        echo "findings_before=$total"
        echo "findings_after=${RERUN_FINDINGS_AFTER:-0}"
        echo "files_fixed=0"
        echo "files_skipped=$_STATIC_SKIP_COUNT"
        echo "files_proposed=$_STATIC_PROPOSE_COUNT"
        return 0
    fi

    # Step 15: Stage and commit (REQ-7)
    for f in "${batch_files[@]}"; do
        git add -- "$f" 2>/dev/null || true
    done

    local commit_msg="fix(grinder): pass-3-static / $primary_tool (batch $batch_id)"
    if ! git commit -m "$commit_msg" 2>/dev/null; then
        echo "static: batch $batch_id reverted -- pre-commit hook failure" >&2
        _mechanical_revert_batch "${batch_files[@]}" "$pre_untracked"
        return 1
    fi

    # Step 16: Output findings data
    local total=$(( _STATIC_FIX_COUNT + _STATIC_PROPOSE_COUNT + _STATIC_SKIP_COUNT ))
    echo "findings_before=$total"
    echo "findings_after=${RERUN_FINDINGS_AFTER:-0}"
    echo "files_fixed=$changed_count"
    echo "files_skipped=$_STATIC_SKIP_COUNT"
    echo "files_proposed=$_STATIC_PROPOSE_COUNT"
    return 0
}

# ---------------------------------------------------------------------------
# static_commit_proposals() — Commit proposals.md if modified (REQ-12)
# Reads: PROJECT_DIR
# ---------------------------------------------------------------------------

static_commit_proposals() {
    local proposals_file="$PROJECT_DIR/docs/grinder/proposals.md"
    if [[ ! -f "$proposals_file" ]]; then
        return 0
    fi

    cd "$PROJECT_DIR" || return 0

    # Check if proposals.md has uncommitted changes
    if git diff --quiet -- "docs/grinder/proposals.md" 2>/dev/null && \
       ! git ls-files --others --exclude-standard | grep -q "docs/grinder/proposals.md"; then
        return 0
    fi

    git add "docs/grinder/proposals.md" 2>/dev/null || true
    git commit -m "docs(grinder): pass-3-static proposals" 2>/dev/null || true
}
