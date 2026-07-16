import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent, within, waitFor } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import type { GrinderProjectSummary } from '../types'

/* Mock the five hooks ActivityRail reads. Each test sets the hook
   return value via `vi.mocked(...).mockReturnValue(...)` — the
   beforeEach below defaults every non-grinder hook to an empty list
   so only the grinder-row paths are exercised. */
vi.mock('../hooks/useSessions', () => ({
  useSessions: vi.fn(() => ({ data: [] })),
}))
vi.mock('../hooks/useFeatures', () => ({
  useFeatures: vi.fn(() => ({ data: [] })),
}))
vi.mock('../hooks/usePlans', () => ({
  usePlans: vi.fn(() => ({ data: [] })),
}))
vi.mock('../hooks/useAutopilots', () => ({
  useAutopilots: vi.fn(() => ({ data: [] })),
}))
vi.mock('../hooks/useGrinder', () => ({
  useGrinderList: vi.fn(() => ({ data: [] })),
}))

import ActivityRail from '../components/ActivityRail'
import { useSessions } from '../hooks/useSessions'
import { useFeatures } from '../hooks/useFeatures'
import { usePlans } from '../hooks/usePlans'
import { useAutopilots } from '../hooks/useAutopilots'
import { useGrinderList } from '../hooks/useGrinder'

function renderRail() {
  return render(
    <ThemeProvider theme={theme}>
      <ActivityRail />
    </ThemeProvider>,
  )
}

const mockSummary = (overrides: Partial<GrinderProjectSummary> = {}): GrinderProjectSummary => ({
  project: 'dotfiles',
  path: '/tmp/dotfiles',
  status: 'in_progress',
  current_pass: 'pass-coverage',
  batches_completed: 1,
  batches_total: 4,
  deferrals_count: 0,
  last_event_ts: '2026-05-12T10:00:00Z',
  paused: false,
  ...overrides,
})

/* Locate the `Active Grinders` section by walking up from the header
   button to its parent <Box> (which contains both the header and the
   Collapse body). */
function getGrindersSection(): { header: HTMLElement; section: HTMLElement } {
  const header = screen.getByRole('button', { name: /active grinders/i })
  const section = header.parentElement as HTMLElement
  return { header, section }
}

beforeEach(() => {
  vi.mocked(useSessions).mockReturnValue({ data: [] } as unknown as ReturnType<typeof useSessions>)
  vi.mocked(useFeatures).mockReturnValue({ data: [] } as unknown as ReturnType<typeof useFeatures>)
  vi.mocked(usePlans).mockReturnValue({ data: [] } as unknown as ReturnType<typeof usePlans>)
  vi.mocked(useAutopilots).mockReturnValue({ data: [] } as unknown as ReturnType<typeof useAutopilots>)
  vi.mocked(useGrinderList).mockReturnValue({ data: [] } as unknown as ReturnType<typeof useGrinderList>)
})

/* ═══ Active Grinders rail — filter + subtitle ═══ */

