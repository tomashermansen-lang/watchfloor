---
name: agentic-code
description: Agent navigability checklist for architecture reviews. Ensures code is optimized for coding agents to navigate, understand, and modify. Use alongside SOLID when planning or reviewing components.
user-invocable: false
---

# Agentic Code Principles

Code that is easy for coding agents to navigate, understand, and modify.

The paradigm shift: writing good code → writing good **agentic** code.

## Why This Matters

Coding agents are primary contributors. Every architectural decision should consider: can an agent spin up cold, find the right files, understand the data flow, and make a correct change — without human hand-holding?

## Per-Component Checklist

After each component, verify:

- [ ] **Navigable** — Module name is self-describing. No abbreviations, no generic `utils/helpers/misc`. An agent searching for "retrieval" finds `retrieval.py`, not `r.py` or `core.py`
- [ ] **Explicit interfaces** — Contracts use `Protocol`, `ABC`, or typed dataclasses. No implicit dicts, no `**kwargs` as API surface, no stringly-typed config
- [ ] **Traceable flow** — Data flow is followable through typed schemas (`@dataclass`, Pydantic models). An agent can trace input→transform→output by reading type signatures alone
- [ ] **Observable** — Error paths have structured logging with enough context for an agent to diagnose from traces alone. Log the *what*, *where*, and *with which inputs*
- [ ] **Documented topology** — CLAUDE.md describes all components, how they run, and how they interact. New services/interactions trigger a CLAUDE.md update
- [ ] **Versioned specs** — PLAN.md is committed and maintained. Agent planning artifacts are reviewed by the team as living documents

## Smell → Action

| Smell | Action |
|-------|--------|
| Agent can't find module by name | Rename to match domain concept |
| Data passed as raw dict between modules | Introduce typed schema (dataclass/Pydantic) |
| Error gives no context ("failed") | Add structured log with input state |
| New service not in CLAUDE.md | Update component map section |
| `**kwargs` in public interface | Replace with explicit typed parameters |
| Agent needs 3+ hops to trace data flow | Flatten or add type annotations at boundaries |

## CLAUDE.md Component Map

CLAUDE.md should contain a section that answers these questions for every service:

1. **What does it do?** (one sentence)
2. **Where does it live?** (file path)
3. **What does it depend on?** (upstream)
4. **What depends on it?** (downstream)
5. **How is it configured?** (config keys)

This is the first thing a coding agent reads on spin-up. If it's wrong or incomplete, every subsequent action starts from a wrong mental model.

## Logging for Agents

Agents debug by reading logs, not by stepping through code. Design logging accordingly:

- **Structured format** — Key-value pairs, not prose sentences
- **Error context** — Include the inputs that caused the failure
- **Trace IDs** — Correlate across components in a pipeline
- **Severity levels** — `ERROR` for agent-actionable issues, `DEBUG` for flow tracing

## Relationship to SOLID

Agentic code and SOLID are complementary:

- SOLID ensures the code is *correct and maintainable*
- Agentic code ensures the code is *discoverable and navigable by agents*

A module can pass SOLID but fail agentic checks (e.g., well-structured but opaquely named). Both checklists apply.

## Gotchas

- **Generic `utils/` and `helpers/` modules are agent traps.** An agent
  searching for "session cleanup" won't find it in `utils.py`. Name modules
  by domain concept: `session_cleanup.py`, `event_parsing.py`. This repo's
  `tools/` directory is borderline — each script is well-named, but the
  parent folder is generic.
- **`**kwargs` hides the interface from agents.** An agent reading a function
  signature to understand what it accepts sees nothing. This is especially
  common in Python decorator patterns and Flask/FastAPI dependency injection.
  Always type the public surface even if internals use kwargs.
