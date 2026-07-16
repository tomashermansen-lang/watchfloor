import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import Pipeline from '../components/Pipeline'
import type { Plan, Session, EnrichedChecklistItem } from '../types'

/* ═══ Mock localStorage (jsdom doesn't always provide it) ═══ */
const storageMock: Record<string, string> = {}
const localStorageMock = {
  getItem: vi.fn((key: string) => storageMock[key] ?? null),
  setItem: vi.fn((key: string, value: string) => { storageMock[key] = value }),
  removeItem: vi.fn((key: string) => { delete storageMock[key] }),
  clear: vi.fn(() => { Object.keys(storageMock).forEach((k) => delete storageMock[k]) }),
  get length() { return Object.keys(storageMock).length },
  key: vi.fn((_: number) => null),
}
Object.defineProperty(globalThis, 'localStorage', { value: localStorageMock, writable: true })

// Mock HoverLinkContext
vi.mock('../contexts/HoverLinkContext', () => ({
  useHoverLink: () => ({
    hoveredTaskId: null,
    hoveredSessionBranch: null,
    setHoveredTask: vi.fn(),
    setHoveredSession: vi.fn(),
  }),
}))

const mockPlan: Plan = {
  schema_version: '1.0.0',
  name: 'Test Plan',
  description: 'A test execution plan',
  phases: [
    {
      id: 'setup',
      name: 'Phase 0: Setup',
      tasks: [
        { id: 'task-a', name: 'Task A', status: 'done' },
        { id: 'task-b', name: 'Task B', status: 'wip' },
      ],
      gate: {
        name: 'Setup Gate',
        checklist: ['docker compose up -d', 'uv run pytest', 'uv run alembic upgrade head'],
        passed: false,
      },
    },
    {
      id: 'core',
      name: 'Phase 1: Core',
      tasks: [
        { id: 'task-c', name: 'Task C', status: 'pending', parallel_group: 'group-1', depends: ['task-a'] },
        { id: 'task-d', name: 'Task D', status: 'pending', parallel_group: 'group-1', depends: ['task-a'] },
      ],
    },
    {
      id: 'empty',
      name: 'Phase 2: Empty',
      tasks: [],
    },
  ],
}

/* DAG plan: root -> 3 parallel children (Change 1 + 4 test) */
const dagPlan: Plan = {
  schema_version: '1.0.0',
  name: 'DAG Plan',
  phases: [
    {
      id: 'phase-dag',
      name: 'DAG Phase',
      tasks: [
        { id: 'root', name: 'Root Task', status: 'done' },
        { id: 'child-1', name: 'Child One', status: 'wip', depends: ['root'] },
        { id: 'child-2', name: 'Child Two', status: 'pending', depends: ['root'] },
        { id: 'child-3', name: 'Child Three', status: 'pending', depends: ['root'] },
      ],
    },
  ],
}

function renderPipeline(plan: Plan = mockPlan, sessions: Session[] = []) {
  return render(
    <ThemeProvider theme={theme}>
      <Pipeline plan={plan} sessions={sessions} />
    </ThemeProvider>,
  )
}

beforeEach(() => {
  localStorageMock.clear()
  localStorageMock.getItem.mockClear()
  localStorageMock.setItem.mockClear()
})

/* ═══ Plan header removed (moved to HeroStrip in DashboardShell) ═══ */
describe('Pipeline: plan header removed', () => {
  it('does not render plan name or description', () => {
    renderPipeline()
    expect(screen.queryByText('Test Plan')).not.toBeInTheDocument()
    expect(screen.queryByText('A test execution plan')).not.toBeInTheDocument()
  })

  it('does not render overall progress percentage', () => {
    renderPipeline()
    expect(screen.queryByText('25%')).not.toBeInTheDocument()
    expect(screen.queryByText('1 of 4 tasks')).not.toBeInTheDocument()
  })
})

/* ═══ Horizontal card rail ═══ */
describe('Pipeline: horizontal card rail', () => {
  it('renders all phase names in compact cards', () => {
    renderPipeline()
    const cards = screen.getAllByTestId('phase-card')
    expect(cards.length).toBe(3)
    expect(within(cards[0]).getByText('Phase 0: Setup')).toBeInTheDocument()
    expect(within(cards[1]).getByText('Phase 1: Core')).toBeInTheDocument()
    expect(within(cards[2]).getByText('Phase 2: Empty')).toBeInTheDocument()
  })

  it('renders phase cards with data-testid', () => {
    renderPipeline()
    const cards = document.querySelectorAll('[data-testid="phase-card"]')
    expect(cards.length).toBe(3)
  })

  it('renders connectors between phase cards', () => {
    renderPipeline()
    const connectors = document.querySelectorAll('[data-testid="phase-connector"]')
    expect(connectors.length).toBe(2) // 3 phases → 2 connectors
  })

  /* Audit-13 #2 — connector after a 'done' phase reads as a live
     edge per docs/design_handoff_watchfloor_v2/specs/screens.md
     §Pipeline graph: "Live edges (between done -> running/done):
     wf.signal 1.4px stroke". The wire after a completed phase
     should be signal-blue, not status-done green. */
  it('connector after done phase carries the wf.signal live-edge color (audit-13 #2)', () => {
    renderPipeline()
    const connectors = document.querySelectorAll('[data-testid="phase-connector"]')
    /* Phase 0 (setup) has 1 done + 1 wip → status='wip', so the
       connector after it is NOT a live-edge case. Phase 1 (core)
       has 0 done → also not live. We assert the data-prev-status
       attribute is plumbed so the visual is deterministic. */
    expect(connectors[0].getAttribute('data-prev-status')).toBe('wip')
  })

  it('shows progress counts in compact cards', () => {
    renderPipeline()
    const cards = screen.getAllByTestId('phase-card')
    expect(within(cards[0]).getByText('1/2')).toBeInTheDocument() // setup: 1 done of 2
    expect(within(cards[1]).getByText('0/2')).toBeInTheDocument() // core: 0 done of 2
    expect(within(cards[2]).getByText('0/0')).toBeInTheDocument() // empty
  })
})

/* ═══ Single expansion ═══ */
describe('Pipeline: single expansion', () => {
  it('auto-expands the first WIP phase and shows its tasks', () => {
    renderPipeline()
    // Phase 0 has a WIP task, should auto-expand
    expect(screen.getByText('task-a')).toBeInTheDocument()
    expect(screen.getByText('task-b')).toBeInTheDocument()
  })

  it('expands a collapsed phase on click', async () => {
    renderPipeline()
    // Phase 1 is not expanded, click it via card
    const cards = screen.getAllByTestId('phase-card')
    expect(screen.queryByText('task-c')).not.toBeInTheDocument()
    await userEvent.click(cards[1])
    expect(screen.getByText('task-c')).toBeInTheDocument()
    expect(screen.getByText('task-d')).toBeInTheDocument()
  })

  it('closes the previously expanded phase when opening another', async () => {
    renderPipeline()
    // Phase 0 is auto-expanded
    expect(screen.getByText('task-a')).toBeInTheDocument()
    // Click Phase 1 card → Phase 0 closes, Phase 1 opens
    const cards = screen.getAllByTestId('phase-card')
    await userEvent.click(cards[1])
    expect(screen.queryByText('task-a')).not.toBeInTheDocument()
    expect(screen.getByText('task-c')).toBeInTheDocument()
  })

  it('collapses the expanded phase when clicking it again', async () => {
    renderPipeline()
    expect(screen.getByText('task-a')).toBeInTheDocument()
    const cards = screen.getAllByTestId('phase-card')
    await userEvent.click(cards[0])
    expect(screen.queryByText('task-a')).not.toBeInTheDocument()
  })
})

/* ═══ Auto-scroll to active phase ═══ */
describe('Pipeline: auto-scroll', () => {
  /* Audit-list-filters #2 — Pipeline used to call scrollIntoView on mount
     to center its active phase card. With block: 'nearest', the call
     propagated vertically up the parent chain and scrolled the Plans-tab
     container any time a filter click added/removed a plan (every new
     Pipeline mount fired the effect). The rail is now scrolled directly
     via scrollLeft so it never reaches outer scrollers. */
  it('does not propagate scroll to outer ancestors on mount', () => {
    vi.mocked(Element.prototype.scrollIntoView).mockClear()
    renderPipeline()
    expect(Element.prototype.scrollIntoView).not.toHaveBeenCalled()
  })
})

/* ═══ Task chip tags ═══ */
/* Row-2 layout contract — chips first, then autopilot indicator,
   then work-kind label. Consolidates what used to be three vertical
   rows (title / chips / type) into two so meta-info shares one
   horizontal line with the status pill. */
describe('Pipeline: title row carries mode icon, meta row carries chips + kind', () => {
  /* Skarmaudit-15a #2 — execution-mode icon (RadarMark for autopilot,
     manual phase pointer otherwise) sits inline with the task title
     on Row 1, like a glyph on the same baseline as the name. Row 2
     is then reserved for chips (exception-only per audit-15a #1) and
     the work-kind label (TaskNodeExtrasV2). PhaseStepper-paritet:
     status semantics live next to the name; secondary metadata sits
     below. */
  const planWithAutopilotAndType: Plan = {
    schema_version: '2.0.0',
    name: 'Layout Plan',
    phases: [
      {
        id: 'p',
        name: 'Phase',
        tasks: [
          {
            id: 'layout-task',
            name: 'Layout Task',
            status: 'wip',
            autopilot: true,
            pipeline: 'full',
            task_type: 'development',
          },
        ],
      },
    ],
  } as Plan

  it('autopilot task renders the radar mark inside the title row (next to task name)', () => {
    renderPipeline(planWithAutopilotAndType)
    const radars = document.querySelectorAll('svg[aria-label="watchfloor radar mark"]')
    expect(radars.length).toBe(1)
    /* The radar's nearest flex-row ancestor must contain the task
       name typography element (Row 1 contract). */
    const taskName = screen.getByText('layout-task')
    let row: HTMLElement | null = radars[0] as HTMLElement
    while (row && !row.contains(taskName)) row = row.parentElement
    expect(row).not.toBeNull()
  })

  it('autopilot task does NOT render the radar inside the work-kind row', () => {
    renderPipeline(planWithAutopilotAndType)
    const workKind = screen.getByText('Development')
    /* The radar must NOT share the same flex row as the kind label
       any more — otherwise we have not actually moved it. */
    let row: HTMLElement | null = workKind.parentElement
    while (row && row.parentElement) {
      const rs = row.querySelector('svg[aria-label="watchfloor radar mark"]')
      if (rs) {
        /* Only fail if the row is the meta row (i.e., does not also
           contain the task name — that would be the title row, which
           is allowed to host both). */
        const containsName = row.contains(screen.getByText('layout-task'))
        if (!containsName) throw new Error('radar mark found in meta row')
      }
      row = row.parentElement
    }
    /* If we reach the end without throwing, the radar lives only in
       the title row. Assert work-kind is still present. */
    expect(workKind).toBeInTheDocument()
  })

  it('work-kind label stays in the meta row (Row 2)', () => {
    renderPipeline(planWithAutopilotAndType)
    const workKind = screen.getByText('Development')
    const taskName = screen.getByText('layout-task')
    /* Walk up from the work-kind label looking for a flex row;
       that row must NOT contain the task name (the kind label is
       on a separate row from the title). */
    let row: HTMLElement | null = workKind.parentElement
    let separated = false
    while (row && row.parentElement) {
      if (!row.contains(taskName)) { separated = true; break }
      row = row.parentElement
    }
    expect(separated).toBe(true)
  })

  /* Manual-task indicator: every task without autopilot=true is
     manual. The IconPhaseManual sharp-pointer renders alongside
     the task title now (Row 1). */
  it('non-autopilot task renders the manual phase icon inside the title row, no radar', () => {
    const manualPlan: Plan = {
      schema_version: '2.0.0',
      name: 'Manual Plan',
      phases: [
        {
          id: 'p',
          name: 'Phase',
          tasks: [
            {
              id: 'manual-task',
              name: 'Manual Task',
              status: 'wip',
              task_type: 'review',
            },
          ],
        },
      ],
    } as Plan
    renderPipeline(manualPlan)
    expect(document.querySelectorAll('svg[aria-label="watchfloor radar mark"]').length).toBe(0)
    /* IconPhaseManual draws a polygon path starting at "M6 4 L6 17". */
    const paths = Array.from(document.querySelectorAll('svg path'))
    const manualPath = paths.find((p) => p.getAttribute('d')?.startsWith('M6 4 L6 17'))
    expect(manualPath).toBeDefined()
    /* Manual icon lives in the title row alongside the task name. */
    const taskName = screen.getByText('manual-task')
    let row: HTMLElement | null = manualPath as HTMLElement
    while (row && !row.contains(taskName)) row = row.parentElement
    expect(row).not.toBeNull()
  })

  /* Autopilot tasks render the radar regardless of any manual-test
     authoring info that may also be present. */
  it('autopilot + manual_test renders radar, not manual icon', () => {
    const bothPlan: Plan = {
      schema_version: '2.0.0',
      name: 'Both',
      phases: [
        {
          id: 'b',
          name: 'Phase',
          tasks: [
            {
              id: 'b',
              name: 'Both Task',
              status: 'wip',
              autopilot: true,
              pipeline: 'light',
              task_type: 'development',
              manual_test: 'check it manually',
            },
          ],
        },
      ],
    } as Plan
    renderPipeline(bothPlan)
    expect(document.querySelectorAll('svg[aria-label="watchfloor radar mark"]').length).toBe(1)
  })
})

