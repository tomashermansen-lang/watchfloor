import type { AutopilotPhase, AutopilotPhaseStatus, Feature } from '../types'

/* Synthesise an AutopilotPhase[] from a Feature so the canonical
   DetailSidebar can render the brand PhaseStepper for paused /
   non-autopilot features. The Feature shape carries no per-phase
   duration or cost data (only `phase_index` + `total_phases` +
   `pipeline_type` + `status`) — those fields therefore land as
   null and PhaseStepper degrades the meta line away gracefully.

   Status mapping rules:
     - feature.status === 'done'  → every phase 'completed'
     - phase_index >= total_phases → every phase 'completed' (past last gate)
     - otherwise idx < phase_index → 'completed'; idx === phase_index
       → 'running' (the wf 'currently here' state, even when the
       feature itself is paused — there is no canonical paused-phase
       indicator, and 'running' is the closest match: pulse implies
       "this is the next-actionable row"); idx > phase_index →
       'pending'. */

const FULL_SLUGS = [
  'ba',
  'plan',
  'team-review',
  'implement',
  'static-analysis',
  'manualtest',
  'team-qa',
  'commit',
  'done',
] as const

const LIGHT_SLUGS = [
  'ba',
  'plan',
  'review',
  'implement',
  'static-analysis',
  'qa',
  'commit',
  'done',
] as const

/* Canonical short forms — must match autopilot_helpers.py
   _PHASE_* constants so the PhaseStepper rail reads identically
   for paused (synthesised here) and live (parsed from autopilot
   stream) features. Single source of vocabulary = no divergence
   between the two states of the same feature view. */
const PHASE_DISPLAY: Record<string, string> = {
  ba: 'BA',
  plan: 'Plan',
  'team-review': 'Team Review',
  review: 'Review',
  implement: 'Implement',
  'static-analysis': 'Static Analysis',
  manualtest: 'Manual Test',
  'team-qa': 'Team QA',
  qa: 'QA',
  commit: 'Commit',
  done: 'Done',
}

type FeatureLike = Pick<Feature, 'pipeline_type' | 'phase_index' | 'total_phases' | 'status'>

export function featureToPhases(feature: FeatureLike): AutopilotPhase[] {
  const slugs = feature.pipeline_type === 'light' ? LIGHT_SLUGS : FULL_SLUGS
  const slice = slugs.slice(0, feature.total_phases)
  const isDone = feature.status === 'done'
  const isPastEnd = feature.phase_index >= feature.total_phases

  return slice.map((slug, idx) => {
    let status: AutopilotPhaseStatus
    if (isDone || isPastEnd || idx < feature.phase_index) status = 'completed'
    else if (idx === feature.phase_index) status = 'running'
    else status = 'pending'

    return {
      name: PHASE_DISPLAY[slug] ?? slug,
      status,
      duration_s: null,
      cost: null,
      artifact: null,
      input_tokens: null,
      cache_creation_tokens: null,
      cache_read_tokens: null,
      output_tokens: null,
      num_turns: null,
      started_at: null,
      ended_at: null,
    }
  })
}
