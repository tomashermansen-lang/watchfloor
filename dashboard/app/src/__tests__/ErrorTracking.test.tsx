import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import ErrorTracking from '../components/metrics/ErrorTracking'
import type { ErrorTrackingMetrics } from '../types'

function makeData(overrides?: Partial<ErrorTrackingMetrics>): ErrorTrackingMetrics {
  return {
    total_errors: 8,
    by_tool: { Bash: 6, Read: 2 },
    by_tool_detail: {
      Bash: { failures: 5, interrupts: 1 },
      Read: { failures: 2, interrupts: 0 },
    },
    by_session: { s1: { errors: 8, rate: 5 } },
    interrupts: 1,
    failures: 7,
    timeline: [
      { ts: '2026-05-01T15:00:00Z', sid: 's1', tool: 'Bash', is_interrupt: false },
      { ts: '2026-05-01T15:05:00Z', sid: 's1', tool: 'Bash', is_interrupt: false },
    ],
    ...overrides,
  }
}

function renderTracker(data: ErrorTrackingMetrics, selectedSid: string | 'all' = 'all') {
  return render(
    <ThemeProvider theme={theme}>
      <ErrorTracking data={data} selectedSid={selectedSid} />
    </ThemeProvider>,
  )
}

describe('ErrorTracking polished', () => {
  it('shows total error count as a wfDisplay value', () => {
    /* Brand layout splits the count from its label: "Errors" wfLabel
       above, big "8" wfDisplay number below in status.fault red.
       Replaces the previous combined "8 errors" headlineSmall. */
    renderTracker(makeData())
    expect(screen.getByText('8')).toBeInTheDocument()
    expect(screen.getByText(/^Errors/i)).toBeInTheDocument()
  })

  it('shows failures and interrupts chips with counts', () => {
    renderTracker(makeData())
    expect(screen.getByText(/Failures: 7/i)).toBeInTheDocument()
    expect(screen.getByText(/Interrupts: 1/i)).toBeInTheDocument()
  })

  it('annotates the most error-prone tool below the chart', () => {
    renderTracker(makeData())
    // Annotation is data-driven: 'Most errors originate in Bash (6 of 8)'
    expect(screen.getByTestId('error-annotation')).toHaveTextContent(/Bash/)
    expect(screen.getByTestId('error-annotation')).toHaveTextContent(/6/)
  })

  it('renders empty state when no errors', () => {
    renderTracker(makeData({ total_errors: 0, failures: 0, interrupts: 0, by_tool: {}, by_tool_detail: {}, timeline: [] }))
    expect(screen.getByText(/No errors recorded/i)).toBeInTheDocument()
  })
})
