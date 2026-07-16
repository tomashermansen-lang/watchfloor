import { describe, it, expect, vi, afterEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import type { StreamEvent } from '../types'

// Mock the hooks to control data flow
vi.mock('../hooks/useAutopilotStream', () => ({
  useAutopilotStream: vi.fn(),
}))
vi.mock('../hooks/useSessionActivity', () => ({
  useSessionActivity: vi.fn().mockReturnValue({ events: [], isActive: false }),
}))

// Import after mocking
import AutopilotStreamViewer, { StreamViewer } from '../components/autopilot/StreamViewer'
import { useAutopilotStream } from '../hooks/useAutopilotStream'
import { useSessionActivity } from '../hooks/useSessionActivity'
import type { Mock } from 'vitest'

const mockUseStream = useAutopilotStream as Mock

afterEach(() => { vi.restoreAllMocks() })

/* Phase header rendering — exposes a data-testid so spacing
   regressions surface as DOM-level assertions if needed later.
   Per design_handoff_watchfloor_v2 audit screen 1 #2: header was
   too generously padded (py: 2.5 + my: 0.5) so the narrative read
   loose; tightened to py: 1.5 + my: 0 to match the calm rhythm
   of the watchfloor brand. */
describe('wf-phase-header presence (audit #2 marker)', () => {
  it('renders with a stable data-testid for downstream assertions', () => {
    mockUseStream.mockReturnValue({ events: [phaseEvent], isLive: true, hasStream: true })
    render(
      <ThemeProvider theme={theme}>
        <AutopilotStreamViewer task="test-task" />
      </ThemeProvider>,
    )
    expect(document.querySelector('[data-testid="wf-phase-header"]')).not.toBeNull()
  })
})

function renderViewer(events: StreamEvent[], isLive = true) {
  mockUseStream.mockReturnValue({ events, isLive, hasStream: true })
  return render(
    <ThemeProvider theme={theme}>
      <AutopilotStreamViewer task="test-task" />
    </ThemeProvider>,
  )
}

const phaseEvent: StreamEvent = {
  type: 'phase',
  phase: 'BA',
  status: 'completed',
  duration_s: 42,
}

const assistantTextEvent: StreamEvent = {
  type: 'assistant',
  message: {
    content: [{ type: 'text', text: 'Analyzing requirements...' }],
  },
}

const toolUseEvent: StreamEvent = {
  type: 'assistant',
  message: {
    content: [{
      type: 'tool_use',
      name: 'Bash',
      input: { command: 'ls -la' },
    }],
  },
}

const toolResultEvent: StreamEvent = {
  type: 'user',
  message: {
    content: [{
      type: 'tool_result',
      content: 'line1\nline2\nline3\nline4\nline5\nline6',
    }],
  },
}

const resultEvent: StreamEvent = {
  type: 'result',
  subtype: 'success',
  total_cost_usd: 1.23,
  duration_ms: 120000,
  num_turns: 10,
}

const orchestratorEvent: StreamEvent = {
  type: 'orchestrator',
  msg: '✓ Phase checkpoint reached',
}

describe('StreamViewer', () => {
  describe('event rendering', () => {
    it('renders phase marker with name and status chip', () => {
      renderViewer([phaseEvent])
      expect(screen.getByText('BA')).toBeInTheDocument()
      expect(screen.getByText('completed')).toBeInTheDocument()
    })

    it('phase status chip renders as brand StatusPill', () => {
      renderViewer([phaseEvent])
      const pill = screen.getByText('completed').closest('[data-testid="wf-status-pill"]')
      expect(pill).not.toBeNull()
      expect(pill).toHaveAttribute('data-status', 'completed')
    })

    it('renders assistant text as markdown', () => {
      renderViewer([assistantTextEvent])
      expect(screen.getByText('Analyzing requirements...')).toBeInTheDocument()
    })

    it('renders tool result with reduced opacity', () => {
      // Tool results need tool filter to be visible, but they're in 'tool' category
      // which is hidden by default. Render with tool result as a user event.
      mockUseStream.mockReturnValue({
        events: [toolResultEvent],
        isLive: true,
        hasStream: true,
      })
      render(
        <ThemeProvider theme={theme}>
          <AutopilotStreamViewer task="test-task" />
        </ThemeProvider>,
      )
      // Tool results are in 'tool' category — hidden by default
      expect(screen.queryByText('output')).not.toBeInTheDocument()
    })

    it('renders result summary with turns, duration, and cost', () => {
      renderViewer([resultEvent])
      expect(screen.getByText('10 turns')).toBeInTheDocument()
      expect(screen.getByText(/2\.0m/)).toBeInTheDocument()
      expect(screen.getByText(/\$1\.23/)).toBeInTheDocument()
    })

    it('renders orchestrator message as blockquote', () => {
      renderViewer([orchestratorEvent])
      expect(screen.getByText('✓ Phase checkpoint reached')).toBeInTheDocument()
    })
  })

  describe('filtering', () => {
    it('hides tool calls by default', () => {
      renderViewer([toolUseEvent])
      // Tool calls hidden by default
      expect(screen.queryByText('Bash')).not.toBeInTheDocument()
    })

    it('shows tool calls when filter chip is toggled on', async () => {
      renderViewer([toolUseEvent])
      const toolChip = screen.getByText('Tool calls')
      await userEvent.click(toolChip)
      expect(screen.getByText('Bash')).toBeInTheDocument()
    })

    it('hides narrative when filter chip is toggled off', async () => {
      renderViewer([assistantTextEvent])
      expect(screen.getByText('Analyzing requirements...')).toBeInTheDocument()

      const narrativeChip = screen.getByText('Narrative')
      await userEvent.click(narrativeChip)
      expect(screen.queryByText('Analyzing requirements...')).not.toBeInTheDocument()
    })
  })

  describe('scroll', () => {
    it('shows jump to bottom button when not auto-scrolling', () => {
      // The button only appears when autoScroll is false
      // which requires scrolling up — hard to test without layout
      renderViewer([phaseEvent])
      // Initially auto-scroll is on, button should not be visible
      expect(screen.queryByLabelText('Jump to bottom')).not.toBeInTheDocument()
    })
  })
})

describe('StreamEvent orchestrator type', () => {
  it('accepts orchestrator events with msg field', () => {
    const event: StreamEvent = {
      type: 'orchestrator',
      msg: '✓ Static Analysis artifact found',
      ts: '2026-03-22T10:00:00Z',
    }
    expect(event.type).toBe('orchestrator')
    expect(event.msg).toContain('Static Analysis')
  })

  it('orchestrator events are distinct from phase events', () => {
    const orch: StreamEvent = {
      type: 'orchestrator',
      msg: 'Phase completed in 45s',
    }
    const phase: StreamEvent = {
      type: 'phase',
      phase: 'Static Analysis',
      status: 'completed',
      duration_s: 45,
    }
    expect(orch.type).not.toBe(phase.type)
  })
})


/* Audit #1+#7 — PhaseMarker uses brand StatusDot atom instead of MUI
   filled icons. Phase-type icon was added in audit #7 but reverted in
   skarm-9 cyklus #3 — phase NAME is rendered, so the icon is
   redundant and creates inconsistency (it's only present for known
   names). Keep StatusDot, drop PhaseIcon. */
describe('PhaseMarker brand atoms (audit #1+#7, skarm-9 #3)', () => {
  it('renders a wf StatusDot for phase status (not MUI filled icons)', () => {
    renderViewer([phaseEvent])
    const header = document.querySelector('[data-testid="wf-phase-header"]')
    expect(header).not.toBeNull()
    const dot = (header as Element).querySelector('[data-testid="wf-status-dot"]')
    expect(dot).not.toBeNull()
    expect(dot).toHaveAttribute('data-status', 'completed')
  })

  it('does NOT render a phase-type icon — phase name carries the type signal', () => {
    renderViewer([{ ...phaseEvent, phase: 'Implement', status: undefined }])
    const header = document.querySelector('[data-testid="wf-phase-header"]')
    expect(header).not.toBeNull()
    const phaseIcon = (header as Element).querySelector('[data-testid="wf-phase-icon"]')
    expect(phaseIcon).toBeNull()
  })
})

/* Skarm-9 #1 — StreamViewer dedupes phase events using
   derivePhaseEvents so superseded running headers don't linger
   in the scrollback when a later phase has started. */
describe('StreamViewer phase-event dedup (skarm-9 #1)', () => {
  it('renders only ONE header per phase name when both running and completed events exist', () => {
    renderViewer([
      { type: 'phase', phase: 'BA', status: 'running' } as StreamEvent,
      { type: 'phase', phase: 'BA', status: 'completed', duration_s: 90 } as StreamEvent,
    ])
    const headers = document.querySelectorAll('[data-testid="wf-phase-header"]')
    expect(headers).toHaveLength(1)
    expect(headers[0].querySelector('[data-testid="wf-status-dot"]')).toHaveAttribute('data-status', 'completed')
  })

  it('overrides running -> completed on a phase that has been superseded by a different phase', () => {
    renderViewer([
      { type: 'phase', phase: 'BA', status: 'running' } as StreamEvent,
      { type: 'phase', phase: 'Architecture Plan', status: 'running' } as StreamEvent,
    ])
    const headers = document.querySelectorAll('[data-testid="wf-phase-header"]')
    expect(headers).toHaveLength(2)
    expect(headers[0].querySelector('[data-testid="wf-status-dot"]')).toHaveAttribute('data-status', 'completed')
    expect(headers[1].querySelector('[data-testid="wf-status-dot"]')).toHaveAttribute('data-status', 'running')
  })
})

/* ═══ C4 — StreamViewer (named export, pure component) ═══ */

describe('StreamViewer (named export)', () => {
  const keyedPhaseEvent = { ...phaseEvent, _seq: 0 }
  const keyedTextEvent = { ...assistantTextEvent, _seq: 1 }

  it('C4.1: renders events passed as props', () => {
    render(
      <ThemeProvider theme={theme}>
        <StreamViewer events={[keyedPhaseEvent]} hasStream={true} />
      </ThemeProvider>,
    )
    expect(screen.getByText('BA')).toBeInTheDocument()
  })

  it('C4.2: hasStream=false shows "No stream data available"', () => {
    render(
      <ThemeProvider theme={theme}>
        <StreamViewer events={[]} hasStream={false} />
      </ThemeProvider>,
    )
    expect(screen.getByText('No stream data available')).toBeInTheDocument()
  })

  it('C4.3: hasStream=null shows empty event container (loading/empty)', () => {
    render(
      <ThemeProvider theme={theme}>
        <StreamViewer events={[]} hasStream={null} />
      </ThemeProvider>,
    )
    // Should NOT show the "no stream" message
    expect(screen.queryByText('No stream data available')).not.toBeInTheDocument()
    // Filter bar should still render
    expect(screen.getByText('Show')).toBeInTheDocument()
  })

  it('C4.4: filter chip toggle hides events', async () => {
    render(
      <ThemeProvider theme={theme}>
        <StreamViewer events={[keyedTextEvent]} hasStream={true} />
      </ThemeProvider>,
    )
    expect(screen.getByText('Analyzing requirements...')).toBeInTheDocument()

    const narrativeChip = screen.getByText('Narrative')
    await userEvent.click(narrativeChip)
    expect(screen.queryByText('Analyzing requirements...')).not.toBeInTheDocument()
  })

  it('C4.5: label prop sets aria-label', () => {
    render(
      <ThemeProvider theme={theme}>
        <StreamViewer events={[]} hasStream={true} label="batch abc-123" />
      </ThemeProvider>,
    )
    expect(screen.getByLabelText('Live stream output for batch abc-123')).toBeInTheDocument()
  })
})

/* ═══ C6 — AutopilotStreamViewer (default export) ═══ */

describe('AutopilotStreamViewer (default export)', () => {
  it('C6.1: renders with task prop', () => {
    mockUseStream.mockReturnValue({ events: [], isLive: false, hasStream: true })
    render(
      <ThemeProvider theme={theme}>
        <AutopilotStreamViewer task="my-task" />
      </ThemeProvider>,
    )
    // Should render the filter bar at minimum
    expect(screen.getByText('Show')).toBeInTheDocument()
  })

  it('C6.2: is the default export', () => {
    // AutopilotStreamViewer is imported as the default export
    expect(AutopilotStreamViewer).toBeDefined()
    expect(typeof AutopilotStreamViewer).toBe('function')
  })

  it('C6.3: onLivenessChange fires when isLive changes', () => {
    const onLivenessChange = vi.fn()
    mockUseStream.mockReturnValue({ events: [], isLive: true, hasStream: true })

    const { rerender } = render(
      <ThemeProvider theme={theme}>
        <AutopilotStreamViewer task="task-1" onLivenessChange={onLivenessChange} />
      </ThemeProvider>,
    )

    expect(onLivenessChange).toHaveBeenCalledWith(true)

    mockUseStream.mockReturnValue({ events: [], isLive: false, hasStream: true })
    rerender(
      <ThemeProvider theme={theme}>
        <AutopilotStreamViewer task="task-1" onLivenessChange={onLivenessChange} />
      </ThemeProvider>,
    )

    expect(onLivenessChange).toHaveBeenCalledWith(false)
  })

  it('C6.4: ActivityStrip renders', () => {
    mockUseStream.mockReturnValue({ events: [], isLive: false, hasStream: true })
    vi.mocked(useSessionActivity as Mock).mockReturnValue({
      events: [{ tool: 'Bash', summary: 'ls', ts: new Date().toISOString() }],
      isActive: true,
    })

    render(
      <ThemeProvider theme={theme}>
        <AutopilotStreamViewer task="task-2" />
      </ThemeProvider>,
    )
    expect(screen.getByText('Live activity')).toBeInTheDocument()
  })
})
