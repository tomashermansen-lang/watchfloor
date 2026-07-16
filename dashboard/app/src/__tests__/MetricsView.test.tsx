import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'

/* Mock localStorage */
const storageMock: Record<string, string> = {}
Object.defineProperty(globalThis, 'localStorage', {
  value: {
    getItem: vi.fn((key: string) => storageMock[key] ?? null),
    setItem: vi.fn((key: string, value: string) => { storageMock[key] = value }),
    removeItem: vi.fn((key: string) => { delete storageMock[key] }),
    clear: vi.fn(),
    get length() { return Object.keys(storageMock).length },
    key: vi.fn((_: number) => null),
  },
  writable: true,
})

const mockMetrics = {
  tool_usage: { by_tool: { Bash: 5, Edit: 3 }, by_session: {}, most_used: 'Bash', total: 8 },
  error_tracking: { total_errors: 0, by_tool: {}, by_session: {}, interrupts: 0, failures: 0, timeline: [] },
  session_lifecycle: { sessions: [], model_distribution: {}, source_distribution: {}, end_reasons: {}, concurrency_timeline: [] },
  permission_friction: { total_prompts: 0, by_tool: {}, by_session: {}, mode_distribution: {}, blocked_durations: [], has_tuid_data: false },
  subagent_utilization: { total_spawned: 0, by_type: {}, by_session: {}, peak_concurrent: 0, durations: [], running: [] },
  file_activity: { files: [], conflicts: [], summary: { total: 0, edited: 0, read_only: 0 }, has_fp_data: false },
  task_completion: { total: 0, by_session: {}, tasks: [], rates: {} },
  activity_timeline: { sessions: [] },
}

vi.mock('../hooks/useMetrics', () => ({
  useMetrics: () => ({ data: mockMetrics }),
}))

vi.mock('../hooks/useSessions', () => ({
  useSessions: () => ({ data: [] }),
}))

// Import after mocks
import MetricsView from '../components/metrics/MetricsView'

function renderView() {
  return render(
    <ThemeProvider theme={theme}>
      <MetricsView />
    </ThemeProvider>,
  )
}

describe('MetricsView', () => {
  it('renders filter bar with session selector and time range', () => {
    renderView()
    expect(screen.getByLabelText('Filter by session')).toBeInTheDocument()
    expect(screen.getByLabelText('Time range')).toBeInTheDocument()
  })

  it('renders KPI strip', () => {
    renderView()
    expect(screen.getByTestId('kpi-strip')).toBeInTheDocument()
  })

  it('renders all metric card regions', () => {
    renderView()
    const regions = screen.getAllByRole('region')
    // At least: Activity Timeline, Tool Usage, Error Tracking, Session Lifecycle,
    // Permission Friction, Subagent Utilization, Task Completion, File Activity = 8
    expect(regions.length).toBeGreaterThanOrEqual(8)
  })

  it('renders time range toggle buttons', () => {
    renderView()
    expect(screen.getByText('15m')).toBeInTheDocument()
    expect(screen.getByText('1h')).toBeInTheDocument()
    expect(screen.getByText('6h')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'All' })).toBeInTheDocument()
  })

  /* MetricsView splits into two sub-views: "Activity" (existing 8-card
     observability grid driven by hook events) and "Run Economy" (autopilot
     run aggregates - tokens/cost/duration/turns per feature). Activity is
     the default tab. */
  it('renders sub-tabs for Activity and Run Economy', () => {
    renderView()
    const tabs = screen.getByTestId('metrics-subtabs')
    expect(within(tabs).getByRole('tab', { name: /activity/i })).toBeInTheDocument()
    expect(within(tabs).getByRole('tab', { name: /run economy/i })).toBeInTheDocument()
  })

  it('Activity tab is selected by default and shows the existing KPI + cards', () => {
    renderView()
    const activityTab = screen.getByRole('tab', { name: /activity/i })
    expect(activityTab.getAttribute('aria-selected')).toBe('true')
    expect(screen.getByTestId('kpi-strip')).toBeInTheDocument()
  })
})

/* ═══ Filter bar polish (commit 7 metrics polish) ═══ */
describe('MetricsView: filter bar polish', () => {
  it('renders 24h and 7d range chips', () => {
    renderView()
    const range = screen.getByLabelText('Time range')
    expect(within(range).getByRole('button', { name: /24h/i })).toBeInTheDocument()
    expect(within(range).getByRole('button', { name: /7d/i })).toBeInTheDocument()
  })

  it('renders a data-freshness timestamp in the filter bar', () => {
    renderView()
    const indicator = screen.getByTestId('metrics-live-indicator')
    expect(indicator).toBeInTheDocument()
    expect(indicator.textContent).toMatch(/Updated/i)
  })

  /* ─── Watchfloor brand alignment ──────────────────────────────────── */

  it('(brand) LIVE pill is NOT duplicated on the metrics view', () => {
    /* The brand LiveBadge lives once in the global title-bar chrome
       (handoff §App Chrome — "appears on every authenticated
       screen"). Duplicating it inside per-view filter bars doubles
       the brand surface and reads as noise. The freshness signal
       belongs in a quiet timestamp, not another pill. */
    renderView()
    expect(screen.queryByTestId('wf-live-badge')).not.toBeInTheDocument()
  })

  it('renders an Export CSV button', () => {
    renderView()
    expect(screen.getByRole('button', { name: /Export CSV/i })).toBeInTheDocument()
  })
})

