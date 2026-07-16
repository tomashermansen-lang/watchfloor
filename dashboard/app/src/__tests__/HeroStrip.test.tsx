import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import HeroStrip from '../components/HeroStrip'
import type { Plan, Session } from '../types'

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

const mockPlan: Plan = {
  schema_version: '1.0',
  name: 'OIH',
  description: 'Ops Intelligence Hub',
  phases: [
    {
      id: 'p1',
      name: 'Setup',
      tasks: [
        { id: 't1', name: 'T1', status: 'done' },
        { id: 't2', name: 'T2', status: 'done' },
        { id: 't3', name: 'T3', status: 'wip' },
      ],
    },
    {
      id: 'p2',
      name: 'Build',
      tasks: [
        { id: 't4', name: 'T4', status: 'pending' },
      ],
    },
  ],
}

const noSessions: Session[] = []

describe('HeroStrip', () => {
  it('renders plan name', () => {
    renderWithTheme(<HeroStrip plan={mockPlan} sessions={noSessions} sessionCount={2} />)
    expect(screen.getByText('OIH')).toBeInTheDocument()
  })

  it('renders plan description', () => {
    renderWithTheme(<HeroStrip plan={mockPlan} sessions={noSessions} sessionCount={2} />)
    expect(screen.getByText('Ops Intelligence Hub')).toBeInTheDocument()
  })

  it('shows progress percentage', () => {
    renderWithTheme(<HeroStrip plan={mockPlan} sessions={noSessions} sessionCount={0} />)
    expect(screen.getByText('50%')).toBeInTheDocument()
  })

  it('shows task counts', () => {
    renderWithTheme(<HeroStrip plan={mockPlan} sessions={noSessions} sessionCount={0} />)
    expect(screen.getByText(/2\/4 tasks/)).toBeInTheDocument()
  })

  it('shows session count when > 0', () => {
    renderWithTheme(<HeroStrip plan={mockPlan} sessions={noSessions} sessionCount={3} />)
    expect(screen.getByText(/3 working/)).toBeInTheDocument()
  })

  it('renders segmented progress bar', () => {
    const { container } = renderWithTheme(<HeroStrip plan={mockPlan} sessions={noSessions} sessionCount={0} />)
    expect(container.querySelector('[data-testid="segmented-progress"]')).toBeInTheDocument()
  })

  it('promotes pending task to wip when a working session matches its ID', () => {
    const workingSession: Session = {
      sid: 's1', cwd: '/dev', worktree: '/dev', branch: 'feature/t4',
      event: 'Notification', type: 'agent', msg: '', ts: new Date().toISOString(),
      status: 'working', flow: null,
    }
    renderWithTheme(<HeroStrip plan={mockPlan} sessions={[workingSession]} sessionCount={1} />)
    // t3 is statically wip, t4 promoted from pending → wip = 2 total wip
    expect(screen.getByText(/wip \(2\)/)).toBeInTheDocument()
    expect(screen.getByText(/pending \(0\)/)).toBeInTheDocument()
  })

})
