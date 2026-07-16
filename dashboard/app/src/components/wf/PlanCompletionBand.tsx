import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import SegmentedProgress from '../SegmentedProgress'
import { flattenTasks, computeProgressPct } from '../../utils/planMetrics'
import type { Plan, Feature } from '../../types'

/* Watchfloor plan completion band — handoff §"per-project header"
   accent strip. Sits next to the plan name and active-session
   count; carries two completion meters at a glance:
     · hero pipeline (SegmentedProgress) + N/M tasks · X%
     · feature roll-up: P/Q features · Y%  (omitted when empty)
   Both labels render in the brand wfLabel vocabulary so the
   band reads as instrument-panel chrome, not body copy. */

interface PlanCompletionBandProps {
  plan: Plan
  features: Feature[]
  /* controls-06 #1 — when true, render only the SegmentedProgress
     wrapper (the 240px bar). Numeric labels and the features
     cluster are suppressed so the parent grid can supply explicit
     sibling cells with column-aligned widths. Default false
     preserves the original cluster layout for ProjectSubviewTab. */
  barOnly?: boolean
}

export default function PlanCompletionBand({
  plan,
  features,
  barOnly = false,
}: Readonly<PlanCompletionBandProps>) {
  const tasks = flattenTasks(plan)
  const tasksTotal = tasks.length
  const tasksDone = tasks.filter((t) => t.status === 'done').length
  const tasksPct = computeProgressPct(plan)

  const featuresTotal = features.length
  const featuresDone = features.filter((f) => f.status === 'done').length
  const featuresPct = featuresTotal === 0
    ? 0
    : Math.round((featuresDone / featuresTotal) * 100)

  if (barOnly) {
    return (
      <Box style={{ width: 240 }}>
        <SegmentedProgress tasks={tasks} height={6} minSegmentWidth={2} gap={0} />
      </Box>
    )
  }

  return (
    <Box
      sx={{
        display: 'flex',
        alignItems: 'center',
        gap: 1.5,
        flexWrap: 'wrap',
      }}
    >
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.75 }}>
        {/* Operator brief: hero bar must visibly read up to 100
           tasks. 240px + minSegmentWidth=2 + gap=0 fits 100
           segments comfortably while still scaling small plans
           (each segment expands via flex). */}
        <Box style={{ width: 240 }}>
          <SegmentedProgress tasks={tasks} height={6} minSegmentWidth={2} gap={0} />
        </Box>
        <Typography variant="wfLabel" color="text.secondary">
          {tasksDone}/{tasksTotal} tasks
        </Typography>
        <Typography variant="wfLabel" sx={{ color: 'wf.signal' }}>
          {tasksPct}%
        </Typography>
      </Box>
      {featuresTotal > 0 && (
        <>
          <Box sx={{ width: '1px', height: 14, bgcolor: 'wf.steel' }} />
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.75 }}>
            <Typography variant="wfLabel" color="text.secondary">
              {featuresDone}/{featuresTotal} features
            </Typography>
            <Typography variant="wfLabel" sx={{ color: 'wf.signal' }}>
              {featuresPct}%
            </Typography>
          </Box>
        </>
      )}
    </Box>
  )
}
