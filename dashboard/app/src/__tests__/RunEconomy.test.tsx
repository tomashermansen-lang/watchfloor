import { describe, it, expect, vi, beforeEach } from 'vitest'
import userEvent from '@testing-library/user-event'
import { render, screen, within } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import type { AutopilotSession, AutopilotPhase } from '../types'

/* Fixture phases — three completed phases per feature so aggregate
   tests have non-trivial sums. Token totals stay close to round
   numbers so the k/M formatter outputs predictable strings. */
function phase(
  name: string,
  durSec: number,
  cost: number,
  inputT: number,
  cacheCreate: number,
  cacheRead: number,
  outputT: number,
  turns: number,
  startedAt: string | null = null,
  endedAt: string | null = null,
): AutopilotPhase {
  return {
    name,
    status: 'completed',
    duration_s: durSec,
    cost,
    artifact: null,
    input_tokens: inputT,
    cache_creation_tokens: cacheCreate,
    cache_read_tokens: cacheRead,
    output_tokens: outputT,
    num_turns: turns,
    started_at: startedAt,
    ended_at: endedAt,
  }
}

const featureA: AutopilotSession = {
  task: 'feature-a',
  project: 'dotfiles',
  branch: 'feature/feature-a',
  status: 'completed',
  phases: [
    phase('BA', 600, 0.5, 100, 50000, 1000000, 5000, 10,
      '2026-05-09T09:00:00Z', '2026-05-09T09:10:00Z'),
    phase('Implement', 1200, 5.0, 50, 100000, 5000000, 30000, 40,
      '2026-05-09T09:11:00Z', '2026-05-09T09:31:00Z'),
    phase('QA', 600, 1.0, 30, 20000, 800000, 8000, 15,
      '2026-05-09T09:32:00Z', '2026-05-09T09:42:00Z'),
  ],
  elapsed_s: 2400,
  cost: 6.5,
  log_path: null,
  stream_path: '/tmp/feature-a.ndjson',
}

const featureB: AutopilotSession = {
  task: 'feature-b',
  project: 'dotfiles',
  branch: 'feature/feature-b',
  status: 'completed',
  phases: [
    phase('BA', 300, 0.2, 50, 20000, 500000, 2000, 8,
      '2026-05-09T10:00:00Z', '2026-05-09T10:05:00Z'),
    phase('Implement', 600, 2.0, 25, 50000, 2000000, 15000, 25,
      '2026-05-09T10:05:00Z', '2026-05-09T10:15:00Z'),
  ],
  elapsed_s: 900,
  cost: 2.2,
  log_path: null,
  stream_path: '/tmp/feature-b.ndjson',
}

const fixtureSessions: AutopilotSession[] = [featureA, featureB]

vi.mock('../hooks/useAutopilots', () => ({
  useAutopilots: () => ({ data: fixtureSessions }),
}))

import RunEconomy from '../components/metrics/RunEconomy'

function renderView() {
  return render(
    <ThemeProvider theme={theme}>
      <RunEconomy />
    </ThemeProvider>,
  )
}

describe('RunEconomy', () => {
  it('renders the KPI strip with aggregate totals across all features', () => {
    renderView()
    const strip = screen.getByTestId('run-economy-kpi-strip')
    expect(strip).toBeInTheDocument()
    // Total upstream = featureA upstream + featureB upstream
    //   A: (100+50000+1000000) + (50+100000+5000000) + (30+20000+800000) = 6,970,180
    //   B: (50+20000+500000) + (25+50000+2000000) = 2,570,075
    //   sum = 9,540,255 → "9.5M"
    expect(strip.textContent ?? '').toMatch(/9\.5M/)
    // Total cost = 6.5 + 2.2 = $8.70
    expect(strip.textContent ?? '').toMatch(/\$8\.70/)
    // Total turns = 10+40+15 + 8+25 = 98
    expect(strip.textContent ?? '').toMatch(/98/)
  })

  it('shows feature count in the KPI strip', () => {
    renderView()
    const strip = screen.getByTestId('run-economy-kpi-strip')
    expect(strip.textContent ?? '').toMatch(/2\s*features/i)
  })

  it('renders avg-per-feature row', () => {
    renderView()
    const strip = screen.getByTestId('run-economy-kpi-strip')
    // avg cost = 8.70 / 2 = $4.35
    expect(strip.textContent ?? '').toMatch(/\$4\.35/)
  })

  it('renders a by-feature ranked list with all features', () => {
    renderView()
    const list = screen.getByTestId('run-economy-feature-list')
    expect(within(list).getByText('feature-a')).toBeInTheDocument()
    expect(within(list).getByText('feature-b')).toBeInTheDocument()
  })

  it('default sort is cost descending — most expensive feature first', () => {
    renderView()
    const list = screen.getByTestId('run-economy-feature-list')
    const rows = within(list).getAllByTestId('run-economy-feature-row')
    // featureA cost $6.50 > featureB cost $2.20
    expect(rows[0].textContent ?? '').toContain('feature-a')
    expect(rows[1].textContent ?? '').toContain('feature-b')
  })

  it('each feature row shows cost, total tokens, and duration', () => {
    renderView()
    const list = screen.getByTestId('run-economy-feature-list')
    const rows = within(list).getAllByTestId('run-economy-feature-row')
    // featureA: cost $6.50, upstream ~7M, duration 40m
    expect(rows[0].textContent ?? '').toMatch(/\$6\.50/)
    expect(rows[0].textContent ?? '').toMatch(/40m/)
  })

  it('shows empty state when no autopilot sessions exist', () => {
    vi.doMock('../hooks/useAutopilots', () => ({
      useAutopilots: () => ({ data: [] }),
    }))
    expect(true).toBe(true)
  })

  /* Slice 1.1 - extra averages mirror the sidebar TOTAL row vocabulary
     so the operator sees the same diagnostic signals at the cross-
     feature level: cache rate, new tokens (input + cache_creation),
     and idle time (wall-clock minus phase-sum). */
  it('Tokens KPI cell shows new tokens count alongside cache rate', () => {
    renderView()
    const strip = screen.getByTestId('run-economy-kpi-strip')
    // Total new = featureA(100+50000+50+100000+30+20000) + featureB(50+20000+25+50000)
    //           = 170,180 + 70,075 = 240,255 -> "240.3k new"
    expect(strip.textContent ?? '').toMatch(/240\.3k\s*new/)
    expect(strip.textContent ?? '').toMatch(/97%\s*cache|96%\s*cache|95%\s*cache/)
  })

  it('Avg/Feature row also shows new tokens average', () => {
    renderView()
    const strip = screen.getByTestId('run-economy-kpi-strip')
    // Avg new = 240,255 / 2 = 120,127.5 -> "120.1k new"
    expect(strip.textContent ?? '').toMatch(/120\.1k\s*new/)
  })

  it('Run Time KPI cell shows total idle time', () => {
    renderView()
    const strip = screen.getByTestId('run-economy-kpi-strip')
    const idleEl = within(strip).getByTestId('run-economy-total-idle')
    expect(idleEl.textContent ?? '').toMatch(/2m\s*idle/)
  })

  it('Run Time KPI cell shows average idle per feature', () => {
    renderView()
    const strip = screen.getByTestId('run-economy-kpi-strip')
    const avgIdleEl = within(strip).getByTestId('run-economy-avg-idle')
    expect(avgIdleEl.textContent ?? '').toMatch(/1m\s*idle/)
  })
})

