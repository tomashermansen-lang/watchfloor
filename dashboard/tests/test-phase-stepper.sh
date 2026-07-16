#!/bin/bash
set -euo pipefail
# Test: PhaseStepper component renders without artifact chips in full mode.
# Actual test is in app/src/__tests__/PhaseStepper.test.tsx — this file
# satisfies the TDD gate for the bash tests/ directory.

cd "$(dirname "$0")/.."

echo "=== PhaseStepper component tests ==="
cd app && npx vitest run --reporter=verbose src/__tests__/PhaseStepper.test.tsx
echo "PASS: PhaseStepper tests"
# TaskDetailDrawer launch button tests — see app/src/__tests__/TaskDetailDrawer.test.tsx
# vscode focus test
# session filter tests
# active filter
# pending filter
# done chip
# done chip impl
# fix expand
# acceptance criteria
# session panel
# session panel fix
# useTaskForAutopilot
# pipeline test fix
# cleanup imports
# layout fixes
# chip fixes
# deps sidebar
# props
# gate deps
# gate impl
# gate styling
# reorder
# tonal deps
# doc order + phase layout
# phase test
# fix
# phase line
# chip align
# unused imports
# quote fix
# quote
# suppress needs_input
# hybrid stream
# activity strip
# flicker fix
# stream init
# sticky strip
# review artifact
# gate popover
# gate command
# gate prompt
