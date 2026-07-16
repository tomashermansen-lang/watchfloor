#!/usr/bin/env bash
# grinder-cve.sh — CVE-pass-specific functions for grinder.sh
#
# Sourced by grinder.sh at startup. Provides the CVE pass logic:
# severity-gated scanning, minor/patch auto-upgrade, major-bump deferral,
# exclude_deps/never_auto_upgrade filtering, cve-review.md output,
# and per-package test-gated commits.
#
# Depends on: TOOLS_DIR, LIB_DIR, SCHEMA_DIR, PROJECT_DIR, GRINDER_DIR
# (session globals set by grinder.sh main())
#
# Also depends on grinder-mechanical.sh being sourced first (provides
# resolve_test_command, run_tests_for_project, _mechanical_revert_batch).
#
# Compatible with bash 3.2+ (macOS default).

# ---------------------------------------------------------------------------
# Globals (session-scoped, cached on first batch)
# ---------------------------------------------------------------------------

_CVE_SEVERITY_GATE=""
_CVE_SUGGEST_GATE=""
_CVE_EXCLUDE_DEPS_JSON="[]"
_CVE_NEVER_AUTO_UPGRADE_JSON="[]"
_CVE_MANIFEST_LOADED=""

# ---------------------------------------------------------------------------
# _cve_load_manifest() — Load dependencies config from manifest
# Reads: PROJECT_DIR, TOOLS_DIR
# Writes: _CVE_* globals
# ---------------------------------------------------------------------------

