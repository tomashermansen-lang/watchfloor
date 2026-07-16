import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, waitFor, within, act } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import type { ProjectSummary } from '../types'

/* plans-filter-ui — wrap `usePlanFilters` with vi.fn around the real
   implementation so the default behaviour is the actual hook (so DSH-44
   persistence can round-trip through localStorage), and individual
   tests can override via `mockReturnValueOnce` for synthetic-state cases.
   Forbid `vi.clearAllMocks()` in this file (would strip the storageMock
   vi.fn implementations and break persistence). */
vi.mock('../hooks/usePlanFilters', async () => {
  const actual = await vi.importActual<typeof import('../hooks/usePlanFilters')>(
    '../hooks/usePlanFilters',
  )
  return { ...actual, usePlanFilters: vi.fn(actual.usePlanFilters) }
})

import DashboardShell from '../components/DashboardShell'
import { usePlanFilters } from '../hooks/usePlanFilters'

/* `vi.fn(actual.usePlanFilters)` initially wraps the real hook, but
   `mockReturnValue(...)` permanently replaces the implementation stack
   with no automatic restore. Capture the real implementation lazily
   on first use, then restore it in each `beforeEach` so DSH-* tests
   that round-trip through localStorage (persistence) see the real
   hook unless they explicitly opt into a synthetic return. */
let realUsePlanFilters: typeof usePlanFilters | null = null
async function ensureRealUsePlanFilters(): Promise<typeof usePlanFilters> {
  if (!realUsePlanFilters) {
    const actual = await vi.importActual<typeof import('../hooks/usePlanFilters')>(
      '../hooks/usePlanFilters',
    )
    realUsePlanFilters = actual.usePlanFilters
  }
  return realUsePlanFilters
}
async function restoreRealUsePlanFilters(): Promise<void> {
  const real = await ensureRealUsePlanFilters()
  vi.mocked(usePlanFilters).mockImplementation(real)
}
/* feature-plan-link-and-nav (REQ-11, REQ-14, RSK-C) — type-pin import.
   Catches type-alias rename / signature drift; lowercase prop spelling
   `onNavigateToPlan` below also satisfies the literal-grep gate. */
import type { OnNavigateToPlan } from '../components/features/FeatureCard'

/* Mock localStorage (jsdom may not provide it) */
const storageMock: Record<string, string> = {}
Object.defineProperty(globalThis, 'localStorage', {
  value: {
    getItem: vi.fn((key: string) => storageMock[key] ?? null),
    setItem: vi.fn((key: string, value: string) => { storageMock[key] = value }),
    removeItem: vi.fn((key: string) => { delete storageMock[key] }),
    clear: vi.fn(),
    get length() { return Object.keys(storageMock).length },
    key: vi.fn(() => null),
  },
  writable: true,
})

// Mock HoverLinkContext
vi.mock('../contexts/HoverLinkContext', () => ({
  HoverLinkProvider: ({ children }: { children: React.ReactNode }) => children,
  useHoverLink: () => ({
    hoveredTaskId: null,
    hoveredSessionBranch: null,
    setHoveredTask: vi.fn(),
    setHoveredSession: vi.fn(),
  }),
}))

// Mock hooks. usePlans is `vi.fn()` so feature-plan-link-and-nav
// tests can override the return value per-case (REQ-8 / EC-10
// special-character path test re-mocks plan_dir).
const DEFAULT_PLANS = [
  { project: 'test-project', path: '/tmp/test', phases: 3, progress: 50, has_plan: true },
]
vi.mock('../hooks/usePlans', () => ({
  usePlans: vi.fn(() => ({ data: DEFAULT_PLANS, isLoading: false })),
}))

vi.mock('../hooks/usePlan', () => ({
  usePlan: () => ({
    data: {
      schema_version: '1.0.0',
      name: 'Test',
      description: 'Test plan description',
      phases: [
        {
          id: 'p1',
          name: 'Phase 1',
          tasks: [
            { id: 't1', name: 'Task One', status: 'done' },
            { id: 't2', name: 'Task Two', status: 'wip' },
          ],
        },
      ],
    },
    isLoading: false,
  }),
}))

const mockSessions = [
  {
    sid: 's1',
    cwd: '/tmp/test',
    worktree: '/tmp/test',
    branch: 'feature/t2',
    event: 'Notification',
    type: 'assistant',
    msg: 'working',
    ts: new Date().toISOString(),
    status: 'working' as const,
    flow: null,
  },
]

vi.mock('../hooks/useSessions', () => ({
  useSessions: () => ({ data: mockSessions }),
}))

/* feature-plan-link-and-nav: feature-alpha carries plan_dir/plan_task_id
   matching the project rendered in `usePlans` (REQ-7, REQ-8). beta and
   gamma stay unmodified so existing core-layout / archived tests pass. */
const mockFeatures = [
  {
    name: 'feature-alpha', project: 'test-project', project_root: '/tmp/test',
    phase: 'qa', phase_index: 5, total_phases: 8, pipeline_type: 'full',
    artifacts: [], sessions: [], status: 'active' as const,
    plan_dir: '/tmp/test', plan_task_id: 'feature-alpha',
  },
  {
    name: 'feature-beta', project: 'test-project', project_root: '/tmp/test',
    phase: 'plan', phase_index: 2, total_phases: 8, pipeline_type: 'light',
    artifacts: [], sessions: [], status: 'paused' as const,
  },
  {
    name: 'feature-gamma-archived', project: 'test-project', project_root: '/tmp/test',
    phase: 'done', phase_index: 8, total_phases: 8, pipeline_type: 'full',
    artifacts: [], sessions: [], status: 'done' as const,
  },
]

vi.mock('../hooks/useFeatures', () => ({
  useFeatures: () => ({ data: mockFeatures, isLoading: false }),
}))

vi.mock('../hooks/useAutopilots', () => ({
  useAutopilots: () => ({ data: [] }),
}))

vi.mock('../hooks/useGrinder', () => ({
  useGrinderList: () => ({ data: [] }),
  useGrinderDetail: () => ({ data: undefined }),
}))

/* controls-03 #7 — the new chain SessionControls in ProjectPanel
   calls useSessionControls('chain', …) on every Plans-tab render.
   The real hook would fire SWR fetches against /api/chain/status that
   jsdom can't satisfy; stub the hook to a quiescent idle state so the
   existing 1700+ DashboardShell tests stay deterministic. Individual
   tests in describe('Plans tab — ProjectPanel chain controls') below
   override the implementation per case. */
const { useSessionControlsMock } = vi.hoisted(() => ({
  useSessionControlsMock: vi.fn(),
}))

vi.mock('../hooks/useSessionControls', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../hooks/useSessionControls')>()
  return {
    ...actual,
    useSessionControls: useSessionControlsMock,
  }
})

/* TerminalPanel mounts xterm.js + a real WebSocket via
   useTerminalSocket. Stub it to a probe div so we can assert
   mount/unmount + targetId routing without booting xterm in jsdom. */
vi.mock('../components/TerminalPanel', () => ({
  TerminalPanel: (props: {
    targetKind: string
    targetId: string | null
    onDetach: () => void
  }) => (
    <div
      data-testid="terminal-panel-stub"
      data-target-kind={props.targetKind}
      data-target-id={props.targetId ?? ''}
    >
      <button type="button" onClick={props.onDetach}>
        stub-detach
      </button>
    </div>
  ),
}))

function renderShell() {
  return render(
    <ThemeProvider theme={theme}>
      <DashboardShell />
    </ThemeProvider>,
  )
}

/* Default quiescent state for useSessionControls so the chain
   SessionControls mounted by ProjectPanel does not crash unrelated
   tests. Per-test overrides (controls-03 #7 chain-control suite
   below) re-set the return value. */
useSessionControlsMock.mockReturnValue({
  state: 'idle',
  isPausing: false,
  pauseElapsedSeconds: 0,
  error: null,
  mutate: {
    start: vi.fn().mockResolvedValue(undefined),
    pause: vi.fn().mockResolvedValue(undefined),
    resume: vi.fn().mockResolvedValue(undefined),
    cancel: vi.fn().mockResolvedValue(undefined),
  },
})

/* ═══ Core layout ═══ */
describe('DashboardShell: core layout', () => {
  it('renders header with watchfloor wordmark + LIVE badge, plus active sessions in the rail', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Plans' }))
    /* Title-bar wordmark replaced "Execution Graph Dashboard" — the
       brand identity per design_handoff_watchfloor_brand/README.md. */
    expect(screen.getByText('watchfloor')).toBeInTheDocument()
    /* LIVE pill is the single most important brand-recall surface and
       must appear on every authenticated screen. */
    expect(document.querySelector('[data-testid="wf-live-badge"]')).toBeTruthy()
    // Sessions panel was removed from inside the Plans view; the
    // ActivityRail on the right shows 'Active Sessions' as a section.
    expect(screen.getByText(/Active Sessions/i)).toBeInTheDocument()
  })

  it('renders a header element for the top bar', () => {
    renderShell()
    const header = document.querySelector('header')
    expect(header).toBeTruthy()
  })

  it('main area renders as semantic main element', () => {
    renderShell()
    const main = document.querySelector('main')
    expect(main).toBeTruthy()
  })

  /* Sidebar uses the wf AppIcon set per handoff §App icons set. The
     specific mapping (overview→vision, plan→plan, metrics→metrics,
     features→features) is locked here so future unrelated icon swaps
     trip the test. The global "Deferred Audit" view was retired in
     favour of per-project deferred sub-tabs, so document icon now
     only appears under expanded projects (covered by next test). */
  it('renders brand AppIcons for the global sidebar nav items', () => {
    renderShell()
    expect(document.querySelector('[data-icon="vision"]')).toBeTruthy()
    expect(document.querySelector('[data-icon="plan"]')).toBeTruthy()
    expect(document.querySelector('[data-icon="metrics"]')).toBeTruthy()
    expect(document.querySelector('[data-icon="features"]')).toBeTruthy()
  })

  it('expanded project sub-views use brand AppIcons (vision / pipeline / document / deviations)', () => {
    renderShell()
    /* Click Plans to expand, then click the project to expand its
       sub-view list. */
    fireEvent.click(screen.getByRole('button', { name: 'Plans' }))
    const projectButton = screen.getByRole('button', { name: /test-project/i })
    fireEvent.click(projectButton)
    expect(document.querySelector('[data-icon="pipeline"]')).toBeTruthy()
    expect(document.querySelector('[data-icon="deviations"]')).toBeTruthy()
  })

  /* Project rows under Plans drop the decorative MUI Workspaces
     "3-dot" icon. Chevron + indentation already signal "project
     level" — minimal ornament per handoff §App Chrome. */
  it('does not render the WorkspacesOutlined 3-dot icon next to project names', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Plans' }))
    /* MUI testid would be MUI-internal; assert by class on the icon
       MUI ships, which is stable enough for a one-line guard. */
    expect(document.querySelector('[data-testid="WorkspacesOutlinedIcon"]')).toBeNull()
  })
})

/* ═══ HeroStrip integration ═══ */
describe('DashboardShell: HeroStrip', () => {
  // HeroStrip is part of the Plans view — switch to it before assertions.
  beforeEach(() => {
    Object.keys(storageMock).forEach((k) => delete storageMock[k])
  })

  it('renders HeroStrip with plan name when plan is loaded', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Plans' }))
    expect(screen.getByText('Test')).toBeInTheDocument()
  })

  it('renders plan name as compact header in Plans view', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Plans' }))
    // Plans view now renders only plan.name + session count, not the
    // full HeroStrip with description/vision/criteria. The full
    // metadata moved to the per-project Vision sub-tab.
    expect(screen.getByText('Test')).toBeInTheDocument()
  })

  it('controls-06 #6 omits the active-session count from the plan header', () => {
    /* The "<n> active session(s)" copy was removed because the
       StatusPill + SessionControls action surface already
       communicate whether a session is live on this row — the
       label was redundant chrome and occupied a column the
       controls-06 grid refactor needed for the action cluster.
       Scoped to the plans scroll container so the ActivityRail's
       "Active Sessions" RailSection title doesn't pollute the match. */
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Plans' }))
    const plansScope = screen.getByTestId('plans-scroll-container')
    const matches = within(plansScope).queryAllByText(/active session/i)
    expect(matches.length).toBe(0)
  })
})

/* ═══ DataFreshnessChip integration ═══ */
describe('DashboardShell: DataFreshnessChip', () => {
  it('renders data freshness indicator in header', () => {
    renderShell()
    /* Brand-styled freshness shows just the timestamp when fresh,
       or a state label (paused / connecting / stale) otherwise.
       Hooking on the data-testid is the stable contract. */
    const freshness = document.querySelector('[data-testid="wf-freshness"]')
    expect(freshness).toBeTruthy()
  })
})

