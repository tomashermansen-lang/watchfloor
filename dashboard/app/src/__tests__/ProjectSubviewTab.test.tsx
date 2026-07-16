// ENV NOTE: this suite mounts MUI-responsive components that call
// window.matchMedia on render. jsdom doesn't implement it; src/test-setup.ts
// polyfills it. Without the polyfill these 9 cases throw
// "window.matchMedia is not a function" (regression caught 2026-06-02 when
// run-all.sh finally ran the frontend suite).
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'

vi.mock('../hooks/usePlans', () => ({ usePlans: vi.fn() }))
vi.mock('../hooks/usePlan', () => ({ usePlan: vi.fn() }))
vi.mock('../hooks/useSessions', () => ({ useSessions: vi.fn() }))
vi.mock('../hooks/useFeatures', () => ({ useFeatures: () => ({ data: [], isLoading: false }) }))

/* controls-06 #8 — ProjectHeader (per-project subview) now mounts a
   SessionControls for the chain (mirrors the ProjectPanel pattern on
   the Plans tab). Stub useSessionControls to a quiescent idle so the
   pre-existing Vision / Deferred / Deviations tests don't have to
   manage a real /api/chain/status SWR poll, and so the chain Start
   button shows up when needed below. */
const { useSessionControlsMock } = vi.hoisted(() => ({
  useSessionControlsMock: vi.fn(),
}))
vi.mock('../hooks/useSessionControls', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../hooks/useSessionControls')>()
  return { ...actual, useSessionControls: useSessionControlsMock }
})

import { usePlans } from '../hooks/usePlans'
import { usePlan } from '../hooks/usePlan'
import { useSessions } from '../hooks/useSessions'
import ProjectSubviewTab from '../components/ProjectSubviewTab'

useSessionControlsMock.mockReturnValue({
  state: 'idle',
  isPausing: false,
  pauseElapsedSeconds: 0,
  error: null,
  tmuxSession: null,
  isStale: false,
  mutate: {
    start: vi.fn().mockResolvedValue(undefined),
    pause: vi.fn().mockResolvedValue(undefined),
    resume: vi.fn().mockResolvedValue(undefined),
    cancel: vi.fn().mockResolvedValue(undefined),
  },
})

const swr = { isLoading: false, error: undefined, mutate: vi.fn(), isValidating: false }

function renderTab(subview: 'vision' | 'pipeline' | 'deferred' | 'deviations') {
  return render(
    <ThemeProvider theme={theme}>
      <ProjectSubviewTab projectId="alpha" subview={subview} />
    </ThemeProvider>,
  )
}

describe('ProjectSubviewTab — Vision pane chips → wf StatusPill (muted)', () => {
  beforeEach(() => {
    vi.mocked(usePlans).mockReturnValue({ data: [{ project: 'alpha', path: '/p', plan_dir: '/p' }], ...swr } as never)
    vi.mocked(useSessions).mockReturnValue({ data: [], ...swr } as never)
    vi.mocked(usePlan).mockReturnValue({
      data: {
        schema_version: '2.0.0',
        name: 'Alpha',
        vision: 'A grand plan',
        tech_stack: ['react', 'mui', 'vitest'],
        success_criteria: [
          { id: 'sc-1', description: 'all tests pass', measurable_via: 'pytest' },
        ],
        phases: [],
      },
      ...swr,
    } as never)
  })

  it('renders tech-stack entries as wf-status-pill (muted)', () => {
    const { container } = renderTab('vision')
    const pills = container.querySelectorAll('[data-testid="wf-status-pill"][data-status="muted"]')
    /* 3 tech-stack chips + 1 measurable_via chip = 4 muted pills */
    expect(pills.length).toBeGreaterThanOrEqual(3)
    const labels = Array.from(pills).map((p) => p.textContent?.toLowerCase())
    expect(labels).toEqual(expect.arrayContaining(['react', 'mui', 'vitest']))
  })

  it('Vision section labels render with the wfLabel brand variant', () => {
    const { getByText } = renderTab('vision')
    const visionLabel = getByText('Vision')
    expect(visionLabel.className).toMatch(/MuiTypography-wfLabel/)
    const techLabel = getByText('Tech stack')
    expect(techLabel.className).toMatch(/MuiTypography-wfLabel/)
  })

  it('Vision project name title renders with the wfH1 brand variant', () => {
    const { getByText } = renderTab('vision')
    /* projectId mock is 'alpha' — projectName falls through to it. */
    const title = getByText('alpha')
    expect(title.className).toMatch(/MuiTypography-wfH1/)
  })
})