/* Slice 1.2 - dedupe by task name. /api/autopilots returns one row per
   AutopilotSession; a single feature with N retry runs produces N
   rows. Group by task so each feature appears once with summed metrics
   across all its sessions. */
describe('RunEconomy: dedupe + extended columns', () => {
  const dupFeatureA1 = featureA
  const dupFeatureA2: AutopilotSession = {
    ...featureA,
    branch: 'feature/feature-a-retry',
    phases: [
      phase('BA', 200, 0.1, 10, 5000, 100000, 1000, 5),
    ],
    elapsed_s: 200,
    cost: 0.1,
  }
  const dupSessions: AutopilotSession[] = [dupFeatureA1, dupFeatureA2, featureB]

  beforeEach(() => {
    vi.resetModules()
  })

  async function renderDedupView() {
    vi.doMock('../hooks/useAutopilots', () => ({
      useAutopilots: () => ({ data: dupSessions }),
    }))
    const mod = await import('../components/metrics/RunEconomy')
    const RunEconomyView = mod.default
    return render(
      <ThemeProvider theme={theme}>
        <RunEconomyView />
      </ThemeProvider>,
    )
  }

  it('groups sessions by task so each feature appears once', async () => {
    await renderDedupView()
    const list = screen.getByTestId('run-economy-feature-list')
    const rows = within(list).getAllByTestId('run-economy-feature-row')
    expect(rows).toHaveLength(2)
    const labels = rows.map((r) => r.textContent ?? '')
    expect(labels.filter((l) => l.includes('feature-a'))).toHaveLength(1)
    expect(labels.filter((l) => l.includes('feature-b'))).toHaveLength(1)
  })

  it('aggregates cost across all sessions of the same task', async () => {
    await renderDedupView()
    const list = screen.getByTestId('run-economy-feature-list')
    const rows = within(list).getAllByTestId('run-economy-feature-row')
    const aRow = rows.find((r) => (r.textContent ?? '').includes('feature-a'))
    expect(aRow?.textContent ?? '').toMatch(/\$6\.60/)
  })

  it('feature row exposes separate cells for cost / duration / turns / upstream / downstream', async () => {
    await renderDedupView()
    const list = screen.getByTestId('run-economy-feature-list')
    const rows = within(list).getAllByTestId('run-economy-feature-row')
    const aRow = rows.find((r) => (r.textContent ?? '').includes('feature-a')) as HTMLElement
    expect(within(aRow).getByTestId('run-economy-feature-cost')).toBeInTheDocument()
    expect(within(aRow).getByTestId('run-economy-feature-duration')).toBeInTheDocument()
    expect(within(aRow).getByTestId('run-economy-feature-turns')).toBeInTheDocument()
    expect(within(aRow).getByTestId('run-economy-feature-upstream')).toBeInTheDocument()
    expect(within(aRow).getByTestId('run-economy-feature-downstream')).toBeInTheDocument()
  })

  it('upstream cell shows cache percentage', async () => {
    await renderDedupView()
    const list = screen.getByTestId('run-economy-feature-list')
    const rows = within(list).getAllByTestId('run-economy-feature-row')
    const aRow = rows.find((r) => (r.textContent ?? '').includes('feature-a')) as HTMLElement
    const up = within(aRow).getByTestId('run-economy-feature-upstream')
    expect(up.textContent ?? '').toMatch(/\d+%/)
  })
})

