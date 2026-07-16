import type { Session, AutopilotSession, Task } from '../types'

/* Resolve the "effective" phase progress for a task (audit-12).

   The plan-level `task.status` is updated lazily — when autopilot is
   actively running on a task, the plan often still reads
   `task.status === 'pending'`. The session.flow data (file-scan based
   in server/session_helpers.py) lags too. The autopilot session's
   `phases` array is the live, authoritative source.

   Resolution order:
     1. Autopilot phases (if any phase exists)
     2. session.flow (file-scan, lag-prone fallback)
     3. null — nothing to render

   isActive is true when autopilot is running OR the plan task is
   actively in 'wip'. The bottom-edge progress bar should render
   whenever isActive is true, regardless of task.status. */

/* Canonical pipeline length (audit-15). Autopilot's phases[] is
   emitted incrementally — only phases that have started/completed are
   observable. Using `phases.length` as the denominator while autopilot
   is still running makes BA-only-emitted look 50% complete. The full
   pipeline has 9 phases (BA, Plan, Team Review, Implement, Static
   Analysis, Manual Test, Team QA, Commit, Done — see
   featureToPhases.FULL_SLUGS); light has 8. We use 9 as the floor so
   early-pipeline progress reads as a small sliver instead of mid-bar.
   Once observed phases exceed the canonical (custom pipelines, mode
   switches), `max(observed, canonical)` lets the actual count win. */
const CANONICAL_PIPELINE_PHASES = 9

export interface EffectivePhaseProgress {
  /** Display name of the current phase (running phase if autopilot;
      session.flow.phase otherwise). */
  phase: string
  /** Number of completed phases. */
  completed: number
  /** Total phase count. */
  total: number
  /** Whether work is happening right now (drives whether the bar
      should render at all when task.status alone wouldn't). */
  isActive: boolean
}

interface Args {
  task: Task
  session?: Session
  autopilotSession?: AutopilotSession
}

export function effectivePhaseProgress({ task, session, autopilotSession }: Args): EffectivePhaseProgress | null {
  if (autopilotSession && autopilotSession.phases.length > 0) {
    const phases = autopilotSession.phases
    const completed = phases.filter((p) => p.status === 'completed').length
    const running = phases.find((p) => p.status === 'running')
    const currentPhase = running?.name
      ?? phases[completed]?.name
      ?? phases[completed - 1]?.name
      ?? ''
    const isRunning = autopilotSession.status === 'running'
    const total = isRunning
      ? Math.max(phases.length, CANONICAL_PIPELINE_PHASES)
      : phases.length
    return {
      phase: currentPhase,
      completed,
      total,
      isActive: isRunning,
    }
  }
  if (session?.flow) {
    return {
      phase: session.flow.phase,
      completed: session.flow.phase_index,
      total: session.flow.total_phases,
      isActive: task.status === 'wip',
    }
  }
  return null
}

/* Per-task autopilot fraction in the (0..1+) range (audit-15).
   Shared between TaskProgressBar and Pipeline.runningTaskProgress
   so both consumers apply the canonical floor. Returns null when
   no autopilot or no phases. Clamping is the caller's job —
   completed sessions can return >1 by design. */
export function autopilotPhaseFraction(autopilotSession?: AutopilotSession): number | null {
  if (!autopilotSession || autopilotSession.phases.length === 0) return null
  const phases = autopilotSession.phases
  const completed = phases.filter((p) => p.status === 'completed').length
  const isRunning = autopilotSession.status === 'running'
  const total = isRunning
    ? Math.max(phases.length, CANONICAL_PIPELINE_PHASES)
    : phases.length
  return (completed + 0.5) / total
}
