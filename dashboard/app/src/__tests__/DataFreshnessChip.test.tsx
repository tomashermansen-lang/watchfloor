import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import DataFreshnessChip from '../components/DataFreshnessChip'

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

describe('DataFreshnessChip', () => {
  beforeEach(() => { vi.useFakeTimers() })
  afterEach(() => { vi.useRealTimers() })

  it('shows Connecting when lastFetchTime is null', () => {
    renderWithTheme(<DataFreshnessChip lastFetchTime={null} isTabVisible={true} />)
    expect(screen.getByText(/connecting/i)).toBeInTheDocument()
  })

  it('shows Paused when tab is not visible', () => {
    const now = Date.now()
    vi.setSystemTime(now)
    renderWithTheme(<DataFreshnessChip lastFetchTime={now} isTabVisible={false} />)
    expect(screen.getByText(/paused/i)).toBeInTheDocument()
  })

  it('shows just the elapsed time when data is fresh — LIVE label is on the pill next to it', () => {
    const now = Date.now()
    vi.setSystemTime(now)
    renderWithTheme(<DataFreshnessChip lastFetchTime={now - 3000} isTabVisible={true} />)
    /* Fresh state has no "live" prefix any more — the LIVE pill in
       the title bar carries that signal. The freshness chip is just
       the timestamp ("3s ago" / "now") in mono fog. */
    expect(screen.queryByText(/live/i)).toBeNull()
    expect(screen.getByText(/(ago|now)/i)).toBeInTheDocument()
  })

  it('shows Stale when data is old', () => {
    const now = Date.now()
    vi.setSystemTime(now)
    renderWithTheme(<DataFreshnessChip lastFetchTime={now - 35000} isTabVisible={true} />)
    expect(screen.getByText(/stale/i)).toBeInTheDocument()
  })
})
