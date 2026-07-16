import { describe, it, expect, vi, afterEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { useTaskForAutopilot } from '../hooks/useTaskForAutopilot'
import type { AutopilotSession, Plan, ProjectSummary } from '../types'

afterEach(() => { vi.restoreAllMocks() })

function buildPlan(featureName: string, taskIds: string[]): Plan {
  return {
    name: featureName,
    schema_version: '2.0.0',
    phases: [
      {
        name: 'phase1',
        tasks: taskIds.map((id) => ({
          id,
          name: id,
          status: 'done',
          depends: [],
        })),
      },
    ],
  } as unknown as Plan
}

function buildSummary(project: string, planDirSegment: string): ProjectSummary {
  return {
    project,
    path: '/repo/dotfiles',
    plan_dir: `/repo/dotfiles/docs/${planDirSegment}`,
    phases: 0,
    progress: 0,
    has_plan: true,
  }
}

const session: AutopilotSession = {
  task: 'plans-filter-ui',
  project: 'dotfiles',
  branch: null,
  status: 'completed',
  phases: [],
  elapsed_s: 0,
  cost: null,
  log_path: null,
  stream_path: null,
}

describe('useTaskForAutopilot — multi-plan resolution (audit-22 #1)', () => {
  it('selects the plan that contains the task when multiple plans share the project root', async () => {
    const plans: ProjectSummary[] = [
      buildSummary('monorepo-consolidation', 'DONE_Plan_monorepo-consolidation'),
      buildSummary('watchfloor-list-filters', 'DONE_Plan_watchfloor-list-filters'),
      buildSummary('Pipeline Optimization v2', 'INPROGRESS_Plan_pipeline-optimization-v2'),
    ]
    const planByDir: Record<string, Plan> = {
      'DONE_Plan_monorepo-consolidation': buildPlan('monorepo-consolidation', ['mono-task-a']),
      'DONE_Plan_watchfloor-list-filters': buildPlan('watchfloor-list-filters', ['plans-filter-ui', 'features-tab-status']),
      'INPROGRESS_Plan_pipeline-optimization-v2': buildPlan('pipeline-optimization-v2', ['p2-task']),
    }

    const fetchMock = vi.fn((url: string | URL) => {
      const u = String(url)
      if (u === '/api/plans') {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(plans) })
      }
      const dirKey = Object.keys(planByDir).find((k) => u.includes(encodeURIComponent(k)))
      if (dirKey) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(planByDir[dirKey]) })
      }
      return Promise.reject(new Error('Unexpected URL: ' + u))
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHook(() => useTaskForAutopilot(session))

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })
    expect(result.current.task?.id).toBe('plans-filter-ui')
    expect(result.current.planDir).toContain('watchfloor-list-filters')
    expect(result.current.plan?.name).toBe('watchfloor-list-filters')
    expect(result.current.projectPath).toBe('/repo/dotfiles')
  })

  it('returns task=null when no matching plan contains the task', async () => {
    const plans: ProjectSummary[] = [
      buildSummary('monorepo-consolidation', 'DONE_Plan_monorepo-consolidation'),
      buildSummary('Pipeline Optimization v2', 'INPROGRESS_Plan_pipeline-optimization-v2'),
    ]
    const planByDir: Record<string, Plan> = {
      'DONE_Plan_monorepo-consolidation': buildPlan('monorepo-consolidation', ['mono-task-a']),
      'INPROGRESS_Plan_pipeline-optimization-v2': buildPlan('pipeline-optimization-v2', ['p2-task']),
    }

    vi.stubGlobal('fetch', vi.fn((url: string | URL) => {
      const u = String(url)
      if (u === '/api/plans') {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(plans) })
      }
      const dirKey = Object.keys(planByDir).find((k) => u.includes(encodeURIComponent(k)))
      if (dirKey) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(planByDir[dirKey]) })
      }
      return Promise.reject(new Error('Unexpected URL: ' + u))
    }))

    const unknownSession: AutopilotSession = { ...session, task: 'unknown-task' }
    const { result } = renderHook(() => useTaskForAutopilot(unknownSession))

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })
    expect(result.current.task).toBeNull()
  })

  it('still resolves when the first plan whose project name matches happens to contain the task', async () => {
    const plans: ProjectSummary[] = [
      buildSummary('watchfloor-list-filters', 'DONE_Plan_watchfloor-list-filters'),
    ]
    const planByDir: Record<string, Plan> = {
      'DONE_Plan_watchfloor-list-filters': buildPlan('watchfloor-list-filters', ['plans-filter-ui']),
    }

    vi.stubGlobal('fetch', vi.fn((url: string | URL) => {
      const u = String(url)
      if (u === '/api/plans') {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(plans) })
      }
      const dirKey = Object.keys(planByDir).find((k) => u.includes(encodeURIComponent(k)))
      if (dirKey) {
        return Promise.resolve({ ok: true, json: () => Promise.resolve(planByDir[dirKey]) })
      }
      return Promise.reject(new Error('Unexpected URL: ' + u))
    }))

    const { result } = renderHook(() => useTaskForAutopilot(session))

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })
    expect(result.current.task?.id).toBe('plans-filter-ui')
  })
})
