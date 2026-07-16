import type { Task } from '../types'

/* Execution mode = the orthogonal axis to work-kind. A task is one
   of two modes:
     'autopilot' — task.autopilot flag is true (any pipeline mode)
     'manual'    — every other task; manual is the DEFAULT, autopilot
                   is the exception. Operators read absence of the
                   radar as "this needs hands-on work".

   manualtest_scenarios / manual_test are still relevant data fields
   (they describe HOW to test manually) but they don't gate the
   indicator — the indicator's job is to answer "autopilot or not?"
   for every task, every time. */

export function isManualTask(task: Task): boolean {
  return !task.autopilot
}

export type ExecutionMode = 'autopilot' | 'manual'

export function taskExecutionMode(task: Task): ExecutionMode {
  return task.autopilot ? 'autopilot' : 'manual'
}