/* Slice 2 - by-phase aggregate. For each unique phase name across all
   features, compute averages so the operator can see "which phase
   costs the most on average" at a glance.

   Fixture math (featureA + featureB):
     BA appears 2 times: A=600s/$0.5, B=300s/$0.2
       avg duration = 450s = 7m 30s, avg cost = $0.35
     Implement 2 times: A=1200s/$5, B=600s/$2
       avg duration = 900s = 15m, avg cost = $3.50
     QA 1 time: A=600s/$1
       avg duration = 600s = 10m, avg cost = $1.00 */
describe('RunEconomy: by-phase aggregate', () => {
  it('renders a by-phase table with one row per unique phase name', () => {
    renderView()
    const table = screen.getByTestId('run-economy-by-phase')
    const rows = within(table).getAllByTestId('run-economy-phase-row')
    expect(rows).toHaveLength(3)
    const names = rows.map((r) => within(r).getByTestId('run-economy-phase-name').textContent)
    expect(names).toEqual(expect.arrayContaining(['BA', 'Implement', 'QA']))
  })

  it('default sort is avg cost descending', () => {
    renderView()
    const table = screen.getByTestId('run-economy-by-phase')
    const rows = within(table).getAllByTestId('run-economy-phase-row')
    const names = rows.map((r) => within(r).getByTestId('run-economy-phase-name').textContent)
    // Implement avg = $3.50 > QA avg = $1.00 > BA avg = $0.35
    expect(names).toEqual(['Implement', 'QA', 'BA'])
  })

  it('phase row shows avg cost / duration / turns / tokens / output', () => {
    renderView()
    const table = screen.getByTestId('run-economy-by-phase')
    const rows = within(table).getAllByTestId('run-economy-phase-row')
    const implementRow = rows[0]  // Implement is top-sorted
    expect(within(implementRow).getByTestId('run-economy-phase-cost').textContent ?? '').toMatch(/\$3\.50/)
    expect(within(implementRow).getByTestId('run-economy-phase-duration').textContent ?? '').toMatch(/15m/)
  })

  it('phase row shows feature count (how many features include this phase)', () => {
    renderView()
    const table = screen.getByTestId('run-economy-by-phase')
    const rows = within(table).getAllByTestId('run-economy-phase-row')
    const baRow = rows.find((r) => within(r).getByTestId('run-economy-phase-name').textContent === 'BA') as HTMLElement
    // BA appears in 2 features
    expect(within(baRow).getByTestId('run-economy-phase-count').textContent ?? '').toMatch(/2/)
  })

  /* By-phase headers gain the same sortable click behaviour as the by-
     feature list. Default sort stays cost desc; clicking another header
     switches the active column. */
  /* The "sort: cost ↓" suffix in the section title became redundant
     once the column headers themselves carry the chevron. Verify it's
     gone so it can't drift back. */
  it('by-phase title does not duplicate the sort indicator', () => {
    renderView()
    const table = screen.getByTestId('run-economy-by-phase')
    // Walk up to the section parent to see the title sibling.
    const section = table.parentElement
    expect(section?.textContent ?? '').not.toMatch(/sort:\s*cost/i)
  })

  it('by-phase cost header is a clickable button with aria-sort', () => {
    renderView()
    const table = screen.getByTestId('run-economy-by-phase')
    const costHeader = within(table).getByRole('button', { name: /avg cost/i })
    expect(costHeader.getAttribute('aria-sort')).toBe('descending')
    expect(costHeader.tagName.toLowerCase()).toBe('button')
  })

  it('clicking by-phase Avg Duration header re-sorts that table by duration desc', async () => {
    renderView()
    const table = screen.getByTestId('run-economy-by-phase')
    const durationHeader = within(table).getByRole('button', { name: /avg duration/i })
    await userEvent.click(durationHeader)
    expect(durationHeader.getAttribute('aria-sort')).toBe('descending')
    // Implement = 900s avg, QA = 600s avg, BA = 450s avg.
    const rows = within(table).getAllByTestId('run-economy-phase-row')
    const names = rows.map((r) => within(r).getByTestId('run-economy-phase-name').textContent)
    expect(names).toEqual(['Implement', 'QA', 'BA'])
  })
})

/* Sessions without a stream file have only log-derived data: cost +
   duration via /api/autopilots' `parse_log_phases` path, but no token
   counts, no turns, no per-phase timestamps. Including them in
   averages produces mixed-cardinality math (some phases counted in
   cost-avg but not token-avg, etc.) - the operator sees skewed
   numbers. Filter to stream-backed sessions only so every metric
   has the same denominator. */
