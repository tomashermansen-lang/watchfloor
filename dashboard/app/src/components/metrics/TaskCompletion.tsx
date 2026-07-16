import { Box, Typography } from '@mui/material'
import { memo } from 'react'
import type { TaskCompletionMetrics } from '../../types'
import MetricCard from './MetricCard'

interface TaskCompletionProps {
  data: TaskCompletionMetrics
  selectedSid: string | 'all'
}

/**
 * TaskCompletion — polished version (commit 7 footer panels).
 *
 * Drops the per-session grouped bar chart and recent-task list that
 * crowded the panel before. Reference shows a tight summary:
 *   - 'Completed' label + ratio (responses / tasks)
 *   - One annotation line summarising fleet status
 */
function TaskCompletionInner({ data, selectedSid }: TaskCompletionProps) {
  const totalResponses = data.total_responses ?? 0
  const responsesBySid = data.responses_by_session ?? {}

  const filteredResponses = selectedSid !== 'all'
    ? (responsesBySid[selectedSid] ?? 0)
    : totalResponses

  const filteredTasks = selectedSid !== 'all'
    ? (data.by_session[selectedSid] ?? 0)
    : data.total

  const isEmpty = filteredResponses === 0 && filteredTasks === 0
  const completionRate = filteredTasks > 0 ? (filteredResponses / filteredTasks) * 100 : 0
  const allComplete = filteredTasks > 0 && filteredResponses >= filteredTasks

  return (
    <MetricCard title="Task Completion" isEmpty={false} emptyMessage="">
      <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5 }}>
        <Typography variant="wfLabel" color="text.secondary">
          Completed
        </Typography>
        <Typography
          variant="wfDisplay"
          data-testid="task-completion-ratio"
          sx={{
            color: allComplete ? 'status.completed' : 'wf.bone',
            fontFeatureSettings: '"tnum" 1',
          }}
        >
          {filteredResponses}{filteredTasks > 0 ? ` / ${filteredTasks}` : ''}
        </Typography>
      </Box>
      <Box sx={{ mt: 1.5 }}>
        {isEmpty ? (
          <Typography variant="wfBody" color="text.secondary">
            No tasks scheduled in this window.
          </Typography>
        ) : allComplete ? (
          <Typography variant="wfBody" color="text.secondary">
            All scheduled tasks across the fleet completed this window.
          </Typography>
        ) : filteredTasks > 0 ? (
          <Typography variant="wfBody" color="text.secondary">
            {Math.round(completionRate)}% of scheduled tasks completed —{' '}
            {filteredTasks - filteredResponses} still in flight.
          </Typography>
        ) : (
          <Typography variant="wfBody" color="text.secondary">
            {filteredResponses} response{filteredResponses === 1 ? '' : 's'} delivered.
          </Typography>
        )}
      </Box>
    </MetricCard>
  )
}

const TaskCompletion = memo(TaskCompletionInner)
export default TaskCompletion
