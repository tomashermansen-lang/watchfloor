import type { WfStatus } from '../components/wf/StatusDot'
import type { TaskStatus, SessionStatus, GrinderPassStatus, GrinderEventType } from '../types'

/* /api/features uses the lifecycle vocabulary { active, waiting,
   stuck, paused, done }. The four watchfloor product-status colors
   { running, completed, stalled, fault } cover four of those — the
   fifth, "paused", is intentionally outside the brand palette: it's
   a deliberate non-state and renders as a muted grey instead of a
   live indicator. Returning null lets the caller render that grey
   fallback without overloading WfStatus. */
export function featureToWfStatus(featureStatus: string): WfStatus | null {
  switch (featureStatus) {
    case 'active': return 'running'
    case 'waiting': return 'stalled'
    case 'stuck': return 'fault'
    case 'done': return 'completed'
    default: return null
  }
}

/* ActivityRail's RailRow already abstracts status into a 5-state
   "tone" vocabulary. Translate it once here so every consumer of
   that rail (sessions, plans, grinders) inherits the brand glow. */
export type RailTone = 'info' | 'warning' | 'error' | 'success' | 'muted'
export function toneToWfStatus(tone: RailTone): WfStatus | null {
  switch (tone) {
    case 'info': return 'running'
    case 'warning': return 'stalled'
    case 'error': return 'fault'
    case 'success': return 'completed'
    case 'muted': return null
  }
}

/* /api/autopilots uses { running, completed, failed, stopped }.
   isAutopilotActive is the source-of-truth predicate for the
   ACTIVE PLANS section — only running plans belong there. The
   handoff §three-tier rail caps the section at ~6 entries with a
   "+N completed today →" link below; that link is a later step. */
export function isAutopilotActive(status: string): boolean {
  return status === 'running'
}

/* Plan task lifecycle uses { pending, wip, done, failed, skipped, blocked }.
   Same wf 4-color palette + muted for the two intentional non-states
   (pending = hasn't started yet; skipped = deliberately not run). */
export function taskStatusToWfStatus(status: TaskStatus): WfStatus | null {
  switch (status) {
    case 'wip': return 'running'
    case 'done': return 'completed'
    case 'blocked': return 'stalled'
    case 'failed': return 'fault'
    case 'pending':
    case 'skipped':
      return null
  }
}

/* Session lifecycle: working/needs_input/idle/completed/stopped/stale/closed.
   stale = the session hasn't reported in too long — operationally a
   fault signal (something needs attention). idle/stopped/closed are
   intentional non-states → null (muted pill). */
export function sessionStatusToWfStatus(status: SessionStatus): WfStatus | null {
  switch (status) {
    case 'working': return 'running'
    case 'needs_input': return 'stalled'
    case 'completed': return 'completed'
    case 'stale': return 'fault'
    case 'idle':
    case 'stopped':
    case 'closed':
      return null
  }
}

/* Grinder pass lifecycle: pending/in_progress/completed/failed (+ 'idle'
   on the project-summary row). pending/idle render as muted — no work
   has happened yet, so a colored pill would over-state the signal. */
export function grinderPassStatusToWfStatus(
  status: GrinderPassStatus | 'idle',
): WfStatus | null {
  switch (status) {
    case 'in_progress': return 'running'
    case 'completed': return 'completed'
    case 'failed': return 'fault'
    case 'pending':
    case 'idle':
      return null
  }
}

/* Grinder event lifecycle. resumed maps to running (work resumed).
   abandoned and deferred both indicate a non-success terminal — abandoned
   is a hard fault, deferred is a soft stalled (waiting for human review).
   paused is a deliberate non-state → muted. */
export function grinderEventToWfStatus(event: GrinderEventType): WfStatus | null {
  switch (event) {
    case 'started':
    case 'resumed':
      return 'running'
    case 'completed': return 'completed'
    case 'failed':
    case 'abandoned':
      return 'fault'
    case 'deferred': return 'stalled'
    case 'paused': return null
  }
}

export function autopilotToTone(status: string): RailTone {
  switch (status) {
    case 'running': return 'info'
    case 'completed': return 'success'
    case 'failed': return 'error'
    case 'stopped': return 'muted'
    default: return 'info'
  }
}
