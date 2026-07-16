import Box from '@mui/material/Box'
import Paper from '@mui/material/Paper'
import Typography from '@mui/material/Typography'
import StatusPill from '../wf/StatusPill'
import { grinderPassStatusToWfStatus } from '../../utils/featureStatusMapping'
import type { GrinderPass } from '../../types'

export default function GrinderPassStepper({ passes }: { passes: GrinderPass[] }) {
  return (
    <Box sx={{ display: 'flex', gap: 1.5, flexWrap: 'wrap' }}>
      {passes.map((p) => (
        <Paper
          key={p.id}
          elevation={0}
          sx={{ border: '1px solid', borderColor: 'divider', p: 1.5, flex: '1 1 180px', minWidth: 160 }}
          aria-label={`${p.name} pass, ${p.status.replace('_', ' ')}, ${p.batches_completed} of ${p.batches_total} batches`}
        >
          <Typography variant="titleMedium" sx={{ mb: 0.5 }}>{p.name}</Typography>
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
            <StatusPill
              status={grinderPassStatusToWfStatus(p.status)}
              label={p.status.replace('_', ' ')}
            />
            <Typography variant="labelMedium" color="text.secondary">
              {p.batches_completed}/{p.batches_total} batches
            </Typography>
          </Box>
        </Paper>
      ))}
    </Box>
  )
}
