import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import DeferredAuditView from '../components/plan2/DeferredAuditView'
import type { Plan, DeferredEntry } from '../types'

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

const oneOfEachKind: DeferredEntry[] = [
  {
    id: 'D1',
    kind: 'code_finding',
    finding_id: 'rule:abc12345',
    rule: 'no-bare-except',
    file: 'src/foo.py',
    line: 42,
    state: 'WontFix',
    reason: 'Intentional broad catch in tool runner; documented in design notes.',
    owner: 'alice',
    reviewed_at: '2026-04-25',
    review_trigger: 'manual-review',
  },
  {
    id: 'D2',
    kind: 'review_suggestion',
    date: '2026-04-24',
    feature_or_task_id: 'task-x',
    phase_id: 'phase-1',
    reviewer: 'architect',
    category: 'SOLID',
    description: 'Consider extracting Y',
    reason_deferred: 'Out of scope for this branch — to address in follow-up review pass.',
  },
  {
    id: 'D3',
    kind: 'scope_decision',
    date: '2026-04-23',
    decided_at_task_id: 'task-x',
    decision: 'deferred',
    rationale: 'low-priority',
  },
  {
    id: 'D4',
    kind: 'future_enhancement',
    date: '2026-04-22',
    description: 'Add autoscale knob',
    target_release: 'v2.1',
    effort_estimate: 'm',
  },
]

function makePlan2(deferred: DeferredEntry[] = oneOfEachKind): Plan {
  return {
    schema_version: '2.0.0',
    name: 'Demo',
    vision: 'v',
    users: ['x'],
    success_criteria: [{ id: 'C1', description: 'd' }],
    scope: { in_scope: [], out_of_scope: [] },
    tech_stack: ['x'],
    existing_infrastructure_to_reuse: [],
    test_targets: [{ id: 'self', path: '.' }],
    setup: {
      prerequisites: [], runtime_dependencies: [], services_to_provision: [],
      environment_verification: [], out_of_scope: [],
    },
    kill_criteria: [], design_notes: [], risks: [],
    deferred,
    phases: [{ id: 'p1', name: 'P1', tasks: [] }],
  }
}

