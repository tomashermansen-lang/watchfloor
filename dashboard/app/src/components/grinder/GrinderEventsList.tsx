import { useState, useMemo } from 'react'
import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import Paper from '@mui/material/Paper'
import IconButton from '@mui/material/IconButton'
import PlayArrowIcon from '@mui/icons-material/PlayArrow'
import StatusPill from '../wf/StatusPill'
import ToggleChip from '../wf/ToggleChip'
import { grinderEventToWfStatus } from '../../utils/featureStatusMapping'
import type { GrinderEvent, GrinderEventType } from '../../types'
import { relativeTime } from '../../utils/time'

interface GrinderEventsListProps {
  events: GrinderEvent[]
  onOpenStream?: (batchId: string) => void
}

export default function GrinderEventsList({ events, onOpenStream }: GrinderEventsListProps) {
  const [activeFilter, setActiveFilter] = useState<GrinderEventType | null>(null)

  const eventTypes = useMemo(() => {
    const types = new Set<GrinderEventType>()
    events.forEach((e) => types.add(e.event))
    return Array.from(types)
  }, [events])

  const filtered = activeFilter
    ? events.filter((e) => e.event === activeFilter)
    : events

  if (events.length === 0) {
    return (
      <Paper elevation={0} sx={{ border: '1px solid', borderColor: 'divider', p: 2 }}>
        <Typography variant="titleMedium" sx={{ mb: 1 }}>Recent Events</Typography>
        <Typography variant="body2" color="text.secondary">No events recorded</Typography>
      </Paper>
    )
  }

  return (
    <Paper elevation={0} sx={{ border: '1px solid', borderColor: 'divider', p: 2 }}>
      <Typography variant="wfH3" sx={{ mb: 1 }}>Recent Events</Typography>

      {/* Filter chips — brand toggle vocabulary. */}
      <Box sx={{ display: 'flex', gap: 0.5, mb: 1.5, flexWrap: 'wrap' }}>
        {eventTypes.map((type) => (
          <ToggleChip
            key={type}
            label={type}
            active={activeFilter === type}
            ariaLabel={`Filter by ${type} events`}
            onClick={() => setActiveFilter(activeFilter === type ? null : type)}
          />
        ))}
      </Box>

      {/* Event rows */}
      <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.75 }}>
        {filtered.map((ev, i) => (
          <Box key={`${ev.ts}-${ev.batch}-${i}`} sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
            <Typography variant="caption" color="text.secondary" sx={{ minWidth: 60 }}>
              {relativeTime(ev.ts)}
            </Typography>
            <Typography variant="body2" sx={{ minWidth: 80 }}>{ev.batch}</Typography>
            <Box aria-label={`${ev.event} event`} sx={{ display: 'inline-flex', minWidth: 72 }}>
              <StatusPill status={grinderEventToWfStatus(ev.event)} label={ev.event} />
            </Box>
            {ev.files_fixed != null && (
              <Typography variant="caption" color="text.secondary">{ev.files_fixed} files fixed</Typography>
            )}
            {ev.reason && (
              <Typography variant="caption" color="error.main">{ev.reason}</Typography>
            )}
            {ev.reverted && (
              <Typography variant="caption" color="warning.main">reverted</Typography>
            )}
            {onOpenStream && ev.batch && (
              <IconButton
                size="small"
                onClick={() => onOpenStream(ev.batch)}
                aria-label={`View stream for ${ev.batch}`}
              >
                <PlayArrowIcon fontSize="small" />
              </IconButton>
            )}
          </Box>
        ))}
      </Box>
    </Paper>
  )
}