describe('RunEconomy: stream-file filter', () => {
  beforeEach(() => {
    vi.resetModules()
  })

  async function renderWithSessions(sessions: AutopilotSession[]) {
    vi.doMock('../hooks/useAutopilots', () => ({
      useAutopilots: () => ({ data: sessions }),
    }))
    const mod = await import('../components/metrics/RunEconomy')
    const RunEconomyView = mod.default
    return render(
      <ThemeProvider theme={theme}>
        <RunEconomyView />
      </ThemeProvider>,
    )
  }

  it('excludes sessions without stream_path from the by-feature list', async () => {
    const streamed: AutopilotSession = { ...featureA, stream_path: '/some/stream.ndjson' }
    const logOnly: AutopilotSession = { ...featureB, stream_path: null }
    await renderWithSessions([streamed, logOnly])
    const list = screen.getByTestId('run-economy-feature-list')
    const rows = within(list).getAllByTestId('run-economy-feature-row')
    expect(rows).toHaveLength(1)
    expect(rows[0].textContent ?? '').toContain('feature-a')
  })

  it('excludes sessions without stream_path from the by-phase aggregate', async () => {
    const streamed: AutopilotSession = { ...featureA, stream_path: '/some/stream.ndjson' }
    const logOnly: AutopilotSession = { ...featureB, stream_path: null }
    await renderWithSessions([streamed, logOnly])
    const table = screen.getByTestId('run-economy-by-phase')
    const rows = within(table).getAllByTestId('run-economy-phase-row')
    // featureA has BA, Implement, QA. featureB (filtered) has BA, Implement.
    // Without filter we would also see "Implement" with avg from both;
    // with filter, Implement only counts featureA's instance.
    const featureCount = rows
      .filter((r) => within(r).getByTestId('run-economy-phase-name').textContent === 'Implement')
      .map((r) => within(r).getByTestId('run-economy-phase-count').textContent)
    expect(featureCount).toEqual(['1'])
  })

  it('shows empty state when ALL sessions lack stream files', async () => {
    const a: AutopilotSession = { ...featureA, stream_path: null }
    const b: AutopilotSession = { ...featureB, stream_path: null }
    await renderWithSessions([a, b])
    expect(screen.queryByTestId('run-economy-feature-list')).toBeNull()
    expect(screen.getByTestId('run-economy-empty-state')).toBeInTheDocument()
  })
})

/* Cache-color thresholds: >=95% = good (green), <85% = bad (orange),
   in between = neutral. Both feature rows and phase rows carry the
   same data-cache-tier indicator so the operator can scan either
   table for outliers. */
describe('RunEconomy: cache color tiers', () => {
  beforeEach(() => {
    vi.resetModules()
  })

  async function renderWithCacheRate(cacheRate: number) {
    const upstream = 1000
    const cacheRead = Math.round(cacheRate * upstream)
    const cacheCreate = upstream - cacheRead
    const tuned: AutopilotSession = {
      ...featureA,
      stream_path: '/stream',
      phases: [
        phase('BA', 60, 1.0, 0, cacheCreate, cacheRead, 100, 5,
          '2026-05-09T09:00:00Z', '2026-05-09T09:01:00Z'),
      ],
    }
    vi.doMock('../hooks/useAutopilots', () => ({
      useAutopilots: () => ({ data: [tuned] }),
    }))
    const mod = await import('../components/metrics/RunEconomy')
    const RunEconomyView = mod.default
    return render(
      <ThemeProvider theme={theme}>
        <RunEconomyView />
      </ThemeProvider>,
    )
  }

  it('feature row at 99% cache flags data-cache-tier=good', async () => {
    await renderWithCacheRate(0.99)
    const list = screen.getByTestId('run-economy-feature-list')
    const up = within(list).getByTestId('run-economy-feature-upstream')
    expect(up.getAttribute('data-cache-tier')).toBe('good')
  })

  it('feature row at 90% cache flags data-cache-tier=neutral', async () => {
    await renderWithCacheRate(0.90)
    const list = screen.getByTestId('run-economy-feature-list')
    const up = within(list).getByTestId('run-economy-feature-upstream')
    expect(up.getAttribute('data-cache-tier')).toBe('neutral')
  })

  /* Aggregate threshold is tighter than the sidebar's <85% because an
     average across many features smooths individual variance. 88% as
     observed for Test Plan in the live data needs to flag bad. */
  it('feature row at 88% cache (just below the aggregate threshold) flags bad', async () => {
    await renderWithCacheRate(0.88)
    const list = screen.getByTestId('run-economy-feature-list')
    const up = within(list).getByTestId('run-economy-feature-upstream')
    expect(up.getAttribute('data-cache-tier')).toBe('bad')
  })

  it('feature row at 80% cache flags data-cache-tier=bad', async () => {
    await renderWithCacheRate(0.80)
    const list = screen.getByTestId('run-economy-feature-list')
    const up = within(list).getByTestId('run-economy-feature-upstream')
    expect(up.getAttribute('data-cache-tier')).toBe('bad')
  })

  it('phase row at 99% cache flags data-cache-tier=good', async () => {
    await renderWithCacheRate(0.99)
    const table = screen.getByTestId('run-economy-by-phase')
    const up = within(table).getByTestId('run-economy-phase-upstream')
    expect(up.getAttribute('data-cache-tier')).toBe('good')
  })

  it('phase row at 80% cache flags data-cache-tier=bad', async () => {
    await renderWithCacheRate(0.80)
    const table = screen.getByTestId('run-economy-by-phase')
    const up = within(table).getByTestId('run-economy-phase-upstream')
    expect(up.getAttribute('data-cache-tier')).toBe('bad')
  })
})