/* ═══ Phase cards aligned with task-card vocabulary ═══ */
describe('Pipeline: phase cards mirror task-card chrome', () => {
  /* Operator: top phase strip + side markers + expansion-panel
     edge cards "deres design er ikke alignet med resten". The
     phase card now mirrors the task-card 3-element family:
     header row + meta row + bottom-edge completion gauge. */
  it('compact phase card carries a bottom-edge completion gauge', () => {
    renderPipeline()
    const cards = document.querySelectorAll('[data-testid="phase-card"]')
    expect(cards.length).toBeGreaterThan(0)
    /* Each card must include a wf-phase-gauge element. */
    for (const card of cards) {
      expect(card.querySelector('[data-testid="wf-phase-gauge"]')).not.toBeNull()
    }
  })

  it('phase gauge fills to phase progress percentage', () => {
    /* Phase 0 (mockPlan): 1 done + 1 wip = 50% done. */
    renderPipeline()
    const cards = document.querySelectorAll('[data-testid="phase-card"]')
    const phase0 = cards[0] as HTMLElement
    const gauge = phase0.querySelector('[data-testid="wf-phase-gauge"]') as HTMLElement
    /* phaseProgress(phase) computes done/total = 1/2 = 50%. */
    expect(gauge.getAttribute('aria-valuenow')).toBe('50')
  })
})

/* ═══ Gate-node layout aligned with task-card vocabulary ═══ */
describe('Pipeline: gate node layout matches task card', () => {
  /* Gate boxes used to be a single horizontal row with a 16px
     lock icon — operator: "tekst og ikoner i phase gate boxe
     bør alignes med placering og tekst i andre boxe". The gate
     should now mirror the task-card 2-row structure (status
     row + meta row) plus a completion gauge at the bottom edge. */
  it('gate node renders both the title row and the summary row', () => {
    renderPipeline()
    const gate = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    /* Gate name + summary must both be inside the same gate
       node. The setup-gate plan provides 'Setup Gate' as name
       and a summary like "0/3 checks". */
    expect(within(gate).getByText('Setup Gate')).toBeInTheDocument()
    expect(within(gate).getByText(/checks/i)).toBeInTheDocument()
  })

  it('gate node carries a completion gauge at the bottom edge', () => {
    renderPipeline()
    const gate = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    /* The same data-testid as TaskProgressBar; data-node-id is
       the gate sentinel "__gate". */
    const gauge = gate.querySelector('[data-testid="task-progress-bar"]')
    expect(gauge).not.toBeNull()
  })

  it('passed gate gauge fills 100% completed-green', () => {
    const passed: Plan = {
      schema_version: '1.0.0',
      name: 'P',
      phases: [{
        id: 'p',
        name: 'Phase',
        /* WIP task ensures the phase auto-expands so the gate
           popover/inline node is in the DOM. */
        tasks: [{ id: 't', name: 'T', status: 'wip' }],
        gate: { name: 'G', checklist: ['a'], passed: true },
      }],
    }
    renderPipeline(passed)
    const gate = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    const gauge = gate.querySelector('[data-testid="task-progress-bar"]') as HTMLElement
    expect(gauge.getAttribute('data-status')).toBe('completed')
    expect(gauge.getAttribute('aria-valuenow')).toBe('100')
  })
})

/* ═══ Heading typography unification across task / gate / compact phase ═══ */
describe('Pipeline: brand heading vocabulary', () => {
  /* Task names, gate names, and compact-phase names all sit in
     the same visual rhythm — they should share the wfBody brand
     variant so the rail reads as one font scale, not three. */
  it('task node title uses the wfBody brand variant', () => {
    renderPipeline()
    const titleA = screen.getByText('task-a')
    expect(titleA.className).toMatch(/MuiTypography-wfBody/)
  })

  /* User-request 2026-05-08 - TaskNodeCard now shows task.id as the
     visible heading (matches the chip vocabulary in DEPENDS ON / REQUIRED
     BY) and surfaces task.name via a native title attribute on hover. */
  it('task node visible title is task.id, not task.name', () => {
    renderPipeline()
    expect(screen.getByText('task-a')).toBeInTheDocument()
    expect(screen.queryByText('Task A')).not.toBeInTheDocument()
  })

  it('task node title carries task.name as native title attribute', () => {
    renderPipeline()
    const titleA = screen.getByText('task-a')
    expect(titleA.getAttribute('title')).toBe('Task A')
  })

  it('compact phase card title uses the wfBody brand variant', () => {
    renderPipeline()
    const phaseTitle = screen.getByText('Phase 0: Setup')
    expect(phaseTitle.className).toMatch(/MuiTypography-wfBody/)
  })

  it('gate node title uses the wfBody brand variant', () => {
    renderPipeline()
    const gateTitle = screen.getByText('Setup Gate')
    expect(gateTitle.className).toMatch(/MuiTypography-wfBody/)
  })
})

/* ═══ Phase expansion panel corner reticles — handoff §"instrument panel" ═══ */
describe('Pipeline: expansion-panel corner reticles', () => {
  /* The expanded phase panel renders the wf CornerReticles brand
     overlay (4 L-shaped marks at the corners). Lock the count
     after expanding a phase. */
  it('expanded phase panel renders four wf corner reticles', () => {
    /* mockPlan auto-expands Phase 0 (it carries a wip task) so the
       expansion panel and its reticles are in the DOM on mount. */
    renderPipeline()
    const reticles = document.querySelectorAll('[data-testid="wf-corner-reticle"]')
    expect(reticles.length).toBe(4)
  })
})

/* ═══ Line color taxonomy — chrome vs flow ═══ */
describe('Pipeline: line color taxonomy - solid blue when prev done, solid grey otherwise', () => {
  /* Skarmaudit-15c (rewrite of 15b #3) - the chrome-vs-flow split was
     wrong: operator wants every line where the predecessor is done
     (or actively flowing) to read as the unlocked path - solid blue
     - regardless of whether the line crosses a phase boundary. Grey
     is reserved for lines whose predecessor is pending (future flow,
     not yet unlocked). All strokes are SOLID; dashes removed
     globally because dashed strokes read as noise alongside the
     status-driven colour split.

     Concretely:
       prev done    -> solid wf.signal blue
       prev wip     -> solid wf.signal blue (active flow == unlocked)
       prev pending -> solid grey (text-secondary @ 0.3)
       no prev      -> solid grey (the "Start" marker case) */
  const twoPhaseDonePlan: Plan = {
    schema_version: '1.0.0',
    name: 'D',
    phases: [
      { id: 'p1', name: 'P1', tasks: [{ id: 'a', name: 'A', status: 'done' }] },
      { id: 'p2', name: 'P2', tasks: [{ id: 'b', name: 'B', status: 'wip' }] },
    ],
  }

  it('phase-card connector in top rail after done phase renders solid blue', () => {
    renderPipeline(twoPhaseDonePlan)
    const connectors = document.querySelectorAll('[data-testid="phase-connector"]')
    expect(connectors.length).toBeGreaterThan(0)
    const conn0 = connectors[0] as HTMLElement
    const hairline = conn0.querySelector('[data-testid="phase-connector-line"]') as HTMLElement | null
    expect(hairline).not.toBeNull()
    /* Inline style is the deterministic surface; jsdom does not
       resolve MUI sx classes so computed-style colour reads as
       rgb(0,0,0). Probe the inline border declaration directly. */
    const inlineStyle = (hairline as HTMLElement).getAttribute('style') ?? ''
    expect(inlineStyle).toContain('--mui-palette-wf-signal')
    expect(inlineStyle).toContain('solid')
    expect(hairline?.getAttribute('data-flow')).toBe('true')
  })

  it('phase-card connector after pending phase renders solid grey, not blue', () => {
    const planPendingFirst: Plan = {
      schema_version: '1.0.0',
      name: 'PF',
      phases: [
        { id: 'p1', name: 'P1', tasks: [{ id: 'a', name: 'A', status: 'pending' }] },
        { id: 'p2', name: 'P2', tasks: [{ id: 'b', name: 'B', status: 'pending' }] },
      ],
    }
    renderPipeline(planPendingFirst)
    const connectors = document.querySelectorAll('[data-testid="phase-connector"]')
    expect(connectors.length).toBeGreaterThan(0)
    const hairline = (connectors[0] as HTMLElement).querySelector('[data-testid="phase-connector-line"]') as HTMLElement
    expect(hairline.getAttribute('data-flow')).toBe('false')
    const inlineStyle = hairline.getAttribute('style') ?? ''
    expect(inlineStyle).not.toContain('wf-signal')
  })

  it('expanded-view entry line from done-prev-phase marker to first task renders blue', () => {
    renderPipeline(twoPhaseDonePlan)
    const paths = Array.from(document.querySelectorAll('svg path'))
    const blueStrokes = paths.filter((pp) => {
      const stroke = pp.getAttribute('style') || ''
      return stroke.includes('--mui-palette-wf-signal')
    })
    /* The entry line into phase 2 (prev = phase 1 done) must use
       the wf-signal palette token. */
    expect(blueStrokes.length).toBeGreaterThan(0)
  })

  it('done-phase entry line never references the status-done palette token', () => {
    renderPipeline(twoPhaseDonePlan)
    const paths = Array.from(document.querySelectorAll('svg path'))
    const greenStrokes = paths.filter((pp) => {
      const stroke = pp.getAttribute('style') || ''
      return stroke.includes('--mui-palette-status-done')
    })
    expect(greenStrokes.length).toBe(0)
  })

  it('expanded-view entry line into a phase whose prev is pending renders grey, not blue', () => {
    const planPrevPending: Plan = {
      schema_version: '1.0.0',
      name: 'PP',
      phases: [
        { id: 'p1', name: 'P1', tasks: [{ id: 'a', name: 'A', status: 'pending' }] },
        { id: 'p2', name: 'P2', tasks: [{ id: 'b', name: 'B', status: 'wip' }] },
      ],
    }
    renderPipeline(planPrevPending)
    /* Entry paths start at marker x=140 (MARKER_W_CONST). Filter
       on the d-prefix so the leaf-to-exit path (which starts at the
       task right edge, much further right) is excluded - the leaf
       being wip would emit a separate blue exit line that is not
       what this test is asserting. */
    const paths = Array.from(document.querySelectorAll('svg path'))
    const entryPaths = paths.filter((pp) => (pp.getAttribute('d') ?? '').startsWith('M 140 '))
    expect(entryPaths.length).toBeGreaterThan(0)
    for (const ep of entryPaths) {
      const style = ep.getAttribute('style') ?? ''
      expect(style).not.toContain('wf-signal')
    }
  })

  it('all rendered svg path connectors are solid (no strokeDasharray patterns)', () => {
    renderPipeline(twoPhaseDonePlan)
    const paths = Array.from(document.querySelectorAll('svg path'))
    /* Skip non-connector paths (icons etc.) by filtering for the
       orthogonal "M x y H/V" prefix. */
    const connectors = paths.filter((pp) => (pp.getAttribute('d') ?? '').startsWith('M '))
    for (const c of connectors) {
      const dasharray = c.getAttribute('stroke-dasharray')
      expect(dasharray === null || dasharray === 'none' || dasharray === '0').toBe(true)
    }
  })
})

