import { useState, useEffect } from 'react'
import type { Feature, Plan, Task } from '../types'

export interface UseFeaturePlanTaskResult {
  task: Task | null
  plan: Plan | null
  planDir: string | null
  loading: boolean
}

/**
 * Resolves the execution-plan task for a feature using the
 * server-enriched plan_dir + plan_task_id pair set by
 * server/feature_helpers.py when the discovery loop maps a feature
 * folder to a plan task.
 *
 * Audit-22 #3 - replacement for useTaskForAutopilot in
 * FeatureDetail's autopilot delegation path. The Feature object
 * already knows which plan owns it, so the multi-plan project-name
 * heuristic in useTaskForAutopilot is unnecessary noise here. This
 * hook fails fast (no fetch) when plan_dir or plan_task_id is
 * absent.
 */
export function useFeaturePlanTask(feature: Feature): UseFeaturePlanTaskResult {
  const planDir = feature.plan_dir ?? null
  const taskId = feature.plan_task_id ?? null

  const [task, setTask] = useState<Task | null>(null)
  const [plan, setPlan] = useState<Plan | null>(null)
  const [loading, setLoading] = useState(false)

  useEffect(() => {
    if (!planDir || !taskId) {
      setTask(null)
      setPlan(null)
      setLoading(false)
      return
    }

    let cancelled = false
    setLoading(true)

    fetch(`/api/plan?cwd=${encodeURIComponent(planDir)}`)
      .then((r) => {
        if (!r.ok) throw new Error(`HTTP ${r.status}`)
        return r.json() as Promise<Plan>
      })
      .then((fetchedPlan) => {
        if (cancelled) return
        setPlan(fetchedPlan)
        for (const phase of fetchedPlan.phases) {
          const found = phase.tasks.find((t) => t.id === taskId)
          if (found) {
            setTask(found)
            setLoading(false)
            return
          }
        }
        setTask(null)
        setLoading(false)
      })
      .catch(() => {
        if (cancelled) return
        setTask(null)
        setPlan(null)
        setLoading(false)
      })

    return () => { cancelled = true }
  }, [planDir, taskId])

  return { task, plan, planDir, loading }
}
