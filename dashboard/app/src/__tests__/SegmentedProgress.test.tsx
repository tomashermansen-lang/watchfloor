import { describe, it, expect } from 'vitest'
import { render } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import SegmentedProgress from '../components/SegmentedProgress'
import type { Task } from '../types'

function task(id: string, status: string): Task {
  return { id, name: id, status: status as Task['status'] }
}

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

describe('SegmentedProgress', () => {
  it('renders a segment for each task', () => {
    const { container } = renderWithTheme(
      <SegmentedProgress tasks={[task('a', 'done'), task('b', 'wip'), task('c', 'pending')]} />,
    )
    const segments = container.querySelectorAll('[data-testid="segment"]')
    expect(segments.length).toBe(3)
  })

  it('renders nothing for empty tasks', () => {
    const { container } = renderWithTheme(<SegmentedProgress tasks={[]} />)
    const bar = container.querySelector('[data-testid="segmented-progress"]')
    expect(bar).toBeInTheDocument()
  })

  it('uses custom height', () => {
    const { container } = renderWithTheme(
      <SegmentedProgress tasks={[task('a', 'done')]} height={12} />,
    )
    const bar = container.querySelector('[data-testid="segmented-progress"]')
    expect(bar).toBeInTheDocument()
  })
})
