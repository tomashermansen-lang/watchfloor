import { describe, it, expect } from 'vitest'
import { featureToPhases } from '../utils/featureToPhases'
import type { Feature } from '../types'

const baseFeature: Feature = {
  name: 'x',
  project: 'p',
  project_root: '/tmp',
  phase: 'implement',
  phase_index: 3,
  total_phases: 8,
  pipeline_type: 'light',
  artifacts: [],
  sessions: [],
  status: 'active',
  stuck_info: null,
  last_activity: null,
  is_autopilot: false,
}

/* ═══ featureToPhases helper ═══

   Synthesises an AutopilotPhase[] from a Feature so the canonical
   DetailSidebar can render the brand PhaseStepper for paused /
   non-autopilot features (no per-phase duration or cost data
   available — those fields stay null and PhaseStepper renders the
   row name only). */

describe('featureToPhases', () => {
  /* Display names are the canonical short forms used by the
     autopilot stream (autopilot_helpers.py:_PHASE_*). Keeping one
     vocabulary across paused and live features means the same
     PhaseStepper rail reads the same in both states — paritet. */
  it('FTP-1: light pipeline renders 8 phases with canonical short names', () => {
    const phases = featureToPhases({ ...baseFeature, pipeline_type: 'light', phase_index: 0, total_phases: 8 })
    expect(phases).toHaveLength(8)
    const names = phases.map((p) => p.name)
    expect(names).toEqual([
      'BA',
      'Plan',
      'Review',
      'Implement',
      'Static Analysis',
      'QA',
      'Commit',
      'Done',
    ])
  })

  it('FTP-2: full pipeline renders 9 phases with canonical short names', () => {
    const phases = featureToPhases({ ...baseFeature, pipeline_type: 'full', phase_index: 0, total_phases: 9 })
    expect(phases).toHaveLength(9)
    expect(phases.map((p) => p.name)).toEqual([
      'BA',
      'Plan',
      'Team Review',
      'Implement',
      'Static Analysis',
      'Manual Test',
      'Team QA',
      'Commit',
      'Done',
    ])
  })

  it('FTP-3: phases before phase_index are completed, current is running, rest pending', () => {
    const phases = featureToPhases({ ...baseFeature, pipeline_type: 'light', phase_index: 2, total_phases: 8 })
    expect(phases.map((p) => p.status)).toEqual([
      'completed',
      'completed',
      'running',
      'pending',
      'pending',
      'pending',
      'pending',
      'pending',
    ])
  })

  it('FTP-4: feature.status="done" marks every phase completed regardless of phase_index', () => {
    const phases = featureToPhases({ ...baseFeature, status: 'done', phase_index: 2, total_phases: 8, pipeline_type: 'light' })
    expect(phases.every((p) => p.status === 'completed')).toBe(true)
  })

  it('FTP-5: phase_index >= total_phases marks every phase completed', () => {
    const phases = featureToPhases({ ...baseFeature, phase_index: 8, total_phases: 8, pipeline_type: 'light' })
    expect(phases.every((p) => p.status === 'completed')).toBe(true)
  })

  it('FTP-6: duration_s, cost, artifact are null (no per-phase metadata for non-autopilot features)', () => {
    const phases = featureToPhases({ ...baseFeature, phase_index: 1, total_phases: 8, pipeline_type: 'light' })
    for (const p of phases) {
      expect(p.duration_s).toBeNull()
      expect(p.cost).toBeNull()
      expect(p.artifact).toBeNull()
    }
  })
})