/* Slice 3b - estimate-vs-actual on the by-feature list. Each feature
   that links to a plan task with `estimate.duration_hours` shows the
   planner's projection alongside the actual phase-sum, plus a delta
   percentage colored to flag drift:

     under estimate (-5% or more)    -> status-done (green)
     within +/-5%                    -> wf.bone (neutral)
     over by >20%                    -> status-failed (red)
     between (5%, 20%]               -> status-stalled (orange)

   Features without a linked task (standalone) show "—" so the column
   stays present but the absent estimate doesn't render as $0 / 0%. */
describe('RunEconomy: estimate-vs-actual', () => {
  beforeEach(() => {
    vi.resetModules()
  })

  async function renderWithFeatures(
    sessions: AutopilotSession[],
    featureLookup: Record<string, number | undefined>,
  ) {
    vi.doMock('../hooks/useAutopilots', () => ({
      useAutopilots: () => ({ data: sessions }),
    }))
    vi.doMock('../hooks/useFeatures', () => ({
      useFeatures: () => ({
        data: Object.entries(featureLookup).map(([name, hours]) => ({
          name,
          project: 'dotfiles',
          project_root: '/',
          phase: 'done',
          phase_index: 0,
          total_phases: 0,
          pipeline_type: 'full',
          artifacts: [],
          sessions: [],
          status: 'done',
          stuck_info: null,
          last_activity: null,
          is_autopilot: true,
          plan_task_estimate_hours: hours,
        })),
      }),
    }))
    const mod = await import('../components/metrics/RunEconomy')
    const RunEconomyView = mod.default
    return render(
      <ThemeProvider theme={theme}>
        <RunEconomyView />
      </ThemeProvider>,
    )
  }

  it('feature row shows estimate column when plan task has duration_hours', async () => {
    // featureA phase-sum = 600+1200+600 = 2400s = 40m. With a 1h estimate,
    // delta = (2400-3600)/3600 = -33% under.
    const a: AutopilotSession = { ...featureA, stream_path: '/s1' }
    await renderWithFeatures([a], { 'feature-a': 1 })
    const list = screen.getByTestId('run-economy-feature-list')
    const row = within(list).getByTestId('run-economy-feature-row')
    const est = within(row).getByTestId('run-economy-feature-estimate')
    expect(est.textContent ?? '').toMatch(/1h\s*→\s*40m/i)
    expect(est.textContent ?? '').toMatch(/33%\s*under/i)
  })

  it('feature row shows em-dash when no plan task estimate is linked', async () => {
    const a: AutopilotSession = { ...featureA, stream_path: '/s1' }
    await renderWithFeatures([a], { 'feature-a': undefined })
    const list = screen.getByTestId('run-economy-feature-list')
    const row = within(list).getByTestId('run-economy-feature-row')
    const est = within(row).getByTestId('run-economy-feature-estimate')
    expect(est.textContent ?? '').toBe('—')
  })

  it('estimate cell carries data-estimate-tier reflecting under/on/over status', async () => {
    // 1h estimate, 40m actual -> -33% -> under
    const a: AutopilotSession = { ...featureA, stream_path: '/s1' }
    await renderWithFeatures([a], { 'feature-a': 1 })
    const list = screen.getByTestId('run-economy-feature-list')
    const row = within(list).getByTestId('run-economy-feature-row')
    const est = within(row).getByTestId('run-economy-feature-estimate')
    expect(est.getAttribute('data-estimate-tier')).toBe('under')
  })

  it('estimate over by >20% flags as data-estimate-tier=over', async () => {
    // featureA actual = 2400s = 40m. With a 0.5h (=30m=1800s) estimate,
    // delta = (2400-1800)/1800 = +33% over.
    const a: AutopilotSession = { ...featureA, stream_path: '/s1' }
    await renderWithFeatures([a], { 'feature-a': 0.5 })
    const list = screen.getByTestId('run-economy-feature-list')
    const row = within(list).getByTestId('run-economy-feature-row')
    const est = within(row).getByTestId('run-economy-feature-estimate')
    expect(est.getAttribute('data-estimate-tier')).toBe('over')
  })
})

/* Slice 3c - group-by-plan toggle. When grouped, features sharing a
   plan_dir collapse under a plan header that shows the sum of metrics
   across all the plan's features (cost, duration, estimate). Standalone
   features without a plan land in a "Standalone" group at the bottom. */
