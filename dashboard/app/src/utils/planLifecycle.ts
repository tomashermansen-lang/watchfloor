/* Plan-lifecycle helpers shared between the Plans-tab ProjectPanel
   (DashboardShell) and the per-project ProjectSubviewTab. Pure
   functions of the projects/index ProjectSummary record — no React,
   no hooks, no fetches. Lifted out of DashboardShell at cycle-6 #8
   so the per-project Pipeline / Deferred / Deviations subviews can
   render the same StatusPill + control-gate semantics the Plans
   tab uses, without DashboardShell needing to expose internals or
   the two surfaces drifting on the lifecycle predicate. */

import type { ProjectSummary } from '../types'
import type { LifecycleChip } from '../hooks/usePlanFilters'

/** REQ-32, REQ-33 — single source of truth for the lifecycle chip
   classification. Both the lifecycle filter and the StatusPill
   predicate consume this, so the pill shown on a panel always
   agrees with the chip that gates it. */
export function classifyPlan(p: ProjectSummary): LifecycleChip {
  const lifecycle = p.lifecycle ?? 'inprogress'
  const sessions = p.active_session_count ?? 0
  if (lifecycle === 'done') return 'done'
  if (lifecycle === 'pending') return 'pending'
  return sessions > 0 ? 'active' : 'open'
}

/** REQ-32, REQ-33 — pill props derived from the same `classifyPlan`
   the lifecycle filter consumes, so the pill cannot disagree with
   the chip that gates the panel (R1). */
export function statusPillProps(
  p: ProjectSummary,
): { status: 'running' | 'completed' | null; label: string } {
  const klass = classifyPlan(p)
  if (klass === 'active') return { status: 'running', label: 'active' }
  if (klass === 'done') return { status: 'completed', label: 'done' }
  if (klass === 'open') return { status: null, label: 'open' }
  return { status: null, label: 'pending' }
}
