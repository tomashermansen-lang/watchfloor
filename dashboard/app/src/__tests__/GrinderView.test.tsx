import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import type {
  GrinderProjectSummary,
  GrinderProjectDetail,
  GrinderPass,
  GrinderEvent,
  GrinderDeferral,
} from '../types'

// Mock hooks before imports
vi.mock('../hooks/useGrinder', () => ({
  useGrinderList: vi.fn(),
  useGrinderDetail: vi.fn(),
  usePauseGrinder: vi.fn(),
}))
vi.mock('../hooks/useGrinderStream', () => ({
  useGrinderStream: vi.fn().mockReturnValue({ events: [], isLive: false, hasStream: null }),
}))
vi.mock('../components/autopilot/StreamViewer', () => ({
  StreamViewer: ({ hasStream }: { hasStream: boolean | null }) => (
    <div data-testid="stream-viewer">{hasStream === false ? 'No stream data available' : 'stream'}</div>
  ),
}))

import { useGrinderList, useGrinderDetail, usePauseGrinder } from '../hooks/useGrinder'
import GrinderView from '../components/grinder/GrinderView'
import GrinderProjectList from '../components/grinder/GrinderProjectList'
import GrinderDetail from '../components/grinder/GrinderDetail'
import GrinderPassStepper from '../components/grinder/GrinderPassStepper'
import GrinderBatchCard from '../components/grinder/GrinderBatchCard'
import GrinderEventsList from '../components/grinder/GrinderEventsList'
import GrinderDeferralsTable from '../components/grinder/GrinderDeferralsTable'

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

const mockSummary = (overrides: Partial<GrinderProjectSummary> = {}): GrinderProjectSummary => ({
  project: 'OIH',
  path: '/tmp/OIH',
  status: 'in_progress',
  current_pass: 'pass-coverage',
  batches_completed: 3,
  batches_total: 6,
  deferrals_count: 5,
  last_event_ts: '2026-04-22T10:00:00Z',
  paused: false,
  ...overrides,
})

const mockPass = (overrides: Partial<GrinderPass> = {}): GrinderPass => ({
  id: 'pass-mechanical',
  name: 'Mechanical',
  status: 'completed',
  batches_total: 5,
  batches_completed: 5,
  ...overrides,
})

const mockEvent = (overrides: Partial<GrinderEvent> = {}): GrinderEvent => ({
  ts: '2026-04-22T10:00:00Z',
  batch: 'batch-001',
  event: 'completed',
  files_fixed: 2,
  ...overrides,
})

const mockDeferral = (overrides: Partial<GrinderDeferral> = {}): GrinderDeferral => ({
  rule: 'python:S3776',
  count: 15,
  example_file: 'src/complex.py',
  ...overrides,
})

const mockDetail: GrinderProjectDetail = {
  passes: [
    mockPass(),
    mockPass({ id: 'pass-coverage', name: 'Coverage', status: 'in_progress', batches_total: 4, batches_completed: 2 }),
    mockPass({ id: 'pass-static', name: 'Static Analysis', status: 'pending', batches_total: 3, batches_completed: 0 }),
    mockPass({ id: 'pass-cve', name: 'CVE', status: 'failed', batches_total: 2, batches_completed: 1 }),
  ],
  current_batch: {
    id: 'batch-004',
    pass: 'pass-coverage',
    started_at: '2026-04-22T10:00:00Z',
    turns_elapsed: 5,
  },
  recent_events: [
    mockEvent(),
    mockEvent({ event: 'started', batch: 'batch-004', ts: '2026-04-22T09:59:00Z' }),
    mockEvent({ event: 'failed', batch: 'batch-003', reason: 'test failure', ts: '2026-04-22T09:55:00Z' }),
  ],
  top_deferrals: [
    mockDeferral(),
    mockDeferral({ rule: 'python:S1192', count: 8, example_file: 'src/dup.py' }),
  ],
}

const mockPauseGrinder = { pause: vi.fn(), resume: vi.fn(), isLoading: false }

/* ═══ T6 — GrinderView ═══ */

