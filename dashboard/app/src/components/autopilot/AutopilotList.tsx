import { useMemo } from 'react'
import Box from '@mui/material/Box'
import Skeleton from '@mui/material/Skeleton'
import Stack from '@mui/material/Stack'
import Typography from '@mui/material/Typography'
import type { AutopilotSession, AutopilotSessionStatus } from '../../types'
import AutopilotCard from './AutopilotCard'

const STATUS_SORT_ORDER: Record<AutopilotSessionStatus, number> = {
  running: 0,
  failed: 1,
  completed: 2,
}

interface AutopilotListProps {
  sessions: AutopilotSession[] | undefined
  isLoading: boolean
  selectedTask: string | null
  onSelectTask: (task: string) => void
}

export default function AutopilotList({ sessions, isLoading, selectedTask, onSelectTask }: AutopilotListProps) {
  const sorted = useMemo(() => {
    if (!sessions) return []
    return [...sessions].sort((a, b) => STATUS_SORT_ORDER[a.status] - STATUS_SORT_ORDER[b.status])
  }, [sessions])

  if (isLoading && !sessions) {
    return (
      <Stack spacing={1.5} sx={{ p: 1.5 }}>
        <Skeleton variant="rectangular" height={80} sx={{ borderRadius: 1 }} />
        <Skeleton variant="rectangular" height={80} sx={{ borderRadius: 1 }} />
        <Skeleton variant="rectangular" height={80} sx={{ borderRadius: 1 }} />
      </Stack>
    )
  }

  if (!sorted.length) {
    return (
      <Box sx={{ display: 'flex', flexDirection: 'column', alignItems: 'center', justifyContent: 'center', height: '100%', p: 3 }}>
        <Typography variant="body1" color="text.secondary" sx={{ fontWeight: 500 }}>
          No autopilot sessions running.
        </Typography>
        <Typography variant="caption" color="text.secondary" sx={{ mt: 1 }}>
          Start one with: bash ~/.claude/tools/autopilot.sh &lt;task&gt;
        </Typography>
      </Box>
    )
  }

  return (
    <Box
      role="listbox"
      aria-label="Autopilot sessions"
      sx={{ overflowY: 'auto', flex: 1 }}
    >
      <Stack spacing={1.5} sx={{ p: 1.5 }}>
        {sorted.map((session) => (
          <AutopilotCard
            key={session.task}
            session={session}
            selected={session.task === selectedTask}
            onSelect={() => onSelectTask(session.task)}
          />
        ))}
      </Stack>
    </Box>
  )
}