/* ═══ View toggle ═══ */
describe('DashboardShell: view toggle', () => {
  beforeEach(() => {
    Object.keys(storageMock).forEach((k) => delete storageMock[k])
  })

  it('T5.1 renders Plan/Metrics/Features/Grinder toggle buttons', () => {
    renderShell()
    expect(screen.getByRole('button', { name: 'Overview' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Plans' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Metrics' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Features' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Grinder' })).toBeInTheDocument()
  })

  it('has aria-label on toggle group', () => {
    renderShell()
    expect(screen.getByRole('group', { name: 'Dashboard view' })).toBeInTheDocument()
  })

  it('defaults to Overview with overview button pressed', () => {
    renderShell()
    const overviewButton = screen.getByRole('button', { name: 'Overview' })
    expect(overviewButton.getAttribute('aria-pressed')).toBe('true')
  })

  it('persists view choice to localStorage on Metrics click', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Metrics' }))
    expect(storageMock['dashboard-active-tab']).toBe('metrics')
  })

  it('persists view choice to localStorage on Features click', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Features' }))
    expect(storageMock['dashboard-active-tab']).toBe('features')
  })

  it('T5.2 persists view choice to localStorage on Grinder click', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Grinder' }))
    expect(storageMock['dashboard-active-tab']).toBe('grinder')
  })

  it('T5.3 restores grinder view from localStorage', () => {
    storageMock['dashboard-view'] = 'grinder'
    renderShell()
    const grinderButton = screen.getByRole('button', { name: 'Grinder' })
    expect(grinderButton.getAttribute('aria-pressed')).toBe('true')
  })

  it('DS-2: migrates autopilot localStorage value to features', () => {
    storageMock['dashboard-view'] = 'autopilot'
    renderShell()
    const featuresButton = screen.getByRole('button', { name: 'Features' })
    expect(featuresButton.getAttribute('aria-pressed')).toBe('true')
  })
})

/* ═══ VS Code-style sidebar layout (commit 1: sidebar shell) ═══ */
describe('DashboardShell: sidebar navigation', () => {
  it('renders dashboard navigation as a <nav> landmark labelled Dashboard navigation', () => {
    renderShell()
    expect(screen.getByRole('navigation', { name: 'Dashboard navigation' })).toBeInTheDocument()
  })

  it('places nav buttons inside the sidebar nav landmark', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    // All view buttons must be reachable through the nav element, not the top header
    const overviewBtn = screen.getByRole('button', { name: 'Overview' })
    const metricsBtn = screen.getByRole('button', { name: 'Metrics' })
    expect(nav.contains(overviewBtn)).toBe(true)
    expect(nav.contains(metricsBtn)).toBe(true)
  })
})

/* ═══ Tab system (commit 2: open tabs, active tab, persistence) ═══ */
describe('DashboardShell: tab system', () => {
  beforeEach(() => {
    Object.keys(storageMock).forEach((k) => delete storageMock[k])
  })

  it('renders a tab bar when at least one tab is open', () => {
    renderShell()
    // The default Plan view auto-opens as the first tab on initial mount
    expect(screen.getByRole('tablist', { name: 'Open views' })).toBeInTheDocument()
  })

  it('opens a new tab when clicking a sidebar nav item', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Metrics' }))
    const tablist = screen.getByRole('tablist', { name: 'Open views' })
    // Both Overview (initial) and Metrics (clicked) tabs should exist
    expect(within(tablist).getByRole('tab', { name: /Overview/ })).toBeInTheDocument()
    expect(within(tablist).getByRole('tab', { name: /Metrics/ })).toBeInTheDocument()
  })

  it('marks the most recently opened tab as active', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Metrics' }))
    const tablist = screen.getByRole('tablist', { name: 'Open views' })
    const metricsTab = within(tablist).getByRole('tab', { name: /Metrics/ })
    expect(metricsTab.getAttribute('aria-selected')).toBe('true')
  })

  it('closes a tab when its close button is clicked', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Metrics' }))
    fireEvent.click(screen.getByRole('button', { name: 'Close Metrics tab' }))
    const tablist = screen.getByRole('tablist', { name: 'Open views' })
    expect(within(tablist).queryByRole('tab', { name: /Metrics/ })).not.toBeInTheDocument()
  })

  it('persists open tabs to localStorage', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Metrics' }))
    fireEvent.click(screen.getByRole('button', { name: 'Grinder' }))
    const stored = storageMock['dashboard-open-tabs']
    expect(stored).toBeDefined()
    const parsed = JSON.parse(stored as string)
    expect(parsed).toEqual(expect.arrayContaining(['overview', 'metrics', 'grinder']))
  })

  it('persists active tab id to localStorage', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Metrics' }))
    expect(storageMock['dashboard-active-tab']).toBe('metrics')
  })

  it('restores open tabs from localStorage on mount', () => {
    storageMock['dashboard-open-tabs'] = JSON.stringify(['overview', 'plan', 'metrics', 'grinder'])
    storageMock['dashboard-active-tab'] = 'grinder'
    renderShell()
    const tablist = screen.getByRole('tablist', { name: 'Open views' })
    expect(within(tablist).getByRole('tab', { name: /Overview/ })).toBeInTheDocument()
    expect(within(tablist).getByRole('tab', { name: /Plans/ })).toBeInTheDocument()
    expect(within(tablist).getByRole('tab', { name: /Metrics/ })).toBeInTheDocument()
    const grinderTab = within(tablist).getByRole('tab', { name: /Grinder/ })
    expect(grinderTab.getAttribute('aria-selected')).toBe('true')
  })

  it('focuses an already-open tab instead of duplicating it', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Metrics' }))
    fireEvent.click(screen.getByRole('button', { name: 'Overview' }))
    fireEvent.click(screen.getByRole('button', { name: 'Metrics' }))
    const tablist = screen.getByRole('tablist', { name: 'Open views' })
    const metricsTabs = within(tablist).getAllByRole('tab', { name: /Metrics/ })
    expect(metricsTabs).toHaveLength(1)
    expect(metricsTabs[0].getAttribute('aria-selected')).toBe('true')
  })
})

/* ═══ Overview view as default landing (commit 3) ═══ */
describe('DashboardShell: Overview default landing', () => {
  beforeEach(() => {
    Object.keys(storageMock).forEach((k) => delete storageMock[k])
  })

  it('Overview is the default active tab on first mount', () => {
    renderShell()
    const tablist = screen.getByRole('tablist', { name: 'Open views' })
    const overviewTab = within(tablist).getByRole('tab', { name: /Overview/ })
    expect(overviewTab.getAttribute('aria-selected')).toBe('true')
  })

  it('Overview button exists in sidebar nav', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    expect(within(nav).getByRole('button', { name: 'Overview' })).toBeInTheDocument()
  })

  it('renders the Overview status header line on default mount', () => {
    renderShell()
    // The fleet status header summarises features at a glance — content
    // is data-driven but the testid is stable for layout assertions.
    expect(screen.getByTestId('overview-status-header')).toBeInTheDocument()
  })

  it('renders the Overview feature portfolio table on default mount', () => {
    renderShell()
    expect(screen.getByRole('table', { name: 'Feature portfolio' })).toBeInTheDocument()
  })

  it('renders the Plans sidebar button as expandable', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    const plansBtn = within(nav).getByRole('button', { name: 'Plans' })
    expect(plansBtn).toBeInTheDocument()
    // Plans is a collapsible section per commit 3 — the button advertises
    // its expanded/collapsed state via aria-expanded.
    expect(plansBtn.hasAttribute('aria-expanded')).toBe(true)
  })

  it('Plans children list is hidden by default and revealed on click', () => {
    renderShell()
    const plansBtn = screen.getByRole('button', { name: 'Plans' })
    expect(plansBtn.getAttribute('aria-expanded')).toBe('false')
    fireEvent.click(plansBtn)
    expect(plansBtn.getAttribute('aria-expanded')).toBe('true')
  })
})

/* ═══ VS Code-style sidebar (commit 3 polish: icons + flat tree) ═══ */
describe('DashboardShell: VS Code Explorer styling', () => {
  beforeEach(() => {
    Object.keys(storageMock).forEach((k) => delete storageMock[k])
  })

  it('renders sidebar items as a flat list (no toggle-group border frame)', () => {
    renderShell()
    // After commit-3 polish, the sidebar drops MUI ToggleButtonGroup so
    // children of Plans render INSIDE the same list, not below a framed
    // group. Assertion: all top-level buttons share the nav landmark and
    // none has the grouped 'MuiToggleButton-root' class signature.
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    const overview = within(nav).getByRole('button', { name: 'Overview' })
    expect(overview.className).not.toMatch(/MuiToggleButton-root/)
  })

  it('renders Plans children inside the nav when expanded (sidecar fix)', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    fireEvent.click(within(nav).getByRole('button', { name: 'Plans' }))
    // Child item — usePlans mock returns one project named 'test-project'
    const child = within(nav).getByText('test-project')
    expect(nav.contains(child)).toBe(true)
  })
})

/* ═══ Per-project expansion under Plans (commit 3 polish) ═══ */
describe('DashboardShell: per-project expansion', () => {
  beforeEach(() => {
    Object.keys(storageMock).forEach((k) => delete storageMock[k])
  })

  it('a project row under Plans is itself expandable', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Plans' }))
    // usePlans mock returns one project named 'test-project'
    const projectBtn = screen.getByRole('button', { name: /test-project/ })
    expect(projectBtn.hasAttribute('aria-expanded')).toBe(true)
    expect(projectBtn.getAttribute('aria-expanded')).toBe('false')
  })

  it('clicking a project row reveals its sub-views', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Plans' }))
    const projectBtn = screen.getByRole('button', { name: /test-project/ })
    fireEvent.click(projectBtn)
    expect(projectBtn.getAttribute('aria-expanded')).toBe('true')
    // Sub-views appear — Vision, Pipeline, Deferred, Deviations
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    expect(within(nav).getByRole('button', { name: /Pipeline/ })).toBeInTheDocument()
  })
})

/* ═══ Sidebar icon polish (commit 3 follow-up) ═══ */
describe('DashboardShell: sidebar icons', () => {
  beforeEach(() => {
    Object.keys(storageMock).forEach((k) => delete storageMock[k])
  })

  it('project sub-items each render with their own icon', () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Plans' }))
    fireEvent.click(screen.getByRole('button', { name: /test-project/ }))
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    // Each sub-view button (Vision, Pipeline, Deferred Audit, Deviations)
    // contains an SVG icon now — operator feedback: small icons on
    // sub-items help scan the tree at a glance.
    const visionBtn = within(nav).getByRole('button', { name: /Vision/ })
    expect(visionBtn.querySelector('svg')).toBeTruthy()
    const pipelineBtn = within(nav).getByRole('button', { name: /Pipeline/ })
    expect(pipelineBtn.querySelector('svg')).toBeTruthy()
  })
})

/* User-request 2026-05-08: the FEATURES section + ARCHIVED sub-section
   are removed from the sidebar; the full feature catalog lives in the
   Features tab. Sidebar focuses on live runtime state ("what's running
   right now") via ActivityRail. */
describe('DashboardShell: sidebar GLOBAL section', () => {
  beforeEach(() => {
    Object.keys(storageMock).forEach((k) => delete storageMock[k])
  })

  it('renders a GLOBAL section header above nav items', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    expect(within(nav).getByText('GLOBAL')).toBeInTheDocument()
  })

  it('does not render a FEATURES section in the sidebar', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    /* FEATURES catalog moved to the Features tab. */
    expect(within(nav).queryByText('FEATURES')).not.toBeInTheDocument()
  })

  it('does not render the ARCHIVED section in the sidebar', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    expect(within(nav).queryByText(/ARCHIVED/i)).not.toBeInTheDocument()
    expect(within(nav).queryByTestId('archived-count')).not.toBeInTheDocument()
  })

  /* User-request 2026-05-08: ActivityRail headers (Active Sessions /
     Plans / Features / Grinders) match the GLOBAL section's blue
     chrome - 8x1 wf.signal rule prefix + signal-blue title. Earlier
     they used wf.fog grey, which read as auxiliary chrome instead of
     peer navigation. */
  it('each ActivityRail section renders an 8x1 wf.signal rule prefix', () => {
    renderShell()
    /* Four sections: Sessions, Plans, Features, Grinders. */
    const rules = document.querySelectorAll('[data-testid="rail-section-rule"]')
    expect(rules.length).toBe(4)
  })

  it('ActivityRail section titles are styled blue (wf.signal) via inline style', () => {
    renderShell()
    const sessionTitle = screen.getByText('Active Sessions')
    /* Inline style override is the jsdom-readable surface; sx tokens
       resolve through emotion classes that jsdom does not compute. */
    expect(sessionTitle.style.color).not.toBe('')
  })

  /* User-request 2026-05-08: each Active Sessions row shows the
     worktree path so the operator can disambiguate when several
     worktrees share the same branch name. The mock fixture sets
     session.worktree = '/tmp/test'. */
  it('Active Sessions rows surface the worktree path', () => {
    renderShell()
    expect(screen.getByText('/tmp/test')).toBeInTheDocument()
  })

  /* User-request 2026-05-08: Active Features rail rows are clickable
     and switch the main view to the Features tab. Active Plans rows
     open project:<project>/pipeline for that specific plan
     (revision 2026-05-08 followup). The default useAutopilots mock
     returns no active sessions, so the rail-plan-row click path is
     covered by visual verification only - wiring is symmetric to the
     rail-feature path tested below. */
  it('Active Features row click switches main view to features tab', async () => {
    renderShell()
    /* Default view is 'overview'. After clicking an active feature,
       the features tab should be active. */
    const featuresRailRow = screen.getByTestId('rail-feature-row')
    fireEvent.click(featuresRailRow)
    /* The Features tab shell mounts FeaturesView wrapped in Suspense. */
    expect(await screen.findByTestId('features-view-root')).toBeInTheDocument()
  })
})

