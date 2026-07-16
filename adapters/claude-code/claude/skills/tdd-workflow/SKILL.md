---
name: tdd-workflow
description: TDD workflow rules and test commands for this project. Use when implementing features, writing tests, or debugging test failures.
user-invocable: false
---

# TDD Workflow

## Mandatory Sequence

1. **Test FIRST** — Write failing test before ANY implementation
2. **Verify failure** — Run tests. If passes -> test is wrong, rewrite
3. **Minimum implementation** — Only enough to pass
4. **SOLID checkpoint** — See `.claude/skills/solid-principles/SKILL.md`
5. **All tests** — Run full suite, fix regressions immediately
6. **Refactor** — Only while tests stay green

## Project Commands

```bash
# Hook tests (bash)
bash tests/test-hook.sh                      # Test hook JSONL output
bash tests/test-concurrent-writes.sh         # Test atomic writes
bash tests/test-security.sh                  # Test input sanitization

# All tests
bash tests/run-all.sh                        # Run everything
```

## Project-Specific Patterns

**Hook tests:** Shell scripts that invoke the hook with mock stdin, verify JSONL output.

**Dashboard tests:** Manual browser testing (single HTML file, no framework).

**Security tests:** Feed malicious input to hook, verify safe handling.

## Pre-existing Failures

When the test suite reveals a failing test that predates your changes:

1. **Fix it** in a separate commit (`fix(<scope>):`). Run full suite before
   and after — if any previously-passing test breaks, revert immediately.
2. If the fix is genuinely risky (touches critical paths, unclear root cause),
   note it in the Quality Findings section at checkpoint and flag for review.
3. **Never** silently dismiss as "pre-existing, not related to our changes."
   A professional developer fixes broken tests they encounter.

## Anti-Patterns (STOP immediately)

- Implementation before test
- Test passes without new code (test is wrong)
- Running single test instead of full suite
- Skipping SOLID checkpoint
- "I'll add tests later"
- Dismissing pre-existing test failures as "not our problem"

## Forbidden Completion Language

These words/phrases are BANNED **when claiming a task is complete or a test
passes** (they are permitted in test names, code, and quoted error messages):

> "should", "probably", "seems to", "likely", "I think", "I believe", "appears to"

Any completion claim using these words is automatically invalid. Re-run the
command and show concrete evidence: actual test output, actual command result,
or actual file content. No hedging — prove it or don't claim it.

## Gotchas

- **Shell test scripts need `set -e`.** Without it, a failing assertion
  doesn't stop the script — subsequent tests run on corrupt state and the
  script exits 0. Every `tests/*.sh` file must start with `set -euo pipefail`.
- **Hook tests depend on stdin format.** Hook test scripts pipe mock JSON to
  the hook. If the JSON structure changes (new fields, renamed keys), tests
  pass but with stale fixtures. When modifying hook input format, update test
  fixtures in the same commit.
