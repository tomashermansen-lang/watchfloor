/**
 * Tests for Plan2TaskBody inside SessionPanel (R10 / AS9).
 *
 * Plan2TaskBody renders when task has any of: what, why, where, constraints,
 * artifact_refs, estimate. It is rendered inside the content area of
 * SessionPanel (non-stream mode).
 *
 * These tests mount the full SessionPanel with a 2.0-shaped task to exercise
 * the Plan2TaskBody sub-component without exporting it separately.
 */
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import SessionPanel from '../components/SessionPanel'
import type { Task, Plan } from '../types'

// Suppress lazy-loaded component errors (ArtifactDialog, StreamViewer, LogViewer)
vi.mock('../hooks/useAutopilotArtifacts', () => ({
  useAutopilotArtifacts: () => [],
}))
vi.mock('../hooks/usePlanArtifacts', () => ({
  usePlanArtifacts: () => [],
}))

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

function make2Plan(overrides: Partial<Plan> = {}): Plan {
  return {
    schema_version: '2.0.0',
    name: 'Demo',
    vision: 'v',
    users: ['x'],
    success_criteria: [{ id: 'C1', description: 'd' }],
    scope: { in_scope: [], out_of_scope: [] },
    tech_stack: ['ts'],
    existing_infrastructure_to_reuse: [],
    test_targets: [{ id: 'self', path: '.' }],
    setup: {
      prerequisites: [], runtime_dependencies: [], services_to_provision: [],
      environment_verification: [], out_of_scope: [],
    },
    kill_criteria: [], design_notes: [], risks: [],
    phases: [{ id: 'p1', name: 'P1', tasks: [] }],
    ...overrides,
  }
}

function make2Task(overrides: Partial<Task> = {}): Task {
  return {
    id: 'task-a',
    name: 'Task A',
    status: 'wip',
    what: 'Implement the widget.',
    ...overrides,
  }
}

