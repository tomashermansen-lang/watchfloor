import Box from '@mui/material/Box'
import type { Task } from '../types'
import { pv } from '../utils/cssVars'

interface SegmentedProgressProps {
  tasks: Task[]
  height?: number
  /** Minimum width in CSS pixels per segment. Defaults to 3.
     Drop to 2 for compact hero bars that need to fit ≥100
     segments in a header row without horizontal overflow. */
  minSegmentWidth?: number
  /** Gap between segments in CSS pixels. Defaults to 1px.
     Set to 0 for hero bars where the segments should read as
     a single instrument bar rather than discrete chips. */
  gap?: number
}

export default function SegmentedProgress({
  tasks,
  height = 8,
  minSegmentWidth = 3,
  gap = 1,
}: SegmentedProgressProps) {
  return (
    <Box
      data-testid="segmented-progress"
      sx={{
        display: 'flex',
        borderRadius: height / 2 + 'px',
        overflow: 'hidden',
        height,
        gap: `${gap}px`,
        bgcolor: 'background.default',
      }}
    >
      {tasks.map((task) => (
        <Box
          key={task.id}
          data-testid="segment"
          sx={{
            flex: 1,
            minWidth: minSegmentWidth,
            bgcolor: pv(`status-${task.status}`),
          }}
        />
      ))}
    </Box>
  )
}
