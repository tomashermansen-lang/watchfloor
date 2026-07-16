import { describe, it, expect } from 'vitest'
import { flattenTasks, computeTaskCounts, computeProgressPct } from '../utils/planMetrics'
import type { Plan } from '../types'

const mockPlan: Plan = {
  schema_version: '1.0',
  name: 'Test',
  phases: [
    {
      id: 'p1',
      name: 'Phase 1',
      tasks: [
        { id: 't1', name: 'Task 1', status: 'done' },
        { id: 't2', name: 'Task 2', status: 'done' },
        { id: 't3', name: 'Task 3', status: 'wip' },
      ],
    },
    {
      id: 'p2',
      name: 'Phase 2',
      tasks: [
        { id: 't4', name: 'Task 4', status: 'pending' },
        { id: 't5', name: 'Task 5', status: 'failed' },
      ],
    },
  ],
}

describe('flattenTasks', () => {
  it('flattens tasks from all phases', () => {
    const tasks = flattenTasks(mockPlan)
    expect(tasks).toHaveLength(5)
    expect(tasks.map((t) => t.id)).toEqual(['t1', 't2', 't3', 't4', 't5'])
  })
})

describe('computeTaskCounts', () => {
  it('counts tasks by status', () => {
    const counts = computeTaskCounts(mockPlan)
    expect(counts.total).toBe(5)
    expect(counts.done).toBe(2)
    expect(counts.wip).toBe(1)
    expect(counts.pending).toBe(1)
    expect(counts.failed).toBe(1)
  })
})

describe('computeProgressPct', () => {
  it('computes done percentage', () => {
    expect(computeProgressPct(mockPlan)).toBe(40)
  })

  it('returns 0 for empty plan', () => {
    const empty: Plan = { schema_version: '1.0', name: 'E', phases: [] }
    expect(computeProgressPct(empty)).toBe(0)
  })
})