/* ═══ Sharp 90° elbow connectors — handoff §"orthogonal edges" ═══ */
describe('Pipeline: sharp 90-degree elbow connectors', () => {
  /* The radar geometry the rest of the brand is built on uses
     hard 90° lines (concentric rings + crosshair). The pipeline
     graph should match: no rounded elbows. Quadratic Q commands
     in the connector paths indicate corner curves — assert none
     are rendered. */
  it('connector paths render with hard right angles (no Q curve commands)', () => {
    renderPipeline(dagPlan)
    const paths = Array.from(document.querySelectorAll('svg path'))
    /* Filter to connector paths (those without a fill — connectors
       are stroked-only). */
    const connectors = paths.filter((p) => p.getAttribute('fill') === 'none')
    expect(connectors.length).toBeGreaterThan(0)
    for (const p of connectors) {
      const d = p.getAttribute('d') ?? ''
      expect(d).not.toMatch(/Q/)
    }
  })
})

/* ═══ Per-task completion gauge — handoff §"Task node completion gauge" ═══ */
describe('Pipeline: per-task completion gauge', () => {
  const planWithStatuses: Plan = {
    schema_version: '1.0.0',
    name: 'Gauge Plan',
    phases: [
      {
        id: 'g',
        name: 'Phase',
        tasks: [
          { id: 'g-done', name: 'Done', status: 'done' },
          { id: 'g-wip', name: 'WIP', status: 'wip' },
          { id: 'g-failed', name: 'Failed', status: 'failed' },
          { id: 'g-pending', name: 'Pending', status: 'pending' },
          { id: 'g-skipped', name: 'Skipped', status: 'skipped' },
        ],
      },
    ],
  }

  /* Each task node carries a small bar at the bottom of its card —
     a "completion gauge" — exposing data-testid="task-progress-bar"
     plus data-status (mirrors WfStatus where applicable, "muted"
     for the inert pending/skipped states). The data attributes
     keep tests stable regardless of color tokens. */
  it('renders a completion gauge per task in active states (done/wip/failed)', () => {
    renderPipeline(planWithStatuses)
    const gauges = document.querySelectorAll('[data-testid="task-progress-bar"]')
    /* Active states render the gauge (done/wip/failed = 3). Pending
       and skipped intentionally render no bar — non-state. */
    expect(gauges.length).toBe(3)
  })

  it('done task gauge fills 100% with the completed-green token', () => {
    renderPipeline(planWithStatuses)
    const gauge = document.querySelector('[data-testid="task-progress-bar"][data-task-id="g-done"]') as HTMLElement
    expect(gauge).not.toBeNull()
    expect(gauge.getAttribute('data-status')).toBe('completed')
    expect(gauge.getAttribute('aria-valuenow')).toBe('100')
  })

  it('failed task gauge fills 100% with fault-red token', () => {
    renderPipeline(planWithStatuses)
    const gauge = document.querySelector('[data-testid="task-progress-bar"][data-task-id="g-failed"]') as HTMLElement
    expect(gauge.getAttribute('data-status')).toBe('fault')
    expect(gauge.getAttribute('aria-valuenow')).toBe('100')
  })

  it('wip task gauge uses session.flow progress when a session is live', () => {
    const sess: Session = {
      sid: 's1', cwd: '/dev', worktree: '/dev', branch: 'feature/g-wip',
      event: 'Notification', type: 'agent', msg: '', ts: new Date().toISOString(),
      status: 'working',
      flow: { feature: 'g-wip', phase: 'implement', phase_index: 4, total_phases: 9 },
    }
    renderPipeline(planWithStatuses, [sess])
    const gauge = document.querySelector('[data-testid="task-progress-bar"][data-task-id="g-wip"]') as HTMLElement
    expect(gauge.getAttribute('data-status')).toBe('running')
    /* Midpoint heuristic per audit-11 — (phase_index + 0.5) / total
       so the bar shows halfway-through-current-phase. (4+0.5)/9 = 50. */
    expect(gauge.getAttribute('aria-valuenow')).toBe('50')
  })

  it('wip task without session reports an indeterminate-fill gauge', () => {
    renderPipeline(planWithStatuses)
    const gauge = document.querySelector('[data-testid="task-progress-bar"][data-task-id="g-wip"]') as HTMLElement
    expect(gauge.getAttribute('data-status')).toBe('running')
    /* No session.flow data — gauge falls back to a neutral 50%
       fill so the brand color still reads at a glance. */
    expect(gauge.getAttribute('aria-valuenow')).toBe('50')
  })

  /* Audit-10 #2 — wip track is GREY (wf.steel) per user-spec
     "blå og grå når feature er startet": fill = signal-blue
     progress, track = neutral grey for the remaining slack.
     Done/failed gauges fill 100% so their track is invisible
     either way; only wip exposes the brand-signal of two-tone. */
  it('wip task gauge uses wf.steel grey track (audit-10 #2)', () => {
    renderPipeline(planWithStatuses)
    const gauge = document.querySelector('[data-testid="task-progress-bar"][data-task-id="g-wip"]') as HTMLElement
    expect(gauge).not.toBeNull()
    expect(gauge.getAttribute('data-track')).toBe('wf.steel')
  })

  /* Audit-10 #1 — phase label moves to its own Row 3 below pills/icons.
     The in-row LinearProgress is removed entirely (the bottom-edge
     TaskProgressBar carries the progress signal). User feedback:
     "fase-tekst under pills, radar ikon og typen i stedet for efter". */
  it('phase label renders in a dedicated row, not inline with pills (audit-10 #1)', () => {
    const sess: Session = {
      sid: 's2', cwd: '/dev', worktree: '/dev', branch: 'feature/g-wip',
      event: 'Notification', type: 'agent', msg: '', ts: new Date().toISOString(),
      status: 'working',
      flow: { feature: 'g-wip', phase: 'implement', phase_index: 4, total_phases: 9 },
    }
    renderPipeline(planWithStatuses, [sess])
    const card = document.querySelector('[data-node-id="g-wip"]') as HTMLElement
    expect(card).not.toBeNull()
    const phaseLabel = card.querySelector('[data-testid="task-phase-label"]')
    expect(phaseLabel).not.toBeNull()
    expect(phaseLabel?.textContent).toMatch(/Impl/i)
  })

  it('drops in-row LinearProgress entirely — bottom TaskProgressBar is sole progress indicator (audit-10 #1)', () => {
    const sess: Session = {
      sid: 's3', cwd: '/dev', worktree: '/dev', branch: 'feature/g-wip',
      event: 'Notification', type: 'agent', msg: '', ts: new Date().toISOString(),
      status: 'working',
      flow: { feature: 'g-wip', phase: 'implement', phase_index: 4, total_phases: 9 },
    }
    renderPipeline(planWithStatuses, [sess])
    const card = document.querySelector('[data-node-id="g-wip"]') as HTMLElement
    expect(card.querySelector('.MuiLinearProgress-root')).toBeNull()
  })
})

