import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import type { Feature, FeatureStatus } from '../types'

/* Node 22 / vitest 4 expose `localStorage` as a write-rejecting Proxy with
   no methods, which breaks `useFeatureFilters` hydration and persistence
   under jsdom. Replace it with a Map-backed shim before any module imports
   the hook. The shim is co-located in this test file per REQ-37
   (file-scope discipline). */
{
  const _store = new Map<string, string>()
  const shim: Storage = {
    getItem: (k: string): string | null =>
      _store.has(k) ? (_store.get(k) as string) : null,
    setItem: (k: string, v: string): void => {
      _store.set(k, String(v))
    },
    removeItem: (k: string): void => {
      _store.delete(k)
    },
    clear: (): void => {
      _store.clear()
    },
    key: (i: number): string | null => Array.from(_store.keys())[i] ?? null,
    get length(): number {
      return _store.size
    },
  }
  Object.defineProperty(globalThis, 'localStorage', {
    value: shim,
    configurable: true,
    writable: true,
  })
  if (typeof window !== 'undefined') {
    Object.defineProperty(window, 'localStorage', {
      value: shim,
      configurable: true,
      writable: true,
    })
  }
}

// Mock hooks before importing components
vi.mock('../hooks/useFeatures', () => ({
  useFeatures: vi.fn(),
}))

vi.mock('../hooks/useAutopilots', () => ({
  useAutopilots: () => ({ data: [], isLoading: false }),
}))

vi.mock('../hooks/useFeatureArtifacts', () => ({
  useFeatureArtifacts: () => ({ data: undefined }),
}))

vi.mock('../hooks/useSessionActivity', () => ({
  useSessionActivity: () => ({ events: [], isActive: false }),
}))

// controls-02 #1 — FeatureDetail Branch B now mounts SessionControls.
// Mock it as a prop-capturing stub so this suite stays isolated from
// useSessionControls / SWR / fetch the way SessionPanel.test.tsx does.
vi.mock('../components/SessionControls', () => ({
  SessionControls: (props: {
    targetKind: string
    targetId: string | null
    autopilotMode?: string
    hideStateChip?: boolean
  }) => (
    <div
      data-testid="session-controls-mock"
      data-target-kind={props.targetKind}
      data-target-id={props.targetId ?? ''}
      data-autopilot-mode={props.autopilotMode ?? ''}
      data-hide-state-chip={props.hideStateChip ? 'true' : 'false'}
    />
  ),
}))

/* feature-plan-link-and-nav (REQ-1, REQ-2) — FeatureCard now consumes
   `usePlans()` to resolve the plan-link chip label. The default mock
   returns `{ data: undefined }` so existing FE-1..FE-7 tests (whose
   `mockFeature` has no `plan_dir`/`plan_task_id`) render no chip and
   stay byte-identical to the predecessor baseline. Chip-specific tests
   set `vi.mocked(usePlans).mockReturnValue(...)` per case. */
vi.mock('../hooks/usePlans', () => ({
  usePlans: vi.fn(() => ({ data: undefined, isLoading: false })),
}))

import { useFeatures } from '../hooks/useFeatures'
import { usePlans } from '../hooks/usePlans'
import FeaturesView from '../components/features/FeaturesView'
import FeatureCard, {
  type OnNavigateToPlan,
} from '../components/features/FeatureCard'
import FeatureDetail from '../components/features/FeatureDetail'

const mockFeature = (overrides: Partial<Feature> = {}): Feature => ({
  name: 'test-feature',
  project: 'test-project',
  project_root: '/tmp/test',
  phase: 'implement',
  phase_index: 3,
  total_phases: 8,
  pipeline_type: 'light',
  artifacts: [{ name: 'REQUIREMENTS.md', file: 'REQUIREMENTS.md' }],
  sessions: [{ sid: 'sess-123', status: 'working', last_ts: '2026-01-01T00:00:00Z' }],
  status: 'active',
  stuck_info: null,
  last_activity: '2026-01-01T00:00:00Z',
  is_autopilot: false,
  ...overrides,
})

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

/* ═══ FeaturesView ═══ */

