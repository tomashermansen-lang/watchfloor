import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import SessionLifecycle from '../components/metrics/SessionLifecycle'
import type { SessionLifecycleMetrics } from '../types'

function makeData(overrides?: Partial<SessionLifecycleMetrics>): SessionLifecycleMetrics {
  return {
    sessions: [
      { sid: 's1', start: '2026-05-01T15:00:00Z', end: '2026-05-01T15:12:00Z', duration_s: 720, model: 'opus', source: 'startup', end_reason: 'clear' },
      { sid: 's2', start: '2026-05-01T15:05:00Z', end: '2026-05-01T15:15:00Z', duration_s: 600, model: 'opus', source: 'startup', end_reason: 'clear' },
    ],
    model_distribution: { opus: 2 },
    source_distribution: { startup: 2 },
    end_reasons: { clear: 2 },
    concurrency_timeline: [
      { ts: '2026-05-01T15:00:00Z', concurrent: 1 },
      { ts: '2026-05-01T15:05:00Z', concurrent: 2 },
      { ts: '2026-05-01T15:10:00Z', concurrent: 2 },
      { ts: '2026-05-01T15:15:00Z', concurrent: 0 },
    ],
    ...overrides,
  }
}

function renderLifecycle(data: SessionLifecycleMetrics) {
  return render(
    <ThemeProvider theme={theme}>
      <SessionLifecycle data={data} />
    </ThemeProvider>,
  )
}

describe('SessionLifecycle polished', () => {
  it('shows avg duration headline with session count caption', () => {
    renderLifecycle(makeData())
    // avg = (720+600)/2 = 660s = 11 min
    expect(screen.getByTestId('lifecycle-avg-duration')).toHaveTextContent(/11 min/)
    expect(screen.getByText(/2 sessions/i)).toBeInTheDocument()
  })

  it('shows peak concurrent count', () => {
    renderLifecycle(makeData())
    expect(screen.getByText(/Peak concurrent/i)).toBeInTheDocument()
    expect(screen.getByTestId('lifecycle-peak-concurrent')).toHaveTextContent('2')
  })

  it('renders a concurrency bar visualization', () => {
    const { container } = renderLifecycle(makeData())
    // Expect at least one element with the testid that wraps the visual
    expect(container.querySelector('[data-testid="lifecycle-concurrency-bars"]')).toBeTruthy()
  })

  it('renders source distribution chips', () => {
    renderLifecycle(makeData({
      source_distribution: { startup: 3, other: 3 },
    }))
    expect(screen.getByText(/startup: 3/i)).toBeInTheDocument()
    expect(screen.getByText(/other: 3/i)).toBeInTheDocument()
  })

  it('renders empty state when no sessions', () => {
    renderLifecycle(makeData({
      sessions: [],
      concurrency_timeline: [],
      source_distribution: {},
    }))
    expect(screen.getByText(/No session data/i)).toBeInTheDocument()
  })
})
