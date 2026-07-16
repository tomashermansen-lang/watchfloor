import { describe, it, expect } from 'vitest'
import type { Feature, ProjectSummary } from '../types'

/* Compile-time contract verification for ts-type-contracts (Phase 2 of
   watchfloor-list-filters). The act of constructing these typed literals
   is the assertion: tsc --noEmit fails if any of the five new optional
   fields are missing or mistyped. Runtime expects are pro-forma so vitest
   discovers and counts the test alongside the rest of the suite. */

describe('Feature optional fields contract', () => {
  it('accepts the three lifecycle literal-union members and undefined', () => {
    const pending: Feature['lifecycle'] = 'pending'
    const inprogress: Feature['lifecycle'] = 'inprogress'
    const done: Feature['lifecycle'] = 'done'
    const omitted: Feature['lifecycle'] = undefined
    expect(pending).toBe('pending')
    expect(inprogress).toBe('inprogress')
    expect(done).toBe('done')
    expect(omitted).toBeUndefined()
  })

  it('narrows lifecycle to the literal value inside an equality guard', () => {
    const value: Feature['lifecycle'] = 'pending'
    if (value === 'pending') {
      const narrowed: 'pending' = value
      expect(narrowed).toBe('pending')
    }
  })

  it('typed done_at accepts string, null, and undefined', () => {
    const iso: Feature['done_at'] = '2026-05-04T13:07:02Z'
    const nullVal: Feature['done_at'] = null
    const omitted: Feature['done_at'] = undefined
    expect(iso).toBe('2026-05-04T13:07:02Z')
    expect(nullVal).toBeNull()
    expect(omitted).toBeUndefined()
  })

  it('typed plan_dir narrows from string|undefined to string after a truthy guard', () => {
    const link: Feature['plan_dir'] = 'docs/INPROGRESS_Plan_x'
    if (link) {
      const narrowed: string = link
      expect(narrowed.length).toBeGreaterThan(0)
    }
  })

  it('typed plan_task_id is string|undefined', () => {
    const id: Feature['plan_task_id'] = 'ts-type-contracts'
    const omitted: Feature['plan_task_id'] = undefined
    expect(id).toBe('ts-type-contracts')
    expect(omitted).toBeUndefined()
  })
})

describe('ProjectSummary optional active_session_count contract', () => {
  it('typed active_session_count is number|undefined and ?? 0 yields number', () => {
    const present: ProjectSummary['active_session_count'] = 3
    const omitted: ProjectSummary['active_session_count'] = undefined
    const defaulted: number = omitted ?? 0
    expect(defaulted).toBe(0)
    expect(present).toBe(3)
  })
})

describe('Backwards-compatible literal construction (REQ-8 / EC-8)', () => {
  it('Feature literal without any of the four new fields still satisfies the interface', () => {
    const f: Feature = {
      name: 'test',
      project: 'p',
      project_root: '/tmp',
      phase: 'implement',
      phase_index: 1,
      total_phases: 5,
      pipeline_type: 'light',
      artifacts: [],
      sessions: [],
      status: 'active',
      stuck_info: null,
      last_activity: null,
      is_autopilot: false,
    }
    expect(f.lifecycle).toBeUndefined()
  })

  it('ProjectSummary literal without active_session_count still satisfies the interface', () => {
    const s: ProjectSummary = {
      project: 'p',
      path: '/tmp',
      phases: 0,
      progress: 0,
      has_plan: false,
    }
    expect(s.active_session_count).toBeUndefined()
  })
})