describe('DeferredAuditView', () => {
  it('renders 4 kind chips with aria-pressed', () => {
    renderWithTheme(<DeferredAuditView plan={makePlan2()} />)
    const kindLabels = ['Code findings', 'Review suggestions', 'Scope decisions', 'Future enhancements']
    for (const label of kindLabels) {
      const chip = screen.getByRole('button', { name: label })
      expect(chip).toBeInTheDocument()
      expect(chip).toHaveAttribute('aria-pressed')
    }
  })

  it('renders state filter chips for all four STATE_FILTER_VALUES', () => {
    renderWithTheme(<DeferredAuditView plan={makePlan2()} />)
    for (const s of ['WontFix', 'FalsePositive', 'Deferred', 'Accepted']) {
      // Each STATE_FILTER_VALUE always renders as a chip; some also appear
      // in the DataGrid row when matching data exists. Either way, ≥1 instance.
      expect(screen.getAllByText(s).length).toBeGreaterThanOrEqual(1)
    }
  })

  it('1.x plan renders empty state alert', () => {
    const plan1x: Plan = { schema_version: '1.0.0', name: 'old', phases: [] }
    renderWithTheme(<DeferredAuditView plan={plan1x} />)
    expect(screen.getByText(/only available for schema 2\.0/i)).toBeInTheDocument()
  })

  it('2.0 plan with empty deferred renders empty state', () => {
    renderWithTheme(<DeferredAuditView plan={makePlan2([])} />)
    expect(screen.getByText('No deferred entries.')).toBeInTheDocument()
  })

  /* ─── T4 additions: R12 specifics ───────────────────────────────── */

  it('(T4-a) default sort is descending by timestamp — most recent row appears first', () => {
    // code_finding is the default active kind tab
    const entries: DeferredEntry[] = [
      {
        id: 'D-old',
        kind: 'code_finding',
        finding_id: 'f1',
        rule: 'r1',
        file: 'a.py',
        line: 1,
        state: 'WontFix',
        reason: 'r',
        owner: 'bob',
        reviewed_at: '2026-01-01',
        review_trigger: 'manual-review',
      },
      {
        id: 'D-mid',
        kind: 'code_finding',
        finding_id: 'f2',
        rule: 'r2',
        file: 'b.py',
        line: 2,
        state: 'WontFix',
        reason: 'r',
        owner: 'bob',
        reviewed_at: '2026-03-15',
        review_trigger: 'manual-review',
      },
      {
        id: 'D-new',
        kind: 'code_finding',
        finding_id: 'f3',
        rule: 'r3',
        file: 'c.py',
        line: 3,
        state: 'WontFix',
        reason: 'r',
        owner: 'bob',
        reviewed_at: '2026-04-29',
        review_trigger: 'manual-review',
      },
    ]
    renderWithTheme(<DeferredAuditView plan={makePlan2(entries)} />)
    // All three IDs appear in the DOM; D-new should appear before D-old in document order
    const allText = document.body.textContent ?? ''
    const posNew = allText.indexOf('D-new')
    const posOld = allText.indexOf('D-old')
    expect(posNew).toBeGreaterThan(-1)
    expect(posOld).toBeGreaterThan(-1)
    expect(posNew).toBeLessThan(posOld)
  })

  it('(T4-b) per_row_open_task_button_calls_onSelectTask when entry is referenced', () => {
    const onSelectTask = vi.fn()
    // Deferred entry D1 is referenced from task t-ref via deferred_refs
    const plan: Plan = {
      ...makePlan2([oneOfEachKind[0]]), // code_finding D1
      phases: [{
        id: 'p1',
        name: 'P1',
        tasks: [{ id: 't-ref', name: 'Ref Task', status: 'wip', deferred_refs: ['D1'] }],
      }],
    }
    renderWithTheme(<DeferredAuditView plan={plan} onSelectTask={onSelectTask} />)
    // The "Open task t-ref" icon button should be present
    const btn = screen.getByRole('button', { name: /Open task t-ref/i })
    fireEvent.click(btn)
    expect(onSelectTask).toHaveBeenCalledWith(expect.objectContaining({ id: 't-ref' }))
  })

  /* ─── Watchfloor brand alignment ──────────────────────────────────── */

  it('(brand) renders entry count in panel header strip with wfLabel typography', () => {
    renderWithTheme(<DeferredAuditView plan={makePlan2()} />)
    const header = screen.getByText(/deferred entries/i)
    expect(header).toBeInTheDocument()
    // count "1 ENTRY" appears in the same panel header (default kind = code_finding, 1 row)
    expect(screen.getByText(/^1 ENTRY$/i)).toBeInTheDocument()
  })

  it('(brand) data grid uses JetBrains Mono and sharp brand corners', () => {
    renderWithTheme(<DeferredAuditView plan={makePlan2()} />)
    const grid = document.querySelector('.MuiDataGrid-root') as HTMLElement
    expect(grid).not.toBeNull()
    const styles = window.getComputedStyle(grid)
    expect(styles.fontFamily).toMatch(/JetBrains Mono/)
    expect(styles.borderRadius).toBe('0px')
  })

  it('(brand) column headers render uppercase via brand text-transform', () => {
    renderWithTheme(<DeferredAuditView plan={makePlan2()} />)
    const titleEl = document.querySelector('.MuiDataGrid-columnHeaderTitle') as HTMLElement
    expect(titleEl).not.toBeNull()
    const styles = window.getComputedStyle(titleEl)
    expect(styles.textTransform).toBe('uppercase')
    expect(styles.fontFamily).toMatch(/JetBrains Mono/)
  })

  it('(T4-c) impossible filter combination shows filter empty state', () => {
    // Start with code_finding entries (default tab); apply WontFix + FalsePositive
    // The only entry is WontFix=true; applying FalsePositive narrows further.
    // Easiest: add a single code_finding with state WontFix, then filter FalsePositive.
    const entry: DeferredEntry = {
      id: 'D-only',
      kind: 'code_finding',
      finding_id: 'fx',
      rule: 'rx',
      file: 'x.py',
      line: 1,
      state: 'WontFix',
      reason: 'r',
      owner: 'eve',
      reviewed_at: '2026-04-29',
      review_trigger: 'manual-review',
    }
    renderWithTheme(<DeferredAuditView plan={makePlan2([entry])} />)
    // Click 'FalsePositive' state filter chip — entry is WontFix so zero rows remain
    fireEvent.click(screen.getByRole('button', { name: 'FalsePositive' }))
    expect(screen.getByText(/No entries match the current filters/i)).toBeInTheDocument()
  })
})
