import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import ProjectHeader from '../components/plan2/ProjectHeader'
import type { Plan } from '../types'

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

function makePlan2(overrides: Partial<Plan> = {}): Plan {
  return {
    schema_version: '2.0.0',
    name: 'Demo',
    vision: 'A clear vision for the project.',
    users: ['developers'],
    success_criteria: [
      { id: 'C1', description: 'Tests pass on every commit', measurable_via: 'test' },
      { id: 'C2', description: 'Manual verification by reviewer', measurable_via: 'review' },
    ],
    scope: { in_scope: [], out_of_scope: [] },
    tech_stack: ['react', 'typescript', 'vite'],
    existing_infrastructure_to_reuse: [],
    test_targets: [],
    setup: {
      prerequisites: [], runtime_dependencies: [], services_to_provision: [],
      environment_verification: [], out_of_scope: [],
    },
    kill_criteria: [],
    design_notes: [],
    risks: [],
    phases: [],
    ...overrides,
  }
}

describe('ProjectHeader (schema 2.0)', () => {
  it('renders vision paragraph for 2.0', () => {
    renderWithTheme(<ProjectHeader plan={makePlan2()} />)
    expect(screen.getByText('A clear vision for the project.')).toBeInTheDocument()
  })

  it('renders one chip per success_criterion', () => {
    renderWithTheme(<ProjectHeader plan={makePlan2()} />)
    expect(screen.getByText(/Tests pass on every commit/)).toBeInTheDocument()
    expect(screen.getByText(/Manual verification by reviewer/)).toBeInTheDocument()
  })

  it('chip carries data-criterion-id attribute', () => {
    const { container } = renderWithTheme(<ProjectHeader plan={makePlan2()} />)
    const chips = container.querySelectorAll('[data-criterion-id]')
    expect(chips.length).toBe(2)
    expect(chips[0].getAttribute('data-criterion-id')).toBe('C1')
  })

  it('renders measurable_via as adjacent chip', () => {
    renderWithTheme(<ProjectHeader plan={makePlan2()} />)
    expect(screen.getByText('test')).toBeInTheDocument()
    expect(screen.getByText('review')).toBeInTheDocument()
  })

  it('renders one chip per tech_stack entry', () => {
    renderWithTheme(<ProjectHeader plan={makePlan2()} />)
    expect(screen.getByText('react')).toBeInTheDocument()
    expect(screen.getByText('typescript')).toBeInTheDocument()
    expect(screen.getByText('vite')).toBeInTheDocument()
  })

  it('renders nothing on 1.x plan', () => {
    const plan1x: Plan = { schema_version: '1.0.0', name: 'Old', phases: [] }
    const { container } = renderWithTheme(<ProjectHeader plan={plan1x} />)
    expect(container.firstChild).toBeNull()
  })

  it('omits chip row when success_criteria is empty', () => {
    const plan = makePlan2({ success_criteria: [] })
    renderWithTheme(<ProjectHeader plan={plan} />)
    expect(screen.getByText('A clear vision for the project.')).toBeInTheDocument()
    expect(screen.queryByText(/Tests pass/)).not.toBeInTheDocument()
  })

  it('omits Vision section when vision is empty but renders tech_stack', () => {
    const plan = makePlan2({ vision: '' })
    renderWithTheme(<ProjectHeader plan={plan} />)
    expect(screen.queryByText('Vision')).not.toBeInTheDocument()
    expect(screen.getByText('react')).toBeInTheDocument()
  })

  /* ─── T6 addition: R7 / R21 partial render ───────────────────────── */

  it('(T6) partial_render_when_phases_missing — vision and tech_stack still render without phases', () => {
    // Plan without phases field (undefined) — best-effort graceful render (EC6 / R21)
    const plan = makePlan2({ phases: undefined as unknown as [] })
    renderWithTheme(<ProjectHeader plan={plan} />)
    // Vision and tech_stack should render even without phases
    expect(screen.getByText('A clear vision for the project.')).toBeInTheDocument()
    expect(screen.getByText('react')).toBeInTheDocument()
    expect(screen.getByText('typescript')).toBeInTheDocument()
  })
})
