import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import KpiStrip from '../components/metrics/KpiStrip'
import type { MetricsResponse } from '../types'

function makeMetrics(overrides?: Partial<MetricsResponse>): MetricsResponse {
  return {
    tool_usage: { by_tool: { Bash: 10 }, by_session: { s1: { count: 10, rate: 2 } }, most_used: 'Bash', total: 10 },
    error_tracking: { total_errors: 1, by_tool: { Bash: 1 }, by_tool_detail: { Bash: { failures: 1, interrupts: 0 } }, by_session: { s1: { errors: 1, rate: 10 } }, interrupts: 0, failures: 1, timeline: [] },
    session_lifecycle: { sessions: [{ sid: 's1', start: '2026-03-01T10:00:00Z', end: '2026-03-01T10:30:00Z', duration_s: 1800, model: 'opus', source: 'new', end_reason: 'clear' }], model_distribution: {}, source_distribution: {}, end_reasons: {}, concurrency_timeline: [] },
    permission_friction: { total_prompts: 0, by_tool: {}, by_tool_mode: {}, by_session: {}, mode_distribution: {}, blocked_durations: [], has_tuid_data: false, timeline: [] },
    subagent_utilization: { total_spawned: 0, by_type: {}, by_session: {}, peak_concurrent: 0, durations: [], running: [] },
    file_activity: { files: [], conflicts: [], summary: { total: 0, edited: 0, read_only: 0 }, has_fp_data: false },
    task_completion: { total: 3, by_session: { s1: 3 }, tasks: [], rates: { s1: 6 }, total_responses: 5, responses_by_session: { s1: 5 } },
    activity_timeline: { sessions: [] },
    ...overrides,
  }
}

function renderStrip(metrics: MetricsResponse | undefined, selectedSid: string | 'all' = 'all') {
  return render(
    <ThemeProvider theme={theme}>
      <KpiStrip metrics={metrics} selectedSid={selectedSid} />
    </ThemeProvider>,
  )
}

describe('KpiStrip', () => {
  it('renders six KPI cards with all-sessions data', () => {
    renderStrip(makeMetrics())
    expect(screen.getByText('Sessions')).toBeInTheDocument()
    expect(screen.getByText('Tool Calls')).toBeInTheDocument()
    expect(screen.getByText('Error Rate')).toBeInTheDocument()
    expect(screen.getByText('Friction')).toBeInTheDocument()
    expect(screen.getByText('Autopilot')).toBeInTheDocument()
    expect(screen.getByText('Spend')).toBeInTheDocument()
  })

  it('shows Duration label when single session selected', () => {
    renderStrip(makeMetrics(), 's1')
    expect(screen.getByText('Duration')).toBeInTheDocument()
    expect(screen.getByText('30 min')).toBeInTheDocument()
  })

  it('shows neutral baseline when no metrics data', () => {
    renderStrip(undefined)
    // Sessions and Tool Calls show '0', Error Rate and Friction show '—',
    // Autopilot shows '0/0', Spend shows '$0'.
    expect(screen.getAllByText('0').length).toBeGreaterThanOrEqual(2)
    expect(screen.getAllByText('—').length).toBeGreaterThanOrEqual(2)
    expect(screen.getByText('0/0')).toBeInTheDocument()
    expect(screen.getByText('$0')).toBeInTheDocument()
  })

  it('has aria-live=polite for screen readers', () => {
    renderStrip(makeMetrics())
    const strip = screen.getByTestId('kpi-strip')
    expect(strip.getAttribute('aria-live')).toBe('polite')
  })
})

/* ═══ Polish: 6 cards with sparklines (commit 7 metrics polish) ═══ */
describe('KpiStrip polished — 6 cards + sparklines', () => {
  it('renders all six KPI cards by label', () => {
    renderStrip(makeMetrics())
    expect(screen.getByText('Sessions')).toBeInTheDocument()
    expect(screen.getByText('Tool Calls')).toBeInTheDocument()
    expect(screen.getByText(/Error/i)).toBeInTheDocument()
    expect(screen.getByText(/Friction/i)).toBeInTheDocument()
    expect(screen.getByText(/Autopilot/i)).toBeInTheDocument()
    expect(screen.getByText(/Spend/i)).toBeInTheDocument()
  })

  it('renders a sparkline (svg) per KPI card', () => {
    renderStrip(makeMetrics())
    const strip = screen.getByTestId('kpi-strip')
    // Each card carries a tiny Recharts AreaChart — count svgs in strip
    const svgs = strip.querySelectorAll('svg')
    // At least 6 SVGs (one per card); some Recharts internals may add more
    expect(svgs.length).toBeGreaterThanOrEqual(6)
  })

  /* ─── Watchfloor brand alignment ──────────────────────────────────── */

  it('(brand) KPI labels use wfLabel uppercase mono chrome', () => {
    /* Handoff §Typography: type.label = JBM uppercase 0.16em, used
       for KPI labels. Locks the strip to the brand vocabulary so
       "SESSIONS / TOOL CALLS / ERROR RATE..." reads as instrument
       readouts, not generic UI labels. */
    renderStrip(makeMetrics())
    const labelEl = screen.getByText('Sessions')
    const styles = window.getComputedStyle(labelEl)
    expect(styles.textTransform).toBe('uppercase')
    expect(styles.fontFamily).toMatch(/JetBrains Mono/)
  })

  it('(brand) KPI value renders in Geist Mono per type.display spec', () => {
    /* Handoff §Typography: type.display = Geist Mono 32px / 500 for
       KPI numbers. The previous Inter headlineSmall variant clashed
       with the rest of the brand-typed strip. */
    renderStrip(makeMetrics())
    const valueEl = screen.getByText('1') // totalSessions
    const styles = window.getComputedStyle(valueEl)
    expect(styles.fontFamily).toMatch(/Geist Mono/)
  })
})

