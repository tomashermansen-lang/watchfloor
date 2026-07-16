#!/usr/bin/env bash
# grinder-coverage.sh — Coverage-pass-specific functions for grinder.sh
#
# Sourced by grinder.sh at startup. Provides the coverage grinder pass
# logic: coverage measurement, prompt building, test validation (suppression
# rejection, mock depth checking), coverage regression detection, and
# batch orchestration.
#
# Depends on: TOOLS_DIR, LIB_DIR, SCHEMA_DIR, PROJECT_DIR, GRINDER_DIR
# (session globals set by grinder.sh main())
#
# Also depends on grinder-mechanical.sh being sourced first (provides
# resolve_test_command, run_tests_for_project).
#
# Compatible with bash 3.2+ (macOS default).

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

COVERAGE_MOCK_DEPTH_LIMIT="${COVERAGE_MOCK_DEPTH_LIMIT:-3}"

# ---------------------------------------------------------------------------
# _coverage_check_suppressions() — Scan test files for inline suppressions
# ---------------------------------------------------------------------------
# Returns 0 if clean, 1 if any suppression found.
# Args: file1 [file2 ...]

_coverage_check_suppressions() {
    local -a files=("$@")
    if [[ ${#files[@]} -eq 0 ]]; then
        return 0
    fi

    # Combined grep pattern for all suppression types.
    # Note: // @ts-expect-error without a specific error code is a suppression,
    # but // @ts-expect-error TS2345 is legitimate. We match bare @ts-expect-error
    # at end of line (no trailing error code).
    local pattern='# pragma: no cover|# noqa|// istanbul ignore|/\* istanbul ignore|# type: ignore|// @ts-ignore|// @ts-expect-error\s*$'

    if grep -nE "$pattern" "${files[@]}" >/dev/null 2>&1; then
        return 1
    fi

    return 0
}

# ---------------------------------------------------------------------------
# _coverage_check_mock_depth() — Count mock patterns per test block
# ---------------------------------------------------------------------------
# Returns 0 if all blocks <= COVERAGE_MOCK_DEPTH_LIMIT, 1 if any exceeds.
# Args: file1 [file2 ...]
#
# A "test block" is approximated by boundaries: describe(, it(, test(, def test_
# Mocks in beforeEach/setup count toward all tests in the block.

_coverage_check_mock_depth() {
    local -a files=("$@")
    if [[ ${#files[@]} -eq 0 ]]; then
        return 0
    fi

    # Pre-compiled regex patterns (bash built-in — no subprocess per line)
    local re_describe='^[[:space:]]*describe\('
    local re_setup='^[[:space:]]*(beforeEach|beforeAll|setup)[[:space:]]*\('
    local re_test='^[[:space:]]*(it|test)[[:space:]]*\('
    local re_pytest='^[[:space:]]*def test_'
    local re_mock='mock\.patch\(|Mock\(|MagicMock\(|patch\.object\(|vi\.mock\(|vi\.fn\(|jest\.mock\(|jest\.fn\('

    for file in "${files[@]}"; do
        [[ ! -f "$file" ]] && continue

        local mock_count=0
        local setup_mocks=0
        local in_setup=false

        while IFS= read -r line; do
            # Check for describe( boundary — resets block counter
            if [[ "$line" =~ $re_describe ]]; then
                mock_count=0
                setup_mocks=0
                in_setup=false
                continue
            fi

            # Check for beforeEach/setup — mocks here count toward all tests
            if [[ "$line" =~ $re_setup ]]; then
                in_setup=true
                continue
            fi

            # Check for test boundary (it/test/def test_) — carries setup_mocks forward
            if [[ "$line" =~ $re_test ]] || [[ "$line" =~ $re_pytest ]]; then
                if [[ "$in_setup" == "true" ]]; then
                    in_setup=false
                fi
                mock_count=$setup_mocks
                continue
            fi

            # Count mock patterns
            if [[ "$line" =~ $re_mock ]]; then
                if [[ "$in_setup" == "true" ]]; then
                    setup_mocks=$((setup_mocks + 1))
                    # Also add to current mock_count for threshold check
                    mock_count=$((mock_count + 1))
                else
                    mock_count=$((mock_count + 1))
                fi
            fi

            # Check threshold after each mock
            if [[ $mock_count -gt $COVERAGE_MOCK_DEPTH_LIMIT ]]; then
                return 1
            fi
        done < "$file"
    done

    return 0
}

# ---------------------------------------------------------------------------
# _coverage_filter_test_files() — Filter file list through test naming patterns
# ---------------------------------------------------------------------------
# Returns matching files on stdout (one per line). Non-matching files are
# silently excluded.
# Args: file1 [file2 ...]

_coverage_filter_test_files() {
    local -a files=("$@")
    for f in "${files[@]}"; do
        local basename
        basename=$(basename "$f")
        # Python test patterns
        if [[ "$basename" == test_*.py ]] || [[ "$basename" == *_test.py ]]; then
            echo "$f"
            continue
        fi
        # TypeScript/JavaScript test patterns
        if [[ "$basename" == *.test.ts ]] || [[ "$basename" == *.test.tsx ]] || \
           [[ "$basename" == *.spec.ts ]] || [[ "$basename" == *.spec.tsx ]]; then
            echo "$f"
            continue
        fi
        # Non-test file — skip silently
    done
}

# ---------------------------------------------------------------------------
# _should_early_exit_coverage() — Check if project-wide coverage meets target
# ---------------------------------------------------------------------------
# Args: current_coverage target_coverage (both as decimals, e.g., 0.85)
# Prints "true" if coverage >= target, "false" otherwise.

_should_early_exit_coverage() {
    local current="$1"
    local target="$2"
    python3 -c "
import sys
current = float(sys.argv[1])
target = float(sys.argv[2])
print('true' if current >= target else 'false')
" "$current" "$target"
}

# ---------------------------------------------------------------------------
# _should_halt_coverage_pass() — Check if >50% of batches failed
# ---------------------------------------------------------------------------
# Args: failed_count completed_count
# Prints "true" if failed > 50% of completed, "false" otherwise.
# EC-7.1: exactly 50% does NOT trigger (strictly greater).

_should_halt_coverage_pass() {
    local failed="$1"
    local completed="$2"
    python3 -c "
import sys
failed = int(sys.argv[1])
completed = int(sys.argv[2])
# Strictly greater than 50%: failed * 2 > completed
print('true' if failed * 2 > completed else 'false')
" "$failed" "$completed"
}

# ---------------------------------------------------------------------------
# _coverage_revert_batch() — Revert tracked changes and clean new files
# ---------------------------------------------------------------------------
# Args: pre_untracked_file batch_files...
# pre_untracked_file: file listing untracked files before the batch ran

_coverage_revert_batch() {
    local pre_untracked_file="$1"
    shift
    local -a batch_files=("$@")

    # shellcheck disable=SC2153  # PROJECT_DIR is a global set by grinder.sh
    cd "$PROJECT_DIR" || return 1

    # Revert tracked file changes
    if [[ -n "$(git diff --name-only 2>/dev/null)" ]]; then
        git checkout -- . 2>/dev/null || true
    fi

    # Clean newly created test files (compare pre/post untracked)
    local post_untracked
    post_untracked=$(git ls-files --others --exclude-standard 2>/dev/null || echo "")
    if [[ -n "$post_untracked" && -f "$pre_untracked_file" ]]; then
        local new_files
        new_files=$(comm -13 <(sort "$pre_untracked_file") <(echo "$post_untracked" | sort))
        if [[ -n "$new_files" ]]; then
            echo "$new_files" | while IFS= read -r f; do
                [[ -n "$f" ]] && git clean -f -- "$f" 2>/dev/null || true
            done
        fi
    elif [[ -n "$post_untracked" && ! -f "$pre_untracked_file" ]]; then
        # No pre-tracking file — clean all new untracked files
        echo "$post_untracked" | while IFS= read -r f; do
            [[ -n "$f" ]] && git clean -f -- "$f" 2>/dev/null || true
        done
    fi
}

# ---------------------------------------------------------------------------
# _coverage_detect_test_files() — Identify generated test files
# ---------------------------------------------------------------------------
# Args: pre_untracked_file
# Prints list of new/modified test files on stdout.

_coverage_detect_test_files() {
    local pre_untracked_file="$1"

    cd "$PROJECT_DIR" || return 1

    # Modified tracked files
    git diff --name-only 2>/dev/null || true

    # Newly created untracked files
    local post_untracked
    post_untracked=$(git ls-files --others --exclude-standard 2>/dev/null || echo "")
    if [[ -n "$post_untracked" && -f "$pre_untracked_file" ]]; then
        comm -13 <(sort "$pre_untracked_file") <(echo "$post_untracked" | sort)
    elif [[ -n "$post_untracked" ]]; then
        echo "$post_untracked"
    fi
}

# ---------------------------------------------------------------------------
# _coverage_find_report_path() — Locate coverage report in project root
# ---------------------------------------------------------------------------
# Args: project_root
# Prints the report path, or empty string if not found.

_coverage_find_report_path() {
    local project_root="${1:-.}"
    if [[ -f "$project_root/coverage/coverage-final.json" ]]; then
        echo "$project_root/coverage/coverage-final.json"
    elif [[ -f "$project_root/coverage.json" ]]; then
        echo "$project_root/coverage.json"
    fi
}

# ---------------------------------------------------------------------------
# _coverage_resolve_command() — Read coverage command from manifest
# ---------------------------------------------------------------------------
# Args: manifest_json
# Prints the coverage command string.

_coverage_resolve_command() {
    local manifest_json="$1"
    echo "$manifest_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
coverage = data.get('coverage', {})
# Try language-keyed commands
for lang in ['typescript', 'python', 'bash']:
    if lang in coverage:
        print(coverage[lang])
        sys.exit(0)
# Fallback: check for 'command' key
if 'command' in coverage:
    print(coverage['command'])
    sys.exit(0)
print('')
"
}

# ---------------------------------------------------------------------------
# _coverage_measure() — Run coverage tool + parse-coverage.py
# ---------------------------------------------------------------------------
# Args: coverage_cmd format project_root
# Prints JSON output from parse-coverage.py

_coverage_measure() {
    local coverage_cmd="$1"
    local format="${2:-auto}"
    local project_root="${3:-$PROJECT_DIR}"

    cd "$project_root" || return 1

    # Run coverage command
    eval "$coverage_cmd" >/dev/null 2>&1 || {
        echo "coverage: coverage command failed" >&2
        return 1
    }

    # Find coverage report
    local report_path=""
    report_path=$(_coverage_find_report_path "$project_root")

    if [[ -z "$report_path" ]]; then
        echo "coverage: no coverage report found -- check coverage command and report output path" >&2
        return 1
    fi

    # shellcheck disable=SC2153  # LIB_DIR is a global set by grinder.sh
    python3 "$LIB_DIR/parse-coverage.py" \
        --format "$format" \
        --report-path "$report_path" \
        --project-root "$project_root"
}

# ---------------------------------------------------------------------------
# _coverage_build_prompt() — Build coverage prompt for claude -p session
# ---------------------------------------------------------------------------
# Args: files_json coverage_json
# Prints the prompt string.

_coverage_build_prompt() {
    local files_json="$1"
    local coverage_json="$2"

    local files_list
    files_list=$(echo "$files_json" | jq -r '.[]' 2>/dev/null || echo "")

    local prompt="You are running a grinder coverage batch.

## Objective

Write comprehensive tests for the listed source files to improve code coverage.
Follow the project's test conventions.

## Source Files and Current Coverage

"
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local pct
        pct=$(echo "$coverage_json" | jq -r --arg f "$f" '.files[$f] // "unknown"' 2>/dev/null || echo "unknown")
        prompt+="- $f (coverage: $pct)
"
    done <<< "$files_list"

    prompt+="
## Constraints

- Write tests only. Do not modify source files.
- Do not add \`# pragma: no cover\`, \`# noqa\`, \`// istanbul ignore\`,
  \`# type: ignore\`, \`// @ts-ignore\`, or any inline coverage/lint suppression.
- Do not mock more than 3 external dependencies per test function.
- Each test must have a meaningful assertion — no empty tests or stub-only tests.
- Test names must describe the behaviour being tested."

    echo "$prompt"
}

# ---------------------------------------------------------------------------
# _coverage_discover_files() — Coverage discovery logic for cmd_discover()
# ---------------------------------------------------------------------------
# Args: manifest_json project_dir lib_dir
# Prints JSON object {path: coverage_pct} of files below target, or empty.

_coverage_discover_files() {
    local manifest_json="$1"
    local project_dir="$2"
    local lib_dir="$3"

    local coverage_block
    coverage_block=$(echo "$manifest_json" | python3 -c "
import json, sys
data = json.load(sys.stdin)
coverage = data.get('coverage', {})
if coverage:
    print(json.dumps(coverage))
else:
    print('')
" 2>/dev/null) || true

    if [[ -z "$coverage_block" ]]; then
        return 0
    fi

    # Extract coverage command
    local coverage_cmd
    coverage_cmd=$(_coverage_resolve_command "$manifest_json" 2>/dev/null) || true

    if [[ -z "$coverage_cmd" ]]; then
        log "discover: no coverage configuration -- skipping coverage pass"
        return 0
    fi

    log "discover: running coverage command for discovery..."

    # Run with timeout (EC-1.1: 600s)
    if ! timeout 600 bash -c "cd '$project_dir' && $coverage_cmd" >/dev/null 2>&1; then
        log "discover: coverage command timed out after 600s -- skipping coverage pass"
        return 0
    fi

    # Parse coverage report
    local cov_report_path=""
    cov_report_path=$(_coverage_find_report_path "$project_dir")

    if [[ -z "$cov_report_path" ]]; then
        log "discover: no coverage report found after running coverage command"
        return 0
    fi

    local cov_output=""
    cov_output=$(python3 "$lib_dir/parse-coverage.py" --format auto --report-path "$cov_report_path" --project-root "$project_dir" 2>/dev/null) || true
    if [[ -z "$cov_output" ]]; then
        return 0
    fi

    # Filter to files below target_per_commit, apply excludes
    local target_per_commit
    target_per_commit=$(echo "$coverage_block" | python3 -c "import json,sys; print(json.load(sys.stdin).get('target_per_commit', 0.99))" 2>/dev/null) || target_per_commit="0.99"
    local exclude_paths_json
    exclude_paths_json=$(echo "$coverage_block" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('exclude_paths', [])))" 2>/dev/null) || exclude_paths_json="[]"
    local exclude_patterns_json
    exclude_patterns_json=$(echo "$coverage_block" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin).get('exclude_patterns', [])))" 2>/dev/null) || exclude_patterns_json="[]"

    echo "$cov_output" | python3 -c "
import json, sys, fnmatch
data = json.load(sys.stdin)
target = float(sys.argv[1])
excludes = json.loads(sys.argv[2])
patterns = json.loads(sys.argv[3])
result = {}
for path, pct in data.get('files', {}).items():
    if pct >= target:
        continue
    excluded = False
    for ep in excludes:
        if path.startswith(ep):
            excluded = True
            break
    if excluded:
        continue
    for pat in patterns:
        if fnmatch.fnmatch(path, pat):
            excluded = True
            break
    if excluded:
        continue
    # Skip test files, config files, type declarations
    bname = path.split('/')[-1]
    if bname.startswith('test_') or bname.endswith('_test.py'):
        continue
    if bname.endswith('.test.ts') or bname.endswith('.test.tsx'):
        continue
    if bname.endswith('.spec.ts') or bname.endswith('.spec.tsx'):
        continue
    if bname.endswith('.d.ts') or bname == 'conftest.py':
        continue
    if '/__tests__/' in path or '/__mocks__/' in path or '/tests/' in path:
        continue
    result[path] = pct
print(json.dumps(result))
" "$target_per_commit" "$exclude_paths_json" "$exclude_patterns_json" 2>/dev/null
}

# ---------------------------------------------------------------------------
# execute_coverage_batch() — Full coverage batch execution
# ---------------------------------------------------------------------------
# Args: batch_id pass_kind files_json estimated_turns
# Returns: 0 on success, 1 on failure
# Stdout: key=value enrichment data (coverage_before, coverage_after, test_files_generated)

execute_coverage_batch() {
    local batch_id="$1"
    # $2 is pass_kind (always "coverage" when dispatched from grinder.sh)
    local files_json="$3"
    local estimated_turns="$4"

    cd "$PROJECT_DIR" || return 1

    # Step 1: Parse batch files
    local -a batch_files=()
    while IFS= read -r f; do
        [[ -n "$f" ]] && batch_files+=("$f")
    done < <(echo "$files_json" | jq -r '.[]' 2>/dev/null)

    if [[ ${#batch_files[@]} -eq 0 ]]; then
        echo "coverage_before=0" ; echo "coverage_after=0" ; echo "test_files_generated=0"
        return 0
    fi

    # Step 2: Path traversal validation
    for f in "${batch_files[@]}"; do
        if [[ "$f" == *".."* ]]; then
            echo "coverage: path traversal detected in batch file: $f" >&2
            return 1
        fi
    done

    # Step 3: Record pre-untracked files
    local pre_untracked_file
    pre_untracked_file=$(mktemp "${TMPDIR:-/tmp}/grinder-coverage-untracked.XXXXXX")
    git ls-files --others --exclude-standard > "$pre_untracked_file" 2>/dev/null || true

    # Step 4-5: Resolve coverage command and run pre-batch measurement
    local manifest_json=""
    manifest_json=$(python3 "$TOOLS_DIR/validate-manifest.py" --parse-grinder "$PROJECT_DIR/CLAUDE.md" 2>/dev/null) || true
    local coverage_cmd=""
    if [[ -n "$manifest_json" ]]; then
        coverage_cmd=$(_coverage_resolve_command "$manifest_json" 2>/dev/null) || true
    fi

    local coverage_json='{"files":{}}'
    local coverage_before=0
    if [[ -n "$coverage_cmd" ]]; then
        local measure_output=""
        measure_output=$(_coverage_measure "$coverage_cmd" "auto" "$PROJECT_DIR" 2>/dev/null) || true
        if [[ -n "$measure_output" ]]; then
            coverage_json="$measure_output"
            coverage_before=$(echo "$measure_output" | python3 -c "import json,sys; print(json.load(sys.stdin).get('project_wide',0))" 2>/dev/null) || coverage_before=0
        fi
    fi

    # Step 6: Build coverage prompt
    export EXTRA_SYSTEM_PROMPT
    EXTRA_SYSTEM_PROMPT=$(_coverage_build_prompt "$files_json" "$coverage_json")

    # Step 7: Run claude -p session
    export PHASE_TIMEOUT="$GRINDER_BATCH_TIMEOUT"
    export MAX_TURNS_PHASE="$estimated_turns"

    local files_list
    files_list=$(echo "$files_json" | jq -r '.[]' 2>/dev/null || echo "")

    local prompt="Write tests for these source files to improve coverage:
$files_list"

    run_phase "$prompt" "grinder-coverage-$batch_id" "$PROJECT_DIR" || true

    # Step 8: Detect generated/modified test files
    local detected_files
    detected_files=$(_coverage_detect_test_files "$pre_untracked_file")

    if [[ -z "$detected_files" ]]; then
        echo "test_files_generated=0"
        rm -f "$pre_untracked_file"
        return 0
    fi

    # Step 8a: Filter by test naming conventions
    local -a filtered_files=()
    while IFS= read -r f; do
        [[ -z "$f" ]] && continue
        local filtered
        filtered=$(_coverage_filter_test_files "$f")
        if [[ -n "$filtered" ]]; then
            filtered_files+=("$f")
        else
            # Revert non-test file
            log "coverage: unexpected non-test file created: $f"
            git checkout -- "$f" 2>/dev/null || git clean -f -- "$f" 2>/dev/null || true
        fi
    done <<< "$detected_files"

    if [[ ${#filtered_files[@]} -eq 0 ]]; then
        echo "test_files_generated=0"
        rm -f "$pre_untracked_file"
        return 0
    fi

    # Step 9: Validate generated tests
    if ! _coverage_check_suppressions "${filtered_files[@]}"; then
        echo "coverage: inline suppression detected in generated test" >&2
        _coverage_revert_batch "$pre_untracked_file" "${filtered_files[@]}"
        rm -f "$pre_untracked_file"
        return 1
    fi

    if ! _coverage_check_mock_depth "${filtered_files[@]}"; then
        echo "coverage: mock depth exceeded $COVERAGE_MOCK_DEPTH_LIMIT" >&2
        _coverage_revert_batch "$pre_untracked_file" "${filtered_files[@]}"
        rm -f "$pre_untracked_file"
        return 1
    fi

    # Step 10: Run test suite
    local test_cmd
    test_cmd=$(resolve_test_command 2>/dev/null || echo "")
    if [[ -n "$test_cmd" ]]; then
        if ! (cd "$PROJECT_DIR" && eval "$test_cmd" >/dev/null 2>&1); then
            echo "coverage: generated tests fail" >&2
            _coverage_revert_batch "$pre_untracked_file" "${filtered_files[@]}"
            rm -f "$pre_untracked_file"
            return 1
        fi
    fi

    # Step 11: Post-batch coverage measurement and regression check
    local coverage_after="$coverage_before"
    if [[ -n "$coverage_cmd" ]]; then
        local post_measure=""
        post_measure=$(_coverage_measure "$coverage_cmd" "auto" "$PROJECT_DIR" 2>/dev/null) || true
        if [[ -n "$post_measure" ]]; then
            coverage_after=$(echo "$post_measure" | python3 -c "import json,sys; print(json.load(sys.stdin).get('project_wide',0))" 2>/dev/null) || coverage_after="$coverage_before"
            # Check per-file regression
            local regressed=""
            regressed=$(python3 -c "
import json, sys
before = json.loads(sys.argv[1])
after = json.loads(sys.argv[2])
for f, pct in before.get('files', {}).items():
    if f in after.get('files', {}) and after['files'][f] < pct:
        print(f)
" "$coverage_json" "$post_measure" 2>/dev/null) || true
            if [[ -n "$regressed" ]]; then
                echo "coverage: coverage regression detected in: $regressed" >&2
                _coverage_revert_batch "$pre_untracked_file" "${filtered_files[@]}"
                rm -f "$pre_untracked_file"
                return 1
            fi
        fi
    fi

    # Step 12: Stage and commit test files only
    for f in "${filtered_files[@]}"; do
        git add "$f" 2>/dev/null || true
    done

    if ! git commit -m "test(grinder): pass-2-coverage (batch $batch_id)" 2>/dev/null; then
        log "coverage: batch $batch_id commit failed"
        _coverage_revert_batch "$pre_untracked_file" "${filtered_files[@]}"
        rm -f "$pre_untracked_file"
        return 1
    fi

    # Step 13: Output enrichment data
    local test_file_count=${#filtered_files[@]}
    echo "coverage_before=$coverage_before"
    echo "coverage_after=$coverage_after"
    echo "test_files_generated=$test_file_count"

    rm -f "$pre_untracked_file"
    return 0
}