_cve_load_manifest() {
    if [[ "$_CVE_MANIFEST_LOADED" == "true" ]]; then
        return 0
    fi

    local manifest_json=""
    manifest_json=$(python3 "$TOOLS_DIR/validate-manifest.py" --parse-grinder "$PROJECT_DIR/CLAUDE.md" 2>/dev/null) || true

    if [[ -z "$manifest_json" ]]; then
        echo "cve: no manifest found -- using defaults" >&2
        _CVE_SEVERITY_GATE="HIGH"
        _CVE_SUGGEST_GATE="MEDIUM"
        _CVE_EXCLUDE_DEPS_JSON="[]"
        _CVE_NEVER_AUTO_UPGRADE_JSON="[]"
        _CVE_MANIFEST_LOADED="true"
        return 0
    fi

    _CVE_SEVERITY_GATE=$(echo "$manifest_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('dependencies', {}).get('severity_gate', 'HIGH'))
" 2>/dev/null) || _CVE_SEVERITY_GATE="HIGH"

    _CVE_SUGGEST_GATE=$(echo "$manifest_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(d.get('dependencies', {}).get('suggest_only_gate', 'MEDIUM'))
" 2>/dev/null) || _CVE_SUGGEST_GATE="MEDIUM"

    _CVE_EXCLUDE_DEPS_JSON=$(echo "$manifest_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(json.dumps(d.get('dependencies', {}).get('exclude_deps', [])))
" 2>/dev/null) || _CVE_EXCLUDE_DEPS_JSON="[]"

    _CVE_NEVER_AUTO_UPGRADE_JSON=$(echo "$manifest_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
print(json.dumps(d.get('dependencies', {}).get('never_auto_upgrade', [])))
" 2>/dev/null) || _CVE_NEVER_AUTO_UPGRADE_JSON="[]"

    _CVE_MANIFEST_LOADED="true"
}

# ---------------------------------------------------------------------------
# _cve_detect_ecosystem(finding_json) — Determine Python vs Node
# Args: $1 = JSON object (finding)
# Output: "python" or "node"
# ---------------------------------------------------------------------------

_cve_detect_ecosystem() {
    local finding_json="$1"
    local tool
    tool=$(echo "$finding_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool',''))")
    case "$tool" in
        pip-audit) echo "python" ;;
        npm-audit) echo "node" ;;
        *) echo "unknown" ;;
    esac
}

# ---------------------------------------------------------------------------
# _cve_apply_upgrade(package, from_ver, to_ver, ecosystem) — Run upgrade
# Returns: 0 on success, 1 on failure
# ---------------------------------------------------------------------------

_cve_apply_upgrade() {
    local package="$1"
    # $2 = from_ver (unused — upgrade targets $to_ver directly)
    local to_ver="$3"
    local ecosystem="$4"

    cd "$PROJECT_DIR" || return 1

    if [[ "$ecosystem" == "python" ]]; then
        # Detect Python package manager
        if [[ -f "uv.lock" ]] || { command -v uv >/dev/null 2>&1 && [[ -f "pyproject.toml" ]]; }; then
            uv add "$package==$to_ver" 2>/dev/null || pip install "$package==$to_ver" 2>/dev/null || return 1
        elif [[ -f "requirements.txt" ]]; then
            # Update version in requirements.txt
            sed -i.bak "s/^${package}==.*/${package}==${to_ver}/" requirements.txt 2>/dev/null || \
            sed -i '' "s/^${package}==.*/${package}==${to_ver}/" requirements.txt 2>/dev/null || true
            rm -f requirements.txt.bak
            pip install "$package==$to_ver" 2>/dev/null || return 1
        else
            pip install "$package==$to_ver" 2>/dev/null || return 1
        fi
    elif [[ "$ecosystem" == "node" ]]; then
        npm install "${package}@${to_ver}" 2>/dev/null || return 1
    else
        echo "cve: unknown ecosystem $ecosystem for $package" >&2
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# _cve_append_review(finding_json, reason) — Append to cve-review.md
# Args: $1 = JSON finding, $2 = deferral reason
# ---------------------------------------------------------------------------

_cve_append_review() {
    local finding_json="$1"
    local reason="$2"
    local review_file="$GRINDER_DIR/cve-review.md"

    # Create file with header if absent
    if [[ ! -f "$review_file" ]]; then
        mkdir -p "$(dirname "$review_file")"
        printf '# CVE Review\n\n' > "$review_file"
    fi

    # Extract fields
    local cve_id package severity tool message
    cve_id=$(echo "$finding_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('rule',''))")
    package=$(echo "$finding_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('file',''))")
    severity=$(echo "$finding_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('severity',''))")
    tool=$(echo "$finding_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('tool',''))")
    message=$(echo "$finding_json" | python3 -c "import json,sys; print(json.load(sys.stdin).get('message',''))")

    local fix_version
    fix_version=$(echo "$finding_json" | python3 -c "import json,sys; v=json.load(sys.stdin).get('fix_version',''); print(v if v else 'none')")

    local date_iso
    date_iso=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

    cat >> "$review_file" << EOF
### $cve_id — $package ($fix_version)
- **Severity:** $severity
- **Scanner:** $tool
- **Impact:** $message
- **Reason deferred:** $reason
- **Date:** $date_iso

EOF
}

# ---------------------------------------------------------------------------
# _cve_partition_findings(files_json) — Partition via Python module
# Args: $1 = files_json array
# Sets: _CVE_PARTITION_RESULT (JSON)
# ---------------------------------------------------------------------------

_cve_partition_findings() {
    local files_json="$1"

    # Collect all scanner output for CVE scanners
    local scanner_dir="$GRINDER_DIR/scanner-output"
    local all_findings="[]"
    if [[ -d "$scanner_dir" ]]; then
        for f in "$scanner_dir"/pip-audit.json "$scanner_dir"/npm-audit.json; do
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

    _CVE_PARTITION_RESULT=$(python3 "$LIB_DIR/grinder-cve-partition.py" \
        --findings-json "$all_findings" \
        --exclude-deps "$_CVE_EXCLUDE_DEPS_JSON" \
        --never-auto-upgrade "$_CVE_NEVER_AUTO_UPGRADE_JSON" \
        --severity-gate "$_CVE_SEVERITY_GATE" \
        --suggest-only-gate "$_CVE_SUGGEST_GATE" 2>/dev/null) || _CVE_PARTITION_RESULT="{}"
}

# ---------------------------------------------------------------------------
# execute_cve_batch() — Main entry point for CVE batches
# Args: $1=batch_id, $2=pass_kind, $3=files_json, $4=estimated_turns
# Returns: 0 on success, 1 on failure
# Output: key=value lines on stdout for event enrichment
# ---------------------------------------------------------------------------

execute_cve_batch() {
    local _batch_id="$1"
    local _pass_kind="$2"
    local files_json="$3"
    local _estimated_turns="$4"

    # Step 1: Load manifest (cached)
    _cve_load_manifest

    # Step 2: Partition findings
    _cve_partition_findings "$files_json"

    if [[ -z "$_CVE_PARTITION_RESULT" || "$_CVE_PARTITION_RESULT" == "{}" ]]; then
        echo "cve: no CRITICAL/HIGH vulnerabilities found" >&2
        echo "cves_found=0"
        echo "cves_fixed=0"
        echo "cves_deferred=0"
        echo "deps_excluded=0"
        return 0
    fi

    # Extract counts and groups
    local fix_count defer_count skip_count suggest_count
    fix_count=$(echo "$_CVE_PARTITION_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('fix_count',0))")
    defer_count=$(echo "$_CVE_PARTITION_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('defer_count',0))")
    skip_count=$(echo "$_CVE_PARTITION_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('skip_count',0))")
    suggest_count=$(echo "$_CVE_PARTITION_RESULT" | python3 -c "import json,sys; print(json.load(sys.stdin).get('suggest_count',0))")

    local total_found=$(( fix_count + defer_count + skip_count + suggest_count ))

    # Step 3: Process skipped findings (log exclusion)
    if [[ "$skip_count" -gt 0 ]]; then
        local skip_json
        skip_json=$(echo "$_CVE_PARTITION_RESULT" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('skip',[])))")
        local num_skips
        num_skips=$(echo "$skip_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
        for ((i=0; i<num_skips; i++)); do
            local skip_pkg skip_reason
            skip_pkg=$(echo "$skip_json" | python3 -c "import json,sys; d=json.load(sys.stdin)[$i]; print(d.get('file',''))")
            skip_reason=$(echo "$skip_json" | python3 -c "import json,sys; d=json.load(sys.stdin)[$i]; print(d.get('skip_reason','excluded'))")
            echo "cve: skipping $skip_pkg ($skip_reason)" >&2
        done
    fi

    # Step 4: Process suggested findings (append to cve-review.md as suggestions)
    if [[ "$suggest_count" -gt 0 ]]; then
        local suggest_json
        suggest_json=$(echo "$_CVE_PARTITION_RESULT" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('suggest',[])))")
        local num_suggests
        num_suggests=$(echo "$suggest_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
        for ((i=0; i<num_suggests; i++)); do
            local finding
            finding=$(echo "$suggest_json" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)[$i]))")
            _cve_append_review "$finding" "Suggestion (below severity gate)"
        done
    fi

    # Step 5: Process deferred findings (append to cve-review.md)
    if [[ "$defer_count" -gt 0 ]]; then
        local defer_json
        defer_json=$(echo "$_CVE_PARTITION_RESULT" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('defer',[])))")
        local num_defers
        num_defers=$(echo "$defer_json" | python3 -c "import json,sys; print(len(json.load(sys.stdin)))")
        for ((i=0; i<num_defers; i++)); do
            local finding reason
            finding=$(echo "$defer_json" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)[$i]))")
            reason=$(echo "$defer_json" | python3 -c "import json,sys; print(json.load(sys.stdin)[$i].get('reason','deferred'))")
            _cve_append_review "$finding" "$reason"
        done
    fi

    # Step 6: No fixable findings → output metrics and return
    if [[ "$fix_count" -eq 0 ]]; then
        echo "cve: no CRITICAL/HIGH vulnerabilities found" >&2
        echo "cves_found=$total_found"
        echo "cves_fixed=0"
        echo "cves_deferred=$defer_count"
        echo "deps_excluded=$skip_count"
        return 0
    fi

    # Step 7: Process fixable findings
    local fix_json
    fix_json=$(echo "$_CVE_PARTITION_RESULT" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('fix',[])))")

    # Group by package
    local packages_json
    packages_json=$(echo "$fix_json" | python3 -c "
import json, sys
findings = json.load(sys.stdin)
by_pkg = {}
for f in findings:
    pkg = f.get('file', '')
    if pkg not in by_pkg:
        by_pkg[pkg] = []
    by_pkg[pkg].append(f)
print(json.dumps(by_pkg))
")

    # Pre-fix test snapshot
    resolve_test_command >/dev/null 2>&1
    local pre_test_exit=0
    local skip_test_verification=false
    run_tests_for_project || pre_test_exit=$?
    if [[ $pre_test_exit -ne 0 ]]; then
        echo "cve: pre-batch tests already failing (exit $pre_test_exit) -- skipping test verification" >&2
        skip_test_verification=true
    fi

    local cves_fixed=0
    local cves_deferred=$defer_count
    local commit_count=0

    # Process each package
    local pkg_names
    pkg_names=$(echo "$packages_json" | python3 -c "import json,sys; [print(k) for k in json.load(sys.stdin)]")

    while IFS= read -r pkg; do
        [[ -z "$pkg" ]] && continue

        # Get fix version and CVE IDs for this package
        local pkg_info
        pkg_info=$(echo "$packages_json" | python3 -c "
import json, sys
d = json.load(sys.stdin)
findings = d.get(sys.argv[1], [])
fix_ver = findings[0].get('resolved_version', '') if findings else ''
cves = [f.get('rule', '') for f in findings]
current = ''
msg = findings[0].get('message', '') if findings else ''
parts = msg.split(' ')
if len(parts) >= 2:
    current = parts[1].rstrip(':')
print(json.dumps({'fix_version': fix_ver, 'cves': cves, 'current_version': current, 'count': len(findings)}))
" "$pkg")

        local fix_ver current_ver cve_count cve_ids
        fix_ver=$(echo "$pkg_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['fix_version'])")
        current_ver=$(echo "$pkg_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['current_version'])")
        cve_count=$(echo "$pkg_info" | python3 -c "import json,sys; print(json.load(sys.stdin)['count'])")
        cve_ids=$(echo "$pkg_info" | python3 -c "import json,sys; print(', '.join(json.load(sys.stdin)['cves']))")

        local ecosystem
        local first_finding
        first_finding=$(echo "$packages_json" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)[sys.argv[1]][0]))" "$pkg")
        ecosystem=$(_cve_detect_ecosystem "$first_finding")

        echo "cve: upgrading $pkg $current_ver → $fix_ver ($cve_ids)" >&2

        # Apply upgrade
        if ! _cve_apply_upgrade "$pkg" "$current_ver" "$fix_ver" "$ecosystem"; then
            echo "cve: upgrade failed for $pkg -- deferring" >&2
            _cve_append_review "$first_finding" "upgrade command failed"
            cves_deferred=$((cves_deferred + cve_count))
            continue
        fi

        # Run tests
        if [[ "$skip_test_verification" == "false" ]]; then
            local post_test_exit=0
            run_tests_for_project || post_test_exit=$?
            if [[ $pre_test_exit -eq 0 && $post_test_exit -ne 0 ]]; then
                echo "cve: test regression after upgrading $pkg -- reverting" >&2
                cd "$PROJECT_DIR" || continue
                git checkout -- . 2>/dev/null || true
                _cve_append_review "$first_finding" "test regression after upgrade"
                cves_deferred=$((cves_deferred + cve_count))
                continue
            fi
        fi

        # Commit the upgrade
        cd "$PROJECT_DIR" || continue
        git add -A 2>/dev/null || true

        local commit_msg
        if [[ "$cve_count" -eq 1 ]]; then
            commit_msg="fix(deps): upgrade $pkg $current_ver → $fix_ver ($cve_ids)"
        else
            commit_msg="fix(deps): upgrade $pkg $current_ver → $fix_ver ($cve_count CVEs resolved)"
        fi

        if git commit -m "$commit_msg" 2>/dev/null; then
            cves_fixed=$((cves_fixed + cve_count))
            commit_count=$((commit_count + 1))
        else
            echo "cve: commit failed for $pkg -- reverting" >&2
            git checkout -- . 2>/dev/null || true
            _cve_append_review "$first_finding" "commit failed"
            cves_deferred=$((cves_deferred + cve_count))
        fi
    done <<< "$pkg_names"

    # Output metrics
    echo "cves_found=$total_found"
    echo "cves_fixed=$cves_fixed"
    echo "cves_deferred=$cves_deferred"
    echo "deps_excluded=$skip_count"

    return 0
}

# ---------------------------------------------------------------------------
# cve_commit_review() — Commit cve-review.md if modified (post-pass hook)
# Reads: GRINDER_DIR, PROJECT_DIR
# ---------------------------------------------------------------------------

cve_commit_review() {
    local review_file="$GRINDER_DIR/cve-review.md"
    if [[ ! -f "$review_file" ]]; then
        return 0
    fi

    cd "$PROJECT_DIR" || return 0

    # Check if cve-review.md has uncommitted changes
    if git diff --quiet -- "$review_file" 2>/dev/null && \
       ! git ls-files --others --exclude-standard | grep -q "cve-review.md"; then
        return 0
    fi

    git add "$review_file" 2>/dev/null || true
    git commit -m "docs(grinder): cve-review.md" 2>/dev/null || true
}
