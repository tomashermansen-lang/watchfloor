import type { Phase, TaskStatus } from '../types'

export function phaseStatus(phase: Phase): TaskStatus {
  const t = phase.tasks
  if (t.length === 0) return 'pending'
  if (t.every((x) => x.status === 'done')) return 'done'
  if (t.some((x) => x.status === 'failed')) return 'failed'
  if (t.some((x) => x.status === 'wip')) return 'wip'
  return 'pending'
}

export function phaseProgress(phase: Phase): { done: number; total: number; pct: number } {
  const total = phase.tasks.length
  const done = phase.tasks.filter((t) => t.status === 'done').length
  return { done, total, pct: total > 0 ? Math.round((done / total) * 100) : 0 }
}

/* Overlay-aware variants (audit-12+13): take a Map<taskId, fraction>
   where the fraction (0..1) is the task's own sub-phase progress
   ratio. Overlay-marked tasks are treated as actively-running for
   status purposes (pending → wip), and contribute their fraction to
   the parent phase's progress total. The overlay never masks failed
   and never downgrades done. */

export type OverlayProgress = ReadonlyMap<string, number>

function clamp01(v: number): number {
  if (v < 0) return 0
  if (v > 1) return 1
  return v
}

export function phaseStatusWithOverlay(phase: Phase, overlay: OverlayProgress): TaskStatus {
  if (overlay.size === 0) return phaseStatus(phase)
  const t = phase.tasks
  if (t.length === 0) return 'pending'
  if (t.some((x) => x.status === 'failed')) return 'failed'
  if (t.every((x) => x.status === 'done')) return 'done'
  const anyEffectiveWip = t.some((x) => x.status === 'wip' || overlay.has(x.id))
  if (anyEffectiveWip) return 'wip'
  return 'pending'
}

export function phaseProgressWithOverlay(phase: Phase, overlay: OverlayProgress): { done: number; total: number; pct: number } {
  const total = phase.tasks.length
  if (total === 0) return { done: 0, total: 0, pct: 0 }
  const done = phase.tasks.filter((t) => t.status === 'done').length
  /* Each overlay-marked task contributes its actual sub-phase
     fraction (0..1) — so the parent phase aggregate reflects the
     real depth of work, not a flat 0.5-per-active-task. */
  let fractional = done
  for (const t of phase.tasks) {
    if (t.status === 'done' || t.status === 'failed') continue
    const ratio = overlay.get(t.id)
    if (ratio !== undefined) fractional += clamp01(ratio)
  }
  return { done, total, pct: Math.round((fractional / total) * 100) }
}
