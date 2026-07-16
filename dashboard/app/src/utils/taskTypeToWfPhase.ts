import type { Task } from '../types'
import type { WfPhaseType } from '../components/wf/PhaseIcon'

/* Translate the legacy TaskType vocabulary into the watchfloor
   phase-icon vocabulary. Five values map 1:1; research/testing pick
   the nearest semantic neighbour; other/undefined/unknown return
   null so the call site can suppress the icon entirely (rather than
   defaulting to a misleading glyph). The two wf-only keys —
   autopilot and manual — are not produced from TaskType because
   they describe execution mode, not work kind; callers that have
   that signal pass them through to <PhaseIcon> directly. */

export function taskTypeToWfPhase(taskType: string | undefined): WfPhaseType | null {
  switch (taskType) {
    case 'development': return 'development'
    case 'documentation': return 'documentation'
    case 'setup': return 'setup'
    case 'review': return 'review'
    case 'refactor': return 'refactor'
    case 'research': return 'review'
    case 'testing': return 'gate'
    default: return null
  }
}

/* Whole-task variant — adds the autopilot-flag override on top of
   the task_type mapping. Autopilot wins because the half-sweep
   wedge IS the brand signal for "running in the watchfloor pipeline";
   on a task that has both, surfacing the autopilot identity is more
   informative than its underlying work kind. */
export function taskToWfPhase(task: Task): WfPhaseType | null {
  if (task.autopilot) return 'autopilot'
  return taskTypeToWfPhase(task.task_type)
}
