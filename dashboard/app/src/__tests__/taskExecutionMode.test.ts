import { describe, it, expect } from 'vitest'
import { isManualTask, taskExecutionMode } from '../utils/taskExecutionMode'
import type { Task } from '../types'

/* "Execution mode" is the orthogonal axis to "work kind". A task can
   be development-kind that is run as autopilot, or testing-kind that
   is run manually, etc. The mode is the third signal in the task-
   node row (after status and work-kind), so we route it through one
   helper that the UI can consume without re-doing the field checks. */

function makeTask(overrides: Partial<Task>): Task {
  return { id: 't1', name: 'Test', status: 'pending', ...overrides } as Task
}

describe('isManualTask', () => {
  it('false when autopilot flag is true', () => {
    expect(isManualTask(makeTask({ autopilot: true }))).toBe(false)
  })

  it('true when autopilot flag is missing', () => {
    expect(isManualTask(makeTask({}))).toBe(true)
  })

  it('true when autopilot flag is explicitly false', () => {
    expect(isManualTask(makeTask({ autopilot: false }))).toBe(true)
  })

  it('manualtest_scenarios is metadata — does not affect the manual classification', () => {
    /* The presence of manualtest_scenarios describes HOW to test
       manually, but the binary "is this a manual task" question is
       answered solely by the absence of the autopilot flag. */
    expect(isManualTask(makeTask({ manualtest_scenarios: ['s'] }))).toBe(true)
    expect(isManualTask(makeTask({ autopilot: true, manualtest_scenarios: ['s'] }))).toBe(false)
  })
})

describe('taskExecutionMode', () => {
  it('autopilot when autopilot flag is true', () => {
    expect(taskExecutionMode(makeTask({ autopilot: true }))).toBe('autopilot')
  })

  it('manual is the default — every non-autopilot task is manual', () => {
    expect(taskExecutionMode(makeTask({}))).toBe('manual')
    expect(taskExecutionMode(makeTask({ task_type: 'development' }))).toBe('manual')
    expect(taskExecutionMode(makeTask({ autopilot: false }))).toBe('manual')
  })
})