describe('ProjectSubviewTab — Deferred pane mounts DeferredAuditView', () => {
  beforeEach(() => {
    vi.mocked(usePlans).mockReturnValue({ data: [{ project: 'alpha', path: '/p', plan_dir: '/p' }], ...swr } as never)
    vi.mocked(useSessions).mockReturnValue({ data: [], ...swr } as never)
    /* Schema 2.0 keeps `deferred` at the top level of the plan
       (not nested under project.) — that's the contract
       DeferredAuditView consumes. */
    vi.mocked(usePlan).mockReturnValue({
      data: {
        schema_version: '2.0.0',
        name: 'Alpha',
        deferred: [
          {
            id: 'd1', kind: 'code_finding', finding_id: 'f1', rule: 'r1',
            file: 'a.py', line: 1, state: 'WontFix', reason: 'r',
            owner: 'a', reviewed_at: '2026-04-01', review_trigger: 'manual-review',
          },
          {
            id: 'd2', kind: 'review_suggestion', date: '2026-04-01',
            feature_or_task_id: 't1', phase_id: 'p1', reviewer: 'rev',
            category: 'SOLID', description: 'x', reason_deferred: 'y',
          },
        ],
        phases: [],
      },
      ...swr,
    } as never)
  })

  it('renders the rich DeferredAuditView with kind toggle chips', () => {
    /* The deferred sub-tab now mounts DeferredAuditView (kind tabs +
       state/owner toggle chips + DataGrid). Verify the kind chips
       render with their human labels — proves the rich view is
       actually wired in, not just an empty Box. */
    renderTab('deferred')
    expect(screen.getByRole('button', { name: 'Code findings' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Review suggestions' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Scope decisions' })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: 'Future enhancements' })).toBeInTheDocument()
  })
})

describe('ProjectSubviewTab — Deviations pane chips → wf StatusPill (muted)', () => {
  beforeEach(() => {
    vi.mocked(usePlans).mockReturnValue({ data: [{ project: 'alpha', path: '/p', plan_dir: '/p' }], ...swr } as never)
    vi.mocked(useSessions).mockReturnValue({ data: [], ...swr } as never)
    vi.mocked(usePlan).mockReturnValue({
      data: {
        schema_version: '2.0.0',
        name: 'Alpha',
        phases: [{
          id: 'p1', name: 'Phase 1',
          tasks: [{
            id: 't1', name: 'Task',
            phase_results: [
              { phase: 'implement', conformance: 'aligned' },
              { phase: 'review', conformance: 'deviated' },
            ],
          }],
        }],
      },
      ...swr,
    } as never)
  })

  it('renders phase chips as wf-status-pill (muted)', () => {
    const { container } = renderTab('deviations')
    const pills = container.querySelectorAll('[data-testid="wf-status-pill"][data-status="muted"]')
    expect(pills.length).toBeGreaterThanOrEqual(2)
  })
})

