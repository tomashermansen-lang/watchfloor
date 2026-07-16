import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import Paper from '@mui/material/Paper'
import useMediaQuery from '@mui/material/useMediaQuery'
import { useTheme } from '@mui/material/styles'
import { StreamViewer } from '../autopilot/StreamViewer'
import type { GrinderBatch } from '../../types'
import type { KeyedStreamEvent } from '../../hooks/useStreamPolling'

interface GrinderBatchViewProps {
  batchId: string
  batch: GrinderBatch | null
  events: KeyedStreamEvent[]
  hasStream: boolean | null
}

export default function GrinderBatchView({
  batchId,
  batch,
  events,
  hasStream,
}: GrinderBatchViewProps) {
  const theme = useTheme()
  const isNarrow = useMediaQuery(theme.breakpoints.down('sm'))

  return (
    <Box
      sx={{
        display: 'flex',
        flexDirection: isNarrow ? 'column' : 'row',
        flex: 1,
        minHeight: 0,
        gap: 2,
      }}
    >
      {/* Left sidebar — batch metadata */}
      <Paper
        elevation={0}
        sx={{
          width: isNarrow ? '100%' : 280,
          flexShrink: 0,
          border: '1px solid',
          borderColor: 'divider',
          p: 2,
          display: 'flex',
          flexDirection: 'column',
          gap: 0.75,
        }}
      >
        <Typography variant="titleMedium" sx={{ mb: 0.5 }}>Batch {batchId}</Typography>
        <Typography variant="body2">
          <strong>Pass:</strong> {batch?.pass ?? '—'}
        </Typography>
        <Typography variant="body2">
          <strong>Status:</strong> {batch ? 'active' : '—'}
        </Typography>
        <Typography variant="body2">
          <strong>Turns:</strong> {batch?.turns_elapsed ?? '—'}
        </Typography>
        <Typography variant="body2">
          <strong>Started:</strong> {batch?.started_at ?? '—'}
        </Typography>
      </Paper>

      {/* Right pane — stream viewer */}
      <Box
        sx={{
          flex: 1,
          minHeight: 0,
          border: '1px solid',
          borderColor: 'divider',
          borderRadius: 1,
          display: 'flex',
          flexDirection: 'column',
          overflow: 'hidden',
        }}
      >
        <StreamViewer
          events={events}
          hasStream={hasStream}
          label={`batch ${batchId}`}
        />
      </Box>
    </Box>
  )
}
