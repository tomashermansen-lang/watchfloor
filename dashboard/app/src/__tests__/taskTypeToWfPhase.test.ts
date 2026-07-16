import { describe, it, expect } from 'vitest'
import { taskTypeToWfPhase, taskToWfPhase } from '../utils/taskTypeToWfPhase'
import type { Task } from '../types'

/* The legacy TaskType vocab (development, documentation, research,
   setup, review, refactor, testing, other) is the source of truth in
   plan YAMLs today. The wf phase-icon set has its own 8 keys, only
   five of which match 1:1. The remaining three (research, testing,
   other) plus undefined need a sensible fallback so existing plans
   keep rendering without a data migration. */

describe('taskTypeToWfPhase', () => {
  it('1:1 mappings preserve semantics', () => {
    expect(taskTypeToWfPhase('development')).toBe('development')
    expect(taskTypeToWfPhase('documentation')).toBe('documentation')
    expect(taskTypeToWfPhase('setup')).toBe('setup')
    expect(taskTypeToWfPhase('review')).toBe('review')
    expect(taskTypeToWfPhase('refactor')).toBe('refactor')
  })

  it('research → review (closest semantic match — investigation work)', () => {
    expect(taskTypeToWfPhase('research')).toBe('review')
  })

  it('testing → gate (testing IS the quality gate)', () => {
    expect(taskTypeToWfPhase('testing')).toBe('gate')
  })

  it('other → null (no icon — operator hasn\'t classified the work yet)', () => {
    expect(taskTypeToWfPhase('other')).toBeNull()
  })

  it('undefined → null', () => {
    expect(taskTypeToWfPhase(undefined)).toBeNull()
  })

  it('unknown values → null (defensive — never throws)', () => {
    expect(taskTypeToWfPhase('whatever')).toBeNull()
    expect(taskTypeToWfPhase('')).toBeNull()
  })
})

/* taskToWfPhase reads the whole Task (autopilot flag + task_type) and
   picks the visually most informative icon. Autopilot wins over
   task_type because the radar-derived autopilot glyph IS the brand
   signal for "running in watchfloor pipeline" — when both signals
   are present the autopilot identity is the more useful one to surface. */
function makeTask(overrides: Partial<Task>): Task {
  return {
    id: 't1',
    name: 'Test',
    status: 'pending',
    ...overrides,
  } as Task
}

describe('taskToWfPhase (full-task variant)', () => {
  it('autopilot=true overrides task_type → autopilot', () => {
    expect(taskToWfPhase(makeTask({ autopilot: true, task_type: 'development' }))).toBe('autopilot')
    expect(taskToWfPhase(makeTask({ autopilot: true, task_type: 'review' }))).toBe('autopilot')
    expect(taskToWfPhase(makeTask({ autopilot: true }))).toBe('autopilot')
  })

  it('autopilot=false falls back to task_type mapping', () => {
    expect(taskToWfPhase(makeTask({ autopilot: false, task_type: 'development' }))).toBe('development')
    expect(taskToWfPhase(makeTask({ autopilot: false, task_type: 'testing' }))).toBe('gate')
  })

  it('autopilot undefined falls back to task_type mapping', () => {
    expect(taskToWfPhase(makeTask({ task_type: 'refactor' }))).toBe('refactor')
  })

  it('no autopilot + no task_type → null (no icon)', () => {
    expect(taskToWfPhase(makeTask({}))).toBeNull()
  })
})
