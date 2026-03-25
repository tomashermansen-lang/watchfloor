---
name: solid-principles
description: SOLID principles verification checklist for architecture reviews. Use when reviewing code design, planning components, or checking architectural compliance.
user-invocable: false
---

# SOLID Principles

## When to Use

- Reviewing or planning component architecture
- After implementing a component (checkpoint in `/implement`)
- During `/review`, `/team-review`, `/qa` phases

Do NOT apply rigidly to shell scripts, one-off tooling, or config files.

## Thinking Framework

Before checking boxes, ask:
1. **What changes together?** — identifies S violations
2. **What would break if I added a feature?** — identifies O violations
3. **What does the consumer actually need?** — identifies I violations

## Per-Component Checklist

After each component, verify:

- [ ] **S** — ONE job. If describing requires "and", split it
- [ ] **O** — Added behavior without modifying existing tested code?
- [ ] **I** — No unused methods in interfaces?
- [ ] **D** — Depends on abstractions, not concretions?
- [ ] **~50 lines** — Extract if function exceeds this

*L rarely applies — prefer composition over inheritance.*

## Code Standards

- No dead code, no commented-out code
- No hardcoding — use config files or environment variables

## Smell -> Action

| Smell | Action |
|-------|--------|
| Module changes for multiple reasons | Split (S) |
| New feature modifies existing code | Add extension point (O) |
| `isinstance` checks | Use polymorphism (L) |
| High-level imports low-level | Introduce abstraction (D) |

## Gotchas

- **Over-abstraction in solo projects.** DIP says depend on abstractions, but
  introducing an interface with one implementation adds indirection with no
  benefit. In this repo: use abstractions at module boundaries, not within them.
- **SRP vs. file count explosion.** Splitting a 60-line Python module into 3
  files creates navigability problems for agents. SRP applies to
  *responsibilities*, not line counts — a single file with two private helpers
  and one public function is fine.