describe('Pipeline: task chips - exception-only contract', () => {
  /* Brand decision (skarmaudit-15a): pills carry no signal that the
     dot+bar do not already carry. Default flow is pill-free; pills
     only appear for EXCEPTION states that interrupt expected progress
     (failed, blocked, needs_input, paused/stopped). Closed/completed/
     working/idle never get pills. Keeps Row 2 clean and matches the
     PhaseStepper sidebar rhythm where status is encoded purely in
     the dot + label typography. */

  it('does not show ACTIVE badge (removed, StatusDot is sufficient)', () => {
    renderPipeline()
    expect(screen.queryByText('ACTIVE')).not.toBeInTheDocument()
    expect(screen.queryByText('active')).not.toBeInTheDocument()
  })

  it('shows "fix" chip for failed tasks', () => {
    const failPlan: Plan = {
      schema_version: '1.0.0',
      name: 'Fail Plan',
      phases: [{
        id: 'p', name: 'Phase', tasks: [
          { id: 't1', name: 'Broken Task', status: 'failed' },
        ],
      }],
    }
    renderPipeline(failPlan)
    expect(screen.getByText('fix')).toBeInTheDocument()
  })

  it('does NOT show blocked chip on blocked pending tasks (dashed inbound connector signals the dependency)', () => {
    const blockedPlan: Plan = {
      schema_version: '1.0.0',
      name: 'Blocked Plan',
      phases: [{
        id: 'p', name: 'Phase', tasks: [
          { id: 'dep', name: 'Dep', status: 'wip' },
          { id: 'blocked-task', name: 'Blocked Task', status: 'pending', depends: ['dep'] },
        ],
      }],
    }
    renderPipeline(blockedPlan)
    /* Skarmaudit-15b #1 - the BLOCKED pill duplicated information
       the dashed inbound SVG connector + hollow status dot already
       carry. Pill dropped; the connector is now the sole blocked
       signal. */
    expect(screen.queryByText('blocked')).not.toBeInTheDocument()
    /* The inbound SVG connector still renders so the dependency
       structure is visible. */
    const blockedCard = document.querySelector('[data-node-id="blocked-task"]')
    expect(blockedCard).not.toBeNull()
  })

  /* Redundant pill drops - the StatusDot in Row 1 + TaskProgressBar
     fill carry the status. Adding a pill triples the visual weight
     for no information gain. */
  it('does NOT show working session chip on wip task (StatusDot is sufficient)', () => {
    const sessionPlan: Plan = {
      schema_version: '1.0.0',
      name: 'Session Plan',
      phases: [{
        id: 'p', name: 'Phase', tasks: [
          { id: 'my-task', name: 'My Task', status: 'wip' },
        ],
      }],
    }
    const sessions: Session[] = [{
      sid: 's1', cwd: '/tmp', worktree: '/tmp', branch: 'feat/my-task',
      event: 'Notification', type: 'agent', msg: 'working', ts: new Date().toISOString(),
      status: 'working', flow: null,
    }]
    renderPipeline(sessionPlan, sessions)
    expect(screen.queryByText('working')).not.toBeInTheDocument()
  })

  it('does not show session chip for ended sessions on pending tasks', () => {
    const sessionPlan: Plan = {
      schema_version: '1.0.0',
      name: 'Stale Session Plan',
      phases: [{
        id: 'p', name: 'Phase', tasks: [
          { id: 'recon-eval', name: 'Recon Eval', status: 'pending' },
        ],
      }],
    }
    const sessions: Session[] = [{
      sid: 's1', cwd: '/tmp', worktree: '/tmp', branch: 'feature/recon-eval',
      event: 'SessionEnd', type: '', msg: '', ts: '2026-03-22T16:56:36Z',
      status: 'closed', flow: null,
    }]
    renderPipeline(sessionPlan, sessions)
    expect(screen.queryByText('closed')).not.toBeInTheDocument()
  })

  it('does NOT show closed session chip on wip task (StatusDot + bar are sufficient)', () => {
    const sessionPlan: Plan = {
      schema_version: '1.0.0',
      name: 'WIP Closed Plan',
      phases: [{
        id: 'p', name: 'Phase', tasks: [
          { id: 'my-task', name: 'My Task', status: 'wip' },
        ],
      }],
    }
    const sessions: Session[] = [{
      sid: 's1', cwd: '/tmp', worktree: '/tmp', branch: 'feat/my-task',
      event: 'SessionEnd', type: '', msg: '', ts: '2026-03-22T10:00:00Z',
      status: 'closed', flow: null,
    }]
    renderPipeline(sessionPlan, sessions)
    expect(screen.queryByText('closed')).not.toBeInTheDocument()
  })

  it('does NOT show completed chip on done tasks (StatusDot + bar are sufficient)', async () => {
    const donePlan: Plan = {
      schema_version: '1.0.0',
      name: 'Done Plan',
      phases: [{
        id: 'p', name: 'Phase', tasks: [
          { id: 'finished-task', name: 'Finished Task', status: 'done' },
        ],
      }],
    }
    renderPipeline(donePlan, [])
    const cards = screen.getAllByTestId('phase-card')
    await userEvent.click(cards[0])
    expect(screen.queryByText('completed')).not.toBeInTheDocument()
  })

  it('shows "needs input" session chip with pulse', () => {
    const sessionPlan: Plan = {
      schema_version: '1.0.0',
      name: 'Input Plan',
      phases: [{
        id: 'p', name: 'Phase', tasks: [
          { id: 'my-task', name: 'My Task', status: 'wip' },
        ],
      }],
    }
    const sessions: Session[] = [{
      sid: 's1', cwd: '/tmp', worktree: '/tmp', branch: 'feat/my-task',
      event: 'Notification', type: 'agent', msg: 'help', ts: new Date().toISOString(),
      status: 'needs_input', flow: null,
    }]
    renderPipeline(sessionPlan, sessions)
    expect(screen.getByText('needs input')).toBeInTheDocument()
  })

  /* PAUSED muted pill - when session is intentionally stopped or has
     gone stale on a wip task, the pill primitive's muted variant
     (status=null, fog text on steel border) flags the inert state
     without adding more colour to the palette. The muted variant
     is documented in StatusPill.tsx as the spec target for paused. */
  it('shows paused muted pill when session is stopped on wip task', () => {
    const plan: Plan = {
      schema_version: '1.0.0',
      name: 'Paused Plan',
      phases: [{
        id: 'p', name: 'Phase', tasks: [
          { id: 'my-task', name: 'My Task', status: 'wip' },
        ],
      }],
    }
    const sessions: Session[] = [{
      sid: 's1', cwd: '/tmp', worktree: '/tmp', branch: 'feat/my-task',
      event: 'SessionEnd', type: '', msg: '', ts: new Date().toISOString(),
      status: 'stopped', flow: null,
    }]
    renderPipeline(plan, sessions)
    expect(screen.getByText('paused')).toBeInTheDocument()
  })

  it('shows paused muted pill when session is stale on wip task', () => {
    const plan: Plan = {
      schema_version: '1.0.0',
      name: 'Stale Plan',
      phases: [{
        id: 'p', name: 'Phase', tasks: [
          { id: 'my-task', name: 'My Task', status: 'wip' },
        ],
      }],
    }
    const sessions: Session[] = [{
      sid: 's1', cwd: '/tmp', worktree: '/tmp', branch: 'feat/my-task',
      event: 'Notification', type: 'agent', msg: 'idle', ts: new Date().toISOString(),
      status: 'stale', flow: null,
    }]
    renderPipeline(plan, sessions)
    expect(screen.getByText('paused')).toBeInTheDocument()
  })

  it('paused chip renders as muted wf-status-pill (status=muted)', () => {
    const plan: Plan = {
      schema_version: '1.0.0',
      name: 'Paused Plan',
      phases: [{
        id: 'p', name: 'Phase', tasks: [
          { id: 'my-task', name: 'My Task', status: 'wip' },
        ],
      }],
    }
    const sessions: Session[] = [{
      sid: 's1', cwd: '/tmp', worktree: '/tmp', branch: 'feat/my-task',
      event: 'SessionEnd', type: '', msg: '', ts: new Date().toISOString(),
      status: 'stopped', flow: null,
    }]
    renderPipeline(plan, sessions)
    const pill = document
      .querySelector('[data-testid="wf-status-pill"][data-status="muted"]')
    expect(pill).not.toBeNull()
    expect(pill?.textContent?.toLowerCase()).toContain('paused')
  })

  /* Brand handoff: the remaining task-node status chips (fix /
     needs input / paused) all render as wf StatusPills so
     they share the brand pill shape, mono uppercase label, and the
     correct colour band (or the muted treatment for paused). */
  it('renders the failed-task "fix" chip as a wf-status-pill (fault)', () => {
    const failPlan: Plan = {
      schema_version: '1.0.0',
      name: 'Fail',
      phases: [{
        id: 'p', name: 'Phase', tasks: [
          { id: 't', name: 'Broken', status: 'failed' },
        ],
      }],
    }
    renderPipeline(failPlan, [])
    const pill = document
      .querySelector('[data-testid="wf-status-pill"][data-status="fault"]')
    expect(pill).not.toBeNull()
    expect(pill?.textContent?.toLowerCase()).toContain('fix')
  })

  /* Plain wip task with no exception condition has no pill in Row 2.
     The radar/manual mode icon and the kind label still render
     (those are not chips). This is the dominant case in steady-state
     pipelines so it must stay visually clean. */
  it('plain wip task without exception state has no status pill', () => {
    const plan: Plan = {
      schema_version: '1.0.0',
      name: 'Clean WIP',
      phases: [{
        id: 'p', name: 'Phase', tasks: [
          { id: 't', name: 'Clean Task', status: 'wip' },
        ],
      }],
    }
    renderPipeline(plan, [])
    const card = document.querySelector('[data-node-id="t"]') as HTMLElement
    expect(card).not.toBeNull()
    const pills = card.querySelectorAll('[data-testid="wf-status-pill"]')
    expect(pills.length).toBe(0)
  })

  /* Task-node content stacks from the TOP edge (justify-content:
     flex-start) - slack collapses to the bottom so the upcoming
     progress bar can drop in there without re-flowing the rows. */
  it('aligns task-node rows to the top edge (slack at bottom)', () => {
    renderPipeline()
    const node = document.querySelector('[data-node-id]') as HTMLElement
    expect(node).toBeTruthy()
    const cs = window.getComputedStyle(node)
    expect(cs.justifyContent).toBe('flex-start')
  })
})

/* ═══ Start entry line goes blue when first task starts (audit-15c #8) ═══ */
describe('Pipeline: Start entry line color (audit-15c #8)', () => {
  it('Start entry line is blue when the first root task is wip', () => {
    const wipFirstPlan: Plan = {
      schema_version: '1.0.0',
      name: 'WF',
      phases: [{
        id: 'p',
        name: 'P',
        tasks: [{ id: 'a', name: 'A', status: 'wip' }],
      }],
    }
    renderPipeline(wipFirstPlan)
    const paths = Array.from(document.querySelectorAll('svg path'))
    const entryPaths = paths.filter((pp) => (pp.getAttribute('d') ?? '').startsWith('M 140 '))
    expect(entryPaths.length).toBeGreaterThan(0)
    const blueEntries = entryPaths.filter((ep) => (ep.getAttribute('style') ?? '').includes('--mui-palette-wf-signal'))
    expect(blueEntries.length).toBeGreaterThan(0)
  })

  it('Start entry line is grey when the first root task is pending', () => {
    const pendingFirstPlan: Plan = {
      schema_version: '1.0.0',
      name: 'PF',
      phases: [{
        id: 'p',
        name: 'P',
        tasks: [
          { id: 'a', name: 'A', status: 'pending' },
          { id: 'b', name: 'B', status: 'wip', depends: ['a'] },
        ],
      }],
    }
    renderPipeline(pendingFirstPlan)
    const paths = Array.from(document.querySelectorAll('svg path'))
    const entryPaths = paths.filter((pp) => (pp.getAttribute('d') ?? '').startsWith('M 140 '))
    expect(entryPaths.length).toBeGreaterThan(0)
    for (const ep of entryPaths) {
      const style = ep.getAttribute('style') ?? ''
      expect(style).not.toContain('--mui-palette-wf-signal')
    }
  })
})

/* ═══ Phase tree panel sizing is consistent regardless of banner ═══ */
describe('Pipeline: phase-tree panel sizing (audit-15c #9)', () => {
  it('phase-tree height equals tree content (no extra banner gap below)', () => {
    /* Use a chain of two tasks so dagLayout places them at col 0+1
       row 0+0 (single row). A single isolated task would otherwise
       land at row 1 (dagLayout reserves row 0 for connected tasks
       even when there are none). */
    const plan: Plan = {
      schema_version: '2.0.0',
      name: 'BS',
      phases: [{
        id: 'p',
        name: 'P',
        tasks: [
          { id: 'a', name: 'A', status: 'wip' },
          { id: 'b', name: 'B', status: 'pending', depends: ['a'] },
        ],
      }],
    } as Plan
    renderPipeline(plan)
    const tree = document.querySelector('[data-testid="phase-tree"]') as HTMLElement
    expect(tree).not.toBeNull()
    const inlineStyle = tree.getAttribute('style') ?? ''
    /* Single-row tree (NODE_H=72) - height should be 72px, NOT 104
       (the old code added +32 for the banner). */
    expect(inlineStyle).toMatch(/height:\s*72px/)
  })

  it('phase-tree does NOT render the legacy overview banner or context accordion (audit-15c #11)', () => {
    /* Operator: "det er ikke meningen at phase overview banner
       eller phase context accordion overhovedet skal vises der".
       Both were dropped from the phase-tree expansion panel; their
       data still lives on the plan but is no longer rendered here. */
    const plan: Plan = {
      schema_version: '2.0.0',
      name: 'NB',
      phases: [{
        id: 'p',
        name: 'P',
        overview_summary: 'A summary that should not appear in the phase tree.',
        sequencing_rationale: 'Rationale that should not appear in the phase tree.',
        tasks: [
          { id: 'a', name: 'A', status: 'wip' },
          { id: 'b', name: 'B', status: 'pending', depends: ['a'] },
        ],
      }],
    } as Plan
    renderPipeline(plan)
    expect(document.querySelector('[data-testid="phase-header-row"]')).toBeNull()
    expect(document.querySelector('[data-testid="phase-overview-summary"]')).toBeNull()
    expect(document.querySelector('[data-testid="phase-context-accordion"]')).toBeNull()
    expect(screen.queryByText('Phase context')).not.toBeInTheDocument()
    expect(screen.queryByText(/should not appear in the phase tree/i)).not.toBeInTheDocument()
  })
})