describe('ProjectSubviewTab — Deviations pane surfaces deviation detail fields', () => {
  /* Backlog #30 follow-up: the summary row was the only thing rendered, so the
     actual `deviations[]` payload (description/reason/evidence/type/confidence)
     was invisible even though it lives in the YAML. These tests pin the detail
     surface so we don't regress to summary-only. */
  beforeEach(() => {
    vi.mocked(usePlans).mockReturnValue({ data: [{ project: 'alpha', path: '/p', plan_dir: '/p' }], ...swr } as never)
    vi.mocked(useSessions).mockReturnValue({ data: [], ...swr } as never)
    vi.mocked(usePlan).mockReturnValue({
      data: {
        schema_version: '2.0.0',
        name: 'Alpha',
        phases: [{
          id: 'p1', name: 'Phase 1',
          tasks: [{
            id: 't-rich', name: 'Task with rich deviations',
            phase_results: [
              {
                phase: 'qa',
                timestamp: '2026-05-04T12:00:00Z',
                conformance: 'deviated',
                acceptance_status: 'partial',
                deviations: [
                  {
                    type: 'scope_creep',
                    description: 'touched 4 files; estimate was 2',
                    reason: 'shared util refactor was unavoidable',
                    impact: 'modified',
                    confidence: 0.85,
                    evidence: 'src/lib/util.ts:42; src/lib/index.ts:1',
                    criteria_affected: ['AC-A'],
                  },
                  {
                    type: 'requirement_gap',
                    description: 'AC-D acceptance criterion not implemented',
                    reason: 'spec ambiguous about edge case',
                    impact: 'gap',
                    confidence: 0.7,
                    evidence: 'tests/test_foo.py:120',
                    criteria_affected: ['AC-D'],
                  },
                ],
              },
              { phase: 'implement', conformance: 'aligned', deviations: [] },
            ],
          }],
        }],
      },
      ...swr,
    } as never)
  })

  it('shows description + reason + evidence text for each deviation', () => {
    renderTab('deviations')
    expect(screen.getByText(/touched 4 files; estimate was 2/)).toBeInTheDocument()
    expect(screen.getByText(/shared util refactor was unavoidable/)).toBeInTheDocument()
    expect(screen.getByText(/src\/lib\/util\.ts:42/)).toBeInTheDocument()
    expect(screen.getByText(/AC-D acceptance criterion not implemented/)).toBeInTheDocument()
    expect(screen.getByText(/spec ambiguous about edge case/)).toBeInTheDocument()
    expect(screen.getByText(/tests\/test_foo\.py:120/)).toBeInTheDocument()
  })

  it('shows the deviation type and confidence on each deviation', () => {
    renderTab('deviations')
    expect(screen.getByText(/scope_creep/)).toBeInTheDocument()
    expect(screen.getByText(/requirement_gap/)).toBeInTheDocument()
    /* confidence is rendered as a percentage or 0.85 — accept either format */
    const text = document.body.textContent ?? ''
    expect(text).toMatch(/0\.85|85%/)
    expect(text).toMatch(/0\.70|70%|0\.7/)
  })

  it('renders nothing for the deviated row when deviations[] is empty (aligned)', () => {
    /* For the aligned implement phase there should be no detail block. */
    renderTab('deviations')
    /* Anchor: only one row's worth of detail blocks (the qa one with 2 deviations). */
    const detailNodes = document.querySelectorAll('[data-testid="deviation-detail"]')
    expect(detailNodes.length).toBe(2)
  })
})

/* controls-06 #8 — per-project subview Pipeline tab gains the same
   chain-control surface the Plans-tab ProjectPanel got in cycles
   1-7. The header now mirrors the watchfloor grid pattern
   (screens.md:35 Feature portfolio precedent): plan-title cluster
   (name + StatusPill in a shared flex) → action column → bar →
   counts → label → percent. Operator can Start / Pause / Cancel /
   Restart the chain without having to navigate back to the Plans
   tab. */
describe('ProjectSubviewTab — Pipeline pane mounts SessionControls', () => {
  beforeEach(() => {
    vi.mocked(usePlans).mockReturnValue({
      data: [{
        project: 'alpha',
        path: '/p',
        plan_dir: '/p/docs/INPROGRESS_Plan_alpha-chain',
        lifecycle: 'inprogress',
        active_session_count: 0,
      }],
      ...swr,
    } as never)
    vi.mocked(useSessions).mockReturnValue({ data: [], ...swr } as never)
    vi.mocked(usePlan).mockReturnValue({
      data: {
        schema_version: '2.0.0',
        name: 'pipeline-smoke-test',
        phases: [{
          id: 'p1', name: 'Phase 1',
          tasks: [
            { id: 't1', name: 'T1', status: 'pending' },
            { id: 't2', name: 'T2', status: 'pending' },
          ],
        }],
      },
      ...swr,
    } as never)
  })

  it('Pipeline header mounts a Start chain button', () => {
    renderTab('pipeline')
    expect(screen.getByRole('button', { name: /^Start chain$/i })).toBeInTheDocument()
  })

  it('Pipeline header clusters the StatusPill with the plan title', () => {
    renderTab('pipeline')
    const cluster = screen.getByTestId('plan-title-cluster')
    expect(within(cluster).getByText('pipeline-smoke-test')).toBeInTheDocument()
    expect(within(cluster).getByTestId('wf-status-pill')).toBeInTheDocument()
  })

  it('Pipeline header renders the row-counts / TASKS / percent cells', () => {
    renderTab('pipeline')
    const row = screen.getByTestId('plan-header-row')
    expect(within(row).getByTestId('plan-row-counts')).toBeInTheDocument()
    expect(within(row).getByTestId('plan-row-label')).toBeInTheDocument()
    expect(within(row).getByTestId('plan-row-percent')).toBeInTheDocument()
  })

  it('Pipeline header places SessionControls BEFORE the progress bar in DOM order', () => {
    renderTab('pipeline')
    const startBtn = screen.getByRole('button', { name: /^Start chain$/i })
    const band = screen.getByTestId('segmented-progress')
    expect(
      band.compareDocumentPosition(startBtn) & Node.DOCUMENT_POSITION_PRECEDING,
    ).toBeTruthy()
  })
})
