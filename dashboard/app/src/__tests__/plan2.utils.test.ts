import { describe, it, expect, vi } from 'vitest'
import { isPlan2, SCHEMA_MAJOR } from '../utils/planVersion'
import { planValidity } from '../utils/planValidity'
import { whereSummary } from '../utils/whereSummary'
import { resolveArtifactRef } from '../utils/artifactRefs'
import { TASK_TYPE_ICONS, TASK_TYPE_LABEL, taskTypeIcon } from '../utils/taskTypeIcons'
import BuildIcon from '@mui/icons-material/Build'
import type { Plan } from '../types'

const minimal2_0Plan: Plan = {
  schema_version: '2.0.0',
  name: 'Demo',
  vision: 'A short vision.',
  users: ['me'],
  success_criteria: [{ id: 'C1', description: 'must work' }],
  scope: { in_scope: ['x'], out_of_scope: ['y'] },
  tech_stack: ['react'],
  existing_infrastructure_to_reuse: [],
  test_targets: [{ id: 'self', path: '.' }],
  setup: {
    prerequisites: [],
    runtime_dependencies: [],
    services_to_provision: [],
    environment_verification: [],
    out_of_scope: [],
  },
  kill_criteria: [],
  design_notes: [],
  risks: [],
  phases: [],
}

describe('planVersion.ts', () => {
  it('isPlan2 returns true for 2.0.0', () => {
    expect(isPlan2({ schema_version: '2.0.0' })).toBe(true)
  })

  it('isPlan2 returns true for 2.99.0 forward-compat', () => {
    expect(isPlan2({ schema_version: '2.99.0' })).toBe(true)
  })

  it('isPlan2 returns false for 1.x', () => {
    expect(isPlan2({ schema_version: '1.0.0' })).toBe(false)
  })

  it('isPlan2 handles null gracefully', () => {
    expect(isPlan2(null)).toBe(false)
  })

  it('SCHEMA_MAJOR returns first segment', () => {
    expect(SCHEMA_MAJOR({ schema_version: '2.5.1' })).toBe('2')
    expect(SCHEMA_MAJOR({ schema_version: '1.0.0' })).toBe('1')
  })
})

describe('planValidity.ts', () => {
  it('planValidity does not call fetch', () => {
    const fetchSpy = vi.spyOn(global, 'fetch').mockImplementation(() => Promise.reject(new Error('no fetch')))
    planValidity(minimal2_0Plan)
    expect(fetchSpy).not.toHaveBeenCalled()
    fetchSpy.mockRestore()
  })

  it('valid 2.0 plan returns valid:true', () => {
    const v = planValidity(minimal2_0Plan)
    expect(v.valid).toBe(true)
    expect(v.errors).toEqual([])
  })

  it('2.0 missing vision returns invalid', () => {
    const p = { ...minimal2_0Plan } as Plan
    delete (p as Partial<Plan>).vision
    const v = planValidity(p)
    expect(v.valid).toBe(false)
    expect(v.errors.some((e) => e.includes('vision'))).toBe(true)
  })

  it('2.0 missing 7 fields caps errors at 5 with totalCount=7', () => {
    const p = { schema_version: '2.0.0', name: 'x', phases: [] } as unknown as Plan
    const v = planValidity(p)
    expect(v.valid).toBe(false)
    expect(v.errors.length).toBe(5)
    expect(v.totalCount).toBeGreaterThanOrEqual(7)
  })

  it('1.x happy path returns valid:true', () => {
    const p: Plan = { schema_version: '1.0.0', name: 'old', phases: [{ id: 'p', name: 'p', tasks: [] }] }
    const v = planValidity(p)
    expect(v.valid).toBe(true)
  })

  it('1.x missing phases returns invalid', () => {
    const p = { schema_version: '1.0.0', name: 'x' } as unknown as Plan
    expect(planValidity(p).valid).toBe(false)
  })
})

describe('whereSummary.ts', () => {
  it('returns null when block undefined', () => {
    expect(whereSummary(undefined)).toBeNull()
  })

  it('returns null when all arrays empty', () => {
    expect(whereSummary({ modify: [], create: [], delete: [] })).toBeNull()
  })

  it('formats modify only', () => {
    expect(whereSummary({ modify: ['a'] })).toBe('modify 1')
  })

  it('formats full block in modify·create·delete order', () => {
    expect(whereSummary({ modify: ['a', 'b'], create: ['c'], delete: ['d'] })).toBe('modify 2 · create 1 · delete 1')
  })

  it('order is modify create delete (regardless of input order)', () => {
    expect(whereSummary({ delete: ['a'], modify: ['b'] })).toBe('modify 1 · delete 1')
  })
})

describe('artifactRefs.ts', () => {
  it('resolveArtifactRef does not call fetch', () => {
    const fetchSpy = vi.spyOn(global, 'fetch').mockImplementation(() => Promise.reject(new Error('no fetch')))
    resolveArtifactRef({
      value: 'self:docs/foo.md',
      plan: minimal2_0Plan,
      planDir: '/work/p',
      taskId: 't1',
    })
    expect(fetchSpy).not.toHaveBeenCalled()
    fetchSpy.mockRestore()
  })

  it('resolves <id>:<path> via test_targets', () => {
    const result = resolveArtifactRef({
      value: 'self:docs/foo.md',
      plan: minimal2_0Plan,
      planDir: '/work/p',
      taskId: 't1',
    })
    expect(result.resolved).toBe(true)
    if (result.resolved) {
      expect(result.url).toContain('cwd=')
      expect(result.url).toContain('task=t1')
      expect(result.url).toContain('file=docs%2Ffoo.md')
    }
  })

  it('unknown project_id returns resolved:false', () => {
    const result = resolveArtifactRef({
      value: 'unknown:foo.md',
      plan: minimal2_0Plan,
      planDir: '/work/p',
      taskId: 't1',
    })
    expect(result.resolved).toBe(false)
    if (!result.resolved) {
      expect(result.tooltip).toContain("Unknown project 'unknown'")
    }
  })

  it('value without colon resolves via plan_dir', () => {
    const result = resolveArtifactRef({
      value: 'foo.md',
      plan: minimal2_0Plan,
      planDir: '/work/p',
      taskId: 't1',
    })
    expect(result.resolved).toBe(true)
    if (result.resolved) {
      expect(result.url).toContain('plan_dir=')
      expect(result.url).toContain('file=foo.md')
    }
  })

  it('empty test_targets returns resolved:false for id:path', () => {
    const plan = { ...minimal2_0Plan, test_targets: [] }
    const result = resolveArtifactRef({
      value: 'self:foo.md',
      plan,
      planDir: '/work/p',
      taskId: 't1',
    })
    expect(result.resolved).toBe(false)
  })
})

describe('taskTypeIcons.ts', () => {
  it('icon map covers all eight enum values', () => {
    for (const key of [
      'development', 'documentation', 'research', 'setup',
      'review', 'refactor', 'testing', 'other',
    ] as const) {
      expect(TASK_TYPE_ICONS[key]).toBeDefined()
      expect(TASK_TYPE_LABEL[key]).toBeDefined()
    }
  })

  it('unknown task_type falls back to BuildIcon', () => {
    const fn = taskTypeIcon('not-a-real-type')
    expect(fn).toBe(BuildIcon)
  })
})