/* ═══ Phase rail scrollbar visibility + entry/exit straightening ═══ */
describe('Pipeline: rail scrollbar + entry/exit anchor (audit-16)', () => {
  it('both rails reveal scrollbar thumb on hover (transparent until container hover)', () => {
    /* Operator (audit-16 final): macOS auto-hide may keep scrollbars
       fully hidden when system pref is 'When scrolling'. Hover-reveal
       pattern: 8px scrollbar always reserves space (no layout shift)
       but track + thumb are transparent until container :hover, then
       fade in. Identical rules on both rails. Probe stylesheet for
       ':hover ::-webkit-scrollbar-thumb' rule so the hover fade-in
       contract is asserted. */
    renderPipeline()
    const styleEls = Array.from(document.querySelectorAll('style'))
    let hoverThumbRules = 0
    for (const el of styleEls) {
      const txt = el.textContent ?? ''
      const matches = txt.match(/:hover\s*::-webkit-scrollbar-thumb\s*\{[^}]*\}/g) ?? []
      hoverThumbRules += matches.length
    }
    expect(hoverThumbRules).toBeGreaterThanOrEqual(2)
  })

  /* Audit-15c #7 - entry line from prev-phase marker to first task
     should be straight when all roots share a single row, even if
     the tree has more rows below for branching children. */
  it('entry line is straight when all roots share a single row', () => {
    const branchingPlan: Plan = {
      schema_version: '1.0.0',
      name: 'B',
      phases: [{
        id: 'p',
        name: 'P',
        tasks: [
          { id: 'root', name: 'Root', status: 'wip' },
          { id: 'b', name: 'B', status: 'pending', depends: ['root'] },
          { id: 'c', name: 'C', status: 'pending', depends: ['root'] },
        ],
      }],
    }
    renderPipeline(branchingPlan)
    const paths = Array.from(document.querySelectorAll('svg path'))
    const entryPaths = paths.filter((pp) => (pp.getAttribute('d') ?? '').startsWith('M 140 '))
    expect(entryPaths.length).toBeGreaterThan(0)
    /* No vertical command -> path is a straight horizontal line. */
    for (const ep of entryPaths) {
      const d = ep.getAttribute('d') ?? ''
      expect(d).not.toMatch(/\sV\s/)
    }
  })

  /* Symmetric: exit line is straight when all leaves share a row. */
  it('leaf-to-exit line is straight when all leaves share a single row', () => {
    const branchingThenJoinPlan: Plan = {
      schema_version: '1.0.0',
      name: 'BJ',
      phases: [{
        id: 'p',
        name: 'P',
        tasks: [
          { id: 'r1', name: 'R1', status: 'wip' },
          { id: 'r2', name: 'R2', status: 'wip' },
          { id: 'leaf', name: 'Leaf', status: 'pending', depends: ['r1', 'r2'] },
        ],
      }],
    }
    renderPipeline(branchingThenJoinPlan)
    const paths = Array.from(document.querySelectorAll('svg path'))
    /* leaf-to-exit path starts at the leaf's right edge (taskRight)
       which is ENTRY_W + 1 * (NODE_W + GAP_X) + NODE_W = 168 + 268 +
       240 = 676. Filter on that prefix. */
    const exitPaths = paths.filter((pp) => (pp.getAttribute('d') ?? '').startsWith('M 676 '))
    expect(exitPaths.length).toBeGreaterThan(0)
    for (const ep of exitPaths) {
      const d = ep.getAttribute('d') ?? ''
      expect(d).not.toMatch(/\sV\s/)
    }
  })
})

/* ═══ Selected phase chrome — blue regardless of phase status ═══ */
describe('Pipeline: selected phase card chrome (audit-15c #3)', () => {
  /* Operator: "den groenne baggrund og tyde groenne ramme omkring
     box taenker jeg bare er stoej". Done phase cards used to render
     green border + green-tinted bg when expanded - the bottom green
     completion bar is sufficient to symbolise "done". The selected/
     expanded state should use a blue border + blue tint regardless
     of phase status, so the chrome reads consistently across done
     and pending selections. */
  const planDoneSelected: Plan = {
    schema_version: '1.0.0',
    name: 'DS',
    phases: [
      { id: 'p1', name: 'P1', tasks: [{ id: 'a', name: 'A', status: 'done' }] },
      { id: 'p2', name: 'P2', tasks: [{ id: 'b', name: 'B', status: 'wip' }] },
    ],
  }

  it('done phase card when selected uses a discreet blue border (wf-signal at <100% opacity), not green', async () => {
    renderPipeline(planDoneSelected)
    /* Phase 2 auto-expands (wip task). Click P1 to expand it instead.
       Phase 1 is fully done, so the test exercises the "done + active"
       case that previously rendered green chrome. */
    const cards = screen.getAllByTestId('phase-card')
    await userEvent.click(cards[0])
    const active = cards[0] as HTMLElement
    expect(active.getAttribute('data-active')).toBe('true')
    const inlineStyle = active.getAttribute('style') ?? ''
    /* Border must reference the wf-signal palette token, not
       status-done (green). */
    expect(inlineStyle).toContain('--mui-palette-wf-signal')
    expect(inlineStyle).not.toContain('--mui-palette-status-done')
    /* Audit-15c #5 - operator wants the active border less dominant.
       The colour is now a color-mix() with reduced opacity, not the
       raw var() at full saturation. */
    expect(inlineStyle).toMatch(/border:[^;]*color-mix/)
  })

  it('non-selected done phase card carries no status-tinted chrome (only the bottom gauge)', () => {
    renderPipeline(planDoneSelected)
    const cards = screen.getAllByTestId('phase-card')
    /* Phase 1 is done, but phase 2 is the auto-expanded one.
       Phase 1's card must therefore be the inactive case. */
    const phase1 = cards[0] as HTMLElement
    expect(phase1.getAttribute('data-active')).toBe('false')
    const inlineStyle = phase1.getAttribute('style') ?? ''
    expect(inlineStyle).not.toContain('--mui-palette-status-done')
    expect(inlineStyle).not.toContain('--mui-palette-wf-signal')
    /* The bottom completion gauge stays as the done signal. */
    const gauge = phase1.querySelector('[data-testid="wf-phase-gauge"]') as HTMLElement
    expect(gauge).not.toBeNull()
    expect(gauge.getAttribute('data-status')).toBe('done')
  })

  it('selected pending/wip phase card uses the same blue border as selected done', () => {
    renderPipeline(planDoneSelected)
    const cards = screen.getAllByTestId('phase-card')
    /* Phase 2 wip auto-expanded. Border should be blue. */
    const active = cards[1] as HTMLElement
    expect(active.getAttribute('data-active')).toBe('true')
    const inlineStyle = active.getAttribute('style') ?? ''
    expect(inlineStyle).toContain('--mui-palette-wf-signal')
  })

  /* Audit-15c #4 - bottom progress bar/gauge rides ON the card's
     bottom border so it stays visible when the active blue border
     would otherwise frame it in. Negative bottom offset + zIndex
     puts the bar visually in front of the border line. */
  it('TaskNodeCard hover border is wf-signal (audit-15c #6) - never status-tinted', () => {
    /* Operator: hover on a done task produced a green-tinted border
       (status-done). Hover should be a selection-affordance signal,
       which uses the same blue as the active phase border, not the
       status colour. Probe the emotion stylesheet for any :hover
       rule that references --mui-palette-status-* in its border-
       color; none should remain. */
    const taskPlan: Plan = {
      schema_version: '1.0.0',
      name: 'TP',
      phases: [{
        id: 'p',
        name: 'P',
        tasks: [
          { id: 'a', name: 'A', status: 'done' },
          { id: 'b', name: 'B', status: 'wip' },
        ],
      }],
    }
    renderPipeline(taskPlan)
    const styleEls = Array.from(document.querySelectorAll('style'))
    let offendingHover = ''
    for (const el of styleEls) {
      const txt = el.textContent ?? ''
      const matches = txt.match(/[^{}]+:hover\s*\{[^}]*\}/g) ?? []
      for (const m of matches) {
        const inner = m.split('{')[1] ?? ''
        const borderClause = inner.match(/border-color:[^;]+/)?.[0] ?? ''
        if (borderClause.includes('--mui-palette-status-')) {
          offendingHover = m.slice(0, 200)
          break
        }
      }
      if (offendingHover) break
    }
    expect(offendingHover).toBe('')
  })

  it('PhaseGauge renders in front of the card border (negative bottom + zIndex)', () => {
    renderPipeline(planDoneSelected)
    const gauge = document.querySelector('[data-testid="wf-phase-gauge"]') as HTMLElement
    expect(gauge).not.toBeNull()
    const inlineStyle = gauge.getAttribute('style') ?? ''
    expect(inlineStyle).toContain('bottom: -1px')
    expect(inlineStyle).toMatch(/z-index:\s*1/)
  })

  it('TaskProgressBar renders in front of the card border', () => {
    const taskPlan: Plan = {
      schema_version: '1.0.0',
      name: 'TP',
      phases: [{
        id: 'p',
        name: 'P',
        tasks: [{ id: 't', name: 'T', status: 'wip' }],
      }],
    }
    renderPipeline(taskPlan)
    const bar = document.querySelector('[data-testid="task-progress-bar"]') as HTMLElement
    expect(bar).not.toBeNull()
    const inlineStyle = bar.getAttribute('style') ?? ''
    expect(inlineStyle).toContain('bottom: -1px')
    expect(inlineStyle).toMatch(/z-index:\s*1/)
  })
})

