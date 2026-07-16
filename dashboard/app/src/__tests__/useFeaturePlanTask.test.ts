import { describe, it, expect, vi, afterEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { useFeaturePlanTask } from '../hooks/useFeaturePlanTask'
import type { Feature, Plan } from '../types'

afterEach(() => { vi.restoreAllMocks() })

function buildPlan(featureName: string, taskIds: string[]): Plan {
  return {
    name: featureName,
    schema_version: '2.0.0',
    phases: [
      {
        name: 'phase1',
        tasks: taskIds.map((id) => ({ id, name: id, status: 'done', depends: [] })),
      },
    ],
  } as unknown as Plan
}

function buildFeature(overrides: Partial<Feature> = {}): Feature {
  return {
    name: 'plans-filter-ui',
    project: 'dotfiles',
    project_root: '/repo/dotfiles',
    phase: 'done',
    phase_index: 7,
    total_phases: 8,
    pipeline_type: 'full',
    artifacts: [],
    sessions: [],
    status: 'done',
    stuck_info: null,
    last_activity: null,
    is_autopilot: true,
    plan_dir: '/repo/dotfiles/docs/DONE_Plan_watchfloor-list-filters',
    plan_task_id: 'plans-filter-ui',
    ...overrides,
  }
}

describe('useFeaturePlanTask (audit-22 #3)', () => {
  it('resolves task by feature.plan_dir + plan_task_id', async () => {
    const plan = buildPlan('watchfloor-list-filters', ['plans-filter-ui', 'features-tab-status'])
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve(plan),
    }))

    const { result } = renderHook(() => useFeaturePlanTask(buildFeature()))

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })
    expect(result.current.task?.id).toBe('plans-filter-ui')
    expect(result.current.plan?.name).toBe('watchfloor-list-filters')
    expect(result.current.planDir).toBe('/repo/dotfiles/docs/DONE_Plan_watchfloor-list-filters')
  })

  it('does not fetch when feature.plan_dir is missing', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHook(() =>
      useFeaturePlanTask(buildFeature({ plan_dir: undefined })),
    )

    await new Promise((r) => setTimeout(r, 50))
    expect(fetchMock).not.toHaveBeenCalled()
    expect(result.current.task).toBeNull()
    expect(result.current.planDir).toBeNull()
    expect(result.current.loading).toBe(false)
  })

  it('does not fetch when feature.plan_task_id is missing', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHook(() =>
      useFeaturePlanTask(buildFeature({ plan_task_id: undefined })),
    )

    await new Promise((r) => setTimeout(r, 50))
    expect(fetchMock).not.toHaveBeenCalled()
    expect(result.current.task).toBeNull()
  })

  it('returns task=null when plan does not contain the task id', async () => {
    const plan = buildPlan('watchfloor-list-filters', ['other-task-only'])
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve(plan),
    }))

    const { result } = renderHook(() => useFeaturePlanTask(buildFeature()))

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })
    expect(result.current.task).toBeNull()
    expect(result.current.plan?.name).toBe('watchfloor-list-filters')
  })

  it('returns task=null on fetch failure', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('network')))

    const { result } = renderHook(() => useFeaturePlanTask(buildFeature()))

    await waitFor(() => {
      expect(result.current.loading).toBe(false)
    })
    expect(result.current.task).toBeNull()
    expect(result.current.plan).toBeNull()
  })
})