describe('Plan2TaskBody (via SessionPanel) — R10 / AS9', () => {
  /* Audit-18 - the brief sub-filter row introduced ToggleChip buttons
     labeled What / Why / Where / Constraints / Acceptance / Artifacts
     / Estimate / Description, which collide with the same-named h3
     section headings inside Plan2TaskBody. Tests now query by role
     'heading' to disambiguate between the toggle buttons and section
     titles. */

  it('(a) renders What section above acceptance criteria', () => {
    const task = make2Task({
      what: 'Build the registration form.',
      acceptance: ['Form submits successfully'],
    })
    renderWithTheme(
      <SessionPanel task={task} autopilotSession={null} plan={make2Plan()} />,
    )
    const whatHeading = screen.getByRole('heading', { name: 'What', level: 3 })
    expect(whatHeading).toBeInTheDocument()
    expect(screen.getByText('Build the registration form.')).toBeInTheDocument()
    expect(screen.getByText('Form submits successfully')).toBeInTheDocument()
    const acEl = screen.getByText('Acceptance Criteria')
    expect(
      whatHeading.compareDocumentPosition(acEl) & Node.DOCUMENT_POSITION_FOLLOWING,
    ).toBeTruthy()
  })

  /* Audit-19 #2 - Why is no longer collapsible. Operator request:
     "Alt skal aabnes enablet saa kan man filtere ud" - every brief
     section renders fully open, and the sub-filter row is the single
     point of control for hiding/showing them. The Why heading is now
     a plain h3 ("Why", not "Why +") with the body always visible. */
  it('(b) renders Why section with body always visible (no collapsible toggle)', () => {
    const task = make2Task({ why: 'Because it drives business value.' })
    renderWithTheme(
      <SessionPanel task={task} autopilotSession={null} plan={make2Plan()} />,
    )
    const whyHeading = screen.getByRole('heading', { name: 'Why', level: 3 })
    expect(whyHeading).toBeInTheDocument()
    expect(screen.getByText('Because it drives business value.')).toBeInTheDocument()
    const whyButtons = screen.queryAllByRole('button', { name: /Why/ })
    const collapsibleBtn = whyButtons.find((b) => b.hasAttribute('aria-expanded'))
    expect(collapsibleBtn).toBeUndefined()
  })

  /* Audit-19 #1 - What text is no longer truncated. Operator request:
     full text rendered so the operator does not need to hover for the
     tail of the message. */
  it('(a2) renders full What text without truncation', () => {
    const longWhat = 'Wrap the Plans rendering in dashboard/app/src/components/DashboardShell.tsx with a new PlansFilterBar component (create dashboard/app/src/components/PlansFilterBar.tsx) that owns the filter chip rail above the project list grid.'
    const task = make2Task({ what: longWhat })
    renderWithTheme(
      <SessionPanel task={task} autopilotSession={null} plan={make2Plan()} />,
    )
    expect(screen.getByText(longWhat)).toBeInTheDocument()
  })

  it('(c) renders Where breakdown with one Chip per path', () => {
    const task = make2Task({
      where: {
        modify: ['src/foo.ts', 'src/bar.ts'],
        create: ['src/baz.ts'],
        delete: ['src/old.ts'],
      },
    })
    renderWithTheme(
      <SessionPanel task={task} autopilotSession={null} plan={make2Plan()} />,
    )
    expect(screen.getByRole('heading', { name: 'Where', level: 3 })).toBeInTheDocument()
    expect(screen.getByText('src/foo.ts')).toBeInTheDocument()
    expect(screen.getByText('src/bar.ts')).toBeInTheDocument()
    expect(screen.getByText('src/baz.ts')).toBeInTheDocument()
    expect(screen.getByText('src/old.ts')).toBeInTheDocument()
  })

  it('(d) renders Constraints list when non-empty, absent when empty', () => {
    const taskWith = make2Task({ constraints: ['Must not break public API', 'Max 200 lines'] })
    const { unmount } = renderWithTheme(
      <SessionPanel task={taskWith} autopilotSession={null} plan={make2Plan()} />,
    )
    expect(screen.getByRole('heading', { name: 'Constraints', level: 3 })).toBeInTheDocument()
    expect(screen.getByText('Must not break public API')).toBeInTheDocument()
    expect(screen.getByText('Max 200 lines')).toBeInTheDocument()
    unmount()

    const taskWithout = make2Task({ constraints: [] })
    renderWithTheme(
      <SessionPanel task={taskWithout} autopilotSession={null} plan={make2Plan()} />,
    )
    expect(screen.queryByRole('heading', { name: 'Constraints', level: 3 })).not.toBeInTheDocument()
  })

  /* Audit-19 #11 - artifact_refs section removed from BriefView. The
     sidebar Documents column already lists every artifact (REQUIREMENTS,
     PLAN, REVIEW, ...) with a click link, so the BriefView row was
     duplicating a more discoverable affordance. The on-disk
     task.artifact_refs object is still consumed by the sidebar
     (mergeArtifacts + DetailSidebar.artifacts) — it just no longer
     surfaces inside the brief content panel. */
  it('(e) does NOT render an artifact_refs section inside BriefView', () => {
    const plan = make2Plan({
      test_targets: [{ id: 'self', path: '.' }],
    })
    const task = make2Task({
      artifact_refs: {
        requirements_path: 'REQUIREMENTS.md',
        plan_path: 'PLAN.md',
      },
    })
    renderWithTheme(
      <SessionPanel task={task} autopilotSession={null} plan={plan} planDir="/tmp/demo" />,
    )
    expect(screen.queryByText('Artifact refs')).not.toBeInTheDocument()
  })

  it('(f) renders estimate label with lines and hours', () => {
    const task = make2Task({
      estimate: { lines_estimate: 600, duration_hours: 4 },
    })
    renderWithTheme(
      <SessionPanel task={task} autopilotSession={null} plan={make2Plan()} />,
    )
    expect(screen.getByText(/~600 lines/)).toBeInTheDocument()
    expect(screen.getByText(/4h/)).toBeInTheDocument()
  })
})
