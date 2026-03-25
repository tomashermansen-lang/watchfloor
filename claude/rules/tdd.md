# TDD is mandatory for all code changes

Every bug fix and feature implementation must follow red-green-refactor:
1. Write a failing test FIRST
2. Write minimal code to pass
3. Refactor

No exceptions — including inline fixes during /manualtest.

## Failing tests are your problem

If you find a failing test — pre-existing or not — fix it. Do not label it
"pre-existing" and move on. A professional developer fixes broken tests they
encounter, regardless of who broke them. Fix it in a separate commit
(`fix(<scope>):`) if it's unrelated to the current task.
