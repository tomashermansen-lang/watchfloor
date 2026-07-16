import Box from '@mui/material/Box'
import Paper from '@mui/material/Paper'
import Typography from '@mui/material/Typography'
import StatusPill from '../wf/StatusPill'
import type { WfStatus } from '../wf/StatusDot'
import type { AutopilotSession, AutopilotSessionStatus } from '../../types'
import PhaseStepper from './PhaseStepper'

function formatElapsed(seconds: number): string {
  const m = Math.floor(seconds / 60)
  const s = seconds % 60
  return m > 0 ? `${m}m ${s}s` : `${s}s`
}

const AUTOPILOT_STATUS_TO_WF: Record<AutopilotSessionStatus, WfStatus> = {
  running: 'running',
  completed: 'completed',
  failed: 'fault',
}

interface AutopilotCardProps {
  session: AutopilotSession
  selected: boolean
  onSelect: () => void
}

export default function AutopilotCard({ session, selected, onSelect }: AutopilotCardProps) {
  return (
    <Paper
      role="option"
      aria-selected={selected}
      aria-label={`${session.task} — ${session.project ?? 'unknown'} — ${session.status}`}
      tabIndex={selected ? 0 : -1}
      onClick={onSelect}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          onSelect()
        }
      }}
      elevation={0}
      sx={{
        p: 1.5,
        cursor: 'pointer',
        border: '1px solid',
        borderColor: selected ? 'primary.main' : 'divider',
        bgcolor: selected ? 'surface1' : 'transparent',
        '&:hover': {
          borderColor: 'primary.light',
          transition: 'var(--motion-short4) var(--motion-emphasized)',
        },
      }}
    >
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', mb: 0.75 }}>
        <Typography variant="wfH3" sx={{ fontWeight: 500 }}>
          {session.task}
        </Typography>
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
          <Typography variant="wfLabel" color="text.secondary">
            {session.project ?? ''}
          </Typography>
          <StatusPill status={AUTOPILOT_STATUS_TO_WF[session.status]} label={session.status} />
        </Box>
      </Box>

      <PhaseStepper phases={session.phases} mode="compact" />

      <Box sx={{ display: 'flex', justifyContent: 'space-between', mt: 0.75 }}>
        <Typography variant="wfLabel" color="text.secondary">
          {formatElapsed(session.elapsed_s)}
        </Typography>
        <Typography variant="wfLabel" color="text.secondary">
          {session.cost !== null ? `$${session.cost.toFixed(2)}` : '—'}
        </Typography>
      </Box>
    </Paper>
  )
}
