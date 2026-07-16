import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import PlanCompletionBand from '../components/wf/PlanCompletionBand'
import type { Plan, Feature } from '../types'

function renderBand(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

const plan: Plan = {
  schema_version: '1.0.0',
  name: 'Demo',
  phases: [
    {
      id: 'p1',
      name: 'Phase 1',
      tasks: [
        { id: 't1', name: 'T1', status: 'done' },
        { id: 't2', name: 'T2', status: 'done' },
        { id: 't3', name: 'T3', status: 'wip' },
        { id: 't4', name: 'T4', status: 'pending' },
      ],
    },
  ],
}

function mockFeature(over: Partial<Feature> = {}): Feature {
  return {
    name: 'feat',
    project: 'demo',
    project_root: '/tmp',
    phase: 'implement',
    phase_index: 3,
    total_phases: 8,
    pipeline_type: 'light',
    artifacts: [],
    sessions: [],
    status: 'active',
    stuck_info: null,
    last_activity: '2026-01-01T00:00:00Z',
    is_autopilot: false,
    ...over,
  } as Feature
}

describe('wf/PlanCompletionBand', () => {
  it('renders the segmented hero pipeline for the plan tasks', () => {
    renderBand(<PlanCompletionBand plan={plan} features={[]} />)
    /* Reuses the existing SegmentedProgress primitive. */
    expect(screen.getByTestId('segmented-progress')).toBeInTheDocument()
  })

  it('shows done/total tasks and the percentage', () => {
    renderBand(<PlanCompletionBand plan={plan} features={[]} />)
    /* 2 of 4 done = 50%. */
    expect(screen.getByText(/2\/4 tasks/i)).toBeInTheDocument()
    expect(screen.getByText(/50%/)).toBeInTheDocument()
  })

  it('shows done/total features and the percentage when features are provided', () => {
    const features = [
      mockFeature({ name: 'a', status: 'active' }),
      mockFeature({ name: 'b', status: 'done' }),
      mockFeature({ name: 'c', status: 'done' }),
      mockFeature({ name: 'd', status: 'waiting' }),
    ]
    renderBand(<PlanCompletionBand plan={plan} features={features} />)
    /* 2 of 4 features done = 50%. */
    expect(screen.getByText(/2\/4 features/i)).toBeInTheDocument()
    /* The 50% from tasks AND the 50% from features both render —
       we can find them by counting wfCode percentages or testid. */
    const pcts = screen.getAllByText(/50%/)
    expect(pcts.length).toBe(2)
  })

  it('omits the feature counter when no features supplied', () => {
    renderBand(<PlanCompletionBand plan={plan} features={[]} />)
    expect(screen.queryByText(/features/i)).not.toBeInTheDocument()
  })

  it('renders with brand wfLabel chrome typography on the count labels', () => {
    renderBand(<PlanCompletionBand plan={plan} features={[mockFeature()]} />)
    const tasksLabel = screen.getByText(/2\/4 tasks/i)
    expect(tasksLabel.className).toMatch(/MuiTypography-wfLabel/)
  })

  it('controls-06 #1 barOnly mode renders the segmented bar without counts or features', () => {
    /* The ProjectPanel grid refactor places the N/M-tasks, TASKS
       label, and percent cells in their own grid columns so they
       align vertically across rows. PlanCompletionBand's default
       (full-cluster) layout puts those cells in the SAME flex row
       as the bar — useful for ProjectSubviewTab, but counter to the
       row-grid contract here. barOnly returns just the
       SegmentedProgress wrapper so the parent grid can supply the
       sibling cells with explicit column widths. */
    renderBand(<PlanCompletionBand plan={plan} features={[mockFeature()]} barOnly />)
    expect(screen.getByTestId('segmented-progress')).toBeInTheDocument()
    expect(screen.queryByText(/2\/4 tasks/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/50%/)).not.toBeInTheDocument()
    expect(screen.queryByText(/features/i)).not.toBeInTheDocument()
  })

  it('hero pipeline accommodates up to 100 tasks at the brand minimum segment width', () => {
    /* Operator request: the band must visibly read up to 100
       tasks. Build a plan with 100 tasks and assert the
       SegmentedProgress wrapper is at least 200px wide (100
       segments × ≥2px brand minimum). */
    const bigPlan: Plan = {
      schema_version: '1.0.0',
      name: 'Big',
      phases: [{
        id: 'p',
        name: 'Phase',
        tasks: Array.from({ length: 100 }, (_, i) => ({
          id: `t${i}`,
          name: `T${i}`,
          status: i < 30 ? 'done' : 'pending',
        })),
      }],
    } as Plan
    const { container } = renderBand(<PlanCompletionBand plan={bigPlan} features={[]} />)
    const segments = container.querySelectorAll('[data-testid="segment"]')
    expect(segments.length).toBe(100)
    /* Locate the SegmentedProgress wrapper and assert its width
       is generous enough for 100 tasks. */
    const sp = container.querySelector('[data-testid="segmented-progress"]') as HTMLElement
    const wrapper = sp.parentElement as HTMLElement
    /* Inline style width comes through with a "px" suffix; parse. */
    const wrapperWidth = parseInt(wrapper.style.width || '0', 10)
    expect(wrapperWidth).toBeGreaterThanOrEqual(200)
  })
})
