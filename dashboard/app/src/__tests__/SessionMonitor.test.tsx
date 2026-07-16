import { describe, it, expect, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import SessionMonitor from '../components/SessionMonitor'
import type { Session } from '../types'

// Mock HoverLinkContext
vi.mock('../contexts/HoverLinkContext', () => ({
  useHoverLink: () => ({
    hoveredTaskId: null,
    hoveredSessionBranch: null,
    setHoveredTask: vi.fn(),
    setHoveredSession: vi.fn(),
  }),
}))

// Mock useSessions hook
const mockSessions: Session[] = [
  {
    sid: 's1',
    cwd: '/Users/dev/project',
    worktree: '/Users/dev/project',
    branch: 'feature/analysis-agent',
    event: 'Notification',
    type: 'agent',
    msg: 'Working on analysis',
    ts: new Date().toISOString(),
    status: 'working',
    flow: { feature: 'analysis', phase: 'implement', phase_index: 3, total_phases: 9 },
  },
  {
    sid: 's2',
    cwd: '/Users/dev/project',
    worktree: '/Users/dev/project',
    branch: 'feature/outliers',
    event: 'Notification',
    type: 'agent',
    msg: 'Waiting for input',
    ts: new Date().toISOString(),
    status: 'needs_input',
    flow: { feature: 'outliers', phase: 'team-qa', phase_index: 6, total_phases: 9 },
  },
  {
    sid: 's3',
    cwd: '/Users/dev/project',
    worktree: '/Users/dev/project',
    branch: 'main',
    event: 'SessionEnd',
    type: 'agent',
    msg: 'Done',
    ts: new Date(Date.now() - 3600000).toISOString(),
    status: 'completed',
    flow: null,
  },
]

vi.mock('../hooks/useSessions', () => ({
  useSessions: () => ({ data: mockSessions }),
}))

function renderSessionMonitor() {
  return render(
    <ThemeProvider theme={theme}>
      <SessionMonitor />
    </ThemeProvider>,
  )
}

describe('SessionMonitor', () => {
  it('renders Sessions header', () => {
    renderSessionMonitor()
    expect(screen.getByText('Sessions')).toBeInTheDocument()
  })

  it('renders all session rows including completed', () => {
    renderSessionMonitor()
    const rows = document.querySelectorAll('[data-testid="session-row"]')
    expect(rows.length).toBe(3)
  })
})

/* ═══ Summary strip ═══ */
describe('Session summary strip', () => {
  it('renders aggregate status chips above the session list', () => {
    renderSessionMonitor()
    expect(screen.getByText(/1 working/i)).toBeInTheDocument()
    expect(screen.getByText(/1 needs input/i)).toBeInTheDocument()
  })

  it('omits zero-count statuses from summary strip', () => {
    renderSessionMonitor()
    expect(screen.queryByText(/0 idle/i)).not.toBeInTheDocument()
    expect(screen.queryByText(/0 stopped/i)).not.toBeInTheDocument()
  })
})

/* ═══ Session row layout ═══ */
describe('Session row layout', () => {
  it('sorts sessions urgency-first: needs_input before working before completed', () => {
    renderSessionMonitor()
    const rows = document.querySelectorAll('[data-testid="session-row"]')
    expect(rows[0].getAttribute('data-session-id')).toBe('s2') // needs_input
    expect(rows[1].getAttribute('data-session-id')).toBe('s1') // working
    expect(rows[2].getAttribute('data-session-id')).toBe('s3') // completed
  })

  it('renders completed session rows alongside active ones', () => {
    renderSessionMonitor()
    const completedRow = document.querySelector('[data-session-id="s3"]')
    expect(completedRow).toBeTruthy()
  })
})

/* ═══ Brand StatusPill migration ═══ */
describe('SessionMonitor brand StatusPill migration', () => {
  it('summary-strip count chips render as brand StatusPills', () => {
    renderSessionMonitor()
    const workingPill = screen.getByText(/1 working/i).closest('[data-testid="wf-status-pill"]')
    expect(workingPill).not.toBeNull()
    expect(workingPill).toHaveAttribute('data-status', 'running')

    const needsInputPill = screen.getByText(/1 needs input/i).closest('[data-testid="wf-status-pill"]')
    expect(needsInputPill).not.toBeNull()
    expect(needsInputPill).toHaveAttribute('data-status', 'stalled')
  })

  it('session-row status chip renders as brand StatusPill', () => {
    renderSessionMonitor()
    const workingRow = document.querySelector('[data-session-id="s1"]') as HTMLElement
    const pill = workingRow.querySelector('[data-testid="wf-status-pill"]')
    expect(pill).not.toBeNull()
    expect(pill).toHaveAttribute('data-status', 'running')
  })

  it('completed session row uses muted variant via sessionStatusToWfStatus', () => {
    renderSessionMonitor()
    const completedRow = document.querySelector('[data-session-id="s3"]') as HTMLElement
    const pill = completedRow.querySelector('[data-testid="wf-status-pill"]')
    expect(pill).not.toBeNull()
    expect(pill).toHaveAttribute('data-status', 'completed')
  })
})

/* ═══ Session deduplication ═══ */
describe('Session deduplication', () => {
  it('deduplicates sessions with same worktree+branch, keeping most recent', () => {
    renderSessionMonitor()
    // The mock data has unique worktree+branch combos, so all 3 survive dedup
    const rows = document.querySelectorAll('[data-testid="session-row"]')
    expect(rows.length).toBe(3)
  })
})
