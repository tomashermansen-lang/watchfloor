import type { Plan, Task } from '../types'

export function flattenTasks(plan: Plan): Task[] {
  return plan.phases.flatMap((p) => p.tasks)
}

export function computeTaskCounts(plan: Plan): Record<string, number> {
  const tasks = flattenTasks(plan)
  const counts: Record<string, number> = { total: tasks.length, done: 0, wip: 0, failed: 0, pending: 0, skipped: 0 }
  for (const t of tasks) {
    counts[t.status] = (counts[t.status] ?? 0) + 1
  }
  return counts
}

export function computeProgressPct(plan: Plan): number {
  const tasks = flattenTasks(plan)
  if (tasks.length === 0) return 0
  const done = tasks.filter((t) => t.status === 'done').length
  return Math.round((done / tasks.length) * 100)
}
