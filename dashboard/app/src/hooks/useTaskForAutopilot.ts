import { useState, useEffect } from 'react'
import type { Task, Plan, ProjectSummary, AutopilotSession } from '../types'

/**
 * Looks up the matching execution plan Task for an autopilot session.
 * Fetches /api/plans to find the project, then /api/plan to find the task.
 */
export function useTaskForAutopilot(session: AutopilotSession | null): {
  task: Task | null
  plan: Plan | null
  planDir: string | null
  projectPath: string | null
  loading: boolean
} {
  const [task, setTask] = useState<Task | null>(null)
  const [plan, setPlan] = useState<Plan | null>(null)
  const [planDir, setPlanDir] = useState<string | null>(null)
  const [projectPath, setProjectPath] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)

  const sessionTask = session?.task ?? null
  const sessionProject = session?.project ?? null

  useEffect(() => {
    if (!sessionTask || !sessionProject) {
      setTask(null)
      setPlan(null)
      setPlanDir(null)
      setProjectPath(null)
      return
    }

    let cancelled = false
    setLoading(true)

    /* Audit-22 #1 - iterate ALL plans whose project/path matches
       sessionProject, not just the first. Multiple plans can share
       the same repo root (e.g. dotfiles has 6 plans across DONE_ and
       INPROGRESS_ folders); the first .find() match was deterministic
       but wrong whenever sessionTask lived in a later plan. The hook
       now resolves the plan whose phases contain sessionTask, falling
       back to clearing state only when every candidate was searched. */
    const lookup = async () => {
      try {
        const plansResp = await fetch('/api/plans')
        if (!plansResp.ok) throw new Error(`HTTP ${plansResp.status}`)
        const plans = (await plansResp.json()) as ProjectSummary[]

        const projectLower = sessionProject.toLowerCase()
        const candidates = plans.filter(
          (p) =>
            p.plan_dir &&
            (p.project.toLowerCase().startsWith(projectLower) ||
              p.path.toLowerCase().includes(projectLower)),
        )

        for (const candidate of candidates) {
          if (cancelled) return
          const planResp = await fetch(
            `/api/plan?cwd=${encodeURIComponent(candidate.plan_dir!)}`,
          )
          if (!planResp.ok) continue
          const fetchedPlan = (await planResp.json()) as Plan
          for (const phase of fetchedPlan.phases) {
            const found = phase.tasks.find((t) => t.id === sessionTask)
            if (found) {
              if (cancelled) return
              setProjectPath(candidate.path)
              setPlanDir(candidate.plan_dir!)
              setPlan(fetchedPlan)
              setTask(found)
              setLoading(false)
              return
            }
          }
        }

        if (!cancelled) {
          setTask(null)
          setPlan(null)
          setPlanDir(null)
          setProjectPath(null)
          setLoading(false)
        }
      } catch {
        if (!cancelled) {
          setTask(null)
          setPlan(null)
          setPlanDir(null)
          setProjectPath(null)
          setLoading(false)
        }
      }
    }

    lookup()

    return () => { cancelled = true }
  }, [sessionTask, sessionProject])

  return { task, plan, planDir, projectPath, loading }
}
