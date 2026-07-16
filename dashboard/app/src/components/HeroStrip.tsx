import { useMemo } from 'react'
import Box from '@mui/material/Box'
import Paper from '@mui/material/Paper'
import Typography from '@mui/material/Typography'
import SegmentedProgress from './SegmentedProgress'
import { flattenTasks, computeProgressPct } from '../utils/planMetrics'
import { pva } from '../utils/cssVars'
import { planValidity } from '../utils/planValidity'
import PlanInvalidChip from './plan2/PlanInvalidChip'
import type { Plan, Session, Task } from '../types'

interface HeroStripProps {
  plan: Plan
  sessions: Session[]
  sessionCount: number
}

/* HeroStrip — per-project progress card. Shows plan name + completion %,
   description, segmented progress, task counts, and session count.
   Vision / Success criteria / Tech stack live in the per-project Vision
   sub-tab; plan-level docs in the sidebar / SessionPanel — none of
   that is duplicated here. */
export default function HeroStrip({ plan, sessions, sessionCount }: HeroStripProps) {
  const allTasks = flattenTasks(plan)
  const pct = computeProgressPct(plan)
  const validity = useMemo(() => planValidity(plan), [plan])

  // Cross-reference sessions with tasks: if a session is working on a branch
  // whose feature matches a task ID, treat that task as live WIP
  const { counts, liveTasks } = useMemo(() => {
    const workingFeatures = new Set(
      sessions
        .filter((s) => s.status === 'working' || s.status === 'needs_input')
        .map((s) => s.branch.split('/').pop() ?? ''),
    )

    const result: Record<string, number> = { total: allTasks.length, done: 0, wip: 0, failed: 0, pending: 0, skipped: 0 }
    const augmented: Task[] = allTasks.map((t) => {
      // Promote pending → wip if a working session matches this task
      if (t.status === 'pending' && workingFeatures.has(t.id)) {
        result.wip++
        return { ...t, status: 'wip' as const }
      }
      result[t.status] = (result[t.status] ?? 0) + 1
      return t
    })

    return { counts: result, liveTasks: augmented }
  }, [allTasks, sessions])

  return (
    <>
      <Paper
        elevation={0}
        sx={{
          bgcolor: pva('primary-main', 0.06),
          borderRadius: 1,
          p: { xs: 2, md: 3 },
        }}
      >
        <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', mb: 0.5 }}>
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, flexWrap: 'wrap' }}>
            <Typography variant="headlineSmall" component="h2">
              {plan.name}
            </Typography>
            <PlanInvalidChip validity={validity} />
          </Box>
          <Typography variant="displayMedium" component="span" sx={{ fontSize: { xs: '1.8rem', md: '2.8rem' }, lineHeight: 1 }}>
            {pct}%
          </Typography>
        </Box>

        <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', mb: 1.5 }}>
          {plan.description && (
            <Typography variant="body2" color="text.secondary" sx={{ flex: 1 }}>
              {plan.description}
            </Typography>
          )}
          <Typography variant="labelMedium" color="text.secondary" sx={{ flexShrink: 0, ml: 2 }}>
            {counts.done}/{counts.total} tasks
          </Typography>
        </Box>

        <Box sx={{ mb: 1.5 }}>
          <SegmentedProgress tasks={liveTasks} />
        </Box>

        <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center' }}>
          <Typography variant="labelSmall" color="text.secondary">
            done ({counts.done}) · wip ({counts.wip}) · pending ({counts.pending})
          </Typography>
          {sessionCount > 0 && (
            <Typography variant="labelSmall" color="text.secondary">
              {sessionCount} working
            </Typography>
          )}
        </Box>
      </Paper>
    </>
  )
}
