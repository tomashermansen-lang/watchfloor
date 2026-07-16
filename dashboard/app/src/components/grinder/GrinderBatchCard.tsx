import Paper from '@mui/material/Paper'
import Typography from '@mui/material/Typography'
import Box from '@mui/material/Box'
import Button from '@mui/material/Button'
import PlayArrowIcon from '@mui/icons-material/PlayArrow'
import type { GrinderBatch } from '../../types'
import { relativeTime } from '../../utils/time'

interface GrinderBatchCardProps {
  batch: GrinderBatch | null
  onOpenStream?: (batchId: string) => void
}

export default function GrinderBatchCard({ batch, onOpenStream }: GrinderBatchCardProps) {
  return (
    <Paper elevation={0} sx={{ border: '1px solid', borderColor: 'divider', p: 2 }}>
      <Typography variant="titleMedium" sx={{ mb: 1 }}>Current Batch</Typography>
      {batch ? (
        <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5 }}>
          <Typography variant="body2"><strong>Batch:</strong> {batch.id}</Typography>
          <Typography variant="body2"><strong>Pass:</strong> {batch.pass}</Typography>
          <Typography variant="body2"><strong>Started:</strong> {relativeTime(batch.started_at)}</Typography>
          <Typography variant="body2"><strong>Turns:</strong> {batch.turns_elapsed}</Typography>
          {onOpenStream && (
            <Button
              variant="outlined"
              size="small"
              startIcon={<PlayArrowIcon />}
              onClick={() => onOpenStream(batch.id)}
              aria-label="View stream"
              sx={{ mt: 0.5, alignSelf: 'flex-start' }}
            >
              View stream
            </Button>
          )}
        </Box>
      ) : (
        <Typography variant="body2" color="text.secondary">No active batch</Typography>
      )}
    </Paper>
  )
}