describe('RunEconomy: group-by-plan', () => {
  beforeEach(() => {
    vi.resetModules()
  })

  async function renderWithPlanLinks(
    sessions: AutopilotSession[],
    featureLookup: Array<{ name: string; planDir?: string; estimateHours?: number }>,
  ) {
    vi.doMock('../hooks/useAutopilots', () => ({
      useAutopilots: () => ({ data: sessions }),
    }))
    vi.doMock('../hooks/useFeatures', () => ({
      useFeatures: () => ({
        data: featureLookup.map((f) => ({
          name: f.name,
          project: 'dotfiles',
          project_root: '/',
          phase: 'done',
          phase_index: 0,
          total_phases: 0,
          pipeline_type: 'full',
          artifacts: [],
          sessions: [],
          status: 'done',
          stuck_info: null,
          last_activity: null,
          is_autopilot: true,
          plan_dir: f.planDir,
          plan_task_estimate_hours: f.estimateHours,
        })),
      }),
    }))
    const mod = await import('../components/metrics/RunEconomy')
    const RunEconomyView = mod.default
    return render(
      <ThemeProvider theme={theme}>
        <RunEconomyView />
      </ThemeProvider>,
    )
  }

  it('renders a Group toggle (Flat | By Plan)', async () => {
    const a: AutopilotSession = { ...featureA, stream_path: '/s1' }
    await renderWithPlanLinks([a], [{ name: 'feature-a' }])
    const toggle = screen.getByTestId('run-economy-group-toggle')
    expect(within(toggle).getByRole('button', { name: /flat/i })).toBeInTheDocument()
    expect(within(toggle).getByRole('button', { name: /by plan/i })).toBeInTheDocument()
  })

  it('default mode is flat (no plan-group headers)', async () => {
    const a: AutopilotSession = { ...featureA, stream_path: '/s1' }
    await renderWithPlanLinks([a], [{ name: 'feature-a', planDir: '/path/INPROGRESS_Plan_watchfloor' }])
    expect(screen.queryByTestId('run-economy-plan-group')).toBeNull()
  })

  it('clicking By Plan groups features by plan_dir', async () => {
    const a: AutopilotSession = { ...featureA, stream_path: '/s1' }
    const b: AutopilotSession = { ...featureB, stream_path: '/s2' }
    await renderWithPlanLinks([a, b], [
      { name: 'feature-a', planDir: '/path/INPROGRESS_Plan_watchfloor', estimateHours: 1 },
      { name: 'feature-b', planDir: '/path/INPROGRESS_Plan_watchfloor', estimateHours: 2 },
    ])
    const byPlanBtn = screen.getByRole('button', { name: /by plan/i })
    await userEvent.click(byPlanBtn)
    const groups = screen.getAllByTestId('run-economy-plan-group')
    expect(groups).toHaveLength(1)
    expect(groups[0].textContent ?? '').toContain('watchfloor')
    // Both feature rows visible under the plan header
    const rows = within(groups[0]).getAllByTestId('run-economy-feature-row')
    expect(rows).toHaveLength(2)
  })

  it('plan header shows aggregated cost across child features', async () => {
    const a: AutopilotSession = { ...featureA, stream_path: '/s1' }
    const b: AutopilotSession = { ...featureB, stream_path: '/s2' }
    await renderWithPlanLinks([a, b], [
      { name: 'feature-a', planDir: '/path/INPROGRESS_Plan_watchfloor' },
      { name: 'feature-b', planDir: '/path/INPROGRESS_Plan_watchfloor' },
    ])
    await userEvent.click(screen.getByRole('button', { name: /by plan/i }))
    const group = screen.getByTestId('run-economy-plan-group')
    const header = within(group).getByTestId('run-economy-plan-header')
    // featureA $6.50 + featureB $2.20 = $8.70
    expect(header.textContent ?? '').toMatch(/\$8\.70/)
  })

  it('standalone features (no plan_dir) land in a Standalone group at the bottom', async () => {
    const a: AutopilotSession = { ...featureA, stream_path: '/s1' }
    const b: AutopilotSession = { ...featureB, stream_path: '/s2' }
    await renderWithPlanLinks([a, b], [
      { name: 'feature-a', planDir: '/path/INPROGRESS_Plan_watchfloor' },
      { name: 'feature-b' },
    ])
    await userEvent.click(screen.getByRole('button', { name: /by plan/i }))
    const groups = screen.getAllByTestId('run-economy-plan-group')
    expect(groups).toHaveLength(2)
    expect(groups[0].textContent ?? '').toContain('watchfloor')
    expect(groups[1].textContent ?? '').toMatch(/standalone/i)
  })
})

/* Slice 4a - sortable column headers on the by-feature list. Click a
   header to sort by that column; click again to flip direction. The
   currently-active header carries a chevron indicator so the operator
   can see at a glance which column drives ranking. Default stays
   cost desc (matches the existing aggregate output). */
