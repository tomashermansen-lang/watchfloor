import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import TaskCompletion from '../components/metrics/TaskCompletion'
import type { TaskCompletionMetrics } from '../types'

function makeData(overrides?: Partial<TaskCompletionMetrics>): TaskCompletionMetrics {
  return {
    total: 8,
    by_session: { s1: 8 },
    tasks: [],
    rates: { s1: 5 },
    total_responses: 8,
    responses_by_session: { s1: 8 },
    ...overrides,
  }
}

function renderCompletion(data: TaskCompletionMetrics, selectedSid: string | 'all' = 'all') {
  return render(
    <ThemeProvider theme={theme}>
      <TaskCompletion data={data} selectedSid={selectedSid} />
    </ThemeProvider>,
  )
}

describe('TaskCompletion polished', () => {
  it('shows completed ratio as headline', () => {
    renderCompletion(makeData())
    expect(screen.getByTestId('task-completion-ratio')).toHaveTextContent('8 / 8')
  })

  it('shows positive annotation when all tasks complete', () => {
    renderCompletion(makeData())
    expect(screen.getByText(/All scheduled tasks/i)).toBeInTheDocument()
  })

  it('shows neutral annotation when no tasks', () => {
    renderCompletion(makeData({ total: 0, total_responses: 0 }))
    expect(screen.getByText(/No tasks scheduled/i)).toBeInTheDocument()
  })
})
