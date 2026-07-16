# Fixture vision — schema 2.0 producer dogfood

A canned vision input for `/plan-project` to dogfood the producer rewrite.
The producer should emit a plan structurally equivalent to `minimal.yaml`.

**Project name:** dogfood-plan

**Vision:** Plan-project producer regenerates a deterministic minimal 2.0
plan from a fixed vision input, validating that the rewritten command
emits YAML only and that self-review passes on first attempt.

**Users:**
- operator running /plan-project against this canned vision

**Success criteria:**
- validate-plan.py exits 0 on the produced YAML
- no EXECUTION_PLAN.md, SETUP_PLAN.md, or PLANNING_BRIEF.md is written

**Tech stack:** python3, jsonschema, PyYAML

**Test targets:**
- dotfiles (this repo)

**Out of scope:** dashboard rendering changes, real producer LLM behaviour
