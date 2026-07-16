---
name: integration-gate-authoring
description: How /plan-project emits a real kind=integration phase gate from the target project's manifest. Read at Step 5 when a phase touches the project's integration surface. Extends plan-producer-conventions' gate section; not user-invoked.
user-invocable: false
disable-model-invocation: true
---

# Authoring a Real Integration Gate

A `kind: integration` gate-check is the first-class, manifest-driven form of the
"cross-feature integration" check (see `plan-producer-conventions` §gate). Use it
instead of a hand-written `kind: shell` suite-run when a phase touches the
project's **integration surface** — the emergent behaviour only the combined
phase can exercise (real integration gates §4.3).

## Ground truth = the target project's manifest

Read the target project's `pipeline.yaml` `integration_test:` block (NOT a
dotfiles-shaped default — reason about *that* project's surface):

```yaml
integration_test:
  commands: [ ... ]          # the unsandboxed suite command(s)
  trigger:  [ glob, ... ]    # the project's infra surface
  services: [ ... ]          # services the gate env brings up
```

If the project has no `integration_test` block, do **not** author an integration
gate — there is nothing to run.

## When to emit one

Emit a `kind: integration` check on a phase's gate **iff** the union of that
phase's task paths (`where.modify` + `where.create`) intersects the manifest's
`trigger` globs. A phase that touches no trigger glob gets only the usual
`kind: shell` cross-feature checks — running the heavy suite there is pure cost
(§5).

## The shape (copy trigger from the manifest — this is load-bearing)

```yaml
gate:
  name: "<phase> integration gate"
  checklist:
    - item: "<what emerges when this phase's tasks combine>"
      check:
        kind: integration
        # command: omit → the orchestrator resolves it from the manifest.
        #          Set it only to override; if set, match the manifest verbatim.
        trigger:                       # COPY integration_test.trigger VERBATIM —
          - <manifest glob 1>          #   the SAME globs, SAME order. Do NOT
          - <manifest glob 2>          #   substitute the phase's own file paths.
          - <manifest glob N>          #   §7 asserts plan trigger == manifest
        remediation:                   #   trigger by value; drift = green theater.
          agent: lead-developer        # only value allowed
          max_iterations: 2            # 1..5; lean 2
          on_unfixable: escalate       # only value allowed (honest fail, §6.3)
  passed: false
```

Rules:
- **`trigger` MUST equal the manifest's `integration_test.trigger`, by value —
  the exact same globs, verbatim.** It is the project's whole infra surface, NOT
  this phase's file list. The single most common mistake is "improving" it by
  scoping it to the phase's own paths — narrowing a manifest glob `<area>/**`
  down to the phase's own subdirectory `<area>/<this-phase>/**`. DON'T. A
  narrowed trigger **under-fires**
  — it misses infra changes the phase makes outside the narrow glob — and
  under-firing silently drops integration coverage, the exact failure this whole
  mechanism exists to prevent. Over-broad (the manifest surface) is safe;
  narrowing is not. Copy the manifest globs; do not paraphrase, reorder, or scope.
- Prefer **omitting `command`** so the manifest stays the single source; set it
  only to override, and then match the manifest string exactly.
- `remediation` is required: `agent: lead-developer`, `max_iterations` 1..5
  (lean 2), `on_unfixable: escalate`. These are the only valid values (the
  schema enforces it; the guards live in the contract, see DESIGN §6).
- An integration check may coexist with `kind: shell` checks in the same gate —
  the integration run + targeted cross-feature assertions are complementary.

## Anti-patterns

| Reject | Why | Instead |
|---|---|---|
| `kind: integration` on a phase that touches no trigger glob | Heavy suite, zero emergent signal (§5) | Use `kind: shell` checks, or no gate |
| `trigger` scoped to the phase's own paths (`<area>/<this-phase>/**`) instead of the manifest glob (`<area>/**`) | Under-fires — misses infra changes outside the narrow glob (§5); also author↔executor drift (§7) | Copy the manifest globs verbatim, same order |
| `on_unfixable: warn` / a non-`escalate` value | Decoration — a gate that always greens (§6.3) | `escalate` (schema rejects anything else) |
| Restating one feature's `kind: shell` suite as integration | Already ran at that feature's commit | Test the *combined* phase behaviour |
