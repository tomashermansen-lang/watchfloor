# Hermetic test data for `test_response_compat.py`

This tree is the deterministic, committed input that drives byte-equivalence
testing of the dashboard's data-touching endpoints (api-plans, api-sessions,
api-metrics, api-features, etc.).

## Layout

- `dashboard-data/` — the runtime `DASHBOARD_DATA_DIR`. Templates here are
  copied into a per-process tmp tree and rendered with absolute paths
  before each capture/replay.
- `dashboard-data/sessions.jsonl.template` — JSONL events with
  `__PROJECTS_ROOT__/...` placeholders that the harness substitutes with
  the runtime path before launching the stdlib/uvicorn server.
- `projects-root/` — the runtime `PROJECTS_ROOT` and runtime `HOME`. One
  project (`alpha`) with both a docs-level Plan and Feature directory plus
  a root-level execution-plan.yaml.

## Why templates + runtime substitution

The 4 data-dependent endpoints emit absolute paths in their JSON bodies
(e.g., `/api/plans` lists project paths). A purely-committed sessions.jsonl
would still need ABSOLUTE path strings, which differ per machine and per
checkout.

The harness handles this by:

1. Copying templates to `${TMPDIR}/dashboard-hermetic-rt/` (stable per
   process, wiped+rebuilt on demand).
2. Rendering placeholders (`__PROJECTS_ROOT__`, `__HOME__`,
   `__DASHBOARD_DATA_DIR__`) into the runtime tree.
3. Running `git init` inside `projects-root/alpha/` so plan-helpers'
   `git worktree list` resolution succeeds.
4. Setting `PROJECTS_ROOT`, `DASHBOARD_DATA_DIR`, and `HOME` for the
   server child process.
5. Replacing the runtime-tree paths with placeholders in the captured
   response bodies BEFORE writing fixtures (and again in replay before
   diffing) — fixtures-on-disk stay byte-stable across machines.

## Recapture

```
python3 dashboard/tests/test_response_compat.py capture
```

The CLI is self-contained: it boots stdlib serve.py with the hermetic env
vars on a temporary port, captures all 22 fixtures, and shuts the server
down. No external services required.