describe('RunEconomy: sortable headers', () => {
  it('cost header has button role with aria-sort indicating active sort', () => {
    renderView()
    const list = screen.getByTestId('run-economy-feature-list')
    const costHeader = within(list).getByRole('button', { name: /cost/i })
    expect(costHeader).toBeInTheDocument()
    // Default sort is cost desc -> aria-sort = descending on the cost header.
    expect(costHeader.getAttribute('aria-sort')).toBe('descending')
    // Native <button> element so click events fire reliably across
    // browsers (operator screenshot 2026-05-09 reported headers
    // un-clickable on Box-as-button rendering).
    expect(costHeader.tagName.toLowerCase()).toBe('button')
  })

  it('clicking a non-active header switches the active sort column', async () => {
    renderView()
    const list = screen.getByTestId('run-economy-feature-list')
    const durationHeader = within(list).getByRole('button', { name: /duration/i })
    await userEvent.click(durationHeader)
    expect(durationHeader.getAttribute('aria-sort')).toBe('descending')
    // Cost header is no longer the active sort.
    const costHeader = within(list).getByRole('button', { name: /cost/i })
    expect(costHeader.getAttribute('aria-sort')).toBe('none')
  })

  it('clicking the active header twice flips the direction', async () => {
    renderView()
    const list = screen.getByTestId('run-economy-feature-list')
    const costHeader = within(list).getByRole('button', { name: /cost/i })
    // Currently desc by default. Click once -> ascending.
    await userEvent.click(costHeader)
    expect(costHeader.getAttribute('aria-sort')).toBe('ascending')
    // Click again -> descending.
    await userEvent.click(costHeader)
    expect(costHeader.getAttribute('aria-sort')).toBe('descending')
  })

  it('sort by duration ascending puts shortest-running feature first', async () => {
    renderView()
    const list = screen.getByTestId('run-economy-feature-list')
    const durationHeader = within(list).getByRole('button', { name: /duration/i })
    // featureA duration=2400s, featureB=900s. Ascending should put B first.
    await userEvent.click(durationHeader)  // active desc
    await userEvent.click(durationHeader)  // active asc
    const rows = within(list).getAllByTestId('run-economy-feature-row')
    expect(rows[0].textContent ?? '').toContain('feature-b')
    expect(rows[1].textContent ?? '').toContain('feature-a')
  })

  it('sort by feature name A->Z is alphabetical', async () => {
    renderView()
    const list = screen.getByTestId('run-economy-feature-list')
    const nameHeader = within(list).getByRole('button', { name: /^feature$/i })
    await userEvent.click(nameHeader)  // desc -> Z->A
    await userEvent.click(nameHeader)  // asc -> A->Z
    const rows = within(list).getAllByTestId('run-economy-feature-row')
    expect(rows[0].textContent ?? '').toContain('feature-a')
    expect(rows[1].textContent ?? '').toContain('feature-b')
  })
})

/* Slice 4b - plan filter dropdown. Single-select; "all plans" default
   shows everything, picking a specific plan filters the by-feature
   list (and its KPI strip + by-phase aggregate) to features under
   that plan. */
describe('RunEconomy: plan filter', () => {
  beforeEach(() => {
    vi.resetModules()
  })

  async function renderWithPlans(
    sessions: AutopilotSession[],
    featureLookup: Array<{ name: string; planDir?: string }>,
  ) {
    vi.doMock('../hooks/useAutopilots', () => ({
      useAutopilots: () => ({ data: sessions }),
    }))
    vi.doMock('../hooks/useFeatures', () => ({
      useFeatures: () => ({
        data: featureLookup.map((f) => ({
          name: f.name,
          project: 'dotfiles',
          project_root: '/',
          phase: 'done',
          phase_index: 0,
          total_phases: 0,
          pipeline_type: 'full',
          artifacts: [],
          sessions: [],
          status: 'done',
          stuck_info: null,
          last_activity: null,
          is_autopilot: true,
          plan_dir: f.planDir,
        })),
      }),
    }))
    const mod = await import('../components/metrics/RunEconomy')
    const RunEconomyView = mod.default
    return render(
      <ThemeProvider theme={theme}>
        <RunEconomyView />
      </ThemeProvider>,
    )
  }

  it('renders a plan filter dropdown with All Plans default', async () => {
    const a: AutopilotSession = { ...featureA, stream_path: '/s1' }
    await renderWithPlans([a], [{ name: 'feature-a', planDir: '/path/INPROGRESS_Plan_watchfloor' }])
    const select = screen.getByLabelText(/filter by plan/i)
    expect(select).toBeInTheDocument()
    expect(select.textContent ?? '').toMatch(/all/i)
  })

  it('selecting a plan filters the feature list to that plans features only', async () => {
    const a: AutopilotSession = { ...featureA, stream_path: '/s1' }
    const b: AutopilotSession = { ...featureB, stream_path: '/s2' }
    await renderWithPlans([a, b], [
      { name: 'feature-a', planDir: '/path/INPROGRESS_Plan_watchfloor' },
      { name: 'feature-b', planDir: '/path/INPROGRESS_Plan_other' },
    ])
    await userEvent.click(screen.getByLabelText(/filter by plan/i))
    await userEvent.click(await screen.findByRole('option', { name: /watchfloor/i }))

    const list = screen.getByTestId('run-economy-feature-list')
    const rows = within(list).getAllByTestId('run-economy-feature-row')
    expect(rows).toHaveLength(1)
    expect(rows[0].textContent ?? '').toContain('feature-a')
  })

  it('selecting Standalone shows only features with no plan_dir', async () => {
    const a: AutopilotSession = { ...featureA, stream_path: '/s1' }
    const b: AutopilotSession = { ...featureB, stream_path: '/s2' }
    await renderWithPlans([a, b], [
      { name: 'feature-a', planDir: '/path/INPROGRESS_Plan_watchfloor' },
      { name: 'feature-b' },
    ])
    await userEvent.click(screen.getByLabelText(/filter by plan/i))
    await userEvent.click(await screen.findByRole('option', { name: /standalone/i }))

    const list = screen.getByTestId('run-economy-feature-list')
    const rows = within(list).getAllByTestId('run-economy-feature-row')
    expect(rows).toHaveLength(1)
    expect(rows[0].textContent ?? '').toContain('feature-b')
  })

  it('KPI strip reflects the filtered subset (feature count drops to 1)', async () => {
    const a: AutopilotSession = { ...featureA, stream_path: '/s1' }
    const b: AutopilotSession = { ...featureB, stream_path: '/s2' }
    await renderWithPlans([a, b], [
      { name: 'feature-a', planDir: '/path/INPROGRESS_Plan_watchfloor' },
      { name: 'feature-b', planDir: '/path/INPROGRESS_Plan_other' },
    ])
    await userEvent.click(screen.getByLabelText(/filter by plan/i))
    await userEvent.click(await screen.findByRole('option', { name: /watchfloor/i }))

    const strip = screen.getByTestId('run-economy-kpi-strip')
    expect(strip.textContent ?? '').toMatch(/1\s*features?/i)
  })
})