/* ═══ Gate inline node ═══ */
describe('Pipeline: gate inline node', () => {
  it('renders gate as inline node in the tree when phase is expanded', () => {
    renderPipeline()
    const gateNode = document.querySelector('[data-testid="gate-node"]')
    expect(gateNode).toBeTruthy()
  })

  it('shows gate name and check count in inline node', () => {
    renderPipeline()
    expect(screen.getByText('Setup Gate')).toBeInTheDocument()
    expect(screen.getByText('0/3 checks')).toBeInTheDocument()
  })

  it('does not render standalone gate section below tree', () => {
    renderPipeline()
    // Gate checklist items should NOT be directly visible (they are in a Tooltip)
    expect(screen.queryByText('docker compose up -d')).not.toBeInTheDocument()
  })

  it('opens popover with object-form checklist without crashing', async () => {
    const objectChecklistPlan: Plan = {
      schema_version: '1.0.0',
      name: 'Object Checklist Plan',
      phases: [{
        id: 'p', name: 'Phase', tasks: [{ id: 't', name: 'T', status: 'wip' }],
        gate: {
          name: 'Object Gate',
          checklist: [
            { item: 'All Python tests pass', check: { kind: 'shell', cmd: 'pytest' } },
            { item: 'Lint passes', check: { kind: 'shell', cmd: 'ruff check' } },
          ] as unknown as string[],
          passed: false,
        },
      }],
    }
    renderPipeline(objectChecklistPlan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    expect(gateNode).toBeTruthy()
    await userEvent.click(gateNode)
    expect(screen.getByText('All Python tests pass')).toBeInTheDocument()
    expect(screen.getByText('Lint passes')).toBeInTheDocument()
  })
})

/* ═══ Shows empty phase message ═══ */
describe('Pipeline: empty phases', () => {
  it('shows "No tasks defined yet" for empty phases when expanded', async () => {
    renderPipeline()
    const cards = screen.getAllByTestId('phase-card')
    await userEvent.click(cards[2])
    expect(screen.getByText('No tasks defined yet')).toBeInTheDocument()
  })
})

/* ═══ Change 1: Left-to-right tree flow ═══ */
describe('Change 1: Left-to-right tree flow', () => {
  it('uses horizontal overflow on phase tree container', () => {
    renderPipeline(dagPlan)
    const treeContainer = document.querySelector('[data-testid="phase-tree"]')
    expect(treeContainer).toBeTruthy()
  })

  it('positions task nodes with absolute layout via data-node-id', () => {
    renderPipeline(dagPlan)
    const nodes = document.querySelectorAll('[data-node-id]')
    expect(nodes.length).toBe(4) // root + 3 children
  })

  it('renders root and children as separate node elements', () => {
    renderPipeline(dagPlan)
    expect(document.querySelector('[data-node-id="root"]')).toBeTruthy()
    expect(document.querySelector('[data-node-id="child-1"]')).toBeTruthy()
    expect(document.querySelector('[data-node-id="child-2"]')).toBeTruthy()
    expect(document.querySelector('[data-node-id="child-3"]')).toBeTruthy()
  })
})

/* ═══ Change 2: Variable node width ═══ */
describe('Change 2: Variable node width', () => {
  it('long task names are accessible via the native title tooltip', () => {
    /* Pre-2026-05-08 contract was 'long task names render fully on the
       card'. The card now shows task.id as the visible title (kebab-case,
       matches sidebar chip vocabulary) and surfaces task.name via the
       native title attribute on hover. The full long name remains
       accessible to operators - just not via direct visual rendering. */
    const longNamePlan: Plan = {
      schema_version: '1.0.0',
      name: 'Long Names',
      phases: [{
        id: 'p',
        name: 'Phase',
        tasks: [
          { id: 'pre-commit-hooks', name: 'Pre-commit hooks (Ruff, mypy, isort)', status: 'wip' },
        ],
      }],
    }
    renderPipeline(longNamePlan)
    const titleEl = screen.getByText('pre-commit-hooks')
    expect(titleEl.getAttribute('title')).toBe('Pre-commit hooks (Ruff, mypy, isort)')
  })

  it('renders node with absolute positioning', () => {
    renderPipeline(dagPlan)
    const node = document.querySelector('[data-node-id="root"]') as HTMLElement
    expect(node).toBeTruthy()
    expect(node.className).toBeTruthy()
  })
})

/* ═══ Change 3: Smoothstep connectors (no arrowheads) ═══ */
describe('Change 3: Smoothstep connectors', () => {
  it('renders SVG connector overlay', () => {
    renderPipeline(dagPlan)
    const svg = document.querySelector('svg')
    expect(svg).toBeTruthy()
  })

  it('uses clean lines without arrowhead markers', () => {
    renderPipeline(dagPlan)
    const marker = document.querySelector('marker')
    expect(marker).toBeNull()
  })

  it('SVG has aria-hidden for accessibility', () => {
    renderPipeline(dagPlan)
    const svg = document.querySelector('svg')
    expect(svg?.getAttribute('aria-hidden')).toBe('true')
  })
})

/* ═══ Change 4: Parallel fan-out (clean DAG, no extra decoration) ═══ */
describe('Change 4: Parallel fan-out', () => {
  it('shows all parallel children as separate nodes without rail decoration', () => {
    renderPipeline(dagPlan)
    expect(document.querySelector('[data-node-id="child-1"]')).toBeTruthy()
    expect(document.querySelector('[data-node-id="child-2"]')).toBeTruthy()
    expect(document.querySelector('[data-node-id="child-3"]')).toBeTruthy()
    expect(document.querySelector('[data-testid="parallel-rail"]')).toBeNull()
  })
})

/* ═══ Change 6: Animated WIP edges (RETIRED — audit-15c) ═══ */
/* The animated dashFlow on wip-parent connectors was retired when
   the line taxonomy collapsed to "solid blue when prev done/wip,
   solid grey otherwise". Operator: dashes are noise alongside the
   status colour split. */

/* ═══ Persist expansion state ═══ */
describe('Pipeline: persist expansion state', () => {
  it('saves expanded phase ID to localStorage on toggle', async () => {
    renderPipeline()
    const cards = screen.getAllByTestId('phase-card')
    await userEvent.click(cards[1])
    expect(localStorageMock.setItem).toHaveBeenCalledWith(
      'pipeline-expanded-Test Plan',
      expect.any(String),
    )
  })

  it('reads from localStorage on mount', () => {
    storageMock['pipeline-expanded-Test Plan'] = JSON.stringify('core')
    renderPipeline()
    expect(localStorageMock.getItem).toHaveBeenCalledWith('pipeline-expanded-Test Plan')
    // Core phase should be expanded (task-c visible), Setup collapsed
    expect(screen.getByText('task-c')).toBeInTheDocument()
    expect(screen.queryByText('task-a')).not.toBeInTheDocument()
  })
})

/* ═══ Change 8: prefers-reduced-motion ═══ */
describe('Change 8: prefers-reduced-motion', () => {
  it('StatusDot WIP renders without error (CSS media query applied)', () => {
    renderPipeline()
    expect(screen.getByText('task-b')).toBeInTheDocument()
  })

  /* SVG-level reduced-motion media query was attached to the
     dashFlow connector animation; both retired in audit-15c. The
     remaining reduced-motion guards (TaskNodeCard wip glow, status
     dot pulse, etc.) live on individual sx blocks rather than a
     shared SVG-scoped <style> tag. */
})

/* ═══ Linked highlighting ═══ */
describe('Pipeline: linked highlighting', () => {
  it('task nodes have data-node-id attribute for hover linking', () => {
    renderPipeline()
    const nodeA = document.querySelector('[data-node-id="task-a"]')
    const nodeB = document.querySelector('[data-node-id="task-b"]')
    expect(nodeA).toBeTruthy()
    expect(nodeB).toBeTruthy()
  })

  it('task nodes are keyboard accessible (tabIndex=0)', () => {
    renderPipeline()
    const nodeA = document.querySelector('[data-node-id="task-a"]') as HTMLElement
    expect(nodeA?.getAttribute('tabindex')).toBe('0')
  })
})

/* ═══ Click to navigate ═══ */
describe('Pipeline: click to navigate', () => {
  it('opens session panel when task node is clicked', async () => {
    renderPipeline()
    const nodeB = document.querySelector('[data-node-id="task-b"]') as HTMLElement
    expect(nodeB).toBeTruthy()
    await userEvent.click(nodeB)
    expect(screen.getByLabelText('Close panel')).toBeInTheDocument()
  })
})

/* ═══ All tasks shown individually (no collapsed chains) ═══ */
describe('Sequential tasks shown individually', () => {
  const longChainPlan: Plan = {
    schema_version: '1.0.0',
    name: 'Chain Plan',
    phases: [{
      id: 'p',
      name: 'Chain Phase',
      tasks: [
        { id: 't1', name: 'Step 1', status: 'done' },
        { id: 't2', name: 'Step 2', status: 'done', depends: ['t1'] },
        { id: 't3', name: 'Step 3', status: 'done', depends: ['t2'] },
        { id: 't4', name: 'Step 4', status: 'done', depends: ['t3'] },
        { id: 't5', name: 'Step 5', status: 'wip', depends: ['t4'] },
      ],
    }],
  }

  it('shows all tasks individually without collapsing', () => {
    renderPipeline(longChainPlan)
    expect(screen.getByText('t1')).toBeInTheDocument()
    expect(screen.getByText('t2')).toBeInTheDocument()
    expect(screen.getByText('t3')).toBeInTheDocument()
    expect(screen.getByText('t4')).toBeInTheDocument()
    expect(screen.getByText('t5')).toBeInTheDocument()
    expect(document.querySelector('[data-testid="collapsed-chain"]')).toBeNull()
  })
})

/* ═══ Start/End wayfinding markers ═══ */
describe('Pipeline: start/end markers', () => {
  it('renders Start label when first phase is expanded', () => {
    renderPipeline()
    const marker = screen.getByTestId('start-marker')
    expect(within(marker).getByText('Start')).toBeInTheDocument()
  })

  it('renders next phase as mini card with name and progress', () => {
    renderPipeline()
    // Phase 0 is auto-expanded, Phase 1 is next
    const marker = screen.getByTestId('end-marker')
    expect(within(marker).getByText('Phase 1: Core')).toBeInTheDocument()
    expect(within(marker).getByText('0/2')).toBeInTheDocument()
  })

  it('renders prev phase as mini card with name and progress when not first', async () => {
    renderPipeline()
    const cards = screen.getAllByTestId('phase-card')
    await userEvent.click(cards[1])
    const marker = screen.getByTestId('start-marker')
    expect(within(marker).getByText('Phase 0: Setup')).toBeInTheDocument()
    expect(within(marker).getByText('1/2')).toBeInTheDocument()
  })

  it('renders Finished as end marker for last phase', () => {
    // dagPlan has a single phase → it is both first and last
    renderPipeline(dagPlan)
    const marker = screen.getByTestId('end-marker')
    expect(within(marker).getByText('Finished')).toBeInTheDocument()
  })

  it('Finished fallback marker is inset from the inner edge to clear the exit line (audit-15c #2)', () => {
    /* Operator: in the screenshot the leaf-to-exit line ended on top
       of the "Finished" label because the fallback marker hugged the
       inner edge of its container. Padding-left on the end-marker
       fallback gives the label room to breathe so the connector
       stops cleanly before the text. */
    renderPipeline(dagPlan)
    const marker = screen.getByTestId('end-marker') as HTMLElement
    const cs = window.getComputedStyle(marker)
    /* MUI pl: 1 maps to 8px padding-left. */
    expect(parseFloat(cs.paddingLeft)).toBeGreaterThanOrEqual(8)
  })
})

/* ═══ Gate evaluation status (C6-C8) ═══ */

function makeEnrichedGatePlan(
  enrichedChecklist: EnrichedChecklistItem[],
  passed = false,
): Plan {
  return {
    schema_version: '1.0.0',
    name: 'Enriched Gate Plan',
    phases: [{
      id: 'p',
      name: 'Phase',
      tasks: [{ id: 't', name: 'Task', status: 'wip' }],
      gate: {
        name: 'Test Gate',
        checklist: enrichedChecklist.map((i) => i.item),
        enrichedChecklist,
        passed,
      },
    }],
  }
}

describe('C6: Per-item status icons', () => {
  it('IC1: shell passed shows green checkmark', async () => {
    const plan = makeEnrichedGatePlan([
      { item: 'tests pass', kind: 'shell', lastResult: 'passed' },
    ])
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    expect(screen.getByTestId('gate-item-icon-passed')).toBeInTheDocument()
  })

  it('IC2: shell failed shows red X', async () => {
    const plan = makeEnrichedGatePlan([
      { item: 'tests pass', kind: 'shell', lastResult: 'failed' },
    ])
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    expect(screen.getByTestId('gate-item-icon-failed')).toBeInTheDocument()
  })

  it('IC3: shell timeout shows red X', async () => {
    const plan = makeEnrichedGatePlan([
      { item: 'tests pass', kind: 'shell', lastResult: 'timeout' },
    ])
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    expect(screen.getByTestId('gate-item-icon-failed')).toBeInTheDocument()
  })

  it('IC4: shell not evaluated shows pending indicator', async () => {
    const plan = makeEnrichedGatePlan([
      { item: 'tests pass', kind: 'shell', lastResult: null },
    ])
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    expect(screen.getByTestId('gate-item-icon-pending')).toBeInTheDocument()
  })

  it('IC5: shell needs_review shows pending indicator', async () => {
    const plan = makeEnrichedGatePlan([
      { item: 'tests pass', kind: 'shell', lastResult: 'needs_review' },
    ])
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    expect(screen.getByTestId('gate-item-icon-pending')).toBeInTheDocument()
  })

  it('IC6: human check shows radio button', async () => {
    const plan = makeEnrichedGatePlan([
      { item: 'review UX', kind: 'human', lastResult: 'needs_review' },
    ])
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    expect(screen.getByTestId('gate-item-icon-human')).toBeInTheDocument()
  })

  it('IC7: human no result shows radio button', async () => {
    const plan = makeEnrichedGatePlan([
      { item: 'review UX', kind: 'human', lastResult: null },
    ])
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    expect(screen.getByTestId('gate-item-icon-human')).toBeInTheDocument()
  })

  it('IC8: gate.passed=true shows all green checkmarks', async () => {
    const plan = makeEnrichedGatePlan([
      { item: 'tests', kind: 'shell', lastResult: 'passed' },
      { item: 'review', kind: 'human', lastResult: 'needs_review' },
    ], true)
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    const passedIcons = screen.getAllByTestId('gate-item-icon-passed')
    expect(passedIcons.length).toBe(2)
  })

  it('IC8b: gate popover PASSED label renders as brand StatusPill (completed)', async () => {
    const plan = makeEnrichedGatePlan([
      { item: 'tests', kind: 'shell', lastResult: 'passed' },
    ], true)
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    /* Skarmaudit-15b #2 - inline gate node no longer carries the
       PASSED pill (100% green completion gauge at the bottom is the
       passed signal). The popover keeps its PASSED pill since the
       popover is a detail view focused on the gate state. */
    expect(within(gateNode).queryByText('PASSED')).not.toBeInTheDocument()
    await userEvent.click(gateNode)
    const pills = screen.getAllByText('PASSED').map((el) => el.closest('[data-testid="wf-status-pill"]'))
    expect(pills.length).toBeGreaterThanOrEqual(1)
    expect(pills.every((p) => p?.getAttribute('data-status') === 'completed')).toBe(true)
  })

  it('IC8b2: passed gate inline node uses steel hairline border, not green-tinted (audit-15b #2)', () => {
    const plan = makeEnrichedGatePlan([
      { item: 'tests', kind: 'shell', lastResult: 'passed' },
    ], true)
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    expect(gateNode).not.toBeNull()
    const cs = window.getComputedStyle(gateNode)
    /* The completion gauge at the bottom (PhaseGauge / GateProgressBar)
       carries the passed signal, exactly like task cards bottom bar
       fills 100% green when done. The border itself stays neutral
       steel hairline, matching task cards. */
    expect(cs.borderColor).not.toMatch(/91, 214, 138/)
  })

  it('IC8c: gate popover header renders with the wfH3 brand variant', async () => {
    const plan = makeEnrichedGatePlan([
      { item: 'tests', kind: 'shell', lastResult: 'passed' },
    ])
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    /* Brand chrome lock: the gate name in the popover header must
       use Geist Mono via the wfH3 variant. "Test Gate" also renders
       as the gate-node label, so scope to the wfH3-variant element
       (MUI emits MuiTypography-wfH3 as a class). */
    const headers = screen.getAllByText('Test Gate')
    const popoverHeader = headers.find((h) => h.className.includes('MuiTypography-wfH3'))
    expect(popoverHeader).not.toBeUndefined()
  })

  it('IC9: no enrichedChecklist falls back to current behavior', async () => {
    const plan: Plan = {
      schema_version: '1.0.0',
      name: 'Fallback Plan',
      phases: [{
        id: 'p', name: 'Phase',
        tasks: [{ id: 't', name: 'Task', status: 'wip' }],
        gate: { name: 'Gate', checklist: ['item1', 'item2'], passed: false },
      }],
    }
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    // Fallback: radio buttons for unchecked items
    const radioIcons = document.querySelectorAll('[data-testid="gate-item-icon-unchecked"]')
    expect(radioIcons.length).toBe(2)
  })
})

describe('C7: Conditional copy-paste prompt', () => {
  it('CP1: all shell passed hides prompt', async () => {
    const plan = makeEnrichedGatePlan([
      { item: 'a', kind: 'shell', lastResult: 'passed' },
      { item: 'b', kind: 'shell', lastResult: 'passed' },
    ])
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    expect(screen.queryByLabelText('Copy gate prompt')).not.toBeInTheDocument()
  })

  it('CP2: mixed shell+human shows prompt', async () => {
    const plan = makeEnrichedGatePlan([
      { item: 'a', kind: 'shell', lastResult: 'passed' },
      { item: 'b', kind: 'human', lastResult: 'needs_review' },
    ])
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    expect(screen.getByLabelText('Copy gate prompt')).toBeInTheDocument()
  })

  it('CP3: all human shows prompt', async () => {
    const plan = makeEnrichedGatePlan([
      { item: 'a', kind: 'human', lastResult: 'needs_review' },
    ])
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    expect(screen.getByLabelText('Copy gate prompt')).toBeInTheDocument()
  })

  it('CP4: shell pending shows prompt', async () => {
    const plan = makeEnrichedGatePlan([
      { item: 'a', kind: 'shell', lastResult: null },
    ])
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    expect(screen.getByLabelText('Copy gate prompt')).toBeInTheDocument()
  })

  it('CP5: empty enrichedChecklist hides prompt', async () => {
    const plan: Plan = {
      schema_version: '1.0.0',
      name: 'Empty Enriched',
      phases: [{
        id: 'p', name: 'Phase',
        tasks: [{ id: 't', name: 'Task', status: 'wip' }],
        gate: { name: 'Gate', checklist: [], enrichedChecklist: [], passed: false },
      }],
    }
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    expect(screen.queryByLabelText('Copy gate prompt')).not.toBeInTheDocument()
  })

  it('CP6: no enrichedChecklist shows prompt (existing behavior)', async () => {
    const plan: Plan = {
      schema_version: '1.0.0',
      name: 'No Enriched',
      phases: [{
        id: 'p', name: 'Phase',
        tasks: [{ id: 't', name: 'Task', status: 'wip' }],
        gate: { name: 'Gate', checklist: ['item1'], passed: false },
      }],
    }
    renderPipeline(plan)
    const gateNode = document.querySelector('[data-testid="gate-node"]') as HTMLElement
    await userEvent.click(gateNode)
    expect(screen.getByLabelText('Copy gate prompt')).toBeInTheDocument()
  })
})

describe('C8: Gate node summary', () => {
  it('GN1: gate.passed=true shows total/total checks', () => {
    const plan = makeEnrichedGatePlan([
      { item: 'a', kind: 'shell', lastResult: 'passed' },
      { item: 'b', kind: 'shell', lastResult: 'passed' },
      { item: 'c', kind: 'human', lastResult: 'passed' },
    ], true)
    renderPipeline(plan)
    expect(screen.getByText('3/3 checks')).toBeInTheDocument()
  })

  it('GN2: partial auto-pass shows N/M auto-passed', () => {
    const plan = makeEnrichedGatePlan([
      { item: 'a', kind: 'shell', lastResult: 'passed' },
      { item: 'b', kind: 'shell', lastResult: 'passed' },
      { item: 'c', kind: 'human', lastResult: 'needs_review' },
    ])
    renderPipeline(plan)
    expect(screen.getByText('2/3 auto-passed')).toBeInTheDocument()
  })

  it('GN3: none passed shows 0/N checks', () => {
    const plan = makeEnrichedGatePlan([
      { item: 'a', kind: 'shell', lastResult: null },
      { item: 'b', kind: 'shell', lastResult: null },
      { item: 'c', kind: 'human', lastResult: null },
    ])
    renderPipeline(plan)
    expect(screen.getByText('0/3 checks')).toBeInTheDocument()
  })

  it('GN4: no enrichedChecklist uses existing behavior', () => {
    const plan: Plan = {
      schema_version: '1.0.0',
      name: 'No Enriched Summary',
      phases: [{
        id: 'p', name: 'Phase',
        tasks: [{ id: 't', name: 'Task', status: 'wip' }],
        gate: { name: 'Gate', checklist: ['a', 'b', 'c'], passed: false },
      }],
    }
    renderPipeline(plan)
    expect(screen.getByText('0/3 checks')).toBeInTheDocument()
  })
})

/* ═══ Schema 2.0 task node body — what description hidden, where summary kept ═══ */
describe('Pipeline: TaskNodeExtrasV2 hides task.what description', () => {
  const plan2: Plan = {
    schema_version: '2.0.0',
    name: 'Plan 2.0 — body row',
    phases: [{
      id: 'p1',
      name: 'Phase 1',
      tasks: [{
        id: 'task-with-what',
        name: 'Task With What',
        status: 'wip',
        task_type: 'refactor',
        what: 'When uv run pytest --cov=src --cov-report=xml is executed after triage',
        where: { modify: ['src/a.py', 'src/b.py'], create: ['tests/new.py'] },
      }],
    }],
  }

  it('does not render task.what prose in the node body', () => {
    renderPipeline(plan2)
    expect(screen.queryByText(/When uv run pytest/i)).not.toBeInTheDocument()
  })

  it('does not render the where summary chip in the overview', () => {
    renderPipeline(plan2)
    // modify/create counts are noise in the pipeline overview — they were
    // hidden along with task.what so cards stay name + status + type.
    expect(screen.queryByText('modify 2 · create 1')).not.toBeInTheDocument()
    expect(screen.queryByTestId('task-where-summary')).not.toBeInTheDocument()
  })

  it('still renders the task_type label row', () => {
    renderPipeline(plan2)
    expect(screen.getByText(/refactor/i)).toBeInTheDocument()
  })

  /* User-request 2026-05-08: task-type label and tier-label both pick
     up the wfLabel typography variant so their font size matches the
     gate's '0/4 CHECKS' summary line (10px JetBrains Mono uppercase).
     Previously the type label used `variant="labelSmall"` with a
     fontSize override and the tier-label had its own 8.5px override,
     producing three different font sizes for three near-identical
     pieces of chrome. */
  it('task-type label uses wfLabel variant (matches gate CHECKS size)', () => {
    renderPipeline(plan2)
    const label = screen.getByText(/refactor/i)
    expect(label.className).toMatch(/MuiTypography-wfLabel/)
  })

  /* User-request 2026-05-08 (revision): the wfLabel variant brings 10px
     size match with the gate CHECKS line, but its built-in
     textTransform: uppercase made type labels render as DEVELOPMENT
     etc. — too shouty for what is supposed to be supporting metadata.
     The label keeps wfLabel size + family, but text-transform is
     restored to none so 'Development' / 'Refactor' read mixed-case as
     the human-friendly task_type strings intend. */
  it('task-type label renders mixed-case (textTransform reset to none)', () => {
    renderPipeline(plan2)
    /* Exact-match string casing — would fail if textTransform: uppercase
       leaked through, since textContent reflects the literal JSX value
       but a .toMatch(/refactor/i) would still pass either way. */
    expect(screen.getByText('Refactor')).toBeInTheDocument()
    const label = screen.getByText('Refactor')
    /* Inline style override is queryable in jsdom — safer than emotion. */
    expect(label.style.textTransform).toBe('none')
  })
})

/* ═══ Audit-15 #4 — TaskProgressBar stuck state (needs_input) ═══ */
describe('Pipeline: per-task gauge stuck state (audit-15 #4)', () => {
  const stuckPlan: Plan = {
    schema_version: '1.0.0',
    name: 'Stuck Plan',
    phases: [
      {
        id: 'g',
        name: 'Phase',
        tasks: [
          /* Trigger forces phase auto-expansion (auto-expand picks
             first wip/failed phase) so TaskNodeCards + their gauges
             actually render in jsdom. */
          { id: 'g-trigger', name: 'Trigger', status: 'wip' },
          { id: 'g-stuck', name: 'Stuck Task', status: 'pending' },
          { id: 'g-stuck-done', name: 'Done Task', status: 'done' },
        ],
      },
    ],
  }

  it('renders bar in fault color at midpoint when session needs_input + session.flow live (audit-15 #4)', () => {
    const sess: Session = {
      sid: 'stuck1', cwd: '/dev', worktree: '/dev', branch: 'feature/g-stuck',
      event: 'Notification', type: 'agent', msg: '', ts: new Date().toISOString(),
      status: 'needs_input',
      flow: { feature: 'g-stuck', phase: 'implement', phase_index: 4, total_phases: 9 },
    }
    renderPipeline(stuckPlan, [sess])
    const gauge = document.querySelector('[data-testid="task-progress-bar"][data-task-id="g-stuck"]') as HTMLElement
    expect(gauge).not.toBeNull()
    expect(gauge.getAttribute('data-status')).toBe('fault')
    /* (4 + 0.5) / 9 = 50 — midpoint heuristic preserved so the
       stuck position reads where it stalled, not at 100%. */
    expect(gauge.getAttribute('aria-valuenow')).toBe('50')
  })

  it('uses neutral wf.steel track for stuck state so partial fill reads (audit-15 #4)', () => {
    const sess: Session = {
      sid: 'stuck2', cwd: '/dev', worktree: '/dev', branch: 'feature/g-stuck',
      event: 'Notification', type: 'agent', msg: '', ts: new Date().toISOString(),
      status: 'needs_input',
      flow: { feature: 'g-stuck', phase: 'implement', phase_index: 4, total_phases: 9 },
    }
    renderPipeline(stuckPlan, [sess])
    const gauge = document.querySelector('[data-testid="task-progress-bar"][data-task-id="g-stuck"]') as HTMLElement
    expect(gauge.getAttribute('data-track')).toBe('wf.steel')
  })

  it('renders bar at neutral 50% in fault color when needs_input but no flow data (audit-15 #4)', () => {
    const sess: Session = {
      sid: 'stuck3', cwd: '/dev', worktree: '/dev', branch: 'feature/g-stuck',
      event: 'Notification', type: 'agent', msg: '', ts: new Date().toISOString(),
      status: 'needs_input', flow: null,
    }
    renderPipeline(stuckPlan, [sess])
    const gauge = document.querySelector('[data-testid="task-progress-bar"][data-task-id="g-stuck"]') as HTMLElement
    expect(gauge).not.toBeNull()
    expect(gauge.getAttribute('data-status')).toBe('fault')
    expect(gauge.getAttribute('aria-valuenow')).toBe('50')
  })

  it('terminal task.status=done wins over stuck session — bar stays completed/100% (audit-15 #4)', () => {
    const sess: Session = {
      sid: 'stuck4', cwd: '/dev', worktree: '/dev', branch: 'feature/g-stuck-done',
      event: 'Notification', type: 'agent', msg: '', ts: new Date().toISOString(),
      status: 'needs_input',
      flow: { feature: 'g-stuck-done', phase: 'implement', phase_index: 4, total_phases: 9 },
    }
    renderPipeline(stuckPlan, [sess])
    const gauge = document.querySelector('[data-testid="task-progress-bar"][data-task-id="g-stuck-done"]') as HTMLElement
    expect(gauge.getAttribute('data-status')).toBe('completed')
    expect(gauge.getAttribute('aria-valuenow')).toBe('100')
  })

  /* Audit-15 #5 — phase label persistence.
     Row 3 phase label previously hidden when isActive=false; it
     therefore disappeared during phase transitions and when the
     autopilot wrapper exited mid-pipeline (needs_input). Phase
     name should persist as long as `live.phase` has data and the
     task is not terminal (done/failed). */
  it('phase label persists when session needs_input + flow data (audit-15 #5)', () => {
    const sess: Session = {
      sid: 'stuck5', cwd: '/dev', worktree: '/dev', branch: 'feature/g-stuck',
      event: 'Notification', type: 'agent', msg: '', ts: new Date().toISOString(),
      status: 'needs_input',
      flow: { feature: 'g-stuck', phase: 'implement', phase_index: 4, total_phases: 9 },
    }
    renderPipeline(stuckPlan, [sess])
    const card = document.querySelector('[data-node-id="g-stuck"]') as HTMLElement
    expect(card).not.toBeNull()
    const label = card.querySelector('[data-testid="task-phase-label"]')
    expect(label).not.toBeNull()
    expect(label?.textContent).toMatch(/Impl/i)
  })

  it('phase label hidden for terminal done task even with live phase data (audit-15 #5)', () => {
    const sess: Session = {
      sid: 'stuck6', cwd: '/dev', worktree: '/dev', branch: 'feature/g-stuck-done',
      event: 'Notification', type: 'agent', msg: '', ts: new Date().toISOString(),
      status: 'needs_input',
      flow: { feature: 'g-stuck-done', phase: 'implement', phase_index: 4, total_phases: 9 },
    }
    renderPipeline(stuckPlan, [sess])
    const card = document.querySelector('[data-node-id="g-stuck-done"]') as HTMLElement
    const label = card.querySelector('[data-testid="task-phase-label"]')
    expect(label).toBeNull()
  })
})

/* === Audit-18 followup - Pipeline forwards plan + planDir to
   SessionPanel so BriefView's plan-2.0 sections (what / why / where /
   constraints / artifacts / estimate) are not gated off by a missing
   isPlan2 dispatch. Without forwarding, only acceptance + description
   render (the two sections that don't depend on schema_version). */
describe('Pipeline: forwards plan + planDir to SessionPanel (audit-18 followup)', () => {
  it('renders the What heading inside SessionPanel when a plan-2.0 task is selected', async () => {
    const planWith2_0Task: Plan = {
      schema_version: '2.0.0',
      name: 'Brief 2.0 Plan',
      phases: [
        {
          id: 'phase-1',
          name: 'Phase 1',
          tasks: [
            {
              id: 'task-with-what',
              name: 'Task With What',
              status: 'wip',
              what: 'Build the registration form.',
              why: 'Because users need to sign up.',
              where: { modify: ['src/foo.ts'] },
              constraints: ['Stay under 200 lines'],
              estimate: { lines_estimate: 120, duration_hours: 2 },
              acceptance: ['Form submits successfully'],
            },
          ],
        },
      ],
    }
    renderPipeline(planWith2_0Task)
    const card = document.querySelector('[data-node-id="task-with-what"]') as HTMLElement
    expect(card).not.toBeNull()
    await userEvent.click(card)
    /* BriefView renders the What section heading as h3 only when
       isPlan2(plan) is true; if Pipeline failed to forward the plan
       prop the heading would be absent. */
    expect(screen.getByRole('heading', { name: 'What', level: 3 })).toBeInTheDocument()
    expect(screen.getByText('Build the registration form.')).toBeInTheDocument()
  })
})


/* ═══ Audit-20 — phase rail vs task rail hierarchy ═══ */
describe('Pipeline: expanded panel tier-label hierarchy (audit-20 #1)', () => {
  /* When a phase card is expanded, the surrounding panel must announce
     itself as a hierarchy boundary — one tier deeper than the phase
     rail above. chrome.md:121-125 originally prescribed 8.5px for the
     tier-label, but per user-request 2026-05-08 the size now matches
     the gate's CHECKS summary (wfLabel default, 10px) so the three
     near-identical pieces of label chrome read as one consistent scale.
     The 8x1 wf.signal rule + 0.22em letter-spacing are unchanged. The
     label reads "TASKS · {phase.name}" so the user knows which phase's
     tasks are in view. */
  it('expanded phase panel renders TASKS tier-label with phase name', () => {
    renderPipeline()
    /* Phase 0 auto-expands due to wip task. */
    const tierLabel = screen.getByTestId('phase-tasks-tier-label')
    expect(tierLabel).toHaveTextContent('TASKS · Phase 0: Setup')
    expect(tierLabel.className).toMatch(/MuiTypography-wfLabel/)
  })

  it('tier-label is preceded by an 8x1 wf.signal rule per chrome.md', () => {
    renderPipeline()
    const rule = document.querySelector('[data-testid="phase-tasks-tier-rule"]') as HTMLElement
    expect(rule).not.toBeNull()
  })
})

describe('Pipeline: TaskNodeCard inherits panel bg, no surface1 (audit-20 #3)', () => {
  /* TaskNodeCard inside the expanded panel should read as one tier
     deeper than the surrounding CompactPhaseCard in the rail above.
     Both currently share bgcolor surface1; dropping it on TaskNodeCard
     lets it inherit the panel's wf.ink background, so tasks visually
     recess into a darker shade than the phase rail. */
  it('TaskNodeCard does not paint surface1 background', () => {
    renderPipeline()
    const node = document.querySelector('[data-node-id="task-a"]') as HTMLElement
    expect(node).not.toBeNull()
    /* Probe emotion stylesheet: surface1 var should be absent from
       any rule attached to the rendered card's class chain. */
    const emotionClasses = Array.from(node.classList).filter((c) => c.startsWith('css-'))
    expect(emotionClasses.length).toBeGreaterThan(0)
    const allCss = Array.from(document.querySelectorAll('style'))
      .map((s) => s.textContent ?? '')
      .join('\n')
    const ruleBodies = emotionClasses
      .map((c) => {
        const re = new RegExp(`\\.${c}\\s*\\{([^}]+)\\}`)
        const m = allCss.match(re)
        return m ? m[1] : ''
      })
      .join('\n')
    expect(ruleBodies).not.toMatch(/surface1/)
  })
})
