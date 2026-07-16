import { describe, it, expect } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import ToolUsage from '../components/metrics/ToolUsage'
import type { ToolUsageMetrics } from '../types'

function makeData(overrides?: Partial<ToolUsageMetrics>): ToolUsageMetrics {
  return {
    by_tool: { Bash: 167, Read: 141, Grep: 96, Edit: 64, Write: 52 },
    by_session: { s1: { count: 167, rate: 12 } },
    most_used: 'Bash',
    total: 520,
    ...overrides,
  }
}

function renderToolUsage(data: ToolUsageMetrics, selectedSid: string | 'all' = 'all') {
  return render(
    <ThemeProvider theme={theme}>
      <ToolUsage data={data} selectedSid={selectedSid} />
    </ThemeProvider>,
  )
}

describe('ToolUsage polished', () => {
  it('renders one row per tool with name, count, bar, and sparkline', () => {
    renderToolUsage(makeData())
    const list = screen.getByTestId('tool-usage-list')
    const rows = within(list).getAllByTestId('tool-usage-row')
    expect(rows).toHaveLength(5)
    expect(within(rows[0]).getByText('Bash')).toBeInTheDocument()
    expect(within(rows[0]).getByText('167')).toBeInTheDocument()
    rows.forEach((row) => {
      expect(row.querySelector('svg')).toBeTruthy()
    })
  })

  it('shows empty-state message when there are no tools', () => {
    renderToolUsage(makeData({ by_tool: {}, total: 0 }))
    expect(screen.getByText(/No tool usage data/i)).toBeInTheDocument()
  })

  it('sorts rows by count descending', () => {
    renderToolUsage(makeData())
    const list = screen.getByTestId('tool-usage-list')
    const rows = within(list).getAllByTestId('tool-usage-row')
    const counts = rows.map((row) => Number(row.getAttribute('data-count')))
    const sorted = [...counts].sort((a, b) => b - a)
    expect(counts).toEqual(sorted)
  })

  /* ─── Watchfloor brand alignment ──────────────────────────────────── */

  it('(brand) tool name + count cells use JetBrains Mono per data-table spec', () => {
    /* Handoff §Typography: data tables, log lines, timestamps render
       in JetBrains Mono. Tool name labels and tabular counts are
       data cells, not prose — locking them to JBM keeps the
       ToolUsage row reading like an instrument readout, not a UI list. */
    renderToolUsage(makeData())
    const list = screen.getByTestId('tool-usage-list')
    const rows = within(list).getAllByTestId('tool-usage-row')
    const nameCell = within(rows[0]).getByText('Bash')
    const countCell = within(rows[0]).getByText('167')
    expect(window.getComputedStyle(nameCell).fontFamily).toMatch(/JetBrains Mono/)
    expect(window.getComputedStyle(countCell).fontFamily).toMatch(/JetBrains Mono/)
  })
})
