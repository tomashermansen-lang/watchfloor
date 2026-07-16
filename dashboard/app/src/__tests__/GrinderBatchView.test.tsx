import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import GrinderBatchView from '../components/grinder/GrinderBatchView'
import type { GrinderBatch } from '../types'
import type { KeyedStreamEvent } from '../hooks/useStreamPolling'
import type { StreamEvent } from '../types'

// Mock StreamViewer to avoid complex rendering
vi.mock('../components/autopilot/StreamViewer', () => ({
  StreamViewer: ({ events, hasStream, label }: { events: unknown[]; hasStream: boolean | null; label?: string }) => (
    <div data-testid="stream-viewer">
      {hasStream === false ? 'No stream data available' : `${events.length} events`}
      {label && <span data-testid="stream-label">{label}</span>}
    </div>
  ),
}))

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

const mockBatch: GrinderBatch = {
  id: 'batch-004',
  pass: 'pass-coverage',
  started_at: '2026-04-22T10:00:00Z',
  turns_elapsed: 5,
}

const phaseEvent: StreamEvent = {
  type: 'phase',
  phase: 'BA',
  status: 'running',
}

const mockEvents: KeyedStreamEvent[] = [
  { ...phaseEvent, _seq: 0 },
  { ...phaseEvent, _seq: 1 },
]

describe('GrinderBatchView', () => {
  it('C8.1: renders batch metadata sidebar', () => {
    renderWithTheme(
      <GrinderBatchView batchId="batch-004" batch={mockBatch} events={mockEvents} hasStream={true} />,
    )
    expect(screen.getByText(/Batch batch-004/)).toBeInTheDocument()
    expect(screen.getByText(/pass-coverage/)).toBeInTheDocument()
    expect(screen.getByText(/Turns:/)).toBeInTheDocument()
  })

  it('C8.2: renders StreamViewer in right pane', () => {
    renderWithTheme(
      <GrinderBatchView batchId="batch-004" batch={mockBatch} events={mockEvents} hasStream={true} />,
    )
    expect(screen.getByTestId('stream-viewer')).toBeInTheDocument()
    expect(screen.getByText('2 events')).toBeInTheDocument()
  })

  it('C8.3: missing batch shows dashes', () => {
    renderWithTheme(
      <GrinderBatchView batchId="batch-004" batch={null} events={[]} hasStream={true} />,
    )
    const dashes = screen.getAllByText('—')
    expect(dashes.length).toBeGreaterThanOrEqual(2)
  })

  it('C8.4: hasStream=false shows no-stream message', () => {
    renderWithTheme(
      <GrinderBatchView batchId="batch-004" batch={mockBatch} events={[]} hasStream={false} />,
    )
    expect(screen.getByText('No stream data available')).toBeInTheDocument()
  })
})