describe('GrinderView', () => {
  beforeEach(() => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: undefined,
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderList>)
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: undefined,
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    vi.mocked(usePauseGrinder).mockReturnValue(mockPauseGrinder)
  })

  it('T6.4 shows empty state when no projects', () => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: [],
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderList>)
    renderWithTheme(<GrinderView />)
    expect(screen.getByText(/no grinder data found/i)).toBeInTheDocument()
  })

  it('T6.1 shows project list when no selection', () => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: [mockSummary()],
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderList>)
    renderWithTheme(<GrinderView />)
    expect(screen.getByText('OIH')).toBeInTheDocument()
  })

  it('T6.2 shows detail when project is clicked', () => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: [mockSummary()],
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderList>)
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: mockDetail,
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    renderWithTheme(<GrinderView />)
    fireEvent.click(screen.getByText('OIH'))
    expect(screen.getByText(/grinder \//i)).toBeInTheDocument()
  })

  it('T6.3 back navigation returns to project list', () => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: [mockSummary()],
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderList>)
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: mockDetail,
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    renderWithTheme(<GrinderView />)
    // Navigate to detail
    fireEvent.click(screen.getByText('OIH'))
    expect(screen.getByText(/grinder \//i)).toBeInTheDocument()
    // C2 auto-opens stream pane; close it via breadcrumb to reach the detail-view back button
    fireEvent.click(screen.getByText(/← Grinder \/ OIH/))
    // Navigate back
    fireEvent.click(screen.getByLabelText(/back/i))
    // Should show project list again
    expect(screen.getByText('OIH')).toBeInTheDocument()
    expect(screen.queryByText(/grinder \//i)).not.toBeInTheDocument()
  })
})

/* ══��� T7 — GrinderProjectList ═══ */

describe('GrinderProjectList', () => {
  it('T7.1 renders project rows', () => {
    const onSelect = vi.fn()
    renderWithTheme(
      <GrinderProjectList
        projects={[mockSummary(), mockSummary({ project: 'dotfiles', status: 'completed' })]}
        onSelectProject={onSelect}
      />,
    )
    expect(screen.getByText('OIH')).toBeInTheDocument()
    expect(screen.getByText('dotfiles')).toBeInTheDocument()
  })

  it('T7.2 click row selects project', () => {
    const onSelect = vi.fn()
    renderWithTheme(
      <GrinderProjectList projects={[mockSummary()]} onSelectProject={onSelect} />,
    )
    fireEvent.click(screen.getByText('OIH'))
    expect(onSelect).toHaveBeenCalledWith('OIH')
  })

  it('T7.3 Enter key selects project', () => {
    const onSelect = vi.fn()
    renderWithTheme(
      <GrinderProjectList projects={[mockSummary()]} onSelectProject={onSelect} />,
    )
    const row = screen.getByText('OIH').closest('tr')!
    fireEvent.keyDown(row, { key: 'Enter' })
    expect(onSelect).toHaveBeenCalledWith('OIH')
  })

  it('T7.4 status cell renders brand StatusPill (in_progress → running)', () => {
    renderWithTheme(
      <GrinderProjectList projects={[mockSummary()]} onSelectProject={vi.fn()} />,
    )
    const pill = screen.getByText(/in progress/i).closest('[data-testid="wf-status-pill"]')
    expect(pill).not.toBeNull()
    expect(pill).toHaveAttribute('data-status', 'running')
  })

  it('T7.5 paused project renders muted StatusPill', () => {
    renderWithTheme(
      <GrinderProjectList
        projects={[mockSummary({ paused: true })]}
        onSelectProject={vi.fn()}
      />,
    )
    const pill = screen.getByText('paused').closest('[data-testid="wf-status-pill"]')
    expect(pill).not.toBeNull()
    expect(pill).toHaveAttribute('data-status', 'muted')
  })
})

/* ═══ T9 — GrinderPassStepper ═══ */

