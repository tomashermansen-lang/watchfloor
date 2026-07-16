import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import type { Feature } from '../types'

vi.mock('../hooks/useFeatures', () => ({ useFeatures: vi.fn() }))
vi.mock('../hooks/useSessions', () => ({ useSessions: vi.fn() }))
vi.mock('../hooks/usePlans', () => ({ usePlans: vi.fn() }))

import { useFeatures } from '../hooks/useFeatures'
import { useSessions } from '../hooks/useSessions'
import { usePlans } from '../hooks/usePlans'
import OverviewView from '../components/OverviewView'

const mockFeature = (overrides: Partial<Feature> = {}): Feature => ({
  name: 'test-feature',
  project: 'test-project',
  project_root: '/tmp/test',
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
  ...overrides,
})

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

const swrEmpty = { isLoading: false, error: undefined, mutate: vi.fn(), isValidating: false }

describe('OverviewView — feature portfolio status pill', () => {
  beforeEach(() => {
    vi.mocked(useSessions).mockReturnValue({ data: [], ...swrEmpty } as never)
    vi.mocked(usePlans).mockReturnValue({ data: [], ...swrEmpty } as never)
  })

  /* Brand handoff §UI Primitives "Status pills" — feature portfolio
     row's status column must use the wf StatusPill so colors stay on
     the 4-status palette and the format stays consistent with the rest
     of the chrome. The pill emits data-testid="wf-status-pill" with a
     data-status attribute matching the WfStatus key. */
  it('renders a wf-status-pill with status="running" for an active feature', () => {
    vi.mocked(useFeatures).mockReturnValue({
      data: [mockFeature({ name: 'alpha', status: 'active' })],
      ...swrEmpty,
    } as never)

    renderWithTheme(<OverviewView />)

    const pills = screen.getAllByTestId('wf-status-pill')
    expect(pills.length).toBeGreaterThan(0)
    const pill = pills[0]
    expect(pill.getAttribute('data-status')).toBe('running')
    expect(pill.textContent?.toUpperCase()).toContain('ACTIVE')
  })

  it('maps each feature status to the correct wf status', () => {
    vi.mocked(useFeatures).mockReturnValue({
      data: [
        mockFeature({ name: 'a', status: 'active' }),
        mockFeature({ name: 'b', status: 'waiting' }),
        mockFeature({ name: 'c', status: 'stuck' }),
        mockFeature({ name: 'd', status: 'done' }),
      ],
      ...swrEmpty,
    } as never)

    renderWithTheme(<OverviewView />)

    const statuses = screen
      .getAllByTestId('wf-status-pill')
      .map((p) => p.getAttribute('data-status'))
    expect(statuses).toEqual(['running', 'stalled', 'fault', 'completed'])
  })

  it('KPI tiles expose data-testid="kpi-tile" with their label as data-label', () => {
    vi.mocked(useFeatures).mockReturnValue({
      data: [
        mockFeature({ name: 'a', status: 'active' }),
        mockFeature({ name: 'b', status: 'stuck' }),
      ],
      ...swrEmpty,
    } as never)

    renderWithTheme(<OverviewView />)

    const tiles = screen.getAllByTestId('kpi-tile')
    expect(tiles.length).toBe(4)
    const labels = tiles.map((t) => t.getAttribute('data-label'))
    expect(labels).toEqual(['running', 'awaiting review', 'blocked', 'shipped (this wk)'])
  })

  it('KPI tile with warn tone emits data-tone="stalled" (brand vocabulary)', () => {
    vi.mocked(useFeatures).mockReturnValue({
      data: [mockFeature({ name: 'b', status: 'stuck' })],
      ...swrEmpty,
    } as never)

    renderWithTheme(<OverviewView />)

    const blocked = screen.getAllByTestId('kpi-tile').find((t) => t.getAttribute('data-label') === 'blocked')
    expect(blocked?.getAttribute('data-tone')).toBe('stalled')
  })

  it('section panel titles render with the wfLabel brand variant', () => {
    vi.mocked(useFeatures).mockReturnValue({
      data: [mockFeature({ name: 'a', status: 'active' })],
      ...swrEmpty,
    } as never)

    renderWithTheme(<OverviewView />)

    /* All four chrome panels should adopt the brand mono UPPERCASE
       label variant. MUI emits MuiTypography-wfLabel as the class
       so we can verify without fragile fontFamily computed checks. */
    const panels = ['Feature portfolio', 'Activity · last 24h', 'Weekly throughput', 'Health']
    for (const title of panels) {
      const node = screen.getByText(title)
      expect(node.className).toMatch(/MuiTypography-wfLabel/)
    }
  })

  it('health row labels use the brand wfLabel variant', () => {
    vi.mocked(useFeatures).mockReturnValue({
      data: [mockFeature({ name: 'a', status: 'active' })],
      ...swrEmpty,
    } as never)

    renderWithTheme(<OverviewView />)

    const passRate = screen.getByText('Pass-rate')
    expect(passRate.className).toMatch(/MuiTypography-wfLabel/)
  })

  it('KPI tile with ok tone emits data-tone="completed" (brand vocabulary)', () => {
    vi.mocked(useFeatures).mockReturnValue({
      data: [mockFeature({ name: 'd', status: 'done' })],
      ...swrEmpty,
    } as never)

    renderWithTheme(<OverviewView />)

    const shipped = screen.getAllByTestId('kpi-tile').find((t) => t.getAttribute('data-label') === 'shipped (this wk)')
    expect(shipped?.getAttribute('data-tone')).toBe('completed')
  })

  it('renders the wf EmptyScope when there are no projects, sessions or features', () => {
    vi.mocked(useFeatures).mockReturnValue({ data: [], ...swrEmpty } as never)
    vi.mocked(useSessions).mockReturnValue({ data: [], ...swrEmpty } as never)
    vi.mocked(usePlans).mockReturnValue({ data: [], ...swrEmpty } as never)

    renderWithTheme(<OverviewView />)

    expect(screen.getByTestId('wf-empty-scope')).toBeInTheDocument()
    expect(screen.getByText(/the watchfloor is listening/i)).toBeInTheDocument()
    /* The KPI grid + portfolio table should not render in absolute zero
       state — the brand moment owns the canvas. */
    expect(screen.queryByText(/feature portfolio/i)).not.toBeInTheDocument()
  })

  it('keeps the regular layout when there are projects but no features', () => {
    vi.mocked(useFeatures).mockReturnValue({ data: [], ...swrEmpty } as never)
    vi.mocked(useSessions).mockReturnValue({ data: [], ...swrEmpty } as never)
    vi.mocked(usePlans).mockReturnValue({
      data: [{ project: 'OIH' }, { project: 'dotfiles' }],
      ...swrEmpty,
    } as never)

    renderWithTheme(<OverviewView />)

    expect(screen.queryByTestId('wf-empty-scope')).not.toBeInTheDocument()
    expect(screen.getByText(/feature portfolio/i)).toBeInTheDocument()
  })

  it('renders a muted pill when status is paused (outside the 4-color palette)', () => {
    vi.mocked(useFeatures).mockReturnValue({
      data: [mockFeature({ name: 'p', status: 'paused' })],
      ...swrEmpty,
    } as never)

    renderWithTheme(<OverviewView />)

    /* paused → featureToWfStatus returns null → muted StatusPill, NOT
       a plain caption. Pill shape stays consistent with the rest of
       the column; the muted token-set signals "deliberate non-state". */
    const pills = screen.getAllByTestId('wf-status-pill')
    expect(pills.length).toBe(1)
    expect(pills[0].getAttribute('data-status')).toBe('muted')
    expect(pills[0].textContent?.toUpperCase()).toContain('PAUSED')
  })
})
