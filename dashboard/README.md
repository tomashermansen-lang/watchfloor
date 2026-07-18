# Claude Agent Dashboard

Real-time monitoring dashboard for autonomous Claude Code pipelines. Provides visibility into autopilot sessions, execution plan progress, streaming logs, phase artifacts, and session metrics across parallel AI workloads.

Built for operators running unattended Claude Code pipelines who need a single pane of glass for session state, phase progression, and failure detection.

## What It Monitors

- **Autopilot sessions** -- discovers active tmux-based autopilot runs, streams logs in real time via NDJSON, and surfaces phase-level status (BA, Plan, Implement, QA, etc.)
- **Phase steppers** -- tracks pipeline progression through each flow phase with visual step indicators and gate evaluation
- **Stream events** -- incremental NDJSON streaming of tool calls, subagent activity, orchestrator messages, permission requests, and errors
- **Artifact viewing** -- renders phase artifacts (REQUIREMENTS.md, PLAN.md, DESIGN.md, QA_REPORT.md, etc.) inline from both autopilot and plan-based workflows
- **Execution plans** -- parses YAML/JSON execution plans, merges file-level status from git, and renders DAG-based pipeline trackers
- **Session metrics** -- eight metric categories (M1--M8): tool usage, error tracking, session lifecycle, permission friction, subagent utilization, file activity, task completion, and activity timelines
- **Interactive sessions** -- monitors all active Claude Code sessions across projects via hook events, with click-to-focus VS Code switching

## Architecture

```
Claude Code sessions (any project)
        |
   hooks/report-status.sh  -- async hook, appends JSONL events
        |
        v
  data/sessions.jsonl       -- append-only event log (O_APPEND atomic, rotated at 1MB)
        |
  autopilot-stream.ndjson   -- structured stream events per autopilot task
        |
        v
  serve.py                  -- Python HTTP server (127.0.0.1:8787)
    server/plan_helpers.py       plan loading, discovery, artifact queries
    server/session_helpers.py    session state derivation from JSONL
    server/metrics_helpers.py    M1-M8 metric computation (2s cache)
    server/autopilot_helpers.py  tmux discovery, log parsing, incremental reads
        |
        v
  app/                      -- React SPA (127.0.0.1:5175)
    DashboardShell            tab navigation, hero strip, data freshness
    SessionMonitor            live session grid with status filtering
    Pipeline                  execution plan DAG with task detail drawer
    AutopilotView             session cards, phase stepper, log/stream viewers
    MetricsView               KPI strip + chart panels (Recharts)
```

The backend is a FastAPI application (uvicorn). It reads flat files (JSONL, NDJSON, YAML), shells out to `git` for worktree discovery, and exposes a control surface for driving autopilot sessions (pause/resume, session controls) plus a WebSocket terminal bridge into tmux. No database. The original read-only stdlib server remains as a legacy shim (`_serve_legacy.py`).

The frontend polls the API endpoints and renders with React 19, MUI v7, and Recharts v3.

## Prerequisites

| Dependency | Version | Purpose |
|------------|---------|---------|
| Python | 3.10+ | Backend server |
| Node.js | 18+ | Frontend build and dev server |
| git | any | Worktree discovery, plan status |
| jq | any | Hook event parsing |
| Claude Code | with hooks | Source of session events |

## Setup

```bash
git clone https://github.com/tomashermansen-lang/watchfloor.git
cd watchfloor/dashboard

# Register the session hook in ~/.claude/settings.json
./install.sh

# Install frontend dependencies
cd app && npm install && cd ..
```

## Running

Start both servers:

```bash
start-system dashboard
```

Or start individually:

```bash
# Backend (port 8787)
python3 serve.py

# Frontend dev server (port 5175)
cd app && npm run dev
```

Open `http://127.0.0.1:5175`.

## Running Tests

```bash
# Frontend unit tests
cd app && npx vitest run

# All test suites (backend + hook + security + schema + API)
bash tests/run-all.sh
```

## Screenshots