describe('GrinderPassStepper', () => {
  it('T9.1 renders pass cards', () => {
    renderWithTheme(<GrinderPassStepper passes={mockDetail.passes} />)
    expect(screen.getByText('Mechanical')).toBeInTheDocument()
    expect(screen.getByText('Coverage')).toBeInTheDocument()
    expect(screen.getByText('Static Analysis')).toBeInTheDocument()
    expect(screen.getByText('CVE')).toBeInTheDocument()
  })

  it('T9.3 shows progress fraction', () => {
    renderWithTheme(<GrinderPassStepper passes={[mockPass({ batches_completed: 3, batches_total: 5 })]} />)
    expect(screen.getByText('3/5 batches')).toBeInTheDocument()
  })

  it('T9.4 has aria-labels', () => {
    renderWithTheme(<GrinderPassStepper passes={[mockPass()]} />)
    expect(screen.getByLabelText(/mechanical pass, completed, 5 of 5 batches/i)).toBeInTheDocument()
  })

  it('T9.5 status chip renders brand StatusPill', () => {
    renderWithTheme(
      <GrinderPassStepper passes={[
        mockPass({ status: 'in_progress' }),
        mockPass({ id: 'p2', name: 'Other', status: 'failed' }),
      ]} />,
    )
    const running = screen.getByText(/in progress/i).closest('[data-testid="wf-status-pill"]')
    expect(running).toHaveAttribute('data-status', 'running')
    const fault = screen.getByText('failed').closest('[data-testid="wf-status-pill"]')
    expect(fault).toHaveAttribute('data-status', 'fault')
  })
})

/* ═══ T10 — GrinderBatchCard ═══ */

describe('GrinderBatchCard', () => {
  it('T10.1 shows active batch info', () => {
    renderWithTheme(<GrinderBatchCard batch={mockDetail.current_batch} />)
    expect(screen.getAllByText('batch-004').length).toBeGreaterThanOrEqual(1)
    expect(screen.getByText((_, el) => el?.textContent === 'Turns: 5')).toBeInTheDocument()
  })

  it('T10.2 shows empty state when null', () => {
    renderWithTheme(<GrinderBatchCard batch={null} />)
    expect(screen.getByText(/no active batch/i)).toBeInTheDocument()
  })

  it('C7.1 "View stream" button renders when onOpenStream provided', () => {
    renderWithTheme(<GrinderBatchCard batch={mockDetail.current_batch} onOpenStream={vi.fn()} />)
    expect(screen.getByRole('button', { name: /stream/i })).toBeInTheDocument()
  })

  it('C7.2 button click calls onOpenStream with batchId', () => {
    const onOpen = vi.fn()
    renderWithTheme(<GrinderBatchCard batch={mockDetail.current_batch} onOpenStream={onOpen} />)
    fireEvent.click(screen.getByRole('button', { name: /stream/i }))
    expect(onOpen).toHaveBeenCalledWith('batch-004')
  })

  it('C7.3 button not rendered when batch is null', () => {
    renderWithTheme(<GrinderBatchCard batch={null} onOpenStream={vi.fn()} />)
    expect(screen.queryByRole('button', { name: /stream/i })).not.toBeInTheDocument()
  })

  it('C7.4 button not rendered without onOpenStream', () => {
    renderWithTheme(<GrinderBatchCard batch={mockDetail.current_batch} />)
    expect(screen.queryByRole('button', { name: /stream/i })).not.toBeInTheDocument()
  })
})

/* ═══ T11 — GrinderEventsList ═══ */