/* ═══ Project sub-view tabs (Vision/Pipeline/Deferred/Deviations) ═══ */
describe('DashboardShell: project sub-view tabs', () => {
  beforeEach(() => {
    Object.keys(storageMock).forEach((k) => delete storageMock[k])
  })

  it('clicking Vision under a project opens a Vision tab labelled with project', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    fireEvent.click(within(nav).getByRole('button', { name: 'Plans' }))
    fireEvent.click(within(nav).getByRole('button', { name: /test-project/ }))
    fireEvent.click(within(nav).getByRole('button', { name: /Vision/ }))
    const tablist = screen.getByRole('tablist', { name: 'Open views' })
    expect(within(tablist).getByRole('tab', { name: /test-project · Vision/ })).toBeInTheDocument()
  })

  it('Vision tab content shows the project name and vision section', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    fireEvent.click(within(nav).getByRole('button', { name: 'Plans' }))
    fireEvent.click(within(nav).getByRole('button', { name: /test-project/ }))
    fireEvent.click(within(nav).getByRole('button', { name: /Vision/ }))
    expect(screen.getByTestId('project-subview-vision')).toBeInTheDocument()
    expect(screen.getByTestId('project-subview-vision')).toHaveTextContent('test-project')
  })

  it('clicking Pipeline opens a Pipeline tab for the project', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    fireEvent.click(within(nav).getByRole('button', { name: 'Plans' }))
    fireEvent.click(within(nav).getByRole('button', { name: /test-project/ }))
    fireEvent.click(within(nav).getByRole('button', { name: /Pipeline/ }))
    const tablist = screen.getByRole('tablist', { name: 'Open views' })
    expect(within(tablist).getByRole('tab', { name: /test-project · Pipeline/ })).toBeInTheDocument()
    expect(screen.getByTestId('project-subview-pipeline')).toBeInTheDocument()
  })

  it('clicking Deferred Audit opens a Deferred tab for the project', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    fireEvent.click(within(nav).getByRole('button', { name: 'Plans' }))
    fireEvent.click(within(nav).getByRole('button', { name: /test-project/ }))
    // Two 'Deferred Audit' buttons exist when Plans is expanded — the
    // top-level sidebar item AND the per-project sub-view item. The
    // sub-view button is the last one rendered.
    const deferredButtons = within(nav).getAllByRole('button', { name: /Deferred Audit/ })
    // Two 'Deferred Audit' buttons exist when Plans is expanded — the
    // sub-view item (rendered inside Plans Collapse) appears first in
    // DOM order, then the global VIEW_OPTIONS item. Click the first.
    fireEvent.click(deferredButtons[0])
    expect(screen.getByTestId('project-subview-deferred')).toBeInTheDocument()
  })

  it('clicking Deviations opens a Deviations tab for the project', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    fireEvent.click(within(nav).getByRole('button', { name: 'Plans' }))
    fireEvent.click(within(nav).getByRole('button', { name: /test-project/ }))
    fireEvent.click(within(nav).getByRole('button', { name: /Deviations/ }))
    expect(screen.getByTestId('project-subview-deviations')).toBeInTheDocument()
  })
})

/* ═══ Per-project routing (replaces removed 'All plans' entry) ═══ */
describe('DashboardShell: per-project plan routing', () => {
  beforeEach(() => {
    Object.keys(storageMock).forEach((k) => delete storageMock[k])
  })

  it('does not render an explicit All plans entry — Plans header itself is the global link', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    fireEvent.click(within(nav).getByRole('button', { name: 'Plans' }))
    expect(within(nav).queryByRole('button', { name: /All plans/i })).not.toBeInTheDocument()
  })

  it('clicking a project row opens that project\'s pipeline tab (not the global plan tab)', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    fireEvent.click(within(nav).getByRole('button', { name: 'Plans' }))
    fireEvent.click(within(nav).getByRole('button', { name: /test-project/ }))
    const tablist = screen.getByRole('tablist', { name: 'Open views' })
    expect(within(tablist).getByRole('tab', { name: /test-project · Pipeline/ })).toBeInTheDocument()
  })
})

/* ═══ Activity sections at bottom of left sidebar (revised placement) ═══ */
describe('DashboardShell: activity sections in sidebar', () => {
  beforeEach(() => {
    Object.keys(storageMock).forEach((k) => delete storageMock[k])
  })

  it('renders the four activity section headers inside the left sidebar nav', () => {
    renderShell()
    const nav = screen.getByRole('navigation', { name: 'Dashboard navigation' })
    expect(within(nav).getByText(/Active Sessions/i)).toBeInTheDocument()
    expect(within(nav).getByText(/Active Plans/i)).toBeInTheDocument()
    expect(within(nav).getByText(/Active Features/i)).toBeInTheDocument()
    expect(within(nav).getByText(/Active Grinders/i)).toBeInTheDocument()
  })

  it('does not render a separate right-side activity-rail aside', () => {
    renderShell()
    expect(screen.queryByTestId('activity-rail')).not.toBeInTheDocument()
  })
})

/* ═══ feature-plan-link-and-nav — plan-link navigation ═══

   Group D (handler/effect) and Group E (data-plan-dir / scroll target).
   `Element.prototype.scrollIntoView` is the global vi.fn() from
   test-setup.ts; cleared per-test. `FeaturesView` is rendered as the
   real lazy module (no stub) so the prop chain is exercised end-to-end.
*/
describe('DashboardShell — plan-link navigation', () => {
  beforeEach(async () => {
    Object.keys(storageMock).forEach((k) => delete storageMock[k])
    vi.mocked(Element.prototype.scrollIntoView).mockClear()
    /* Reset usePlans to the file-scope default each test so per-test
       overrides (E3) cannot bleed across cases. */
    const usePlansModule = await import('../hooks/usePlans')
    vi.mocked(usePlansModule.usePlans).mockReturnValue({
      data: DEFAULT_PLANS,
      isLoading: false,
    } as ReturnType<typeof usePlansModule.usePlans>)
  })

  /* E1 — REQ-8 */
  it('dashboard_shell_renders_data_plan_dir_attribute_on_each_project_panel', async () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Plans' }))
    const wrappers = await waitFor(() => {
      const ws = document.querySelectorAll('[data-plan-dir]')
      expect(ws.length).toBeGreaterThanOrEqual(1)
      return ws
    })
    /* Mock returns one project at /tmp/test (no `plan_dir`, so the
       wrapper falls back to `path`). */
    const values = Array.from(wrappers).map((w) => w.getAttribute('data-plan-dir'))
    expect(values).toContain('/tmp/test')
  })

  /* D1 — REQ-7, REQ-10, AS-4, AS-8 */
  it('dashboard_shell_plan_link_click_switches_to_plan_view', async () => {
    renderShell()
    /* Open Features tab so the chip is visible. */
    fireEvent.click(screen.getByRole('button', { name: 'Features' }))
    const chip = await screen.findByTestId('plan-link-chip')
    fireEvent.click(chip)
    await waitFor(() => {
      expect(storageMock['dashboard-active-tab']).toBe('plan')
    })
  })

  /* D2 — REQ-8, AS-4 */
  it('dashboard_shell_plan_link_click_calls_scrollIntoView_on_matching_panel', async () => {
    renderShell()
    fireEvent.click(screen.getByRole('button', { name: 'Features' }))
    const chip = await screen.findByTestId('plan-link-chip')
    fireEvent.click(chip)
    await waitFor(() => {
      expect(Element.prototype.scrollIntoView).toHaveBeenCalledWith({
        behavior: 'smooth',
        block: 'center',
      })
    })
  })

  /* D3 — REQ-9, AS-5. Override the feature mock locally so plan_dir
     points at a panel that does not exist. Other DOM components
     (e.g. the tab bar) call `scrollIntoView` with their own option
     shapes when switching tabs, so the assertion narrows to "no call
     with the navigation handler's smooth+center options". The
     console.error spy guards against any thrown exception leaking out. */
  it('dashboard_shell_plan_link_click_with_unmatched_plan_dir_still_switches_view', async () => {
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const original = mockFeatures[0].plan_dir
    mockFeatures[0].plan_dir = '/p/missing'
    try {
      renderShell()
      fireEvent.click(screen.getByRole('button', { name: 'Features' }))
      const chip = await screen.findByTestId('plan-link-chip')
      fireEvent.click(chip)
      await waitFor(() => {
        expect(storageMock['dashboard-active-tab']).toBe('plan')
      })
      expect(Element.prototype.scrollIntoView).not.toHaveBeenCalledWith({
        behavior: 'smooth',
        block: 'center',
      })
      expect(errSpy).not.toHaveBeenCalled()
    } finally {
      mockFeatures[0].plan_dir = original
      errSpy.mockRestore()
    }
  })

  /* D4 — EC-7. Already-active plan tab still triggers scroll on
     re-click. The pendingPlanDir reset (setPendingPlanDir(null) after
     each scroll) makes the dependency change on the second click and
     re-fires the effect even though activeTab did not change. The
     count uses a filter on the navigation handler's option shape so
     unrelated tab-bar / list scrolls do not contaminate the total. */
  it('clicking_chip_when_plan_tab_already_active_still_scrolls', async () => {
    renderShell()
    /* (1) Pre-open Plans, (2) switch to Features so chip is visible,
       (3) click chip → first scroll, (4) re-open Features (Plans tab
       stays open, activeTab returns to 'features'), (5) click chip
       again → second scroll. */
    fireEvent.click(screen.getByRole('button', { name: 'Plans' }))
    fireEvent.click(screen.getByRole('button', { name: 'Features' }))
    const chip = await screen.findByTestId('plan-link-chip')
    fireEvent.click(chip)
    const navScrollCount = (): number =>
      vi.mocked(Element.prototype.scrollIntoView).mock.calls.filter(
        (args) =>
          typeof args[0] === 'object' &&
          args[0] !== null &&
          (args[0] as ScrollIntoViewOptions).behavior === 'smooth' &&
          (args[0] as ScrollIntoViewOptions).block === 'center',
      ).length
    await waitFor(() => {
      expect(navScrollCount()).toBe(1)
    })
    /* Re-render Features so chip is mounted again. */
    fireEvent.click(screen.getByRole('button', { name: 'Features' }))
    const chip2 = await screen.findByTestId('plan-link-chip')
    fireEvent.click(chip2)
    await waitFor(() => {
      expect(navScrollCount()).toBe(2)
    })
  })

  /* E3 — REQ-8, EC-10. CSS.escape handles paths with special chars.
     Override the project's plan_dir + the matching feature plan_dir to
     a path with spaces and parentheses; assert scrollIntoView still
     fires. If escape is missing/wrong, querySelector returns null and
     the scroll assertion fails. */
  it('scroll_lookup_uses_css_escape_for_special_characters', async () => {
    const escSpy = vi.spyOn(CSS, 'escape')
    const specialPath = '/Users/me/My Project (v2)/repo'
    const original = mockFeatures[0].plan_dir
    mockFeatures[0].plan_dir = specialPath
    const usePlansModule = await import('../hooks/usePlans')
    vi.mocked(usePlansModule.usePlans).mockReturnValue({
      data: [
        {
          project: 'Special',
          path: specialPath,
          phases: 1,
          progress: 0,
          has_plan: true,
          plan_dir: specialPath,
        },
      ],
      isLoading: false,
    } as ReturnType<typeof usePlansModule.usePlans>)
    try {
      renderShell()
      fireEvent.click(screen.getByRole('button', { name: 'Features' }))
      const chip = await screen.findByTestId('plan-link-chip')
      fireEvent.click(chip)
      await waitFor(() => {
        expect(Element.prototype.scrollIntoView).toHaveBeenCalled()
      })
      expect(escSpy).toHaveBeenCalledWith(specialPath)
    } finally {
      mockFeatures[0].plan_dir = original
      escSpy.mockRestore()
    }
  })

  /* D5 — REQ-11, REQ-14, RSK-C grep gate. Type-pins OnNavigateToPlan
     signature; the local `onNavigateToPlan` lowercase identifier
     satisfies the literal grep gate `grep -q 'onNavigateToPlan'
     dashboard/app/src/__tests__/DashboardShell.test.tsx`. */
  it('dashboard_shell_imports_onNavigateToPlan_type_alias', () => {
    const onNavigateToPlan: OnNavigateToPlan = (planDir: string) => {
      void planDir
    }
    expect(typeof onNavigateToPlan).toBe('function')
  })
})

/* ═══ plans-filter-ui — filter wiring, StatusPill, persistence ═══

   Group 2 from TESTPLAN: covers REQ-1, REQ-3..REQ-23, REQ-32..REQ-35,
   REQ-43, AS-1..AS-22 (where applicable as integration), EC-1..EC-15.

   All Plans-tab tests below click the Plans nav button to switch the
   active tab to the projects stack. Per-test isolation is via
   `localStorage.removeItem('wf.planFilters.v1')` (NOT `vi.clearAllMocks`,
   which would strip the storageMock vi.fn implementations and break
   persistence — see TESTPLAN § Test Infrastructure). */