_Screenshots coming soon._

## API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /api/sessions` | Current session states |
| `GET /api/plans` | Discovered projects with execution plans |
| `GET /api/plan?cwd=` | Structured plan JSON for a project |
| `GET /api/metrics?sid=&since=` | Session metrics (M1--M8) |
| `GET /api/autopilots` | Active autopilot sessions |
| `GET /api/autopilot/stream?task=&offset=` | Incremental NDJSON stream events |
| `GET /api/autopilot/log?task=&offset=` | Incremental log content |
| `GET /api/autopilot/summary?task=` | Parsed autopilot summary |
| `GET /api/autopilot/artifacts?task=` | Available phase artifacts |
| `GET /api/autopilot/artifact?task=&file=` | Raw artifact content |
| `GET /api/plan/artifacts?cwd=&task=` | Task-level doc artifacts |
| `GET /api/plan/artifact?cwd=&task=&file=` | Task artifact content |
| `GET /api/flow-status?cwd=` | Flow phase per feature |
| `GET /api/worktrees?cwd=` | Worktrees for a repo |

All endpoints return JSON. The server binds to `127.0.0.1` only.

## Tech Stack

| Layer | Technology | Version |
|-------|-----------|---------|
| Frontend framework | React | 19 |
| Component library | MUI | v7 |
| Data grid | MUI X Data Grid | v8 (Community) |
| Charts | Recharts | v3 |
| Data fetching | SWR | v2 |
| Markdown rendering | react-markdown + remark-gfm | v10 |
| Build tool | Vite | v7 |
| Type system | TypeScript | 5.9 |
| Test framework | Vitest | v4 |
| Backend | Python FastAPI + uvicorn | -- |
| Styling | Emotion (via MUI) | -- |
| Font | Inter Variable | -- |

## Project Structure

```
dashboard/
  serve.py                   Python HTTP server + route registry
  server/
    plan_helpers.py           plan loading, discovery, status merge
    session_helpers.py        session state derivation from JSONL
    metrics_helpers.py        M1-M8 metric computation
    autopilot_helpers.py      tmux discovery, log/stream parsing
  hooks/
    report-status.sh          Claude Code async hook (appends JSONL)
  app/
    src/
      App.tsx                 root component, tab navigation
      theme.ts                MUI theme (nature palette, dark mode)
      components/
        DashboardShell.tsx    layout shell, hero strip
        SessionMonitor.tsx    live session grid
        Pipeline.tsx          execution plan DAG tracker
        TaskDetailDrawer.tsx  task detail side panel
        autopilot/
          AutopilotView.tsx   autopilot session list + detail
          PhaseStepper.tsx    pipeline phase progress
          LogViewer.tsx       streaming log viewer
          StreamViewer.tsx    NDJSON event stream
          ArtifactDialog.tsx  phase artifact renderer
        metrics/
          MetricsView.tsx     metrics dashboard with KPI strip
          ToolUsage.tsx       tool call analytics
          ErrorTracking.tsx   error rate charts
          ...                 (11 metric panel components)
      hooks/                  custom React hooks
      contexts/               React context providers
      utils/                  CSS variable helpers, shared utilities
  schema/                     JSON Schema for execution plans
  tools/                      PTC scripts (preflight, validation)
  tests/                      backend + hook + security test suites
  data/                       session data (gitignored)
  install.sh                  one-command hook registration
```

## Related Projects

This dashboard is the observability layer for the **Watchfloor pipeline** -- a three-tier execution system (planning, development, autonomy) that runs Claude Code sessions autonomously in tmux.

- **Pipeline source**: this repo -- see the [root README](../README.md)
- **Portfolio**: [tomashermansen-lang.github.io/portfolio](https://tomashermansen-lang.github.io/portfolio)

The pipeline runs unattended. This dashboard provides the visibility: which sessions are active, what phase they are in, whether gates have passed, and where failures occur. It is decoupled from any monitored project -- context is discovered dynamically from git worktrees and hook events.

## License

[MIT](LICENSE)