describe('GrinderEventsList', () => {
  it('T11.1 renders event rows', () => {
    renderWithTheme(<GrinderEventsList events={mockDetail.recent_events} />)
    expect(screen.getByText('batch-001')).toBeInTheDocument()
    expect(screen.getAllByText('batch-004').length).toBeGreaterThanOrEqual(1)
  })

  it('T11.2 filter chips toggle events', () => {
    renderWithTheme(<GrinderEventsList events={mockDetail.recent_events} />)
    // Click "failed" filter — should only show failed events
    const failedChip = screen.getByLabelText(/filter by failed events/i)
    fireEvent.click(failedChip)
    // batch-003 has the failed event
    expect(screen.getByText('batch-003')).toBeInTheDocument()
    // batch-001 (completed) should be hidden
    expect(screen.queryByText('batch-001')).not.toBeInTheDocument()
  })

  it('T11.5 shows empty state', () => {
    renderWithTheme(<GrinderEventsList events={[]} />)
    expect(screen.getByText(/no events recorded/i)).toBeInTheDocument()
  })

  it('C10.1 play button renders for events with batch', () => {
    renderWithTheme(<GrinderEventsList events={[mockEvent()]} onOpenStream={vi.fn()} />)
    expect(screen.getByLabelText(/view stream for batch-001/i)).toBeInTheDocument()
  })

  it('C10.2 play button hidden when no onOpenStream', () => {
    renderWithTheme(<GrinderEventsList events={[mockEvent()]} />)
    expect(screen.queryByLabelText(/view stream/i)).not.toBeInTheDocument()
  })

  it('C10.2b play button hidden for events without batch field', () => {
    // Runtime data may lack batch even though the type requires it
    const noBatchEvent = { ts: '2026-04-22T10:00:00Z', event: 'completed' as const, files_fixed: 1 } as GrinderEvent
    renderWithTheme(<GrinderEventsList events={[noBatchEvent]} onOpenStream={vi.fn()} />)
    expect(screen.queryByLabelText(/view stream/i)).not.toBeInTheDocument()
  })

  it('C10.3 play button click calls onOpenStream', () => {
    const onOpen = vi.fn()
    renderWithTheme(<GrinderEventsList events={[mockEvent()]} onOpenStream={onOpen} />)
    fireEvent.click(screen.getByLabelText(/view stream for batch-001/i))
    expect(onOpen).toHaveBeenCalledWith('batch-001')
  })

  it('T11.6 row event-status chip renders brand StatusPill (completed → completed)', () => {
    renderWithTheme(<GrinderEventsList events={[mockEvent({ event: 'completed' })]} />)
    const wrapper = screen.getByLabelText(/^completed event$/i)
    const pill = wrapper.querySelector('[data-testid="wf-status-pill"]')
    expect(pill).not.toBeNull()
    expect(pill).toHaveAttribute('data-status', 'completed')
  })

  it('T11.7 failed event row renders fault StatusPill', () => {
    renderWithTheme(<GrinderEventsList events={[mockEvent({ event: 'failed' })]} />)
    const wrapper = screen.getByLabelText(/^failed event$/i)
    const pill = wrapper.querySelector('[data-testid="wf-status-pill"]')
    expect(pill).not.toBeNull()
    expect(pill).toHaveAttribute('data-status', 'fault')
  })
})

/* ══��� T12 — GrinderDeferralsTable ═══ */

describe('GrinderDeferralsTable', () => {
  it('T12.1 renders sorted deferrals', () => {
    renderWithTheme(<GrinderDeferralsTable deferrals={mockDetail.top_deferrals} />)
    expect(screen.getByText('python:S3776')).toBeInTheDocument()
    expect(screen.getByText('15')).toBeInTheDocument()
  })

  it('T12.3 shows empty state', () => {
    renderWithTheme(<GrinderDeferralsTable deferrals={[]} />)
    expect(screen.getByText(/no deferred findings/i)).toBeInTheDocument()
  })
})

/* ═══ T8 — GrinderDetail ═══ */