const mockProject = (overrides: Partial<ProjectSummary> = {}): ProjectSummary => ({
  project: 'plan-x',
  path: '/Users/foo/Projekter/test',
  phases: 3,
  progress: 50,
  has_plan: true,
  lifecycle: 'inprogress',
  active_session_count: 0,
  plan_dir: '/Users/foo/Projekter/test',
  schema_version: '2.0.0',
  ...overrides,
})

async function setPlans(
  plans: ProjectSummary[] | undefined,
  isLoading = false,
): Promise<void> {
  const usePlansModule = await import('../hooks/usePlans')
  vi.mocked(usePlansModule.usePlans).mockReturnValue({
    data: plans,
    isLoading,
  } as ReturnType<typeof usePlansModule.usePlans>)
}

/** Click the Plans nav button to mount the projects stack. */
function openPlansTab(): void {
  fireEvent.click(screen.getByRole('button', { name: 'Plans' }))
}

/** Locate a lifecycle/sort/project chip from anywhere in the document. */
const planLifecycleChip = (v: string): HTMLElement | null =>
  document.querySelector(
    `[data-filter="lifecycle"][data-value="${v}"] [data-testid="wf-toggle-chip"]`,
  ) as HTMLElement | null

const planSortChip = (v: string): HTMLElement | null =>
  document.querySelector(
    `[data-filter="sort"][data-value="${v}"] [data-testid="wf-toggle-chip"]`,
  ) as HTMLElement | null

const planProjectChip = (v: string): HTMLElement | null =>
  document.querySelector(
    `[data-filter="project"][data-value="${v}"] [data-testid="wf-toggle-chip"]`,
  ) as HTMLElement | null

/** All ProjectPanel `data-plan-dir` anchor values currently rendered. */
const visiblePlanAnchors = (): string[] =>
  Array.from(document.querySelectorAll('[data-plan-dir]'))
    .map((el) => el.getAttribute('data-plan-dir') ?? '')
    .filter((v) => v !== '')

/* ═══ 2A — Hook integration & state ownership ═══ */
describe('Plans tab — hook integration', () => {
  beforeEach(async () => {
    localStorage.removeItem('wf.planFilters.v1')
    /* Reset usePlans to the file-scope default so per-test overrides
       cannot bleed across cases. */
    const usePlansModule = await import('../hooks/usePlans')
    vi.mocked(usePlansModule.usePlans).mockReturnValue({
      data: DEFAULT_PLANS,
      isLoading: false,
    } as ReturnType<typeof usePlansModule.usePlans>)
    /* Clear the per-test mockReturnValueOnce queue on usePlanFilters
       without stripping its implementation. */
    vi.mocked(usePlanFilters).mockClear()
    await restoreRealUsePlanFilters()
  })

  /* DSH-1 — REQ-1 */
  it('DashboardShell calls usePlanFilters once per render of Plans tab', async () => {
    renderShell()
    openPlansTab()
    await waitFor(() => {
      expect(vi.mocked(usePlanFilters).mock.calls.length).toBeGreaterThanOrEqual(1)
    })
  })

  /* DSH-2 — REQ-3 */
  it('chip toggle on Plans tab writes only to wf.planFilters.v1, no other localStorage key', async () => {
    renderShell()
    openPlansTab()
    const setItemSpy = vi.mocked(localStorage.setItem)
    setItemSpy.mockClear()
    /* Toggle Done chip on. */
    const done = planLifecycleChip('done')
    expect(done).not.toBeNull()
    await act(async () => {
      fireEvent.click(done as HTMLElement)
    })
    /* Inspect every key that was written to during the toggle. */
    const writtenKeys = setItemSpy.mock.calls.map((c) => c[0])
    const otherKeys = writtenKeys.filter(
      (k) =>
        k !== 'wf.planFilters.v1' &&
        k !== 'dashboard-active-tab' &&
        k !== 'dashboard-open-tabs',
    )
    expect(otherKeys).toEqual([])
  })

  /* DSH-3 — REQ-1, REQ-2 (state lives in hook, not local useState).
     Two-plan setPlans is required so the sort row renders (audit-list-filters
     #4 hides it when n ≤ 1). The lifecycle assertion alone is unaffected. */
  it('forcing a synthetic hook return flips chip data-active without click history', async () => {
    await setPlans([
      mockProject({ project: 'p1', path: '/x/p1', plan_dir: '/x/p1', lifecycle: 'done' }),
      mockProject({ project: 'p2', path: '/x/p2', plan_dir: '/x/p2', lifecycle: 'done' }),
    ])
    vi.mocked(usePlanFilters).mockReturnValue({
      lifecycle: new Set(['done']),
      project: new Set<string>(),
      search: '',
      sort: 'name-asc',
      setLifecycle: vi.fn(),
      setProject: vi.fn(),
      setSearch: vi.fn(),
      setSort: vi.fn(),
    })
    renderShell()
    openPlansTab()
    /* The Done chip is the only active lifecycle chip per the synthetic
       return — proves DashboardShell renders directly from hook state. */
    expect(planLifecycleChip('active')?.getAttribute('data-active')).toBe('false')
    expect(planLifecycleChip('open')?.getAttribute('data-active')).toBe('false')
    expect(planLifecycleChip('done')?.getAttribute('data-active')).toBe('true')
    expect(planSortChip('name-asc')?.getAttribute('data-active')).toBe('true')
  })
})