describe('FeaturesView', () => {
  beforeEach(() => {
    /* RSK-2 — clear filter persistence between tests so AS-2 / AS-11
       state does not bleed into unrelated cases. */
    localStorage.removeItem('wf.featureFilters.v1')
    vi.mocked(useFeatures).mockReturnValue({
      data: undefined,
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useFeatures>)
  })

  it('FE-1: shows empty state when no features', () => {
    vi.mocked(useFeatures).mockReturnValue({
      data: [],
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useFeatures>)
    renderWithTheme(<FeaturesView />)
    expect(screen.getByText('No features in progress')).toBeInTheDocument()
  })

  it('FE-2: renders features sorted by status urgency', () => {
    const features: Feature[] = [
      mockFeature({ name: 'paused-feat', status: 'paused', sessions: [] }),
      mockFeature({ name: 'stuck-feat', status: 'stuck', stuck_info: { reason: 'attractor_loop', tool: 'Read', file: 'x.ts' } }),
      mockFeature({ name: 'active-feat', status: 'active' }),
    ]
    vi.mocked(useFeatures).mockReturnValue({
      data: features,
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useFeatures>)
    renderWithTheme(<FeaturesView />)
    const cards = screen.getAllByTestId('feature-card')
    // stuck first, active second, paused third
    expect(within(cards[0]).getByText('stuck-feat')).toBeInTheDocument()
    expect(within(cards[1]).getByText('active-feat')).toBeInTheDocument()
    expect(within(cards[2]).getByText('paused-feat')).toBeInTheDocument()
  })
})

/* ═══ FeatureCard ═══ */

describe('FeatureCard', () => {
  it('FE-3: shows all required info', () => {
    const feature = mockFeature()
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    expect(screen.getByText('test-feature')).toBeInTheDocument()
    expect(screen.getByText('test-project')).toBeInTheDocument()
    expect(screen.getByTestId('phase-chip')).toBeInTheDocument()
    expect(screen.getByTestId('status-chip')).toBeInTheDocument()
  })

  it('FE-4: status chip shows correct status text', () => {
    const feature = mockFeature({ status: 'stuck' })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    const statusChip = screen.getByTestId('status-chip')
    expect(statusChip).toHaveTextContent('stuck')
  })

  /* Brand handoff §UI Primitives — status chip is a wf StatusPill;
     phase chip is a muted StatusPill (it's a tag, not status). */
  it('FE-4b: status chip is a wf-status-pill mapped via featureToWfStatus', () => {
    const feature = mockFeature({ status: 'stuck' })
    const { container } = renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    const pill = container.querySelector('[data-testid="status-chip"] [data-testid="wf-status-pill"]')
    expect(pill).not.toBeNull()
    /* stuck → fault */
    expect(pill?.getAttribute('data-status')).toBe('fault')
  })

  it('FE-4c: phase chip is a muted wf-status-pill (tag, not status)', () => {
    const feature = mockFeature({ phase: 'implement' })
    const { container } = renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    const pill = container.querySelector('[data-testid="phase-chip"] [data-testid="wf-status-pill"]')
    expect(pill?.getAttribute('data-status')).toBe('muted')
  })

  /* FE-5..6 replaced by FE-5a..c — every card now carries an
     execution-mode icon (full/light/manual). The triplet mirrors
     SessionPanel + Pipeline so operators read the same icon in
     every surface. */
  it('FE-5a: autopilot + pipeline=full → execution-mode icon "full"', () => {
    const feature = mockFeature({ is_autopilot: true, pipeline_type: 'full' })
    const { container } = renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    expect(container.querySelector('[data-execution-mode="full"]')).not.toBeNull()
  })

  it('FE-5b: autopilot + pipeline=light → execution-mode icon "light"', () => {
    const feature = mockFeature({ is_autopilot: true, pipeline_type: 'light' })
    const { container } = renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    expect(container.querySelector('[data-execution-mode="light"]')).not.toBeNull()
  })

  it('FE-5c: not autopilot → execution-mode icon "manual"', () => {
    const feature = mockFeature({ is_autopilot: false })
    const { container } = renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    expect(container.querySelector('[data-execution-mode="manual"]')).not.toBeNull()
  })

  /* FE-7: progress bar uses midpoint heuristic so an active feature
     in its FIRST phase still shows a visible blue sliver (~5%) rather
     than 0%. Per audit-11: user feedback "den kommer heller ikke nar
     den er i plan" — strict completed/total formula left phase 0
     invisible. (phase_index + 0.5) / total_phases reads as "halfway
     through the current phase", which is a reasonable visual proxy
     when sub-phase progress isn't tracked. */
  it('FE-7: progress bar uses midpoint heuristic — half a phase past completed-count', () => {
    const feature = mockFeature({ phase_index: 2, total_phases: 5 })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    const progressBar = screen.getByRole('progressbar')
    expect(progressBar).toBeInTheDocument()
    /* (2 + 0.5) / 5 = 50 */
    expect(progressBar).toHaveAttribute('aria-valuenow', '50')
  })

  it('FE-7b: feature on the last active phase is NOT shown as 100% complete', () => {
    const feature = mockFeature({ phase_index: 7, total_phases: 8, status: 'active' })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    const progressBar = screen.getByRole('progressbar')
    /* (7 + 0.5) / 8 = 93.75 → 94 (still < 100, so the last-phase
       activity is visually distinct from a completed feature) */
    expect(progressBar).toHaveAttribute('aria-valuenow', '94')
  })

  it('FE-7e: feature in its FIRST active phase shows a visible sliver — never 0% (audit-11)', () => {
    const feature = mockFeature({ phase_index: 0, total_phases: 9, status: 'active' })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    const progressBar = screen.getByRole('progressbar')
    /* (0 + 0.5) / 9 = 5.56 → 6, visible at 240px wide bar */
    expect(progressBar).toHaveAttribute('aria-valuenow', '6')
  })

  it('FE-7c: status=done renders 100% regardless of phase_index', () => {
    const feature = mockFeature({ phase_index: 5, total_phases: 8, status: 'done' })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    expect(screen.getByRole('progressbar')).toHaveAttribute('aria-valuenow', '100')
  })

  /* Brand handoff §UI Primitives Progress bar — sharp 4px wf.signal
     fill on wf.steel track + 0 0 6px wf.signal glow. The wf primitive
     <ProgressBar> encodes all of these; the card just feeds it value. */
  it('FE-7d: progress bar is the wf ProgressBar primitive (signal blue, sharp, glow)', () => {
    const feature = mockFeature()
    const { container } = renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    const root = container.querySelector('[data-testid="wf-progress-bar"]') as HTMLElement
    expect(root).not.toBeNull()
    const fill = container.querySelector('[data-testid="wf-progress-bar-fill"]') as HTMLElement
    expect(fill.style.backgroundColor).toBe('rgb(59, 158, 255)')
    expect(fill.style.boxShadow).toBe('0 0 6px #3B9EFF')
    expect(root.style.borderRadius).toBe('')
  })
})

/* ═══ FeatureDetail ═══ */

describe('FeatureDetail', () => {
  it('FD-1: renders pipeline phases', () => {
    const feature = mockFeature({ phase_index: 1, pipeline_type: 'light' })
    renderWithTheme(
      <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
    )
    expect(screen.getByText('BA')).toBeInTheDocument()
    expect(screen.getByText('Plan')).toBeInTheDocument()
    expect(screen.getByText('Implement')).toBeInTheDocument()
  })

  it('FD-2: renders artifact chips (ToggleChip strips .md extension)', () => {
    const feature = mockFeature({
      artifacts: [{ name: 'REQUIREMENTS.md', file: 'REQUIREMENTS.md' }],
    })
    renderWithTheme(
      <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
    )
    expect(screen.getByText('REQUIREMENTS')).toBeInTheDocument()
  })

  /* Brand handoff §UI Primitives — Documents converged to ToggleChip
     with the brand 'document' AppIcon glyph (commit b4fc013). Artifact
     entries no longer render as StatusPill clickable buttons. */
  it('FD-2b: artifact chips render as ToggleChip with document AppIcon', () => {
    const feature = mockFeature({
      artifacts: [{ name: 'REQUIREMENTS.md', file: 'REQUIREMENTS.md' }],
    })
    const { container } = renderWithTheme(
      <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
    )
    const chips = container.querySelectorAll('[data-testid="wf-toggle-chip"]')
    expect(chips.length).toBeGreaterThan(0)
    const docChip = Array.from(chips).find((c) => c.textContent?.includes('REQUIREMENTS'))
    expect(docChip).toBeDefined()
    expect(docChip!.querySelector('[data-icon="document"]')).not.toBeNull()
  })

  it('FD-2c: session-status chip renders as wf-status-pill (working → running)', () => {
    const feature = mockFeature({
      sessions: [{ sid: 'abc1234', status: 'working', last_ts: '2026-01-01T00:00:00Z' }],
    })
    const { container } = renderWithTheme(
      <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
    )
    const sessionPill = container.querySelector('[data-testid="session-entry"] [data-testid="wf-status-pill"]')
    expect(sessionPill?.getAttribute('data-status')).toBe('running')
  })

  /* FD-7 — LIVE pill in header. atoms.md §LIVE pill says it
     'appears on every authenticated screen'. Render in FeatureDetail
     header when feature is live (active/stuck) so the brand recall
     surface anchors here too. Paused/done features omit it because
     the radar sweep would lie about active state. */
  describe('FD-7: LiveBadge in header', () => {
    it('renders wf-live-badge when feature is active', () => {
      const feature = mockFeature({ status: 'active' })
      const { container } = renderWithTheme(
        <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
      )
      expect(container.querySelector('[data-testid="wf-live-badge"]')).not.toBeNull()
    })

    it('renders wf-live-badge when feature is stuck (still live, just blocked)', () => {
      const feature = mockFeature({
        status: 'stuck',
        stuck_info: { reason: 'attractor_loop', tool: 'Edit', file: 's.py' },
      })
      const { container } = renderWithTheme(
        <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
      )
      expect(container.querySelector('[data-testid="wf-live-badge"]')).not.toBeNull()
    })

    it('omits wf-live-badge when feature is paused', () => {
      const feature = mockFeature({ status: 'paused' })
      const { container } = renderWithTheme(
        <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
      )
      expect(container.querySelector('[data-testid="wf-live-badge"]')).toBeNull()
    })

    it('omits wf-live-badge when feature is done', () => {
      const feature = mockFeature({ status: 'done' })
      const { container } = renderWithTheme(
        <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
      )
      expect(container.querySelector('[data-testid="wf-live-badge"]')).toBeNull()
    })
  })

  describe('FD-CTL: SessionControls in Branch B (controls-02 #1)', () => {
    it('FD-CTL.1: mounts SessionControls when autopilotSession is null', () => {
      const feature = mockFeature({ name: 'm9-token-and-cost-tracking', is_autopilot: false })
      renderWithTheme(
        <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
      )
      const ctl = screen.getByTestId('session-controls-mock')
      expect(ctl.getAttribute('data-target-kind')).toBe('autopilot')
      expect(ctl.getAttribute('data-target-id')).toBe('m9-token-and-cost-tracking')
      expect(ctl.getAttribute('data-hide-state-chip')).toBe('true')
    })

    it('FD-CTL.2: SessionControls mount is inside the feature-detail surface (not behind the artifact dialog)', () => {
      const feature = mockFeature({ name: 'auto-codify' })
      const { container } = renderWithTheme(
        <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
      )
      const ctl = container.querySelector('[data-testid="session-controls-mock"]')
      expect(ctl).not.toBeNull()
      // Header must precede the action row (chrome ordering: header → actions → main).
      const header = container.querySelector('[data-testid="detail-header"]')
      if (header && ctl) {
        const order = header.compareDocumentPosition(ctl)
        expect(order & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
      }
    })
  })

  /* FD-6 — phase-state indicator must use the brand atoms, not raw
     Material icons. Per design_handoff_watchfloor_v2 screens.md §3
     phase rail: completed = '✓ icon (status.completed)'. Brand
     extension: current = pulsing signal-blue StatusDot, queued =
     fog-grey StatusDot (no glow). MUI CheckCircleIcon /
     RadioButtonUncheckedIcon read as Material, not watchfloor. */
  describe('FD-6: phase-state icons use brand atoms', () => {
    it('renders a brand check (testid wf-phase-state-completed) for completed phases', () => {
      const feature = mockFeature({ phase_index: 3, pipeline_type: 'light' })
      const { container } = renderWithTheme(
        <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
      )
      // pipeline_type=light => 8 phases; phase_index=3 means 3 completed (idx 0,1,2)
      const checks = container.querySelectorAll('[data-testid="wf-phase-state-completed"]')
      expect(checks.length).toBe(3)
      expect(checks[0].textContent).toContain('✓')
    })

    /* PhaseStepper FullStepper marks each row with data-status=phase.status
       via the phase-row testid. The current row has data-status="running"
       (pulse via @keyframes pipelineDotPulse on the inner Box). */
    it('renders a single running phase-row for the current phase', () => {
      const feature = mockFeature({ phase_index: 2, pipeline_type: 'light' })
      const { container } = renderWithTheme(
        <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
      )
      const sidebar = container.querySelector('[data-testid="detail-sidebar"]') as HTMLElement
      const runningRows = sidebar.querySelectorAll('[data-testid="phase-row"][data-status="running"]')
      expect(runningRows.length).toBe(1)
    })

    it('renders pending phase-rows (light pipeline, idx=1 → 6 pending)', () => {
      const feature = mockFeature({ phase_index: 1, pipeline_type: 'light' })
      const { container } = renderWithTheme(
        <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
      )
      const sidebar = container.querySelector('[data-testid="detail-sidebar"]') as HTMLElement
      const pendingRows = sidebar.querySelectorAll('[data-testid="phase-row"][data-status="pending"]')
      expect(pendingRows.length).toBe(6)
    })
  })

  /* FD-5 — atomic structural assertion: the FeatureDetail surface
     must mirror SessionPanel's 2-column shell so users perceive the
     two screens (active autopilot vs paused feature) as one surface
     in different states. Sidebar holds Pipeline Progress + Documents,
     main content holds Stuck/Recent/Sessions. Per design_handoff
     screens.md §3 "Session detail drawer". */
  describe('FD-5: 2-column shell matching SessionPanel', () => {
    it('renders the canonical detail-sidebar (shared with SessionPanel)', () => {
      const feature = mockFeature()
      const { container } = renderWithTheme(
        <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
      )
      const sidebar = container.querySelector('[data-testid="detail-sidebar"]')
      expect(sidebar).not.toBeNull()
    })

    it('renders a main content area marked with data-testid="feature-detail-main"', () => {
      const feature = mockFeature()
      const { container } = renderWithTheme(
        <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
      )
      const main = container.querySelector('[data-testid="feature-detail-main"]')
      expect(main).not.toBeNull()
    })

    it('places Pipeline Progress label inside the sidebar (not the main area)', () => {
      const feature = mockFeature()
      const { container } = renderWithTheme(
        <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
      )
      const sidebar = container.querySelector('[data-testid="detail-sidebar"]') as HTMLElement
      expect(sidebar).not.toBeNull()
      expect(within(sidebar).getByText('Pipeline Progress')).toBeInTheDocument()
    })

    it('places artifacts inside the sidebar (Documents area, not main)', () => {
      const feature = mockFeature({
        artifacts: [{ name: 'REQUIREMENTS.md', file: 'REQUIREMENTS.md' }],
      })
      const { container } = renderWithTheme(
        <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
      )
      const sidebar = container.querySelector('[data-testid="detail-sidebar"]') as HTMLElement
      // ToggleChip strips the .md extension before display
      expect(within(sidebar).getByText('REQUIREMENTS')).toBeInTheDocument()
    })

    it('places sessions list inside the main content area (not sidebar)', () => {
      const feature = mockFeature({
        sessions: [{ sid: 'sess-abc', status: 'working', last_ts: '2026-01-01T00:00:00Z' }],
      })
      const { container } = renderWithTheme(
        <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
      )
      const main = container.querySelector('[data-testid="feature-detail-main"]') as HTMLElement
      expect(within(main).getByTestId('session-entry')).toBeInTheDocument()
    })
  })

  it('FD-3: shows stuck alert for attractor loop', () => {
    const feature = mockFeature({
      status: 'stuck',
      stuck_info: { reason: 'attractor_loop', tool: 'Edit', file: 'server.py' },
    })
    renderWithTheme(
      <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
    )
    const alert = screen.getByTestId('stuck-alert')
    expect(alert).toBeInTheDocument()
    expect(alert).toHaveTextContent('Edit')
    expect(alert).toHaveTextContent('server.py')
  })

  it('FD-4: shows stuck alert for permission oscillation', () => {
    const feature = mockFeature({
      status: 'stuck',
      stuck_info: { reason: 'permission_oscillation' },
    })
    renderWithTheme(
      <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
    )
    const alert = screen.getByTestId('stuck-alert')
    expect(alert).toHaveTextContent('permission prompts')
  })

  it('FD-5: no stuck alert when not stuck', () => {
    const feature = mockFeature({ stuck_info: null })
    renderWithTheme(
      <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
    )
    expect(screen.queryByTestId('stuck-alert')).not.toBeInTheDocument()
  })

  it('FD-6: renders session list', () => {
    const feature = mockFeature({
      sessions: [
        { sid: 'sess-abc1234', status: 'working', last_ts: '2026-01-01T00:00:00Z' },
        { sid: 'sess-def5678', status: 'needs_input', last_ts: '2026-01-01T00:00:01Z' },
        { sid: 'sess-ghi9012', status: 'working', last_ts: '2026-01-01T00:00:02Z' },
      ],
    })
    renderWithTheme(
      <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
    )
    const entries = screen.getAllByTestId('session-entry')
    expect(entries).toHaveLength(3)
  })

  it('FD-7: renders 5+ sessions in scrollable container', () => {
    const sessions = Array.from({ length: 6 }, (_, i) => ({
      sid: `sess-${String(i).padStart(7, '0')}`,
      status: 'working',
      last_ts: `2026-01-01T00:00:0${i}Z`,
    }))
    const feature = mockFeature({ sessions })
    renderWithTheme(
      <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
    )
    const entries = screen.getAllByTestId('session-entry')
    expect(entries).toHaveLength(6)
  })

  it('FD-8: delegates to SessionPanel for autopilot features', () => {
    const feature = mockFeature({ is_autopilot: true })
    const autopilotSession = {
      task: 'test-feature',
      project: 'test-project',
      branch: 'feature/test-feature',
      status: 'running' as const,
      phases: [],
      elapsed_s: 100,
      cost: null,
      log_path: null,
      stream_path: null,
    }
    renderWithTheme(
      <FeatureDetail feature={feature} autopilotSession={autopilotSession} onClose={vi.fn()} />
    )
    /* SessionPanel takes over when autopilot is active. The chrome
       (DetailHeader + DetailSidebar) is shared with the non-autopilot
       path so we can't use chrome testids to distinguish; instead we
       rely on the main-content divergence: SessionPanel never renders
       the 'Recent Activity' / 'Sessions' sections that FeatureDetail's
       paused-feature path puts in its main column. */
    expect(screen.queryByText('Recent Activity')).not.toBeInTheDocument()
  })

  it('R4c: shows activity section header for active features', () => {
    const feature = mockFeature({ status: 'active' })
    renderWithTheme(
      <FeatureDetail feature={feature} autopilotSession={null} onClose={vi.fn()} />
    )
    expect(screen.getByText('Recent Activity')).toBeInTheDocument()
  })
})

/* ═══ Filter Chips & Search ═══ */

const inprogressFeature = (overrides: Partial<Feature> = {}): Feature =>
  mockFeature({ lifecycle: 'inprogress', ...overrides })

const doneFeature = (overrides: Partial<Feature> = {}): Feature =>
  mockFeature({
    lifecycle: 'done',
    status: 'done',
    done_at: '2026-05-01T00:00:00Z',
    ...overrides,
  })

const pendingFeature = (overrides: Partial<Feature> = {}): Feature =>
  mockFeature({ lifecycle: 'pending', status: 'waiting', ...overrides })

function setFeatures(features: Feature[] | undefined, isLoading = false) {
  vi.mocked(useFeatures).mockReturnValue({
    data: features,
    isLoading,
    error: undefined,
    mutate: vi.fn(),
    isValidating: false,
  } as ReturnType<typeof useFeatures>)
}

function lifecycleChip(value: string): HTMLElement {
  return document.querySelector(
    `[data-filter="lifecycle"][data-value="${value}"] [data-testid="wf-toggle-chip"]`,
  ) as HTMLElement
}

function projectChip(value: string): HTMLElement {
  return document.querySelector(
    `[data-filter="project"][data-value="${value}"] [data-testid="wf-toggle-chip"]`,
  ) as HTMLElement
}

function sortChip(value: string): HTMLElement {
  return document.querySelector(
    `[data-filter="sort"][data-value="${value}"] [data-testid="wf-toggle-chip"]`,
  ) as HTMLElement
}

/* Group 1 — Hook integration & legacy removal */

describe('FeaturesView — filter integration', () => {
  beforeEach(() => {
    localStorage.removeItem('wf.featureFilters.v1')
  })

  it('T-1.1: renders without crashing under default filter tuple', () => {
    setFeatures([inprogressFeature({ name: 'only-feat', status: 'stuck' })])
    renderWithTheme(<FeaturesView />)
    expect(screen.getAllByTestId('feature-card')).toHaveLength(1)
    expect(within(screen.getAllByTestId('feature-card')[0]).getByText('only-feat')).toBeInTheDocument()
  })

  it('T-1.3: default sort renders cards in stuck → active → paused order', () => {
    const features: Feature[] = [
      inprogressFeature({ name: 'paused-feat', status: 'paused' }),
      inprogressFeature({ name: 'stuck-feat', status: 'stuck' }),
      inprogressFeature({ name: 'active-feat', status: 'active' }),
    ]
    setFeatures(features)
    renderWithTheme(<FeaturesView />)
    const cards = screen.getAllByTestId('feature-card')
    expect(within(cards[0]).getByText('stuck-feat')).toBeInTheDocument()
    expect(within(cards[1]).getByText('active-feat')).toBeInTheDocument()
    expect(within(cards[2]).getByText('paused-feat')).toBeInTheDocument()
  })

  it('T-1.4 / T-8.2: FeatureList does not write localStorage with non-hook keys', async () => {
    const setItemSpy = vi.spyOn(Storage.prototype, 'setItem')
    setFeatures([inprogressFeature({ name: 'a', status: 'stuck' })])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('pending'))
    /* All keys observed must be the hook's storage key. */
    for (const call of setItemSpy.mock.calls) {
      expect(call[0]).toBe('wf.featureFilters.v1')
    }
    setItemSpy.mockRestore()
  })
})

/* Group 2 — Lifecycle filter chips */

describe('FeaturesView — lifecycle chips', () => {
  beforeEach(() => {
    localStorage.removeItem('wf.featureFilters.v1')
  })

  it('T-2.1: default {Active, Paused} excludes pending and done', () => {
    setFeatures([
      inprogressFeature({ name: 'stuck-feat', status: 'stuck' }),
      pendingFeature({ name: 'pending-feat' }),
      doneFeature({ name: 'done-feat' }),
    ])
    renderWithTheme(<FeaturesView />)
    expect(screen.queryByText('pending-feat')).not.toBeInTheDocument()
    expect(screen.queryByText('done-feat')).not.toBeInTheDocument()
    expect(screen.getByText('stuck-feat')).toBeInTheDocument()
  })

  it('T-2.2: Active chip selects features with inprogress + status ∈ {stuck, waiting, active}', async () => {
    setFeatures([
      inprogressFeature({ name: 'stuck-f', status: 'stuck' }),
      inprogressFeature({ name: 'waiting-f', status: 'waiting' }),
      inprogressFeature({ name: 'active-f', status: 'active' }),
      inprogressFeature({ name: 'paused-f', status: 'paused' }),
    ])
    const { rerender } = renderWithTheme(<FeaturesView />)
    /* default {Active, Paused}: all four render */
    expect(screen.getAllByTestId('feature-card')).toHaveLength(4)
    /* deselect Paused */
    await userEvent.click(lifecycleChip('paused'))
    rerender(<ThemeProvider theme={theme}><FeaturesView /></ThemeProvider>)
    expect(screen.queryByText('paused-f')).not.toBeInTheDocument()
    expect(screen.getByText('stuck-f')).toBeInTheDocument()
    expect(screen.getByText('waiting-f')).toBeInTheDocument()
    expect(screen.getByText('active-f')).toBeInTheDocument()
  })

  it('T-2.3: Paused chip alone selects only inprogress + paused', async () => {
    setFeatures([
      inprogressFeature({ name: 'stuck-f', status: 'stuck' }),
      inprogressFeature({ name: 'paused-f', status: 'paused' }),
    ])
    renderWithTheme(<FeaturesView />)
    /* turn Active off */
    await userEvent.click(lifecycleChip('active'))
    expect(screen.queryByText('stuck-f')).not.toBeInTheDocument()
    expect(screen.getByText('paused-f')).toBeInTheDocument()
  })

  it('T-2.4: Pending chip selects features with lifecycle:pending regardless of status', async () => {
    setFeatures([
      pendingFeature({ name: 'p-active', status: 'active' }),
      pendingFeature({ name: 'p-waiting', status: 'waiting' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('pending'))
    expect(screen.getByText('p-active')).toBeInTheDocument()
    expect(screen.getByText('p-waiting')).toBeInTheDocument()
  })

  it('T-2.5 / T-6.1: Done chip selecting renders Done layer below inprogress with divider', async () => {
    setFeatures([
      inprogressFeature({ name: 'inp', status: 'stuck' }),
      doneFeature({ name: 'd1', done_at: '2026-05-01T00:00:00Z' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('done'))
    const cards = screen.getAllByTestId('feature-card')
    expect(cards).toHaveLength(2)
    expect(within(cards[0]).getByText('inp')).toBeInTheDocument()
    expect(within(cards[1]).getByText('d1')).toBeInTheDocument()
    const divider = screen.getByTestId('done-divider')
    expect(divider).toHaveTextContent('Done')
    expect(divider).toHaveTextContent('(1)')
  })

  it('T-2.6: Done features sort by done_at desc within Done layer', async () => {
    setFeatures([
      inprogressFeature({ name: 'inp', status: 'stuck' }),
      doneFeature({ name: 'd-old', done_at: '2026-05-01T00:00:00Z' }),
      doneFeature({ name: 'd-new', done_at: '2026-05-03T00:00:00Z' }),
      doneFeature({ name: 'd-mid', done_at: '2026-05-02T00:00:00Z' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('done'))
    const cards = screen.getAllByTestId('feature-card')
    /* inprogress first, then done desc by date */
    expect(within(cards[0]).getByText('inp')).toBeInTheDocument()
    expect(within(cards[1]).getByText('d-new')).toBeInTheDocument()
    expect(within(cards[2]).getByText('d-mid')).toBeInTheDocument()
    expect(within(cards[3]).getByText('d-old')).toBeInTheDocument()
  })

  it('T-2.7: done_at === null sorts to end of Done layer', async () => {
    setFeatures([
      inprogressFeature({ name: 'inp', status: 'stuck' }),
      doneFeature({ name: 'd-null', done_at: null }),
      doneFeature({ name: 'd-real', done_at: '2026-05-01T00:00:00Z' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('done'))
    const cards = screen.getAllByTestId('feature-card')
    expect(within(cards[0]).getByText('inp')).toBeInTheDocument()
    expect(within(cards[1]).getByText('d-real')).toBeInTheDocument()
    expect(within(cards[2]).getByText('d-null')).toBeInTheDocument()
  })

  it('T-2.8: Done layer ignores active sort mode (always done_at desc)', async () => {
    setFeatures([
      doneFeature({ name: 'apple', done_at: '2026-05-01T00:00:00Z' }),
      doneFeature({ name: 'zebra', done_at: '2026-05-03T00:00:00Z' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('done'))
    await userEvent.click(sortChip('name-asc'))
    const cards = screen.getAllByTestId('feature-card')
    /* still done_at desc, not name-asc */
    expect(within(cards[0]).getByText('zebra')).toBeInTheDocument()
    expect(within(cards[1]).getByText('apple')).toBeInTheDocument()
  })

  it('T-2.9: lifecycle === undefined is treated as inprogress (back-compat)', () => {
    setFeatures([
      mockFeature({ name: 'legacy', status: 'stuck', lifecycle: undefined }),
    ])
    renderWithTheme(<FeaturesView />)
    expect(screen.getByText('legacy')).toBeInTheDocument()
  })

  it('T-2.10: empty lifecycle Set hides cards and shows filter-aware empty state', async () => {
    setFeatures([
      inprogressFeature({ name: 'a', status: 'stuck' }),
      inprogressFeature({ name: 'b', status: 'paused' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('active'))
    await userEvent.click(lifecycleChip('paused'))
    expect(screen.queryByTestId('feature-card')).not.toBeInTheDocument()
    expect(screen.getByTestId('wf-empty-scope')).toBeInTheDocument()
  })

  it('T-2.11: lifecycle:inprogress + status:done renders nowhere', async () => {
    setFeatures([
      inprogressFeature({ name: 'orphan', status: 'done' }),
      inprogressFeature({ name: 'normal', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('done'))
    /* orphan does not render in either layer */
    expect(screen.queryByText('orphan')).not.toBeInTheDocument()
    expect(screen.getByText('normal')).toBeInTheDocument()
  })
})

/* Group 3 — Project filter chips */

describe('FeaturesView — project chips', () => {
  beforeEach(() => {
    localStorage.removeItem('wf.featureFilters.v1')
  })

  it('T-3.1: project chip vocabulary is alphabetised and de-duped', () => {
    setFeatures([
      inprogressFeature({ name: 'a', project: 'oih', status: 'stuck' }),
      inprogressFeature({ name: 'b', project: 'eulex', status: 'stuck' }),
      inprogressFeature({ name: 'c', project: 'oih', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    const chips = document.querySelectorAll('[data-filter="project"]')
    expect(chips).toHaveLength(2)
    expect(chips[0].getAttribute('data-value')).toBe('eulex')
    expect(chips[1].getAttribute('data-value')).toBe('oih')
  })

  it('T-3.2: project chips OR-combine when multiple selected', async () => {
    setFeatures([
      inprogressFeature({ name: 'a', project: 'oih', status: 'stuck' }),
      inprogressFeature({ name: 'b', project: 'eulex', status: 'stuck' }),
      inprogressFeature({ name: 'c', project: 'oih', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(projectChip('oih'))
    await userEvent.click(projectChip('eulex'))
    expect(screen.getAllByTestId('feature-card')).toHaveLength(3)
  })

  it('T-3.3: empty project Set is pass-through', () => {
    setFeatures([
      inprogressFeature({ name: 'a', project: 'oih', status: 'stuck' }),
      inprogressFeature({ name: 'b', project: 'eulex', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    expect(screen.getAllByTestId('feature-card')).toHaveLength(2)
  })

  it('T-3.4: project filter applies AND on top of lifecycle', async () => {
    setFeatures([
      inprogressFeature({ name: 'a', project: 'oih', status: 'stuck' }),
      inprogressFeature({ name: 'b', project: 'eulex', status: 'stuck' }),
      pendingFeature({ name: 'c', project: 'oih' }),
      doneFeature({ name: 'd', project: 'eulex' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(projectChip('oih'))
    expect(screen.getByText('a')).toBeInTheDocument()
    expect(screen.queryByText('b')).not.toBeInTheDocument()
    expect(screen.queryByText('c')).not.toBeInTheDocument()
    expect(screen.queryByText('d')).not.toBeInTheDocument()
  })

  it('T-3.5: empty payload renders baseline empty state and no filter bar', () => {
    setFeatures([])
    renderWithTheme(<FeaturesView />)
    expect(screen.getByText('No features in progress')).toBeInTheDocument()
    expect(document.querySelectorAll('[data-filter="project"]')).toHaveLength(0)
  })

  it('T-3.6: undefined payload (loading) renders skeletons and no filter bar', () => {
    setFeatures(undefined, true)
    renderWithTheme(<FeaturesView />)
    expect(document.querySelectorAll('[data-filter]')).toHaveLength(0)
    expect(screen.queryByTestId('wf-toggle-chip')).not.toBeInTheDocument()
  })

  it('T-3.7: project chip data-value carries unusual characters verbatim', () => {
    setFeatures([
      inprogressFeature({ name: 'x', project: 'a:b', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    const chip = document.querySelector('[data-filter="project"]')
    expect(chip?.getAttribute('data-value')).toBe('a:b')
  })

  it('T-3.8: empty-string project is filtered out of vocabulary', () => {
    setFeatures([
      inprogressFeature({ name: 'a', project: '', status: 'stuck' }),
      inprogressFeature({ name: 'b', project: 'oih', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    const chips = document.querySelectorAll('[data-filter="project"]')
    expect(chips).toHaveLength(1)
    expect(chips[0].getAttribute('data-value')).toBe('oih')
  })

  it('T-3.9: stale project chip member yields empty result', () => {
    /* Seed localStorage with a project Set referring to a project that
       does not exist in the payload. */
    localStorage.setItem(
      'wf.featureFilters.v1',
      JSON.stringify({
        lifecycle: ['active', 'paused'],
        project: ['no-such-project'],
        search: '',
        sort: 'urgency-then-completion',
      }),
    )
    setFeatures([
      inprogressFeature({ name: 'a', project: 'oih', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    expect(screen.queryByTestId('feature-card')).not.toBeInTheDocument()
    expect(screen.getByTestId('wf-empty-scope')).toBeInTheDocument()
  })
})

/* Group 4 — Search input */

describe('FeaturesView — search', () => {
  beforeEach(() => {
    localStorage.removeItem('wf.featureFilters.v1')
  })

  it('T-4.1: search substring matches feature.name (case-insensitive)', async () => {
    setFeatures([
      inprogressFeature({ name: 'auth-flow', status: 'stuck' }),
      inprogressFeature({ name: 'auth-rotate', status: 'stuck' }),
      inprogressFeature({ name: 'session-cache', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.type(screen.getByTestId('feature-filter-search'), 'auth')
    expect(screen.getAllByTestId('feature-card')).toHaveLength(2)
  })

  it('T-4.2: search substring matches feature.project (case-insensitive)', async () => {
    setFeatures([
      inprogressFeature({ name: 'a', project: 'OIH', status: 'stuck' }),
      inprogressFeature({ name: 'b', project: 'eulex', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.type(screen.getByTestId('feature-filter-search'), 'oih')
    expect(screen.getAllByTestId('feature-card')).toHaveLength(1)
    expect(screen.getByText('a')).toBeInTheDocument()
  })

  it('T-4.3: empty search is pass-through', () => {
    setFeatures([
      inprogressFeature({ name: 'a', status: 'stuck' }),
      inprogressFeature({ name: 'b', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    expect(screen.getAllByTestId('feature-card')).toHaveLength(2)
  })

  it('T-4.4: search applies AND on top of lifecycle and project', async () => {
    setFeatures([
      inprogressFeature({ name: 'auth-a', project: 'oih', status: 'stuck' }),
      inprogressFeature({ name: 'auth-b', project: 'eulex', status: 'stuck' }),
      pendingFeature({ name: 'auth-c', project: 'oih' }),
      inprogressFeature({ name: 'session-d', project: 'oih', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(projectChip('oih'))
    await userEvent.type(screen.getByTestId('feature-filter-search'), 'auth')
    /* lifecycle ∈ {Active, Paused}, project = oih, name|project contains 'auth' */
    expect(screen.getAllByTestId('feature-card')).toHaveLength(1)
    expect(screen.getByText('auth-a')).toBeInTheDocument()
  })

  it('T-4.5: regex special characters matched literally', async () => {
    setFeatures([
      inprogressFeature({ name: 'auth.*', status: 'stuck' }),
      inprogressFeature({ name: 'authentication', status: 'stuck' }),
      inprogressFeature({ name: 'auth-flow', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.type(screen.getByTestId('feature-filter-search'), '.*')
    expect(screen.getAllByTestId('feature-card')).toHaveLength(1)
    expect(screen.getByText('auth.*')).toBeInTheDocument()
  })

  it('T-4.6: whitespace is significant (no auto-trim)', async () => {
    setFeatures([
      inprogressFeature({ name: 'auth-flow', status: 'stuck' }),
      inprogressFeature({ name: 'sub auth', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    /* leading space — userEvent.type honours whitespace */
    await userEvent.type(screen.getByTestId('feature-filter-search'), ' auth')
    expect(screen.getAllByTestId('feature-card')).toHaveLength(1)
    expect(screen.getByText('sub auth')).toBeInTheDocument()
  })

  it('T-4.7: search input has aria-label, placeholder, and data-testid wired together', () => {
    setFeatures([inprogressFeature({ name: 'a', status: 'stuck' })])
    renderWithTheme(<FeaturesView />)
    const a = screen.getByLabelText('Search features')
    const b = screen.getByPlaceholderText('Search name or project')
    const c = screen.getByTestId('feature-filter-search')
    expect(a).toBe(b)
    expect(b).toBe(c)
  })

  it('T-4.8: search input is bound to filters.search (controlled)', async () => {
    setFeatures([inprogressFeature({ name: 'a', status: 'stuck' })])
    renderWithTheme(<FeaturesView />)
    const input = screen.getByTestId('feature-filter-search') as HTMLInputElement
    await userEvent.type(input, 'auth')
    expect(input.value).toBe('auth')
  })

  it('T-4.9: large paste does not crash', () => {
    setFeatures([inprogressFeature({ name: 'a', status: 'stuck' })])
    renderWithTheme(<FeaturesView />)
    const input = screen.getByTestId('feature-filter-search') as HTMLInputElement
    expect(() =>
      fireEvent.change(input, { target: { value: 'a'.repeat(100000) } }),
    ).not.toThrow()
  })
})

/* Group 5 — Sort chips */

describe('FeaturesView — sort chips', () => {
  beforeEach(() => {
    localStorage.removeItem('wf.featureFilters.v1')
  })

  it('T-5.1: sort chip group renders three chips with documented values', () => {
    setFeatures([inprogressFeature({ name: 'a', status: 'stuck' })])
    renderWithTheme(<FeaturesView />)
    const chips = document.querySelectorAll('[data-filter="sort"]')
    expect(chips).toHaveLength(3)
    expect(chips[0].getAttribute('data-value')).toBe('urgency-then-completion')
    expect(chips[1].getAttribute('data-value')).toBe('name-asc')
    expect(chips[2].getAttribute('data-value')).toBe('last-activity-desc')
  })

  /* T-5.1a — audit-list-filters #3 (Features-tab parity). Each sort chip
     carries a `title` attribute explaining the sort key. URGENCY in
     particular needs the rank ordering surfaced (stuck → waiting →
     active → paused) since the label alone can't communicate it. */
  it('T-5.1a: each sort chip exposes a title attribute describing its sort key', () => {
    setFeatures([inprogressFeature({ name: 'a', status: 'stuck' })])
    renderWithTheme(<FeaturesView />)
    const urgencyTitle = sortChip('urgency-then-completion').getAttribute('title')
    const nameTitle = sortChip('name-asc').getAttribute('title')
    const recentTitle = sortChip('last-activity-desc').getAttribute('title')
    expect(urgencyTitle).toMatch(/stuck|waiting|active|paused/i)
    expect(nameTitle).toMatch(/name|alphabet/i)
    expect(recentTitle).toMatch(/recent|activity|last/i)
  })

  it('T-5.2: sort chip is single-select', async () => {
    setFeatures([inprogressFeature({ name: 'a', status: 'stuck' })])
    renderWithTheme(<FeaturesView />)
    expect(sortChip('urgency-then-completion').getAttribute('data-active')).toBe('true')
    await userEvent.click(sortChip('name-asc'))
    expect(sortChip('name-asc').getAttribute('data-active')).toBe('true')
    expect(sortChip('urgency-then-completion').getAttribute('data-active')).toBe('false')
  })

  it('T-5.3: clicking the active sort chip is a no-op', async () => {
    setFeatures([
      inprogressFeature({ name: 'paused-feat', status: 'paused' }),
      inprogressFeature({ name: 'stuck-feat', status: 'stuck' }),
      inprogressFeature({ name: 'active-feat', status: 'active' }),
    ])
    renderWithTheme(<FeaturesView />)
    /* Capture default-sort order. */
    const before = screen.getAllByTestId('feature-card').map((c) => c.textContent)
    await userEvent.click(sortChip('urgency-then-completion'))
    const after = screen.getAllByTestId('feature-card').map((c) => c.textContent)
    expect(after).toEqual(before)
    expect(sortChip('urgency-then-completion').getAttribute('data-active')).toBe('true')
  })

  it('T-5.4: urgency-then-completion orders by STATUS_RANK', () => {
    setFeatures([
      inprogressFeature({ name: 'paused-f', status: 'paused' }),
      inprogressFeature({ name: 'stuck-f', status: 'stuck' }),
      inprogressFeature({ name: 'active-f', status: 'active' }),
    ])
    renderWithTheme(<FeaturesView />)
    const cards = screen.getAllByTestId('feature-card')
    expect(within(cards[0]).getByText('stuck-f')).toBeInTheDocument()
    expect(within(cards[1]).getByText('active-f')).toBeInTheDocument()
    expect(within(cards[2]).getByText('paused-f')).toBeInTheDocument()
  })

  it('T-5.5: name-asc orders case-insensitively', async () => {
    setFeatures([
      inprogressFeature({ name: 'beta', status: 'stuck' }),
      inprogressFeature({ name: 'Alpha', status: 'stuck' }),
      inprogressFeature({ name: 'gamma', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(sortChip('name-asc'))
    const cards = screen.getAllByTestId('feature-card')
    expect(within(cards[0]).getByText('Alpha')).toBeInTheDocument()
    expect(within(cards[1]).getByText('beta')).toBeInTheDocument()
    expect(within(cards[2]).getByText('gamma')).toBeInTheDocument()
  })

  it('T-5.6: last-activity-desc orders newest first', async () => {
    setFeatures([
      inprogressFeature({ name: 'oldest', status: 'stuck', last_activity: '2026-05-01T00:00:00Z' }),
      inprogressFeature({ name: 'newest', status: 'stuck', last_activity: '2026-05-03T00:00:00Z' }),
      inprogressFeature({ name: 'mid', status: 'stuck', last_activity: '2026-05-02T00:00:00Z' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(sortChip('last-activity-desc'))
    const cards = screen.getAllByTestId('feature-card')
    expect(within(cards[0]).getByText('newest')).toBeInTheDocument()
    expect(within(cards[1]).getByText('mid')).toBeInTheDocument()
    expect(within(cards[2]).getByText('oldest')).toBeInTheDocument()
  })

  it('T-5.7: null last_activity sorts to end under last-activity-desc', async () => {
    setFeatures([
      inprogressFeature({ name: 'has-ts', status: 'stuck', last_activity: '2026-05-01T00:00:00Z' }),
      inprogressFeature({ name: 'no-ts', status: 'stuck', last_activity: null }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(sortChip('last-activity-desc'))
    const cards = screen.getAllByTestId('feature-card')
    expect(within(cards[0]).getByText('has-ts')).toBeInTheDocument()
    expect(within(cards[1]).getByText('no-ts')).toBeInTheDocument()
  })

  it('T-5.8: all-null last_activity preserves insertion order', async () => {
    setFeatures([
      inprogressFeature({ name: 'first', status: 'stuck', last_activity: null }),
      inprogressFeature({ name: 'second', status: 'stuck', last_activity: null }),
      inprogressFeature({ name: 'third', status: 'stuck', last_activity: null }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(sortChip('last-activity-desc'))
    const cards = screen.getAllByTestId('feature-card')
    expect(within(cards[0]).getByText('first')).toBeInTheDocument()
    expect(within(cards[1]).getByText('second')).toBeInTheDocument()
    expect(within(cards[2]).getByText('third')).toBeInTheDocument()
  })

  it('T-5.9: single feature renders identically across sort modes', async () => {
    setFeatures([inprogressFeature({ name: 'solo', status: 'stuck' })])
    renderWithTheme(<FeaturesView />)
    expect(screen.getAllByTestId('feature-card')).toHaveLength(1)
    await userEvent.click(sortChip('name-asc'))
    expect(screen.getAllByTestId('feature-card')).toHaveLength(1)
    await userEvent.click(sortChip('last-activity-desc'))
    expect(screen.getAllByTestId('feature-card')).toHaveLength(1)
  })

  it('T-5.10: unknown status sorts to end (forward-compatible)', () => {
    setFeatures([
      inprogressFeature({
        name: 'unknown',
        status: 'observed' as unknown as FeatureStatus,
      }),
      inprogressFeature({ name: 'stuck-f', status: 'stuck' }),
      inprogressFeature({ name: 'active-f', status: 'active' }),
    ])
    renderWithTheme(<FeaturesView />)
    const cards = screen.getAllByTestId('feature-card')
    expect(within(cards[0]).getByText('stuck-f')).toBeInTheDocument()
    expect(within(cards[1]).getByText('active-f')).toBeInTheDocument()
    expect(within(cards[2]).getByText('unknown')).toBeInTheDocument()
  })
})

/* Group 6 — Visual layering (Done divider) */

describe('FeaturesView — done divider', () => {
  beforeEach(() => {
    localStorage.removeItem('wf.featureFilters.v1')
  })

  it('T-6.2: divider does not render when Done layer is empty even with Done chip selected', async () => {
    setFeatures([inprogressFeature({ name: 'inp', status: 'stuck' })])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('done'))
    expect(lifecycleChip('done').getAttribute('data-active')).toBe('true')
    expect(screen.queryByTestId('done-divider')).not.toBeInTheDocument()
  })

  it('T-6.3: divider does not render when inprogress layer is empty', async () => {
    setFeatures([doneFeature({ name: 'd', done_at: '2026-05-01T00:00:00Z' })])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('done'))
    expect(screen.queryByTestId('done-divider')).not.toBeInTheDocument()
    expect(screen.getByText('d')).toBeInTheDocument()
  })

  it('T-6.4: Done features use the same FeatureCard component', async () => {
    setFeatures([doneFeature({ name: 'd', done_at: '2026-05-01T00:00:00Z' })])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('done'))
    const cards = screen.getAllByTestId('feature-card')
    expect(cards).toHaveLength(1)
  })

  it('T-6.5: divider count badge matches done-layer cardinality', async () => {
    setFeatures([
      inprogressFeature({ name: 'inp', status: 'stuck' }),
      doneFeature({ name: 'd1', done_at: '2026-05-01T00:00:00Z' }),
      doneFeature({ name: 'd2', done_at: '2026-05-02T00:00:00Z' }),
      doneFeature({ name: 'd3', done_at: '2026-05-03T00:00:00Z' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('done'))
    expect(screen.getByTestId('done-divider')).toHaveTextContent('(3)')
  })
})

/* Group 7 — Empty state */

describe('FeaturesView — empty state', () => {
  beforeEach(() => {
    localStorage.removeItem('wf.featureFilters.v1')
  })

  it('T-7.1: loading preserves three skeletons and hides the filter bar', () => {
    setFeatures(undefined, true)
    const { container } = renderWithTheme(<FeaturesView />)
    expect(container.querySelectorAll('.MuiSkeleton-root').length).toBeGreaterThanOrEqual(3)
    expect(screen.queryByTestId('feature-filter-search')).not.toBeInTheDocument()
    expect(screen.queryByTestId('wf-toggle-chip')).not.toBeInTheDocument()
  })

  it('T-7.2: empty payload preserves baseline empty state and hides the filter bar', () => {
    setFeatures([])
    renderWithTheme(<FeaturesView />)
    expect(screen.getByText('No features in progress')).toBeInTheDocument()
    expect(screen.queryByTestId('feature-filter-search')).not.toBeInTheDocument()
    expect(screen.queryByTestId('wf-toggle-chip')).not.toBeInTheDocument()
  })

  it('T-7.3: filter-aware empty state names active chips and suggests the unselected one', () => {
    setFeatures([pendingFeature({ name: 'p' })])
    renderWithTheme(<FeaturesView />)
    const empty = screen.getByTestId('wf-empty-scope')
    expect(empty).toHaveTextContent('Active+Paused')
    expect(empty).toHaveTextContent('try adding')
    expect(empty).toHaveTextContent('Pending')
  })

  it('T-7.4: all four chips selected suggests clearing the search', async () => {
    setFeatures([
      inprogressFeature({ name: 'a', status: 'stuck' }),
      inprogressFeature({ name: 'b', status: 'paused' }),
      pendingFeature({ name: 'c' }),
      doneFeature({ name: 'd' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('pending'))
    await userEvent.click(lifecycleChip('done'))
    await userEvent.type(
      screen.getByTestId('feature-filter-search'),
      'zzz_no_match',
    )
    const empty = screen.getByTestId('wf-empty-scope')
    expect(empty).toHaveTextContent('Active+Paused+Pending+Done')
    expect(empty).toHaveTextContent('try clearing the search')
  })

  it('T-7.5: filter-aware empty state still renders the filter bar above', () => {
    setFeatures([pendingFeature({ name: 'p' })])
    renderWithTheme(<FeaturesView />)
    expect(screen.getByTestId('feature-filter-search')).toBeInTheDocument()
    expect(screen.getByTestId('wf-empty-scope')).toBeInTheDocument()
    expect(screen.queryByTestId('feature-card')).not.toBeInTheDocument()
  })

  it('T-7.6: only Pending selected and zero pending features → "try adding" subtitle', async () => {
    setFeatures([
      inprogressFeature({ name: 'a', status: 'stuck' }),
      inprogressFeature({ name: 'b', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('active'))
    await userEvent.click(lifecycleChip('paused'))
    await userEvent.click(lifecycleChip('pending'))
    const empty = screen.getByTestId('wf-empty-scope')
    expect(empty).toHaveTextContent('Pending')
    expect(empty).toHaveTextContent('try adding')
  })
})

/* Group 8 — Persistence */

describe('FeaturesView — persistence', () => {
  beforeEach(() => {
    localStorage.removeItem('wf.featureFilters.v1')
  })

  it('T-8.1: state persists across unmount/remount (simulated reload)', async () => {
    setFeatures([
      inprogressFeature({ name: 'inp', status: 'stuck' }),
      doneFeature({ name: 'd', done_at: '2026-05-01T00:00:00Z' }),
    ])
    const { unmount } = renderWithTheme(<FeaturesView />)
    await userEvent.click(lifecycleChip('done'))
    expect(lifecycleChip('done').getAttribute('data-active')).toBe('true')
    unmount()
    /* Re-mount without clearing localStorage. */
    renderWithTheme(<FeaturesView />)
    expect(lifecycleChip('done').getAttribute('data-active')).toBe('true')
    expect(screen.getByText('d')).toBeInTheDocument()
  })
})

/* Group 9 — Selection continuity */

describe('FeaturesView — selection continuity', () => {
  beforeEach(() => {
    localStorage.removeItem('wf.featureFilters.v1')
  })

  it('T-9.1: filtering out the selected card preserves FeatureDetail rendering', async () => {
    setFeatures([
      inprogressFeature({ name: 'auth-flow', status: 'stuck' }),
      inprogressFeature({ name: 'session-cache', status: 'stuck' }),
      inprogressFeature({ name: 'auth-rotate', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    /* Click the middle card. */
    const cards = screen.getAllByTestId('feature-card')
    const middle = cards.find((c) => c.textContent?.includes('session-cache')) as HTMLElement
    await userEvent.click(middle)
    /* Right-pane should now show session-cache details (multiple matches OK). */
    expect(screen.getAllByText('session-cache').length).toBeGreaterThan(0)
    /* Filter to exclude session-cache. */
    await userEvent.type(screen.getByTestId('feature-filter-search'), 'auth')
    /* List region no longer shows session-cache as a card. */
    const listCards = screen.queryAllByTestId('feature-card')
    expect(
      listCards.every((c) => !c.textContent?.includes('session-cache')),
    ).toBe(true)
    /* But the detail pane still references the selected feature name. */
    expect(screen.getAllByText('session-cache').length).toBeGreaterThan(0)
  })
})

/* Group 10 — Filter bar layout */

describe('FeaturesView — filter bar layout & data attributes', () => {
  beforeEach(() => {
    localStorage.removeItem('wf.featureFilters.v1')
  })

  it('T-10.1: lifecycle chip group renders four chips in [active, paused, pending, done] order', () => {
    setFeatures([inprogressFeature({ name: 'a', status: 'stuck' })])
    renderWithTheme(<FeaturesView />)
    const chips = document.querySelectorAll('[data-filter="lifecycle"]')
    const values = Array.from(chips).map((c) => c.getAttribute('data-value'))
    expect(values).toEqual(['active', 'paused', 'pending', 'done'])
  })

  it('T-10.2: lifecycle chip carries data-filter and data-value', () => {
    setFeatures([inprogressFeature({ name: 'a', status: 'stuck' })])
    renderWithTheme(<FeaturesView />)
    const chips = document.querySelectorAll('[data-filter="lifecycle"]')
    expect(chips.length).toBe(4)
    chips.forEach((c) => {
      expect(c.getAttribute('data-filter')).toBe('lifecycle')
      expect(c.getAttribute('data-value')).toBeTruthy()
    })
  })

  it('T-10.3: project chip carries data-filter="project" and data-value', () => {
    setFeatures([
      inprogressFeature({ name: 'a', project: 'oih', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    const chip = document.querySelector('[data-filter="project"]') as HTMLElement
    expect(chip.getAttribute('data-filter')).toBe('project')
    expect(chip.getAttribute('data-value')).toBe('oih')
  })

  it('T-10.4: sort chip carries data-filter="sort" and data-value', () => {
    setFeatures([inprogressFeature({ name: 'a', status: 'stuck' })])
    renderWithTheme(<FeaturesView />)
    const chips = document.querySelectorAll('[data-filter="sort"]')
    const values = Array.from(chips).map((c) => c.getAttribute('data-value'))
    expect(values).toEqual([
      'urgency-then-completion',
      'name-asc',
      'last-activity-desc',
    ])
  })

  it('T-10.5: filter bar layout — three rows in documented DOM order', () => {
    setFeatures([
      inprogressFeature({ name: 'a', project: 'oih', status: 'stuck' }),
      inprogressFeature({ name: 'b', project: 'eulex', status: 'stuck' }),
    ])
    renderWithTheme(<FeaturesView />)
    /* Walk all data-filter elements + the search input in DOM order;
       expected: lifecycle×4, project×2, search, sort×3. */
    const all = Array.from(
      document.querySelectorAll(
        '[data-filter="lifecycle"], [data-filter="project"], [data-filter="sort"], [data-testid="feature-filter-search"]',
      ),
    )
    const types = all.map((el) =>
      el.getAttribute('data-testid') === 'feature-filter-search'
        ? 'search'
        : el.getAttribute('data-filter'),
    )
    /* lifecycle chips appear first */
    const firstLifecycle = types.indexOf('lifecycle')
    const lastLifecycle = types.lastIndexOf('lifecycle')
    const firstProject = types.indexOf('project')
    const searchIdx = types.indexOf('search')
    const firstSort = types.indexOf('sort')
    expect(firstLifecycle).toBeLessThan(firstProject)
    expect(lastLifecycle).toBeLessThan(firstProject)
    expect(firstProject).toBeLessThan(searchIdx)
    expect(searchIdx).toBeLessThan(firstSort)
  })

  it('T-10.6: toggle creates a new Set instance (immutable update)', async () => {
    setFeatures([
      inprogressFeature({ name: 'a', status: 'stuck' }),
      inprogressFeature({ name: 'b', status: 'paused' }),
    ])
    renderWithTheme(<FeaturesView />)
    expect(lifecycleChip('active').getAttribute('data-active')).toBe('true')
    await userEvent.click(lifecycleChip('active'))
    expect(lifecycleChip('active').getAttribute('data-active')).toBe('false')
    await userEvent.click(lifecycleChip('active'))
    expect(lifecycleChip('active').getAttribute('data-active')).toBe('true')
  })
})

/* ═══ feature-plan-link-and-nav — plan-link chip ═══ */

const planLinkFeature = (overrides: Partial<Feature> = {}): Feature =>
  mockFeature({
    plan_dir: '/p/A',
    plan_task_id: 'dark-mode',
    ...overrides,
  })

const ALPHA_PLAN_SUMMARY = {
  project: 'Alpha Plan',
  path: '/p/A',
  phases: 5,
  progress: 50,
  has_plan: true,
  plan_dir: '/p/A',
}

function setPlans(plans: ReturnType<typeof usePlans>['data']): void {
  vi.mocked(usePlans).mockReturnValue({
    data: plans,
    isLoading: false,
  } as ReturnType<typeof usePlans>)
}

describe('FeatureCard — plan-link chip', () => {
  beforeEach(() => {
    /* Default: plans hydrated with one matching entry. Tests that
       care about the loading/empty/unmatched cases override below. */
    setPlans([ALPHA_PLAN_SUMMARY])
  })

  /* A1 — REQ-1, REQ-2, AS-1 */
  it('chip_renders_with_plan_name_when_plan_in_plans_response', () => {
    const feature = planLinkFeature()
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />,
    )
    expect(screen.getByTestId('plan-link-chip')).toHaveTextContent('Alpha Plan')
  })

  /* A2 — REQ-2, AS-2 */
  it('chip_label_falls_back_to_plan_task_id_when_plan_dir_unmatched', () => {
    const feature = planLinkFeature({ plan_dir: '/p/ghost' })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />,
    )
    expect(screen.getByTestId('plan-link-chip')).toHaveTextContent('dark-mode')
  })

  /* A3 — REQ-2, EC-1 */
  it('chip_label_uses_plan_task_id_while_plans_are_loading', () => {
    vi.mocked(usePlans).mockReturnValue({
      data: undefined,
      isLoading: true,
    } as ReturnType<typeof usePlans>)
    const feature = planLinkFeature()
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />,
    )
    expect(screen.getByTestId('plan-link-chip')).toHaveTextContent('dark-mode')
  })

  /* A4 — REQ-2, EC-2 */
  it('chip_label_falls_back_when_plans_array_is_empty', () => {
    setPlans([])
    const feature = planLinkFeature()
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />,
    )
    expect(screen.getByTestId('plan-link-chip')).toHaveTextContent('dark-mode')
  })

  /* A5 — EC-3 (literal string equality) */
  it('chip_label_resolves_when_plan_dirs_match_exactly', () => {
    setPlans([
      {
        project: 'Long Plan',
        path: '/long/abs/path',
        phases: 1,
        progress: 0,
        has_plan: true,
        plan_dir: '/long/abs/path',
      },
    ])
    const feature = planLinkFeature({ plan_dir: '/long/abs/path' })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />,
    )
    expect(screen.getByTestId('plan-link-chip')).toHaveTextContent('Long Plan')
  })

  /* A6 — REQ-3, AS-3 */
  it('chip_omitted_when_feature_has_no_plan_dir', () => {
    const feature = mockFeature() // no plan_dir / plan_task_id
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />,
    )
    expect(screen.queryByTestId('plan-link-chip')).toBeNull()
    /* The card's other elements still render (regression guard). */
    expect(screen.getByText('test-feature')).toBeInTheDocument()
    expect(screen.getByText('test-project')).toBeInTheDocument()
    expect(screen.getByTestId('phase-chip')).toBeInTheDocument()
    expect(screen.getByTestId('status-chip')).toBeInTheDocument()
    expect(screen.getByRole('progressbar')).toBeInTheDocument()
  })

  /* A7 — REQ-3, EC-8 */
  it('chip_omitted_when_only_plan_dir_is_set', () => {
    const feature = mockFeature({ plan_dir: '/p/A' })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />,
    )
    expect(screen.queryByTestId('plan-link-chip')).toBeNull()
  })

  /* A8 — REQ-3, EC-9 */
  it('chip_omitted_when_only_plan_task_id_is_set', () => {
    const feature = mockFeature({ plan_task_id: 'orphan' })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />,
    )
    expect(screen.queryByTestId('plan-link-chip')).toBeNull()
  })

  /* A9 — EC-13 */
  it('chip_renders_for_done_feature_with_plan_link', () => {
    const feature = planLinkFeature({ status: 'done' })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />,
    )
    expect(screen.getByTestId('plan-link-chip')).toBeInTheDocument()
  })

  /* A10 — REQ-13 */
  it('chip_uses_wfLabel_typography_variant', () => {
    const feature = planLinkFeature()
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />,
    )
    const chip = screen.getByTestId('plan-link-chip')
    /* MUI emits the variant name as a class on the rendered element;
       precedent: OverviewView.test.tsx:128, PhaseStepper.test.tsx:33,39. */
    const typography = chip.querySelector('.MuiTypography-wfLabel')
    expect(typography).not.toBeNull()
  })

  /* B1 — REQ-4, AS-4 */
  it('chip_click_invokes_onNavigateToPlan_with_plan_dir', () => {
    const onNavigateToPlan = vi.fn()
    const feature = planLinkFeature()
    renderWithTheme(
      <FeatureCard
        feature={feature}
        selected={false}
        onSelect={vi.fn()}
        onNavigateToPlan={onNavigateToPlan}
      />,
    )
    fireEvent.click(screen.getByTestId('plan-link-chip'))
    expect(onNavigateToPlan).toHaveBeenCalledWith('/p/A')
  })

  /* B2 — REQ-4, EC-14 */
  it('chip_click_invokes_onNavigateToPlan_exactly_once', () => {
    const onNavigateToPlan = vi.fn()
    const feature = planLinkFeature()
    renderWithTheme(
      <FeatureCard
        feature={feature}
        selected={false}
        onSelect={vi.fn()}
        onNavigateToPlan={onNavigateToPlan}
      />,
    )
    fireEvent.click(screen.getByTestId('plan-link-chip'))
    expect(onNavigateToPlan).toHaveBeenCalledTimes(1)
  })

  /* B3 — REQ-4, EC-5 */
  it('chip_click_does_not_invoke_card_onSelect', () => {
    const onSelect = vi.fn()
    const feature = planLinkFeature()
    renderWithTheme(
      <FeatureCard
        feature={feature}
        selected={false}
        onSelect={onSelect}
        onNavigateToPlan={vi.fn()}
      />,
    )
    fireEvent.click(screen.getByTestId('plan-link-chip'))
    expect(onSelect).not.toHaveBeenCalled()
  })

  /* B4 — REQ-5, AS-6 */
  it('chip_keyboard_enter_invokes_onNavigateToPlan', () => {
    const onNavigateToPlan = vi.fn()
    const feature = planLinkFeature()
    renderWithTheme(
      <FeatureCard
        feature={feature}
        selected={false}
        onSelect={vi.fn()}
        onNavigateToPlan={onNavigateToPlan}
      />,
    )
    fireEvent.keyDown(screen.getByTestId('plan-link-chip'), { key: 'Enter' })
    expect(onNavigateToPlan).toHaveBeenCalledTimes(1)
    expect(onNavigateToPlan).toHaveBeenCalledWith('/p/A')
  })

  /* B5 — REQ-5, AS-6 */
  it('chip_keyboard_space_invokes_onNavigateToPlan_and_preventDefault', () => {
    const onNavigateToPlan = vi.fn()
    const feature = planLinkFeature()
    renderWithTheme(
      <FeatureCard
        feature={feature}
        selected={false}
        onSelect={vi.fn()}
        onNavigateToPlan={onNavigateToPlan}
      />,
    )
    const chip = screen.getByTestId('plan-link-chip')
    /* fireEvent dispatches a real Event; preventDefault is observable
       via `defaultPrevented` after dispatch. */
    const event = new KeyboardEvent('keydown', {
      key: ' ',
      bubbles: true,
      cancelable: true,
    })
    chip.dispatchEvent(event)
    expect(onNavigateToPlan).toHaveBeenCalledTimes(1)
    expect(event.defaultPrevented).toBe(true)
  })

  /* B6 — REQ-5, EC-6 */
  it('chip_keyboard_activation_does_not_invoke_card_onSelect', () => {
    const onSelect = vi.fn()
    const feature = planLinkFeature()
    renderWithTheme(
      <FeatureCard
        feature={feature}
        selected={false}
        onSelect={onSelect}
        onNavigateToPlan={vi.fn()}
      />,
    )
    const chip = screen.getByTestId('plan-link-chip')
    fireEvent.keyDown(chip, { key: 'Enter' })
    fireEvent.keyDown(chip, { key: ' ' })
    expect(onSelect).not.toHaveBeenCalled()
  })

  /* B7 — REQ-6, AS-7, EC-12 */
  it('chip_click_no_op_when_callback_omitted', () => {
    const onSelect = vi.fn()
    const feature = planLinkFeature()
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={onSelect} />,
    )
    expect(() =>
      fireEvent.click(screen.getByTestId('plan-link-chip')),
    ).not.toThrow()
    expect(onSelect).not.toHaveBeenCalled()
  })

  /* C1 — REQ-7, REQ-11. Threading test: render FeaturesView with the
     prop set; clicking the chip in the (mocked) feature must reach the
     spy. Pins the C2 → C3 → C4 prop chain inside the FeaturesView
     subtree. */
  it('featuresview_threads_onNavigateToPlan_to_FeatureList_and_FeatureCard', () => {
    const onNavigateToPlan: OnNavigateToPlan = vi.fn()
    const feature = planLinkFeature({ name: 'threaded', status: 'stuck' })
    vi.mocked(useFeatures).mockReturnValue({
      data: [feature],
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useFeatures>)
    renderWithTheme(<FeaturesView onNavigateToPlan={onNavigateToPlan} />)
    fireEvent.click(screen.getByTestId('plan-link-chip'))
    expect(onNavigateToPlan).toHaveBeenCalledWith('/p/A')
  })
})

/* ═══ Audit-21 #1 — drop redundant phase-chip when label === status ═══ */
describe('FeatureCard: audit-21 #1 phase-chip drop when redundant', () => {
  /* Done features render two chips both reading "DONE": phase-chip
     (label = PHASE_LABELS['done'] = 'Done') and status-chip (label =
     feature.status = 'done'). The DONE section header already conveys
     lifecycle state for archived features, and the status-chip carries
     the canonical lifecycle pill — duplicating "DONE" twice is noise.
     Rule: hide the phase-chip when its label matches feature.status
     case-insensitively. Active features (phase='implement', status='active')
     keep both chips since they convey orthogonal information. */
  it('hides phase-chip when its label matches status (case-insensitive)', () => {
    const feature = mockFeature({ phase: 'done', status: 'done' })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    expect(screen.queryByTestId('phase-chip')).toBeNull()
    expect(screen.queryByTestId('status-chip')).not.toBeNull()
  })

  it('keeps phase-chip when label differs from status', () => {
    const feature = mockFeature({ phase: 'implement', status: 'active' })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    expect(screen.queryByTestId('phase-chip')).not.toBeNull()
    expect(screen.queryByTestId('status-chip')).not.toBeNull()
  })

  it('keeps phase-chip when phase=done but status=paused (orthogonal)', () => {
    /* Defensive: if a paused feature ever lands at phase=done, the
       phase-chip label "Done" still differs from status "paused" so
       both render. */
    const feature = mockFeature({ phase: 'done', status: 'paused' })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    expect(screen.queryByTestId('phase-chip')).not.toBeNull()
    expect(screen.queryByTestId('status-chip')).not.toBeNull()
  })
})

/* ═══ FeatureCard header pairs feature.name with plan_task_name ═══ */
describe('FeatureCard: id-primary header with plan task name as subtitle', () => {
  /* User-request 2026-05-08 — same chrome shape as the brief header
     (DH-10..DH-12). The kebab-case feature.name reads as the technical
     identity (matches the chip vocabulary in DEPENDS ON / REQUIRED BY /
     FeatureCard plan-link); the longer plan_task_name from the linked
     plan task lives directly underneath as supporting human description.
     The server populates plan_task_name only when it differs from
     feature.name (feature_helpers._apply_plan_link), so the subtitle
     is always meaningful when present. */
  it('renders plan_task_name as subtitle below feature.name when present', () => {
    const feature = mockFeature({
      name: 'feature-filter-state-hook',
      plan_task_name: 'useFeatureFilters hook with versioned localStorage',
    })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    expect(screen.getByText('feature-filter-state-hook')).toBeInTheDocument()
    const subtitle = screen.getByTestId('feature-card-subtitle')
    expect(subtitle.textContent).toBe('useFeatureFilters hook with versioned localStorage')
  })

  it('omits subtitle when plan_task_name is missing', () => {
    const feature = mockFeature({ name: 'orphan' })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    expect(screen.queryByTestId('feature-card-subtitle')).toBeNull()
  })

  it('omits subtitle when plan_task_name equals feature.name (defensive)', () => {
    /* The server already filters this case (_apply_plan_link won't write
       plan_task_name when it equals feature.name), but the frontend also
       guards against it so a stale cached payload doesn't surface a
       redundant duplicated line. */
    const feature = mockFeature({
      name: 'same-string',
      plan_task_name: 'same-string',
    })
    renderWithTheme(
      <FeatureCard feature={feature} selected={false} onSelect={vi.fn()} />
    )
    expect(screen.queryByTestId('feature-card-subtitle')).toBeNull()
  })
})
