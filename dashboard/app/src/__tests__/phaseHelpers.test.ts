import { describe, it, expect } from 'vitest'
import { phaseStatus, phaseProgress, phaseStatusWithOverlay, phaseProgressWithOverlay } from '../utils/phaseHelpers'
import type { Phase } from '../types'

function phase(statuses: string[]): Phase {
  return {
    id: 'test',
    name: 'Test Phase',
    tasks: statuses.map((s, i) => ({ id: `t${i}`, name: `Task ${i}`, status: s as Phase['tasks'][0]['status'] })),
  }
}

describe('phaseStatus', () => {
  it('returns pending for empty phase', () => {
    expect(phaseStatus({ id: 'x', name: 'x', tasks: [] })).toBe('pending')
  })

  it('returns done when all tasks done', () => {
    expect(phaseStatus(phase(['done', 'done', 'done']))).toBe('done')
  })

  it('returns failed when any task failed', () => {
    expect(phaseStatus(phase(['done', 'failed', 'pending']))).toBe('failed')
  })

  it('returns wip when any task wip', () => {
    expect(phaseStatus(phase(['done', 'wip', 'pending']))).toBe('wip')
  })

  it('returns pending when all pending', () => {
    expect(phaseStatus(phase(['pending', 'pending']))).toBe('pending')
  })
})

describe('phaseProgress', () => {
  it('returns zero for empty phase', () => {
    const result = phaseProgress({ id: 'x', name: 'x', tasks: [] })
    expect(result).toEqual({ done: 0, total: 0, pct: 0 })
  })

  it('computes correct progress', () => {
    const result = phaseProgress(phase(['done', 'done', 'pending', 'wip']))
    expect(result.done).toBe(2)
    expect(result.total).toBe(4)
    expect(result.pct).toBe(50)
  })

  it('returns 100% when all done', () => {
    const result = phaseProgress(phase(['done', 'done']))
    expect(result.pct).toBe(100)
  })
})

describe('phaseStatusWithOverlay (audit-12+13)', () => {
  it('treats overlay-marked tasks as wip when status would otherwise be pending', () => {
    const p = phase(['done', 'done', 'pending'])
    p.tasks[2].id = 'replace'
    expect(phaseStatusWithOverlay(p, new Map([['replace', 0.5]]))).toBe('wip')
  })

  it('falls through to plain phaseStatus when overlay is empty', () => {
    const p = phase(['done', 'done', 'done'])
    expect(phaseStatusWithOverlay(p, new Map())).toBe('done')
  })

  it('does not downgrade an already-wip phase', () => {
    const p = phase(['wip', 'pending', 'pending'])
    p.tasks[1].id = 'overlaid'
    expect(phaseStatusWithOverlay(p, new Map([['overlaid', 0.2]]))).toBe('wip')
  })

  it('does not override failed status', () => {
    const p = phase(['failed', 'pending'])
    p.tasks[1].id = 'overlaid'
    expect(phaseStatusWithOverlay(p, new Map([['overlaid', 0.5]]))).toBe('failed')
  })
})

describe('phaseProgressWithOverlay (audit-13)', () => {
  it('uses the per-task fraction from the overlay map (not a flat 0.5)', () => {
    const p = phase(['done', 'done', 'pending'])
    p.tasks[2].id = 'replace'
    /* 2 fully done + 0.19 for an active task at ~Team Review (3/13)
       = 2.19 / 3 = 73.0 -> 73. Per-task ratio reflects sub-phase
       progress instead of always counting the active task as 0.5. */
    expect(phaseProgressWithOverlay(p, new Map([['replace', 0.19]]))).toEqual({ done: 2, total: 3, pct: 73 })
  })

  it('counts an active task at the END of its sub-phases close to a full credit', () => {
    const p = phase(['done', 'pending'])
    p.tasks[1].id = 'late'
    /* 1 done + 0.95 active = 1.95 / 2 = 97.5 -> 98 */
    expect(phaseProgressWithOverlay(p, new Map([['late', 0.95]]))).toEqual({ done: 1, total: 2, pct: 98 })
  })

  it('matches plain phaseProgress when overlay map is empty', () => {
    const p = phase(['done', 'pending'])
    expect(phaseProgressWithOverlay(p, new Map())).toEqual({ done: 1, total: 2, pct: 50 })
  })

  it('clamps the per-task fraction into [0, 1] (defensive)', () => {
    const p = phase(['pending', 'pending'])
    p.tasks[0].id = 'a'
    p.tasks[1].id = 'b'
    /* a = 1.5 (clamped to 1), b = -0.2 (clamped to 0)
       sum = 1 / 2 = 50 */
    expect(phaseProgressWithOverlay(p, new Map([['a', 1.5], ['b', -0.2]]))).toEqual({ done: 0, total: 2, pct: 50 })
  })
})