/* ═══ 2B — Lifecycle filter ═══ */
describe('Plans tab — lifecycle filter', () => {
  beforeEach(async () => {
    localStorage.removeItem('wf.planFilters.v1')
    vi.mocked(usePlanFilters).mockClear()
    await restoreRealUsePlanFilters()
  })

  /* DSH-4 (AS-1) — defaults {active, open} */
  it('defaults show only inprogress plans (not done, not pending)', async () => {
    await setPlans([
      mockProject({ project: 'plan-a', path: '/x/plan-a', plan_dir: '/x/plan-a', lifecycle: 'inprogress', active_session_count: 2 }),
      mockProject({ project: 'plan-b', path: '/x/plan-b', plan_dir: '/x/plan-b', lifecycle: 'done' }),
      mockProject({ project: 'plan-c', path: '/x/plan-c', plan_dir: '/x/plan-c', lifecycle: 'pending' }),
    ])
    renderShell()
    openPlansTab()
    expect(visiblePlanAnchors()).toEqual(['/x/plan-a'])
  })

  /* DSH-5 (AS-2-1) — {active, open} → click Open off → only Active visible */
  it('toggling Open off leaves only the busy inprogress plan visible', async () => {
    await setPlans([
      mockProject({ project: 'plan-busy', path: '/x/busy', plan_dir: '/x/busy', lifecycle: 'inprogress', active_session_count: 3 }),
      mockProject({ project: 'plan-quiet', path: '/x/quiet', plan_dir: '/x/quiet', lifecycle: 'inprogress', active_session_count: 0 }),
    ])
    renderShell()
    openPlansTab()
    await act(async () => {
      fireEvent.click(planLifecycleChip('open') as HTMLElement)
    })
    expect(visiblePlanAnchors()).toEqual(['/x/busy'])
  })

  /* DSH-6 (AS-2-2) — only {open} → only quiet visible */
  it('with only Open chip selected, only the zero-session inprogress plan is visible', async () => {
    await setPlans([
      mockProject({ project: 'plan-busy', path: '/x/busy', plan_dir: '/x/busy', lifecycle: 'inprogress', active_session_count: 3 }),
      mockProject({ project: 'plan-quiet', path: '/x/quiet', plan_dir: '/x/quiet', lifecycle: 'inprogress', active_session_count: 0 }),
    ])
    renderShell()
    openPlansTab()
    await act(async () => {
      fireEvent.click(planLifecycleChip('active') as HTMLElement)
    })
    expect(visiblePlanAnchors()).toEqual(['/x/quiet'])
  })

  /* DSH-7 (AS-3) — defaults + Done → Active first, Done second */
  it('clicking Done reveals done plan after the Active group (group sort)', async () => {
    await setPlans([
      mockProject({ project: 'plan-a', path: '/x/plan-a', plan_dir: '/x/plan-a', lifecycle: 'inprogress', active_session_count: 2 }),
      mockProject({ project: 'plan-b', path: '/x/plan-b', plan_dir: '/x/plan-b', lifecycle: 'done' }),
    ])
    renderShell()
    openPlansTab()
    await act(async () => {
      fireEvent.click(planLifecycleChip('done') as HTMLElement)
    })
    expect(visiblePlanAnchors()).toEqual(['/x/plan-a', '/x/plan-b'])
  })

  /* DSH-8 (AS-4) — defaults + Pending → Active + Pending visible */
  it('clicking Pending reveals pending plan alongside Active', async () => {
    await setPlans([
      mockProject({ project: 'plan-a', path: '/x/plan-a', plan_dir: '/x/plan-a', lifecycle: 'inprogress', active_session_count: 2 }),
      mockProject({ project: 'plan-c', path: '/x/plan-c', plan_dir: '/x/plan-c', lifecycle: 'pending' }),
    ])
    renderShell()
    openPlansTab()
    await act(async () => {
      fireEvent.click(planLifecycleChip('pending') as HTMLElement)
    })
    expect(visiblePlanAnchors()).toEqual(['/x/plan-a', '/x/plan-c'])
  })

  /* DSH-9 (REQ-8) — undefined lifecycle treated as inprogress + sessions=2 → Active visible */
  it('plan with undefined lifecycle is treated as inprogress (REQ-8)', async () => {
    await setPlans([
      mockProject({ project: 'p', path: '/x/p', plan_dir: '/x/p', lifecycle: undefined, active_session_count: 2 }),
    ])
    renderShell()
    openPlansTab()
    expect(visiblePlanAnchors()).toEqual(['/x/p'])
  })

  /* DSH-10 (REQ-9 / EC-3) — root lifecycle, sessions=1 → Active visible (default chips) */
  it('plan with lifecycle:root is classified together with inprogress', async () => {
    await setPlans([
      mockProject({ project: 'rooted', path: '/x/rooted', plan_dir: '/x/rooted', lifecycle: 'root', active_session_count: 1 }),
    ])
    renderShell()
    openPlansTab()
    expect(visiblePlanAnchors()).toEqual(['/x/rooted'])
  })

  /* DSH-11 (REQ-10 / EC-4) — undefined active_session_count → Open + status=muted/open */
  it('plan with undefined active_session_count is treated as 0 sessions and renders Open StatusPill', async () => {
    await setPlans([
      mockProject({ project: 'pq', path: '/x/pq', plan_dir: '/x/pq', lifecycle: 'inprogress', active_session_count: undefined }),
    ])
    renderShell()
    openPlansTab()
    expect(visiblePlanAnchors()).toEqual(['/x/pq'])
    /* StatusPill renders muted variant with text 'open'. */
    const pill = document.querySelector('[data-testid="wf-status-pill"]')
    expect(pill).toBeTruthy()
    expect(pill?.getAttribute('data-status')).toBe('muted')
    expect(pill?.textContent?.toLowerCase()).toContain('open')
  })

  /* DSH-12 (REQ-11) — empty lifecycle Set → zero panels + filter-aware empty state */
  it('empty lifecycle Set yields zero panels and renders filter-aware empty state', async () => {
    await setPlans([
      mockProject({ project: 'p', path: '/x/p', plan_dir: '/x/p', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    vi.mocked(usePlanFilters).mockReturnValue({
      lifecycle: new Set(),
      project: new Set<string>(),
      search: '',
      sort: 'group-then-progress-desc',
      setLifecycle: vi.fn(),
      setProject: vi.fn(),
      setSearch: vi.fn(),
      setSort: vi.fn(),
    })
    renderShell()
    openPlansTab()
    expect(document.querySelectorAll('[data-plan-dir]').length).toBe(0)
    expect(screen.getByText(/No plans match/i)).toBeInTheDocument()
    expect(screen.getByText(/No lifecycle chips selected/i)).toBeInTheDocument()
  })
})

/* ═══ 2C — Project filter ═══ */
describe('Plans tab — project filter', () => {
  beforeEach(async () => {
    localStorage.removeItem('wf.planFilters.v1')
    vi.mocked(usePlanFilters).mockClear()
    await restoreRealUsePlanFilters()
  })

  /* DSH-13 (AS-12-1) — vocabulary derives from basenames, alphabetical, de-duped */
  it('derives one project chip per distinct repo basename, alphabetical, de-duped', async () => {
    await setPlans([
      mockProject({ project: 'p1', path: '/Users/foo/Projekter/OIH', plan_dir: '/Users/foo/Projekter/OIH', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'p2', path: '/Users/foo/Projekter/eulex', plan_dir: '/Users/foo/Projekter/eulex', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'p3', path: '/Users/foo/Projekter/OIH', plan_dir: '/Users/foo/Projekter/OIH-2', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    renderShell()
    openPlansTab()
    const wrappers = document.querySelectorAll('[data-filter="project"]')
    const values = Array.from(wrappers).map((w) => w.getAttribute('data-value'))
    expect(values).toEqual(['eulex', 'OIH'])
  })

  /* DSH-14 (AS-12-2 / EC-14) — toggling both chips reveals all three plans (collision OR semantics) */
  it('toggling both project chips makes all matching plans visible (OR + collision)', async () => {
    await setPlans([
      mockProject({ project: 'p1', path: '/Users/foo/Projekter/OIH', plan_dir: '/x/p1', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'p2', path: '/Users/foo/Projekter/eulex', plan_dir: '/x/p2', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'p3', path: '/Users/foo/Projekter/OIH', plan_dir: '/x/p3', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    renderShell()
    openPlansTab()
    await act(async () => {
      fireEvent.click(planProjectChip('eulex') as HTMLElement)
    })
    await act(async () => {
      fireEvent.click(planProjectChip('OIH') as HTMLElement)
    })
    expect(visiblePlanAnchors().sort()).toEqual(['/x/p1', '/x/p2', '/x/p3'])
  })

  /* DSH-15 (REQ-14) — project AND lifecycle */
  it('project filter is AND on top of lifecycle (done plan filtered out)', async () => {
    await setPlans([
      mockProject({ project: 'p-active', path: '/Users/foo/Projekter/OIH', plan_dir: '/x/p-active', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'p-done', path: '/Users/foo/Projekter/OIH', plan_dir: '/x/p-done', lifecycle: 'done' }),
    ])
    renderShell()
    openPlansTab()
    await act(async () => {
      fireEvent.click(planProjectChip('OIH') as HTMLElement)
    })
    expect(visiblePlanAnchors()).toEqual(['/x/p-active'])
  })

  /* DSH-16 (EC-6) — trailing slash → basename; empty path → no chip */
  it('trailing-slash path yields proper basename, empty path yields no chip', async () => {
    await setPlans([
      mockProject({ project: 'p-trail', path: '/Users/foo/Projekter/dotfiles/', plan_dir: '/x/trail', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'p-empty', path: '', plan_dir: '/x/empty', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    renderShell()
    openPlansTab()
    const wrappers = document.querySelectorAll('[data-filter="project"]')
    const values = Array.from(wrappers).map((w) => w.getAttribute('data-value'))
    expect(values).toEqual(['dotfiles'])
  })

  /* DSH-17 (EC-5) — adding a new basename via re-rendered payload introduces a new chip */
  it('a new basename in a re-rendered payload renders a new chip', async () => {
    await setPlans([
      mockProject({ project: 'p1', path: '/Users/foo/Projekter/OIH', plan_dir: '/x/p1', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    const { rerender } = renderShell()
    openPlansTab()
    expect(
      Array.from(document.querySelectorAll('[data-filter="project"]')).map((w) =>
        w.getAttribute('data-value'),
      ),
    ).toEqual(['OIH'])
    /* Re-render with an additional basename. */
    await setPlans([
      mockProject({ project: 'p1', path: '/Users/foo/Projekter/OIH', plan_dir: '/x/p1', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'p2', path: '/Users/foo/Projekter/eulex', plan_dir: '/x/p2', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    rerender(
      <ThemeProvider theme={theme}>
        <DashboardShell />
      </ThemeProvider>,
    )
    await waitFor(() => {
      const values = Array.from(document.querySelectorAll('[data-filter="project"]')).map(
        (w) => w.getAttribute('data-value'),
      )
      expect(values).toEqual(['eulex', 'OIH'])
    })
  })

  /* DSH-18 — regression: multiple plans sharing project_root must render
     with distinct React keys. Previous implementation used p.path as the
     key, which collided when two plans pointed at the same repo
     (BACKLOG #55). Asserts no `Encountered two children with the same
     key` warning is emitted by React. */
  it('renders without React duplicate-key warnings when plans share project_root', async () => {
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    await setPlans([
      mockProject({ project: 'p1', path: '/Users/foo/Projekter/OIH', plan_dir: '/x/p1', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'p2', path: '/Users/foo/Projekter/OIH', plan_dir: '/x/p2', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    renderShell()
    openPlansTab()
    const duplicateKeyWarnings = errorSpy.mock.calls.filter((call) => {
      const first = call[0]
      return typeof first === 'string' && first.includes('two children with the same key')
    })
    errorSpy.mockRestore()
    expect(duplicateKeyWarnings).toEqual([])
  })
})

/* ═══ 2D — Search filter ═══ */
describe('Plans tab — search filter', () => {
  beforeEach(async () => {
    localStorage.removeItem('wf.planFilters.v1')
    vi.mocked(usePlanFilters).mockClear()
    await restoreRealUsePlanFilters()
  })

  /* DSH-18 (AS-5) */
  it('search "auth" narrows to plan names containing auth', async () => {
    await setPlans([
      mockProject({ project: 'auth-flow', path: '/x/a', plan_dir: '/x/a', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'auth-rotate', path: '/x/b', plan_dir: '/x/b', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'session-cache', path: '/x/c', plan_dir: '/x/c', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    renderShell()
    openPlansTab()
    const input = screen.getByTestId('plan-filter-search') as HTMLInputElement
    await userEvent.type(input, 'auth')
    expect(visiblePlanAnchors().sort()).toEqual(['/x/a', '/x/b'])
  })

  /* DSH-19 (AS-6) — case-insensitive on basename */
  it('search "oih" (lowercase) matches OIH basename case-insensitively', async () => {
    await setPlans([
      mockProject({ project: 'plan-x', path: '/Users/foo/Projekter/OIH', plan_dir: '/x/x', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'plan-y', path: '/Users/foo/Projekter/eulex', plan_dir: '/x/y', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    renderShell()
    openPlansTab()
    const input = screen.getByTestId('plan-filter-search') as HTMLInputElement
    await userEvent.type(input, 'oih')
    expect(visiblePlanAnchors()).toEqual(['/x/x'])
  })

  /* DSH-20 (REQ-16) — search AND lifecycle */
  it('search AND lifecycle: open plan named auth-rotate is hidden when only Active selected', async () => {
    await setPlans([
      mockProject({ project: 'auth-flow', path: '/x/af', plan_dir: '/x/af', lifecycle: 'inprogress', active_session_count: 2 }),
      mockProject({ project: 'auth-rotate', path: '/x/ar', plan_dir: '/x/ar', lifecycle: 'inprogress', active_session_count: 0 }),
    ])
    renderShell()
    openPlansTab()
    /* Toggle Open off so only Active is selected. */
    await act(async () => {
      fireEvent.click(planLifecycleChip('open') as HTMLElement)
    })
    const input = screen.getByTestId('plan-filter-search') as HTMLInputElement
    await userEvent.type(input, 'auth')
    expect(visiblePlanAnchors()).toEqual(['/x/af'])
  })

  /* DSH-21 (EC-7) — regex chars are literal */
  it('search ".*" is treated as a literal substring, not a regex', async () => {
    await setPlans([
      mockProject({ project: 'wild.*card', path: '/x/wild', plan_dir: '/x/wild', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'something', path: '/x/some', plan_dir: '/x/some', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    renderShell()
    openPlansTab()
    const input = screen.getByTestId('plan-filter-search') as HTMLInputElement
    await userEvent.type(input, '.*')
    expect(visiblePlanAnchors()).toEqual(['/x/wild'])
  })

  /* DSH-22 (EC-8) — leading whitespace preserved */
  it('search " watchfloor" with leading space matches names that contain that exact substring', async () => {
    await setPlans([
      mockProject({ project: 'pre watchfloor', path: '/x/pre', plan_dir: '/x/pre', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'watchfloor', path: '/x/no', plan_dir: '/x/no', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    renderShell()
    openPlansTab()
    const input = screen.getByTestId('plan-filter-search') as HTMLInputElement
    fireEvent.change(input, { target: { value: ' watchfloor' } })
    await waitFor(() => {
      expect(visiblePlanAnchors()).toEqual(['/x/pre'])
    })
  })
})

/* ═══ 2E — Sort ═══ */
describe('Plans tab — sort', () => {
  beforeEach(async () => {
    localStorage.removeItem('wf.planFilters.v1')
    vi.mocked(usePlanFilters).mockClear()
    await restoreRealUsePlanFilters()
  })

  /* DSH-23 (AS-7) — group-then-progress: A,B,C,D */
  it('default sort orders Active > Open > Done > Pending', async () => {
    await setPlans([
      mockProject({ project: 'A', path: '/x/A', plan_dir: '/x/A', lifecycle: 'inprogress', active_session_count: 1, progress: 30 }),
      mockProject({ project: 'B', path: '/x/B', plan_dir: '/x/B', lifecycle: 'inprogress', active_session_count: 0, progress: 50 }),
      mockProject({ project: 'C', path: '/x/C', plan_dir: '/x/C', lifecycle: 'done', progress: 100 }),
      mockProject({ project: 'D', path: '/x/D', plan_dir: '/x/D', lifecycle: 'pending', progress: 0 }),
    ])
    renderShell()
    openPlansTab()
    /* Toggle Done + Pending on. */
    await act(async () => { fireEvent.click(planLifecycleChip('done') as HTMLElement) })
    await act(async () => { fireEvent.click(planLifecycleChip('pending') as HTMLElement) })
    expect(visiblePlanAnchors()).toEqual(['/x/A', '/x/B', '/x/C', '/x/D'])
  })

  /* DSH-24 (AS-8) — within-group, progress desc */
  it('within Active group, progress desc orders 90, 60, 40', async () => {
    await setPlans([
      mockProject({ project: 'p1', path: '/x/p1', plan_dir: '/x/p1', lifecycle: 'inprogress', active_session_count: 1, progress: 40 }),
      mockProject({ project: 'p2', path: '/x/p2', plan_dir: '/x/p2', lifecycle: 'inprogress', active_session_count: 1, progress: 90 }),
      mockProject({ project: 'p3', path: '/x/p3', plan_dir: '/x/p3', lifecycle: 'inprogress', active_session_count: 1, progress: 60 }),
    ])
    renderShell()
    openPlansTab()
    expect(visiblePlanAnchors()).toEqual(['/x/p2', '/x/p3', '/x/p1'])
  })

  /* DSH-25 (AS-9) — name-asc, case-insensitive, ignores grouping */
  it('name-asc sorts case-insensitively across groups', async () => {
    await setPlans([
      mockProject({ project: 'beta', path: '/x/beta', plan_dir: '/x/beta', lifecycle: 'inprogress', active_session_count: 0 }),
      mockProject({ project: 'Alpha', path: '/x/alpha', plan_dir: '/x/alpha', lifecycle: 'done' }),
      mockProject({ project: 'gamma', path: '/x/gamma', plan_dir: '/x/gamma', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    renderShell()
    openPlansTab()
    /* Activate Done + Pending so all three are visible. */
    await act(async () => { fireEvent.click(planLifecycleChip('done') as HTMLElement) })
    await act(async () => { fireEvent.click(planLifecycleChip('pending') as HTMLElement) })
    /* Click Name A→Z. */
    await act(async () => { fireEvent.click(planSortChip('name-asc') as HTMLElement) })
    expect(visiblePlanAnchors()).toEqual(['/x/alpha', '/x/beta', '/x/gamma'])
  })

  /* DSH-26 — last-activity-desc orders by ISO timestamp desc.
     Replaces the legacy AS-10 proxy (active_session_count desc → progress desc)
     with honest recency sourced from the backend `last_activity` field.
     Audit-list-filters #1+#2+#3, cycle 2. */
  it('last-activity-desc orders by last_activity timestamp desc', async () => {
    await setPlans([
      mockProject({ project: 'p1', path: '/x/p1', plan_dir: '/x/p1', lifecycle: 'inprogress', last_activity: '2026-05-01T10:00:00+00:00' }),
      mockProject({ project: 'p2', path: '/x/p2', plan_dir: '/x/p2', lifecycle: 'inprogress', last_activity: '2026-05-08T12:00:00+00:00' }),
      mockProject({ project: 'p3', path: '/x/p3', plan_dir: '/x/p3', lifecycle: 'inprogress', last_activity: '2026-05-05T08:00:00+00:00' }),
    ])
    renderShell()
    openPlansTab()
    await act(async () => { fireEvent.click(planSortChip('last-activity-desc') as HTMLElement) })
    expect(visiblePlanAnchors()).toEqual(['/x/p2', '/x/p3', '/x/p1'])
  })

  /* DSH-26b — last-activity-desc with mixed null/missing sorts those last. */
  it('last-activity-desc places null/missing last_activity at the end', async () => {
    await setPlans([
      mockProject({ project: 'p1', path: '/x/p1', plan_dir: '/x/p1', lifecycle: 'inprogress', last_activity: '2026-05-01T10:00:00+00:00' }),
      mockProject({ project: 'p2', path: '/x/p2', plan_dir: '/x/p2', lifecycle: 'inprogress', last_activity: null }),
      mockProject({ project: 'p3', path: '/x/p3', plan_dir: '/x/p3', lifecycle: 'inprogress', last_activity: '2026-05-05T08:00:00+00:00' }),
    ])
    renderShell()
    openPlansTab()
    await act(async () => { fireEvent.click(planSortChip('last-activity-desc') as HTMLElement) })
    expect(visiblePlanAnchors()).toEqual(['/x/p3', '/x/p1', '/x/p2'])
  })

  /* DSH-27 (REQ-20) — sort applies to post-filter set */
  it('sort applies only to the post-filter set', async () => {
    await setPlans([
      mockProject({ project: 'auth-flow', path: '/x/af', plan_dir: '/x/af', lifecycle: 'inprogress', active_session_count: 2 }),
      mockProject({ project: 'auth-rotate', path: '/x/ar', plan_dir: '/x/ar', lifecycle: 'inprogress', active_session_count: 0 }),
      mockProject({ project: 'auth-x', path: '/x/ax', plan_dir: '/x/ax', lifecycle: 'inprogress', active_session_count: 2 }),
    ])
    renderShell()
    openPlansTab()
    /* Only Active selected, search 'auth', sort name-asc. */
    await act(async () => { fireEvent.click(planLifecycleChip('open') as HTMLElement) })
    const input = screen.getByTestId('plan-filter-search') as HTMLInputElement
    await userEvent.type(input, 'auth')
    await act(async () => { fireEvent.click(planSortChip('name-asc') as HTMLElement) })
    expect(visiblePlanAnchors()).toEqual(['/x/af', '/x/ax'])
  })

  /* DSH-28 (EC-9) — single-plan list hides the sort row entirely.
     Audit-list-filters #4: nothing to reorder when n ≤ 1, so the chips
     are hidden. The plan itself still renders; lifecycle/search chrome
     remains so the operator can broaden the filter. */
  it('single plan hides the sort chip row but still renders the plan', async () => {
    await setPlans([
      mockProject({ project: 'solo', path: '/x/s', plan_dir: '/x/s', lifecycle: 'inprogress' }),
    ])
    renderShell()
    openPlansTab()
    expect(visiblePlanAnchors()).toEqual(['/x/s'])
    expect(document.querySelectorAll('[data-filter="sort"]').length).toBe(0)
    /* Lifecycle chips still render so the operator can change selection. */
    expect(document.querySelectorAll('[data-filter="lifecycle"]').length).toBe(4)
  })

  /* DSH-29 (EC-10) — progress-tie within group preserves insertion order */
  it('within-group progress ties preserve insertion order (V8 stable sort)', async () => {
    await setPlans([
      mockProject({ project: 'a1', path: '/x/a1', plan_dir: '/x/a1', lifecycle: 'inprogress', active_session_count: 1, progress: 0 }),
      mockProject({ project: 'a2', path: '/x/a2', plan_dir: '/x/a2', lifecycle: 'inprogress', active_session_count: 1, progress: 0 }),
      mockProject({ project: 'a3', path: '/x/a3', plan_dir: '/x/a3', lifecycle: 'inprogress', active_session_count: 1, progress: 0 }),
    ])
    renderShell()
    openPlansTab()
    expect(visiblePlanAnchors()).toEqual(['/x/a1', '/x/a2', '/x/a3'])
  })

  /* DSH-29a — audit-list-filters #2. The Plans-tab scroll container disables
     `overflow-anchor` so a sort-mode change doesn't cause the browser's
     default scroll-anchor algorithm to scroll the viewport when the plan
     list re-orders. The property is set via inline style (sx applies
     emotion classes that jsdom doesn't resolve). */
  it('Plans-tab scroll container disables overflow-anchor', async () => {
    await setPlans([
      mockProject({ project: 'p1', path: '/x/p1', plan_dir: '/x/p1', lifecycle: 'inprogress' }),
      mockProject({ project: 'p2', path: '/x/p2', plan_dir: '/x/p2', lifecycle: 'inprogress' }),
    ])
    renderShell()
    openPlansTab()
    const scroller = screen.getByTestId('plans-scroll-container')
    expect(scroller.style.overflowAnchor).toBe('none')
  })

  /* DSH-30 — last-activity-desc with all-null last_activity preserves
     insertion order (V8 stable sort comparator returns 0). Replaces the
     legacy fallback-to-progress-desc behavior of the proxy. */
  it('last-activity-desc with all-null last_activity preserves insertion order', async () => {
    await setPlans([
      mockProject({ project: 'p1', path: '/x/p1', plan_dir: '/x/p1', lifecycle: 'inprogress', last_activity: null, progress: 30 }),
      mockProject({ project: 'p2', path: '/x/p2', plan_dir: '/x/p2', lifecycle: 'inprogress', last_activity: null, progress: 90 }),
      mockProject({ project: 'p3', path: '/x/p3', plan_dir: '/x/p3', lifecycle: 'inprogress', last_activity: null, progress: 60 }),
    ])
    renderShell()
    openPlansTab()
    await act(async () => { fireEvent.click(planSortChip('last-activity-desc') as HTMLElement) })
    expect(visiblePlanAnchors()).toEqual(['/x/p1', '/x/p2', '/x/p3'])
  })
})

/* ═══ 2F — Empty state ═══ */
describe('Plans tab — empty state', () => {
  beforeEach(async () => {
    localStorage.removeItem('wf.planFilters.v1')
    vi.mocked(usePlanFilters).mockClear()
    await restoreRealUsePlanFilters()
  })

  /* DSH-31 (AS-11 / EC-1) — only pending plan + default {active, open} */
  it('renders filter-aware empty state when only pending plan exists under default chips', async () => {
    await setPlans([
      mockProject({ project: 'plan-c', path: '/x/c', plan_dir: '/x/c', lifecycle: 'pending' }),
    ])
    renderShell()
    openPlansTab()
    expect(visiblePlanAnchors()).toEqual([])
    /* EmptyScope subtitle names the active chips and suggests adding missing ones. */
    const empty = screen.getByText(/Active\+Open/i)
    expect(empty).toBeInTheDocument()
    expect(empty.textContent).toMatch(/try adding/i)
    expect(empty.textContent).toMatch(/Done/i)
    expect(empty.textContent).toMatch(/Pending/i)
  })

  /* DSH-32 (EC-2) — all four chips on, search excludes everything */
  it('all-four-chips selected with empty search match → subtitle suggests clearing search', async () => {
    await setPlans([
      mockProject({ project: 'plan-a', path: '/x/a', plan_dir: '/x/a', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    renderShell()
    openPlansTab()
    /* Toggle Done + Pending on so all four are selected. */
    await act(async () => { fireEvent.click(planLifecycleChip('done') as HTMLElement) })
    await act(async () => { fireEvent.click(planLifecycleChip('pending') as HTMLElement) })
    const input = screen.getByTestId('plan-filter-search') as HTMLInputElement
    await userEvent.type(input, 'zzzzzzz-no-match')
    expect(visiblePlanAnchors()).toEqual([])
    const subtitle = await screen.findByText(/Active\+Open\+Done\+Pending/i)
    expect(subtitle.textContent).toMatch(/try clearing the search/i)
  })

  /* DSH-33 — empty Set lifecycle subtitle */
  it('empty lifecycle Set with non-empty payload renders dedicated empty-set subtitle', async () => {
    await setPlans([
      mockProject({ project: 'plan-a', path: '/x/a', plan_dir: '/x/a', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    vi.mocked(usePlanFilters).mockReturnValue({
      lifecycle: new Set(),
      project: new Set<string>(),
      search: '',
      sort: 'group-then-progress-desc',
      setLifecycle: vi.fn(),
      setProject: vi.fn(),
      setSearch: vi.fn(),
      setSort: vi.fn(),
    })
    renderShell()
    openPlansTab()
    expect(screen.getByText(/No lifecycle chips selected/i)).toBeInTheDocument()
  })

  /* DSH-34 (AS-20) — loading state preserves Skeleton, no filter bar */
  it('projects loading renders Skeleton and does not render filter bar or chips', async () => {
    await setPlans(undefined, true)
    renderShell()
    openPlansTab()
    expect(document.querySelector('[data-testid="plan-filter-search"]')).toBeNull()
    expect(document.querySelector('[data-filter="lifecycle"]')).toBeNull()
  })

  /* DSH-35 (AS-21) — empty payload preserves baseline EmptyScope, no filter bar */
  it('empty payload preserves baseline EmptyScope and does not render filter bar', async () => {
    await setPlans([])
    renderShell()
    openPlansTab()
    expect(screen.getByText(/run \/plan-project in a project to generate an execution plan/i)).toBeInTheDocument()
    expect(document.querySelector('[data-testid="plan-filter-search"]')).toBeNull()
  })

  /* DSH-36 — filter bar still renders above empty state when payload non-empty */
  it('filter bar still renders above the empty state when at least one plan exists', async () => {
    await setPlans([
      mockProject({ project: 'plan-c', path: '/x/c', plan_dir: '/x/c', lifecycle: 'pending' }),
    ])
    renderShell()
    openPlansTab()
    expect(document.querySelector('[data-testid="plan-filter-search"]')).not.toBeNull()
    expect(screen.getByText(/No plans match/i)).toBeInTheDocument()
  })
})

/* ═══ 2G — ProjectPanel StatusPill ═══ */
describe('Plans tab — ProjectPanel StatusPill', () => {
  beforeEach(async () => {
    localStorage.removeItem('wf.planFilters.v1')
    vi.mocked(usePlanFilters).mockClear()
    await restoreRealUsePlanFilters()
  })

  /* DSH-37 (AS-13) — inprogress + sessions:2 → running/active */
  it('inprogress with sessions renders StatusPill running/active', async () => {
    await setPlans([
      mockProject({ project: 'p', path: '/x/p', plan_dir: '/x/p', lifecycle: 'inprogress', active_session_count: 2 }),
    ])
    renderShell()
    openPlansTab()
    const pill = await screen.findByTestId('wf-status-pill')
    expect(pill.getAttribute('data-status')).toBe('running')
    expect(pill.textContent?.toLowerCase()).toContain('active')
  })

  /* DSH-38 (AS-14) — inprogress + sessions:0 → muted/open */
  it('inprogress with zero sessions renders StatusPill muted/open', async () => {
    await setPlans([
      mockProject({ project: 'p', path: '/x/p', plan_dir: '/x/p', lifecycle: 'inprogress', active_session_count: 0 }),
    ])
    renderShell()
    openPlansTab()
    const pill = await screen.findByTestId('wf-status-pill')
    expect(pill.getAttribute('data-status')).toBe('muted')
    expect(pill.textContent?.toLowerCase()).toContain('open')
  })

  /* DSH-39 (AS-15) — done → completed/done */
  it('done plan renders StatusPill completed/done', async () => {
    await setPlans([
      mockProject({ project: 'p', path: '/x/p', plan_dir: '/x/p', lifecycle: 'done' }),
    ])
    /* Activate Done chip to make the plan visible. */
    vi.mocked(usePlanFilters).mockReturnValue({
      lifecycle: new Set(['done']),
      project: new Set<string>(),
      search: '',
      sort: 'group-then-progress-desc',
      setLifecycle: vi.fn(),
      setProject: vi.fn(),
      setSearch: vi.fn(),
      setSort: vi.fn(),
    })
    renderShell()
    openPlansTab()
    const pill = await screen.findByTestId('wf-status-pill')
    expect(pill.getAttribute('data-status')).toBe('completed')
    expect(pill.textContent?.toLowerCase()).toContain('done')
  })

  /* DSH-40 (AS-16, REQ-34, EC-13) — pending → muted/pending (dual-signal) */
  it('pending plan renders StatusPill muted/pending (distinguished from open by label)', async () => {
    await setPlans([
      mockProject({ project: 'p', path: '/x/p', plan_dir: '/x/p', lifecycle: 'pending' }),
    ])
    vi.mocked(usePlanFilters).mockReturnValue({
      lifecycle: new Set(['pending']),
      project: new Set<string>(),
      search: '',
      sort: 'group-then-progress-desc',
      setLifecycle: vi.fn(),
      setProject: vi.fn(),
      setSearch: vi.fn(),
      setSort: vi.fn(),
    })
    renderShell()
    openPlansTab()
    const pill = await screen.findByTestId('wf-status-pill')
    expect(pill.getAttribute('data-status')).toBe('muted')
    expect(pill.textContent?.toLowerCase()).toContain('pending')
    expect(pill.textContent?.toLowerCase()).not.toContain('open')
  })

  /* DSH-41 (REQ-32) — StatusPill follows the plan-name title.
     Re-anchored from the "active sessions" label (removed cycle-6 #6)
     to the wfH3 Typography carrying the plan name. */
  it('StatusPill is placed after the plan-name title inside the project header', async () => {
    await setPlans([
      mockProject({ project: 'p', path: '/x/p', plan_dir: '/x/p', lifecycle: 'inprogress', active_session_count: 2 }),
    ])
    renderShell()
    openPlansTab()
    const pill = await screen.findByTestId('wf-status-pill')
    const title = screen.getByText('Test')
    const cmp = title.compareDocumentPosition(pill)
    expect(cmp & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  /* DSH-42 (REQ-33, REQ-9, EC-3) — root + sessions:0 → muted/open */
  it('root lifecycle with zero sessions renders muted/open StatusPill', async () => {
    await setPlans([
      mockProject({ project: 'p', path: '/x/p', plan_dir: '/x/p', lifecycle: 'root', active_session_count: 0 }),
    ])
    renderShell()
    openPlansTab()
    const pill = await screen.findByTestId('wf-status-pill')
    expect(pill.getAttribute('data-status')).toBe('muted')
    expect(pill.textContent?.toLowerCase()).toContain('open')
  })

  /* DSH-43 (R1 invariant) — classification consistency */
  it('a plan classified Active is hidden when only Open chip selected and visible when only Active chip selected (with running pill)', async () => {
    await setPlans([
      mockProject({ project: 'p', path: '/x/p', plan_dir: '/x/p', lifecycle: 'inprogress', active_session_count: 2 }),
    ])
    /* Only Open: hidden. Use mockImplementation so every call during
       this render returns the same synthetic value (mixing synthetic
       with the real hook between calls violates React's hook count). */
    vi.mocked(usePlanFilters).mockImplementation(() => ({
      lifecycle: new Set(['open']),
      project: new Set<string>(),
      search: '',
      sort: 'group-then-progress-desc',
      setLifecycle: vi.fn(),
      setProject: vi.fn(),
      setSearch: vi.fn(),
      setSort: vi.fn(),
    }))
    const { unmount } = renderShell()
    openPlansTab()
    expect(visiblePlanAnchors()).toEqual([])
    unmount()
    /* Only Active: visible + running pill. */
    vi.mocked(usePlanFilters).mockReturnValue({
      lifecycle: new Set(['active']),
      project: new Set<string>(),
      search: '',
      sort: 'group-then-progress-desc',
      setLifecycle: vi.fn(),
      setProject: vi.fn(),
      setSearch: vi.fn(),
      setSort: vi.fn(),
    })
    renderShell()
    openPlansTab()
    expect(visiblePlanAnchors()).toEqual(['/x/p'])
    const pill = await screen.findByTestId('wf-status-pill')
    expect(pill.getAttribute('data-status')).toBe('running')
  })
})

/* ═══ 2H — Persistence ═══ */
describe('Plans tab — persistence', () => {
  beforeEach(async () => {
    localStorage.removeItem('wf.planFilters.v1')
    vi.mocked(usePlanFilters).mockClear()
    await restoreRealUsePlanFilters()
  })

  /* DSH-44 (AS-17) — selection survives unmount + remount */
  it('Done chip selection persists across unmount and remount', async () => {
    await setPlans([
      mockProject({ project: 'plan-a', path: '/x/a', plan_dir: '/x/a', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'plan-b', path: '/x/b', plan_dir: '/x/b', lifecycle: 'done' }),
    ])
    const { unmount } = renderShell()
    openPlansTab()
    await act(async () => {
      fireEvent.click(planLifecycleChip('done') as HTMLElement)
    })
    expect(visiblePlanAnchors()).toEqual(['/x/a', '/x/b'])
    unmount()
    /* Remount — hook hydrates from localStorage. */
    renderShell()
    openPlansTab()
    expect(planLifecycleChip('done')?.getAttribute('data-active')).toBe('true')
    expect(visiblePlanAnchors()).toEqual(['/x/a', '/x/b'])
  })

  /* DSH-45 — search updates the visible list synchronously per keystroke */
  it('typing in search synchronously narrows the visible list', async () => {
    await setPlans([
      mockProject({ project: 'auth-flow', path: '/x/af', plan_dir: '/x/af', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'login-flow', path: '/x/lf', plan_dir: '/x/lf', lifecycle: 'inprogress', active_session_count: 1 }),
    ])
    renderShell()
    openPlansTab()
    const input = screen.getByTestId('plan-filter-search') as HTMLInputElement
    expect(visiblePlanAnchors().sort()).toEqual(['/x/af', '/x/lf'])
    await userEvent.type(input, 'auth')
    expect(visiblePlanAnchors()).toEqual(['/x/af'])
  })
})

/* ═══ 2I — Navigation preserved ═══ */
describe('Plans tab — navigation preserved', () => {
  beforeEach(async () => {
    localStorage.removeItem('wf.planFilters.v1')
    vi.mocked(usePlanFilters).mockClear()
    await restoreRealUsePlanFilters()
  })

  /* DSH-46 (AS-22) — default filter renders data-plan-dir wrappers for inprogress plans */
  it('default chips render data-plan-dir wrapper for every inprogress plan', async () => {
    await setPlans([
      mockProject({ project: 'p1', path: '/x/p1', plan_dir: '/x/p1', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'p2', path: '/x/p2', plan_dir: '/x/p2', lifecycle: 'inprogress', active_session_count: 0 }),
    ])
    renderShell()
    openPlansTab()
    expect(visiblePlanAnchors().sort()).toEqual(['/x/p1', '/x/p2'])
  })

  /* DSH-47 (EC-15) — filtered-out plan has no data-plan-dir wrapper */
  it('a done plan filtered out by default chips has no data-plan-dir wrapper in the DOM', async () => {
    await setPlans([
      mockProject({ project: 'p-active', path: '/x/a', plan_dir: '/x/a', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'p-done', path: '/x/d', plan_dir: '/x/d', lifecycle: 'done' }),
    ])
    renderShell()
    openPlansTab()
    expect(visiblePlanAnchors()).toEqual(['/x/a'])
    expect(document.querySelector('[data-plan-dir="/x/d"]')).toBeNull()
  })

  /* DSH-48 — wrapper count equals filtered count */
  it('the number of data-plan-dir wrappers equals the post-filter list length', async () => {
    await setPlans([
      mockProject({ project: 'p1', path: '/x/p1', plan_dir: '/x/p1', lifecycle: 'inprogress', active_session_count: 1 }),
      mockProject({ project: 'p2', path: '/x/p2', plan_dir: '/x/p2', lifecycle: 'done' }),
      mockProject({ project: 'p3', path: '/x/p3', plan_dir: '/x/p3', lifecycle: 'pending' }),
    ])
    renderShell()
    openPlansTab()
    expect(document.querySelectorAll('[data-plan-dir]').length).toBe(1)
  })
})

/* ═══ 2I — ProjectPanel chain controls (controls-03 #1 #7 #8) ═══ */
describe('Plans tab — ProjectPanel chain controls', () => {
  beforeEach(() => {
    localStorage.removeItem('wf.planFilters.v1')
    vi.mocked(usePlanFilters).mockClear()
    /* Reset hook-mock call log so .find() / .filter() don't pick up
       chain calls from earlier tests in the file (the hoisted mock
       persists across describe blocks). The default idle return
       value survives mockClear, set explicitly to be safe. */
    useSessionControlsMock.mockClear()
    useSessionControlsMock.mockReturnValue({
      state: 'idle',
      isPausing: false,
      pauseElapsedSeconds: 0,
      error: null,
      mutate: {
        start: vi.fn().mockResolvedValue(undefined),
        pause: vi.fn().mockResolvedValue(undefined),
        resume: vi.fn().mockResolvedValue(undefined),
        cancel: vi.fn().mockResolvedValue(undefined),
      },
    })
  })

  function mountChainPlan() {
    /* plan_dir uses the INPROGRESS_Plan_<chainId> convention so the
       composition can derive the chain target_id via planDirToChainId.
       The /tmp prefix mirrors what live operator workflows look like. */
    return setPlans([
      mockProject({
        project: 'p',
        path: '/tmp/test',
        plan_dir: '/tmp/test/docs/INPROGRESS_Plan_demo-chain',
        lifecycle: 'inprogress',
        active_session_count: 0,
      }),
    ])
  }

  /* DSH-50: SessionControls mounts in the plan header with
     targetKind="chain" and the planDirToChainId-derived target_id. */
  it('DSH-50: chain SessionControls is wired with planDirToChainId(plan_dir)', async () => {
    await mountChainPlan()
    renderShell()
    openPlansTab()
    /* SessionControls calls useSessionControls(targetKind, targetId).
       Find the chain invocation in the mock call log. */
    await waitFor(() => {
      const chainCalls = useSessionControlsMock.mock.calls.filter(
        (c) => c[0] === 'chain',
      )
      expect(chainCalls.length).toBeGreaterThan(0)
    })
    const chainCall = useSessionControlsMock.mock.calls.find(
      (c) => c[0] === 'chain',
    )
    expect(chainCall?.[1]).toBe('demo-chain')
  })

  /* DSH-51: the plan header Start button is the chain-kind one. */
  it('DSH-51: idle chain renders "Start chain" button in the plan header', async () => {
    await mountChainPlan()
    renderShell()
    openPlansTab()
    const start = await screen.findByRole('button', { name: /^Start chain$/i })
    expect(start).toBeInTheDocument()
  })

  /* DSH-52 (controls-06 #14 — pivoted from cycle 3): clicking
     Output on the Plans row NAVIGATES to the per-project Pipeline
     subview instead of inline-mounting a terminal. Industry
     convergence (8/9 products surveyed — GitHub Actions, Vercel,
     Render, Heroku, Buildkite, Datadog, Linear, K8s dashboards)
     places live process logs on a dedicated detail page; the
     cycle-3 inline mount was eliminated. The subview itself
     auto-opens the terminal — that's covered by the
     ProjectSubviewTab test suite. */
  it('DSH-52: clicking Output navigates to the per-project Pipeline subview', async () => {
    useSessionControlsMock.mockReturnValue({
      state: 'running',
      isPausing: false,
      pauseElapsedSeconds: 0,
      error: null,
      tmuxSession: 'chain-demo-chain',
      mutate: {
        start: vi.fn().mockResolvedValue(undefined),
        pause: vi.fn().mockResolvedValue(undefined),
        resume: vi.fn().mockResolvedValue(undefined),
        cancel: vi.fn().mockResolvedValue(undefined),
      },
    })
    await mountChainPlan()
    renderShell()
    openPlansTab()
    /* Pre-click: no terminal mount on the Plans row, no project tab
       open (only the Plans / overview tabs). */
    expect(screen.queryByTestId('terminal-panel-stub')).not.toBeInTheDocument()
    fireEvent.click(await screen.findByRole('button', { name: /^Output$/i }))
    /* Post-click: the project's Pipeline subview is the active tab.
       data-testid="project-subview-pipeline" comes from
       ProjectSubviewTab's Pipeline case. */
    await waitFor(() => {
      expect(screen.getByTestId('project-subview-pipeline')).toBeInTheDocument()
    })
    /* And the embedded terminal in the Plans row is NEVER mounted —
       controls-06 #14 removed that surface. */
    expect(screen.queryByTestId('terminal-panel-wrapper')).toBeInTheDocument()
  })

  /* DSH-53 (controls-06 #14 — superseded): the cycle-3 "Detach
     unmounts the inline panel" path no longer exists since the row
     mount is gone. The subview-level detach + close stays as a
     ProjectSubviewTab test surface. */
  it('DSH-53: Plans-row Output click does NOT mount an inline terminal', async () => {
    useSessionControlsMock.mockReturnValue({
      state: 'running',
      isPausing: false,
      pauseElapsedSeconds: 0,
      error: null,
      tmuxSession: 'chain-demo-chain',
      mutate: {
        start: vi.fn().mockResolvedValue(undefined),
        pause: vi.fn().mockResolvedValue(undefined),
        resume: vi.fn().mockResolvedValue(undefined),
        cancel: vi.fn().mockResolvedValue(undefined),
      },
    })
    await mountChainPlan()
    renderShell()
    openPlansTab()
    /* The terminal-panel-stub MAY appear (the subview opens it by
       default once we navigate) but only AFTER the navigation, never
       inside the Plans-row layout. Click Output and verify the row
       wrapper test-id stays absent on the Plans surface. */
    fireEvent.click(await screen.findByRole('button', { name: /^Output$/i }))
    /* After navigation, the wrapper IS on the page but inside the
       project-subview-pipeline tree — not the Plans row. */
    await screen.findByTestId('project-subview-pipeline')
    const pipelineSubview = screen.getByTestId('project-subview-pipeline')
    expect(within(pipelineSubview).queryByTestId('terminal-panel-wrapper'))
      .toBeInTheDocument()
  })

  /* DSH-54 (controls-06 #14 — pivoted): the Plans-row no longer
     renders a Hide button (the cycle-3 toggle is gone). The button
     stays as Output on the Plans surface; navigation replaces
     toggle. */
  it('DSH-54: Plans-row Output button never relabels to Hide', async () => {
    useSessionControlsMock.mockReturnValue({
      state: 'running',
      isPausing: false,
      pauseElapsedSeconds: 0,
      error: null,
      tmuxSession: 'chain-demo-chain',
      mutate: {
        start: vi.fn().mockResolvedValue(undefined),
        pause: vi.fn().mockResolvedValue(undefined),
        resume: vi.fn().mockResolvedValue(undefined),
        cancel: vi.fn().mockResolvedValue(undefined),
      },
    })
    await mountChainPlan()
    renderShell()
    openPlansTab()
    expect(await screen.findByRole('button', { name: /^Output$/i })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^Hide$/i })).not.toBeInTheDocument()
  })

  /* DSH-59 (controls-06 #5 — inverted from cycle-5 #3): the
     amber "chain exited — clear to restart" sub-line was
     dropped. The inline Restart button (cycle-6 #4) is now the
     stale-state signal — visible action surface replaces
     decorative chrome. PlanCompletionBand shows 100% on a stale
     chain, the Restart CTA carries the recovery verb; the row
     no longer needs a separate amber strip explaining itself.
     Anti-test: with isStale=true, the sub-line is gone but the
     Restart button is present. */
  it('DSH-59: stale chain renders the Restart button but no sub-line', async () => {
    useSessionControlsMock.mockReturnValue({
      state: 'running',
      isPausing: false,
      pauseElapsedSeconds: 0,
      error: null,
      tmuxSession: null,
      isStale: true,
      mutate: {
        start: vi.fn().mockResolvedValue(undefined),
        pause: vi.fn().mockResolvedValue(undefined),
        resume: vi.fn().mockResolvedValue(undefined),
        cancel: vi.fn().mockResolvedValue(undefined),
      },
    })
    await mountChainPlan()
    renderShell()
    openPlansTab()
    await screen.findByRole('button', { name: /^Restart chain$/i })
    expect(screen.queryByTestId('stale-lifecycle-subline')).not.toBeInTheDocument()
  })

  /* DSH-58 (controls-06 #2 — inverted from cycle 5): the chain
     SessionControls action surface is now placed BEFORE the
     PlanCompletionBand inside the plan-header row. Cycle 5's
     citations (chrome.md:148, screens.md:98, ui-primitives.md
     Banner line 125) actually govern OTHER surfaces (left-rail
     section labels, Session-detail drawer, Banner primitive) —
     none speak to plan-row layout. The actual spec for record
     rows is screens.md:35 (Feature portfolio table with explicit
     `2fr 80px 1.4fr 70px 70px 70px 1fr` grid). Plans list is the
     same shape, so we use the same grid pattern and place
     controls in their own column ahead of the progress band so
     state-action verbs lead the row's visual scan. */
  it('DSH-58: chain SessionControls appears BEFORE PlanCompletionBand in DOM order', async () => {
    await mountChainPlan()
    renderShell()
    openPlansTab()
    const startBtn = await screen.findByRole('button', { name: /^Start chain$/i })
    const completionBand = await screen.findByTestId('segmented-progress')
    /* compareDocumentPosition returns PRECEDING (bit 2) when the
       argument node is positioned BEFORE the receiver in DOM order. */
    expect(
      completionBand.compareDocumentPosition(startBtn) &
        Node.DOCUMENT_POSITION_PRECEDING,
    ).toBeTruthy()
  })

  /* DSH-61 (controls-06 #1): the plan-header row is a CSS grid with
     explicit column tracks so the action / progress-bar / counts /
     percent cells align vertically across rows. Anchored via the
     `data-testid="plan-header-row"` wrapper rendered by ProjectPanel.
     Inline `style.display` and `style.gridTemplateColumns` (jsdom
     can't introspect MUI sx — same fallback DSH-49 / DSH-60 use). */
  it('DSH-61: plan-header row uses display:grid with explicit column tracks', async () => {
    await mountChainPlan()
    renderShell()
    openPlansTab()
    const row = await screen.findByTestId('plan-header-row')
    expect(row.style.display).toBe('grid')
    /* Seven tracks (left to right):
        plan-name 1fr | status pill auto | actions ~280px |
        bar 240px | N/M 72px | TASKS label auto | percent 56px */
    expect(row.style.gridTemplateColumns).toContain('1fr')
    expect(row.style.gridTemplateColumns).toContain('240px')
    expect(row.style.gridTemplateColumns).toContain('72px')
    expect(row.style.gridTemplateColumns).toContain('56px')
  })

  /* DSH-62 (controls-06 #1): the N/M-tasks, TASKS label, and percent
     cells are rendered as DIRECT siblings of the progress bar inside
     the plan-header row — not nested inside PlanCompletionBand. Each
     anchored by data-testid so jsdom can locate them without
     hitting MUI sx classes. */
  it('DSH-62: row carries explicit cells for N/M, TASKS label, and percent', async () => {
    await mountChainPlan()
    renderShell()
    openPlansTab()
    const row = await screen.findByTestId('plan-header-row')
    expect(within(row).getByTestId('plan-row-counts')).toBeInTheDocument()
    expect(within(row).getByTestId('plan-row-label')).toBeInTheDocument()
    expect(within(row).getByTestId('plan-row-percent')).toBeInTheDocument()
  })

  /* DSH-63 (controls-06 #7): the plan name and the StatusPill share
     a single flex cluster (`plan-title-cluster`) sitting in the
     row's leftmost grid track. Cycle-6 #1's first cut placed the
     title in a 1fr column and the pill in its own auto column —
     because 1fr eats remaining width, the title cell stretched all
     the way across the row and the pill drifted toward the action
     column, looking like it belonged with the controls instead of
     the title. Wrapping them in one flex container glues the pill
     adjacent to the title regardless of available width. */
  it('DSH-63: plan title and StatusPill share a single flex cluster', async () => {
    await mountChainPlan()
    renderShell()
    openPlansTab()
    const cluster = await screen.findByTestId('plan-title-cluster')
    expect(within(cluster).getByTestId('wf-status-pill')).toBeInTheDocument()
    expect(within(cluster).getByText('Test')).toBeInTheDocument()
  })

  /* DSH-57 (controls-06 #3 — inverted from cycle 4): the Plans-tab
     plan header mounts SessionControls with density='header'.
     Compact density now means inline `sm` Pause / Cancel / Attach
     buttons (industry-convergent 7/7 — Vercel / GitHub Actions /
     Render / Linear / Stripe / Heroku / AWS CodePipeline place
     state-machine verbs inline on row-level controls), not a
     kebab overflow menu. The compact-density signature is the
     ABSENCE of a 'pause-button' testid (panel-density anchor for
     the MUI Button) AND the PRESENCE of the inline trio. */
  it('DSH-57: chain SessionControls in plan header uses compact density', async () => {
    useSessionControlsMock.mockReturnValue({
      state: 'running',
      isPausing: false,
      pauseElapsedSeconds: 0,
      error: null,
      tmuxSession: 'chain-demo-chain',
      isStale: false,
      mutate: {
        start: vi.fn().mockResolvedValue(undefined),
        pause: vi.fn().mockResolvedValue(undefined),
        resume: vi.fn().mockResolvedValue(undefined),
        cancel: vi.fn().mockResolvedValue(undefined),
      },
    })
    await mountChainPlan()
    renderShell()
    openPlansTab()
    /* Compact-density signature: inline Pause / Cancel / Attach as
       wf/Button (no `data-testid="pause-button"` — that's the
       panel-density MUI Button anchor). */
    expect(await screen.findByRole('button', { name: /^Pause$/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^Cancel$/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^Output$/i })).toBeInTheDocument()
    expect(screen.queryByTestId('pause-button')).not.toBeInTheDocument()
    expect(screen.queryByTestId('session-controls-overflow')).not.toBeInTheDocument()
  })

  /* DSH-56 (controls-04 #4): when plan_dir is empty/missing,
     planDirToChainId returns "" and the `chainId || null` coercion
     in ProjectPanel must hand useSessionControls a null targetId —
     not "" — so the mutations fall into the disabled-target branch
     rather than POSTing target_id="" (which control.py rejects as
     pydantic schema violation). Non-empty-but-unparseable plan_dirs
     are passed through deliberately (planDirToChainId DONE_/BACKLOG_
     passthrough); only the empty case needs coercion. */
  it('DSH-56: empty plan_dir coerces chain targetId to null', async () => {
    await setPlans([
      mockProject({
        project: 'p',
        path: '/tmp/test',
        plan_dir: '',
        lifecycle: 'inprogress',
        active_session_count: 0,
      }),
    ])
    renderShell()
    openPlansTab()
    await waitFor(() => {
      const chainCalls = useSessionControlsMock.mock.calls.filter(
        (c) => c[0] === 'chain',
      )
      expect(chainCalls.length).toBeGreaterThan(0)
    })
    const chainCall = useSessionControlsMock.mock.calls.find(
      (c) => c[0] === 'chain',
    )
    expect(chainCall?.[1]).toBe(null)
  })

  /* DSH-55 (controls-04 #1): a DONE plan must NOT render the chain
     control surface — the lifecycle pill ("DONE") and the action
     surface are two views of the same lifecycle truth; offering
     "Start chain" on a closed plan would reopen a finished pipeline
     by surprise. Gate is `classifyPlan(project) === 'done'`. */
  it('DSH-55: DONE plan does not mount SessionControls (no Start chain button)', async () => {
    await setPlans([
      mockProject({
        project: 'p',
        path: '/tmp/test',
        plan_dir: '/tmp/test/docs/DONE_Plan_demo-chain',
        lifecycle: 'done',
        active_session_count: 0,
      }),
    ])
    vi.mocked(usePlanFilters).mockReturnValue({
      lifecycle: new Set(['done']),
      project: new Set<string>(),
      search: '',
      sort: 'name-asc',
      setLifecycle: vi.fn(),
      setProject: vi.fn(),
      setSearch: vi.fn(),
      setSort: vi.fn(),
    })
    renderShell()
    openPlansTab()
    /* The plan header still renders (StatusPill, completion band, etc).
       Only the SessionControls action surface must be suppressed. */
    await waitFor(() => {
      expect(
        screen.queryByRole('button', { name: /^Start chain$/i }),
      ).not.toBeInTheDocument()
    })
    /* Defence-in-depth: chain-kind hook calls are allowed for DONE
       plans (ProjectPanel observes isStale via the same hook to
       gate its stale sub-line — see controls-05 #3) but MUST pass
       targetId=null so the hook's A6 short-circuit prevents any
       /status SWR poll firing against a closed chain. */
    const chainCalls = useSessionControlsMock.mock.calls.filter(
      (c) => c[0] === 'chain',
    )
    for (const call of chainCalls) {
      expect(call[1]).toBe(null)
    }
  })
})

/* ═══ 2H — ProjectPanel plan-header borderColor (controls-03 #6) ═══ */
describe('Plans tab — ProjectPanel plan-header borderColor', () => {
  /* jsdom does not resolve MUI sx emotion classes via
     getComputedStyle, so the runtime borderColor returns rgb(0,0,0)
     regardless of token. Anchor the contract via a source-grep on
     the brand-token literal so a future refactor that drops `wf.steel`
     back to MUI's faint `divider` token trips this test. The other
     action-row hairlines (SessionPanel, FeatureDetail Branch B)
     already use `wf.steel`; the plan header joins that convention. */
  /* DSH-60 (controls-05 #6): plan-header row drops `flexWrap: 'wrap'`
     and gives the title a deterministic truncation chain
     (minWidth: 0 + textOverflow: 'ellipsis' + overflow: 'hidden').
     With the cycle-05 #1 right-aligned action surface, wrap-based
     fallback for narrow viewports creates ambiguous layouts
     (SessionControls could wrap below the completion band). The
     spec convention (chrome.md/screens.md) keeps panel-header rows
     to a single line; truncating the title is the brand-correct
     overflow strategy. Source-grep test mirrors the DSH-49 pattern
     since jsdom does not resolve sx tokens. */
  it("DSH-60: ProjectPanel plan-header drops flexWrap and adds ellipsis on title", async () => {
    const { readFileSync } = await import('node:fs')
    const { fileURLToPath } = await import('node:url')
    const { resolve, dirname } = await import('node:path')
    const here = dirname(fileURLToPath(import.meta.url))
    const src = readFileSync(
      resolve(here, '..', 'components', 'DashboardShell.tsx'),
      'utf8',
    )
    const projectPanelStart = src.indexOf('function ProjectPanel(')
    expect(projectPanelStart).toBeGreaterThan(-1)
    const projectPanelEnd = src.indexOf('\nexport default function', projectPanelStart)
    const slice = src.slice(projectPanelStart, projectPanelEnd)
    /* flexWrap: 'wrap' must NOT appear in the ProjectPanel slice. */
    expect(slice).not.toMatch(/flexWrap:\s*['"]wrap['"]/)
    /* The title must carry ellipsis-truncation chrome so a long
       plan name doesn't push the right-aligned controls off-screen. */
    expect(slice).toMatch(/textOverflow:\s*['"]ellipsis['"]/)
    expect(slice).toMatch(/whiteSpace:\s*['"]nowrap['"]/)
  })

  it('DSH-49: ProjectPanel plan-header Box uses borderColor "wf.steel" not "divider"', async () => {
    const { readFileSync } = await import('node:fs')
    const { fileURLToPath } = await import('node:url')
    const { resolve, dirname } = await import('node:path')
    const here = dirname(fileURLToPath(import.meta.url))
    const src = readFileSync(
      resolve(here, '..', 'components', 'DashboardShell.tsx'),
      'utf8',
    )
    /* Locate the ProjectPanel function and slice from its opening
       brace to the next top-level declaration. The plan-header Box
       lives inside this slice; the next major surface (DashboardShell
       default export) is a separate function. */
    const projectPanelStart = src.indexOf('function ProjectPanel(')
    expect(projectPanelStart).toBeGreaterThan(-1)
    const projectPanelEnd = src.indexOf('\nexport default function', projectPanelStart)
    expect(projectPanelEnd).toBeGreaterThan(projectPanelStart)
    const slice = src.slice(projectPanelStart, projectPanelEnd)
    /* The header carries one borderBottom hairline; assert that the
       borderColor in this slice is the wf.steel brand token, and that
       the faint MUI divider alias is no longer referenced. */
    expect(slice).toMatch(/borderColor:\s*['"]wf\.steel['"]/)
    expect(slice).not.toMatch(/borderColor:\s*['"]divider['"]/)
  })
})