describe('ActivityRail — Active Grinders section', () => {
  it('TP-1.1 single in_progress grinder produces one row, section count is 1', () => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: [mockSummary({ project: 'dotfiles', status: 'in_progress', current_pass: 'pass-coverage' })],
    } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    const { header, section } = getGrindersSection()
    expect(within(header).getByText('1')).toBeInTheDocument()
    expect(within(section).getByText('dotfiles')).toBeInTheDocument()
  })

  it('TP-1.2 only completed + pending grinders produce no rows, count is 0', () => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: [
        mockSummary({ project: 'dotfiles', status: 'completed' }),
        mockSummary({ project: 'OIH', status: 'pending' }),
      ],
    } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    const { header, section } = getGrindersSection()
    expect(within(header).getByText('0')).toBeInTheDocument()
    expect(within(section).getByText(/none active/i)).toBeInTheDocument()
    expect(within(section).queryByText('dotfiles')).not.toBeInTheDocument()
    expect(within(section).queryByText('OIH')).not.toBeInTheDocument()
  })

  it('TP-1.3 subtitle renders current_pass, with paused suffix when paused', () => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: [mockSummary({ project: 'dotfiles', status: 'in_progress', current_pass: 'pass-cve', paused: false })],
    } as unknown as ReturnType<typeof useGrinderList>)
    const { unmount } = renderRail()
    expect(screen.getByText('pass-cve')).toBeInTheDocument()
    unmount()

    vi.mocked(useGrinderList).mockReturnValue({
      data: [mockSummary({ project: 'dotfiles', status: 'in_progress', current_pass: 'pass-cve', paused: true })],
    } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    expect(screen.getByText('pass-cve · paused')).toBeInTheDocument()
  })

  it('TP-1.4 subtitle never contains "undefined"', () => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: [mockSummary({ project: 'dotfiles', status: 'in_progress', current_pass: null, paused: false })],
    } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    const { section } = getGrindersSection()
    expect(within(section).queryByText(/undefined/)).toBeNull()
    expect(within(section).getByText('in_progress')).toBeInTheDocument()
  })

  it('TP-1.5 subtitle never contains the literal "null"', () => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: [mockSummary({ project: 'dotfiles', status: 'in_progress', current_pass: null, paused: false })],
    } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    const { section } = getGrindersSection()
    expect(within(section).queryByText(/^null$/)).toBeNull()
  })

  it('TP-1.6 section body contains zero occurrences of the literal "running_batches"', () => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: [mockSummary({ project: 'dotfiles', status: 'in_progress' })],
    } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    const { section } = getGrindersSection()
    expect(section.textContent ?? '').not.toContain('running_batches')
  })

  it('TP-1.7 status "idle" is excluded from the active list', () => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: [mockSummary({ project: 'dotfiles', status: 'idle' as GrinderProjectSummary['status'] })],
    } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    const { header, section } = getGrindersSection()
    expect(within(header).getByText('0')).toBeInTheDocument()
    expect(within(section).queryByText('dotfiles')).not.toBeInTheDocument()
  })

  it('TP-1.8 paused + in_progress is still included; subtitle ends with " · paused"', () => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: [mockSummary({
        project: 'dotfiles',
        status: 'in_progress',
        current_pass: 'pass-mechanical',
        paused: true,
      })],
    } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    const { header, section } = getGrindersSection()
    expect(within(header).getByText('1')).toBeInTheDocument()
    expect(within(section).getByText('pass-mechanical · paused')).toBeInTheDocument()
  })

  it('TP-1.9 useGrinderList returns { data: undefined } — count 0, no crash', () => {
    vi.mocked(useGrinderList).mockReturnValue({ data: undefined } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    const { header, section } = getGrindersSection()
    expect(within(header).getByText('0')).toBeInTheDocument()
    expect(within(section).getByText(/none active/i)).toBeInTheDocument()
  })

  it('TP-1.10 useGrinderList returns empty array — count 0, placeholder', () => {
    vi.mocked(useGrinderList).mockReturnValue({ data: [] } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    const { header, section } = getGrindersSection()
    expect(within(header).getByText('0')).toBeInTheDocument()
    expect(within(section).getByText(/none active/i)).toBeInTheDocument()
  })

  it('TP-1.11 stale running_batches with status: completed is still filtered out by status', () => {
    const stale = {
      ...mockSummary({ project: 'dotfiles', status: 'completed' }),
      running_batches: 5,
    } as GrinderProjectSummary
    vi.mocked(useGrinderList).mockReturnValue({ data: [stale] } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    const { header, section } = getGrindersSection()
    expect(within(header).getByText('0')).toBeInTheDocument()
    expect(within(section).queryByText('dotfiles')).not.toBeInTheDocument()
    expect(section.textContent ?? '').not.toMatch(/5 batch/)
  })

  it('TP-1.12 stale running_batches with status: in_progress shows row but subtitle ignores stale value', () => {
    const stale = {
      ...mockSummary({
        project: 'dotfiles',
        status: 'in_progress',
        current_pass: 'pass-coverage',
        paused: false,
      }),
      running_batches: 5,
    } as GrinderProjectSummary
    vi.mocked(useGrinderList).mockReturnValue({ data: [stale] } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    const { header, section } = getGrindersSection()
    expect(within(header).getByText('1')).toBeInTheDocument()
    expect(within(section).getByText('pass-coverage')).toBeInTheDocument()
    expect(section.textContent ?? '').not.toMatch(/5 batch/)
  })

  it('TP-1.13 multiple grinders — only in_progress contribute, rows render in input order', () => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: [
        mockSummary({ project: 'alpha', status: 'in_progress', current_pass: 'pass-mechanical' }),
        mockSummary({ project: 'beta', status: 'completed' }),
        mockSummary({ project: 'gamma', status: 'in_progress', current_pass: 'pass-cve' }),
      ],
    } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    const { header, section } = getGrindersSection()
    expect(within(header).getByText('2')).toBeInTheDocument()
    const titles = within(section).getAllByText(/^(alpha|beta|gamma)$/).map((el) => el.textContent)
    expect(titles).toEqual(['alpha', 'gamma'])
  })

  it('TP-1.14 clicking the Active Grinders header collapses the section', async () => {
    vi.mocked(useGrinderList).mockReturnValue({
      data: [mockSummary({ project: 'dotfiles', status: 'in_progress' })],
    } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    const { header, section } = getGrindersSection()
    expect(header).toHaveAttribute('aria-expanded', 'true')
    expect(within(section).getByText('dotfiles')).toBeInTheDocument()
    fireEvent.click(header)
    expect(header).toHaveAttribute('aria-expanded', 'false')
    /* Collapse + unmountOnExit defers DOM removal until the
       transition ends, so wait for the row to vanish. */
    await waitFor(() => {
      expect(within(section).queryByText('dotfiles')).not.toBeInTheDocument()
    })
  })

  it('TP-1.15 other rail sections continue to render independently', () => {
    vi.mocked(useSessions).mockReturnValue({
      data: [
        {
          sid: 's1',
          cwd: '/tmp/x',
          worktree: '/tmp/x',
          branch: 'feature/x',
          event: 'Notification',
          type: 'assistant',
          msg: 'working',
          ts: '2026-05-12T10:00:00Z',
          status: 'working',
          flow: null,
        },
      ],
    } as unknown as ReturnType<typeof useSessions>)
    vi.mocked(useFeatures).mockReturnValue({
      data: [
        {
          name: 'feat-x',
          project: 'proj',
          project_root: '/tmp/proj',
          phase: 'plan',
          phase_index: 1,
          total_phases: 8,
          pipeline_type: 'full',
          artifacts: [],
          sessions: [],
          status: 'active',
        },
      ],
    } as unknown as ReturnType<typeof useFeatures>)
    vi.mocked(useAutopilots).mockReturnValue({
      data: [
        {
          task: 'task-a',
          project: 'proj',
          status: 'running',
          phases: [{ name: 'implement', status: 'running' }],
        },
      ],
    } as unknown as ReturnType<typeof useAutopilots>)
    vi.mocked(useGrinderList).mockReturnValue({
      data: [mockSummary({ project: 'dotfiles', status: 'in_progress' })],
    } as unknown as ReturnType<typeof useGrinderList>)
    renderRail()
    expect(screen.getByRole('button', { name: /active sessions/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /active plans/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /active features/i })).toBeInTheDocument()
    expect(screen.getByText('feat-x')).toBeInTheDocument()
    expect(screen.getByText('task-a')).toBeInTheDocument()
    /* Session row title is `branch.split('/').pop()` — for
       'feature/x' that yields 'x'. */
    expect(screen.getByText('x')).toBeInTheDocument()
  })
})