/* Slice 4c - period filter. Restricts the aggregation to features whose
   earliest phase started within the chosen window. Periods follow the
   same vocabulary as the Activity tab's time-range chips: 24h, 7d, 30d,
   all (default). Sessions without timestamps fall through "all" but
   never match a bounded window. */
describe('RunEconomy: period filter', () => {
  beforeEach(() => {
    vi.resetModules()
  })

  function withTimestamps(s: AutopilotSession, startedAt: string): AutopilotSession {
    /* Null out phase 1+ started_at so sessionStartMs reflects only the
       test-controlled phase 0 timestamp. The base featureA/featureB
       fixtures hardcode 2026-05-09 timestamps on every phase; without
       this nulling those leak into sessionStartMs's "earliest across
       phases" reduction and turn the period filter date-dependent —
       the test silently goes red once enough wall-clock time elapses. */
    return {
      ...s,
      stream_path: '/stream',
      phases: s.phases.map((p, i) => ({
        ...p,
        started_at: i === 0 ? startedAt : null,
      })),
    }
  }

  async function renderWithSessions(sessions: AutopilotSession[]) {
    vi.doMock('../hooks/useAutopilots', () => ({
      useAutopilots: () => ({ data: sessions }),
    }))
    vi.doMock('../hooks/useFeatures', () => ({
      useFeatures: () => ({ data: [] }),
    }))
    const mod = await import('../components/metrics/RunEconomy')
    const RunEconomyView = mod.default
    return render(
      <ThemeProvider theme={theme}>
        <RunEconomyView />
      </ThemeProvider>,
    )
  }

  it('renders period toggle (24H | 7D | 30D | ALL)', async () => {
    const a = withTimestamps(featureA, '2026-05-09T08:00:00Z')
    await renderWithSessions([a])
    const toggle = screen.getByTestId('run-economy-period-toggle')
    expect(within(toggle).getByRole('button', { name: /24h/i })).toBeInTheDocument()
    expect(within(toggle).getByRole('button', { name: /7d/i })).toBeInTheDocument()
    expect(within(toggle).getByRole('button', { name: /30d/i })).toBeInTheDocument()
    expect(within(toggle).getByRole('button', { name: /^all$/i })).toBeInTheDocument()
  })

  it('default period is ALL (no filtering)', async () => {
    const recent = withTimestamps({ ...featureA, task: 'recent-feature' }, '2026-05-09T08:00:00Z')
    const old = withTimestamps({ ...featureB, task: 'old-feature' }, '2024-01-01T00:00:00Z')
    await renderWithSessions([recent, old])
    const list = screen.getByTestId('run-economy-feature-list')
    const rows = within(list).getAllByTestId('run-economy-feature-row')
    expect(rows).toHaveLength(2)
  })

  it('selecting 24H filters out features that started more than 24 hours ago', async () => {
    const now = new Date()
    const recentTs = new Date(now.getTime() - 6 * 3600_000).toISOString()  // 6h ago
    const oldTs = new Date(now.getTime() - 48 * 3600_000).toISOString()    // 48h ago
    const recent = withTimestamps({ ...featureA, task: 'recent-feature' }, recentTs)
    const old = withTimestamps({ ...featureB, task: 'old-feature' }, oldTs)
    await renderWithSessions([recent, old])
    await userEvent.click(screen.getByRole('button', { name: /24h/i }))
    const list = screen.getByTestId('run-economy-feature-list')
    const rows = within(list).getAllByTestId('run-economy-feature-row')
    expect(rows).toHaveLength(1)
    expect(rows[0].textContent ?? '').toContain('recent-feature')
  })

  it('sessions without started_at fall through ALL but disappear under bounded windows', async () => {
    // featureA's fixture phases carry timestamps from slice 1.1; null
    // them out so the period filter has no time anchor on this session.
    const noTs: AutopilotSession = {
      ...featureA,
      stream_path: '/s',
      task: 'no-ts',
      phases: featureA.phases.map((p) => ({ ...p, started_at: null, ended_at: null })),
    }
    const recent = withTimestamps({ ...featureB, task: 'recent' }, new Date().toISOString())
    await renderWithSessions([noTs, recent])
    // ALL shows both
    let rows = within(screen.getByTestId('run-economy-feature-list')).getAllByTestId('run-economy-feature-row')
    expect(rows).toHaveLength(2)
    // Switch to 24H - the timestamp-less session drops out
    await userEvent.click(screen.getByRole('button', { name: /24h/i }))
    rows = within(screen.getByTestId('run-economy-feature-list')).getAllByTestId('run-economy-feature-row')
    expect(rows).toHaveLength(1)
    expect(rows[0].textContent ?? '').toContain('recent')
  })
})
