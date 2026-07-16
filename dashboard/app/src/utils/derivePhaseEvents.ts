import type { StreamEvent } from '../types'

/* Derive effective phase status for stream rendering (skarm-9 #1).

   The orchestrator emits BOTH `{type:'phase', status:'running'}` at
   phase start AND `{type:'phase', status:'completed'}` at phase end
   (claude-session-lib.sh:386 + 503). PhaseMarker would otherwise
   render BOTH as separate headers, leaving stale "running" headers
   visible in the scrollback.

   This helper:
     1. Suppresses superseded phase events — when a later phase event
        exists for the SAME phase name, the older one is dropped.
     2. Overrides running → completed for any phase whose latest
        event is still `running` but is followed by a phase event for
        a DIFFERENT phase (orchestrator transition without explicit
        completion event).

   Failed status is preserved verbatim — never auto-converted. */

export function derivePhaseEvents<T extends StreamEvent>(events: T[]): T[] {
  const latestIdxByPhase = new Map<string, number>()
  let lastPhaseIdx = -1
  events.forEach((e, i) => {
    if (e.type === 'phase' && typeof e.phase === 'string') {
      latestIdxByPhase.set(e.phase, i)
      lastPhaseIdx = i
    }
  })

  const out: T[] = []
  events.forEach((event, i) => {
    if (event.type !== 'phase' || typeof event.phase !== 'string') {
      out.push(event)
      return
    }
    if (latestIdxByPhase.get(event.phase) !== i) {
      return
    }
    const isRunningOrUnknown = event.status === undefined || event.status === 'running'
    if (isRunningOrUnknown && i < lastPhaseIdx) {
      out.push({ ...event, status: 'completed' } as T)
      return
    }
    out.push(event)
  })
  return out
}