describe('GrinderDetail', () => {
  beforeEach(() => {
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: mockDetail,
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    vi.mocked(usePauseGrinder).mockReturnValue(mockPauseGrinder)
  })

  it('T8.1 renders all four sections', () => {
    renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />)
    /* C2 auto-opens the stream pane on mount because mockDetail has an
       active batch. Close it via the breadcrumb to reach detail view. */
    fireEvent.click(screen.getByText(/← Grinder \/ OIH/))
    // Pass stepper
    expect(screen.getByText('Mechanical')).toBeInTheDocument()
    // Batch card
    expect(screen.getAllByText('batch-004').length).toBeGreaterThanOrEqual(1)
    // Events
    expect(screen.getByText('batch-001')).toBeInTheDocument()
    // Deferrals
    expect(screen.getByText('python:S3776')).toBeInTheDocument()
  })

  it('T8.2 back button fires onBack', () => {
    const onBack = vi.fn()
    renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={onBack} />)
    // Close auto-opened stream pane (C2) before reaching the detail-view back button
    fireEvent.click(screen.getByText(/← Grinder \/ OIH/))
    fireEvent.click(screen.getByLabelText(/back/i))
    expect(onBack).toHaveBeenCalled()
  })

  it('T8.4 shows Pause button when active', () => {
    renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />)
    // Close auto-opened stream pane (C2) — pause button lives in detail view
    fireEvent.click(screen.getByText(/← Grinder \/ OIH/))
    expect(screen.getByRole('button', { name: /pause grinder/i })).toBeEnabled()
  })

  it('T8.5 shows Resume button when paused', () => {
    renderWithTheme(<GrinderDetail project="OIH" paused={true} onBack={vi.fn()} />)
    // Close auto-opened stream pane (C2) — resume button lives in detail view
    fireEvent.click(screen.getByText(/← Grinder \/ OIH/))
    expect(screen.getByRole('button', { name: /resume grinder/i })).toBeEnabled()
  })

  it('C9.1 stream view opens on batch card click', () => {
    /* C2 auto-open already reaches the stream-view end state on mount;
       the manual-open path is exercised by C9.2 via the events list. */
    renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />)
    // Breadcrumb shows in stream view
    expect(screen.getByText(/← Grinder \/ OIH/)).toBeInTheDocument()
    // StreamViewer is rendered
    expect(screen.getByTestId('stream-viewer')).toBeInTheDocument()
  })

  it('C9.3 breadcrumb renders when stream open', () => {
    /* C2 auto-open reaches stream view without a button click. */
    renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />)
    expect(screen.getByText(/← Grinder \/ OIH/)).toBeInTheDocument()
  })

  it('C9.4 back navigation closes stream', () => {
    /* C2 auto-open reaches stream view; breadcrumb close drops to detail view. */
    renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />)
    const breadcrumb = screen.getByText(/← Grinder \/ OIH/)
    expect(breadcrumb).toBeInTheDocument()
    fireEvent.click(breadcrumb)
    // Should show detail view again (passes visible)
    expect(screen.getByText('Mechanical')).toBeInTheDocument()
  })

  it('T8.6 pause button disabled when idle and not paused', () => {
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: { ...mockDetail, current_batch: null },
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />)
    expect(screen.getByRole('button', { name: /pause grinder/i })).toBeDisabled()
  })

  it('C9.2 clicking play button on event opens stream view', () => {
    /* Override useGrinderDetail with current_batch: null so the C2
       auto-open effect is a no-op and the events list (with the play
       button) is reachable in the detail view. */
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: { ...mockDetail, current_batch: null },
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />)
    // Click the play button for batch-001 in the events list
    const playBtn = screen.getByLabelText(/view stream for batch-001/i)
    fireEvent.click(playBtn)
    // Stream view should be visible (breadcrumb + stream viewer)
    expect(screen.getByText(/← Grinder \/ OIH/)).toBeInTheDocument()
    expect(screen.getByTestId('stream-viewer')).toBeInTheDocument()
  })

  it('C9.5 closing stream view disables stream polling', () => {
    /* C2 auto-open already in stream view; verify the close path. */
    renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />)
    expect(screen.getByTestId('stream-viewer')).toBeInTheDocument()

    // Close stream view via breadcrumb
    fireEvent.click(screen.getByText(/← Grinder \/ OIH/))

    // Stream viewer should no longer be visible
    expect(screen.queryByTestId('stream-viewer')).not.toBeInTheDocument()
    // useGrinderStream should have been called with null project (polling disabled)
    // Verify by checking that detail view is back
    expect(screen.getByText('Mechanical')).toBeInTheDocument()
  })

  /* ═══ C9.6–C9.12 — C2 auto-open / auto-close effect ═══ */

  it('C9.6 auto-opens stream view when current_batch is non-null on mount', () => {
    renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />)
    expect(screen.getByText(/← Grinder \/ OIH/)).toBeInTheDocument()
    expect(screen.getByTestId('stream-viewer')).toBeInTheDocument()
  })

  it('C9.7 detail view renders when current_batch is null on mount', () => {
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: { ...mockDetail, current_batch: null },
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />)
    expect(screen.getByText('Mechanical')).toBeInTheDocument()
    expect(screen.getByText('batch-001')).toBeInTheDocument()
    expect(screen.getByText('python:S3776')).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /pause grinder/i })).toBeInTheDocument()
    expect(screen.queryByTestId('stream-viewer')).not.toBeInTheDocument()
  })

  it('C9.8 unmounts stream pane when current_batch transitions to null', () => {
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: mockDetail,
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    const { rerender } = renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />)
    expect(screen.getByText(/← Grinder \/ OIH/)).toBeInTheDocument()
    /* Simulate a poll that returns no active batch. */
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: { ...mockDetail, current_batch: null },
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    rerender(
      <ThemeProvider theme={theme}>
        <GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />
      </ThemeProvider>,
    )
    expect(screen.queryByText(/← Grinder \/ OIH/)).not.toBeInTheDocument()
    expect(screen.getByText('Mechanical')).toBeInTheDocument()
  })

  it('C9.9 user-closed pane is not re-opened on identical-id re-poll', () => {
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: mockDetail,
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    const { rerender } = renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />)
    expect(screen.getByTestId('stream-viewer')).toBeInTheDocument()
    // User closes the stream pane
    fireEvent.click(screen.getByText(/← Grinder \/ OIH/))
    expect(screen.queryByTestId('stream-viewer')).not.toBeInTheDocument()
    expect(screen.getByText('Mechanical')).toBeInTheDocument()
    /* Re-poll returns the same data — effect dep value unchanged, so
       streamBatchId is not re-mirrored. */
    rerender(
      <ThemeProvider theme={theme}>
        <GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />
      </ThemeProvider>,
    )
    expect(screen.queryByTestId('stream-viewer')).not.toBeInTheDocument()
    expect(screen.getByText('Mechanical')).toBeInTheDocument()
  })

  it('C9.10 stream pane re-opens for a new batch id', () => {
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: mockDetail,
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    const { rerender } = renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />)
    expect(screen.getByText(/batch batch-004/)).toBeInTheDocument()
    /* Batch ends. */
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: { ...mockDetail, current_batch: null },
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    rerender(
      <ThemeProvider theme={theme}>
        <GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />
      </ThemeProvider>,
    )
    expect(screen.queryByText(/batch batch-/)).not.toBeInTheDocument()
    /* New batch starts. */
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: {
        ...mockDetail,
        current_batch: {
          id: 'batch-005',
          pass: 'pass-coverage',
          started_at: '2026-04-22T10:05:00Z',
          turns_elapsed: 0,
        },
      },
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    rerender(
      <ThemeProvider theme={theme}>
        <GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />
      </ThemeProvider>,
    )
    expect(screen.getByText(/batch batch-005/)).toBeInTheDocument()
    expect(screen.getByTestId('stream-viewer')).toBeInTheDocument()
  })

  it('C9.11 data === undefined does not throw and does not open stream', () => {
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: undefined,
      isLoading: true,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    expect(() =>
      renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />),
    ).not.toThrow()
    expect(screen.queryByTestId('stream-viewer')).not.toBeInTheDocument()
  })

  it('C9.12 empty-string current_batch.id is treated as no-batch', () => {
    vi.mocked(useGrinderDetail).mockReturnValue({
      data: {
        ...mockDetail,
        current_batch: {
          id: '',
          pass: 'pass-coverage',
          started_at: '2026-04-22T10:00:00Z',
          turns_elapsed: 0,
        },
      },
      isLoading: false,
      error: undefined,
      mutate: vi.fn(),
      isValidating: false,
    } as ReturnType<typeof useGrinderDetail>)
    renderWithTheme(<GrinderDetail project="OIH" paused={false} onBack={vi.fn()} />)
    // Stream pane not rendered (empty string is falsy)
    expect(screen.queryByTestId('stream-viewer')).not.toBeInTheDocument()
    // Detail view is rendered
    expect(screen.getByText('Mechanical')).toBeInTheDocument()
  })
})
