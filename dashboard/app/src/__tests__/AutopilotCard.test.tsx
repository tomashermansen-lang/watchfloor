import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import AutopilotCard from '../components/autopilot/AutopilotCard'
import type { AutopilotSession, AutopilotSessionStatus } from '../types'

function mockSession(over: Partial<AutopilotSession> = {}): AutopilotSession {
  return {
    task: 'demo-task',
    project: 'OIH',
    status: 'running' as AutopilotSessionStatus,
    phases: [],
    elapsed_s: 42,
    cost: 0.12,
    ...over,
  } as AutopilotSession
}

function renderCard(over: Partial<AutopilotSession> = {}) {
  return render(
    <ThemeProvider theme={theme}>
      <AutopilotCard session={mockSession(over)} selected={false} onSelect={() => {}} />
    </ThemeProvider>,
  )
}

describe('AutopilotCard brand StatusPill migration', () => {
  it('running status renders running StatusPill', () => {
    renderCard({ status: 'running' })
    const pill = screen.getByText('running').closest('[data-testid="wf-status-pill"]')
    expect(pill).not.toBeNull()
    expect(pill).toHaveAttribute('data-status', 'running')
  })

  it('completed status renders completed StatusPill', () => {
    renderCard({ status: 'completed' })
    const pill = screen.getByText('completed').closest('[data-testid="wf-status-pill"]')
    expect(pill).not.toBeNull()
    expect(pill).toHaveAttribute('data-status', 'completed')
  })

  it('failed status renders fault StatusPill', () => {
    renderCard({ status: 'failed' })
    const pill = screen.getByText('failed').closest('[data-testid="wf-status-pill"]')
    expect(pill).not.toBeNull()
    expect(pill).toHaveAttribute('data-status', 'fault')
  })
})
