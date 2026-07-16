import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import PermissionFriction from '../components/metrics/PermissionFriction'
import type { PermissionFrictionMetrics } from '../types'

function makeData(overrides?: Partial<PermissionFrictionMetrics>): PermissionFrictionMetrics {
  return {
    total_prompts: 0,
    by_tool: {},
    by_tool_mode: {},
    by_session: {},
    mode_distribution: {},
    blocked_durations: [],
    has_tuid_data: false,
    timeline: [],
    ...overrides,
  }
}

function renderFriction(data: PermissionFrictionMetrics, selectedSid: string | 'all' = 'all') {
  return render(
    <ThemeProvider theme={theme}>
      <PermissionFriction data={data} selectedSid={selectedSid} />
    </ThemeProvider>,
  )
}

describe('PermissionFriction polished', () => {
  it('shows zero-state headline when no prompts', () => {
    renderFriction(makeData())
    expect(screen.getByTestId('friction-prompts-count')).toHaveTextContent('0')
    expect(screen.getByText(/No permission prompts/i)).toBeInTheDocument()
  })

  it('shows non-zero count and warning annotation when prompts exist', () => {
    renderFriction(makeData({
      total_prompts: 5,
      by_tool: { Bash: 3, Edit: 2 },
    }))
    expect(screen.getByTestId('friction-prompts-count')).toHaveTextContent('5')
    expect(screen.getByText(/Most friction in/i)).toHaveTextContent(/Bash/)
  })
})
