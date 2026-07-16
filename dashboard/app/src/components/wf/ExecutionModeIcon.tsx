import Box from '@mui/material/Box'
import RadarMark from './RadarMark'
import PhaseIcon from './PhaseIcon'

/* Watchfloor execution-mode icon (no label) — the icon-only variant
   of AutopilotBadge for compact surfaces (Pipeline task nodes,
   FeatureCard) where the full pill is too heavy. The triplet matches
   AutopilotBadge.mode 1:1:

     mode='full'   — RadarMark variant=full (filled signal-blue disc)
     mode='light'  — RadarMark variant=light (filled carbon disc with
                     signal-blue lines)
     mode='manual' — manual phase icon (sharp pointer), muted fog color

   Pass live=true (only meaningful for full/light) to spin the sweep. */

const WF_FOG = '#5A6472'

export type ExecutionMode = 'full' | 'light' | 'manual'

interface ExecutionModeIconProps {
  mode: ExecutionMode
  size?: number
  /** Spin the radar sweep — only honored when mode is full or light. */
  live?: boolean
}

export default function ExecutionModeIcon({
  mode,
  size = 14,
  live = false,
}: Readonly<ExecutionModeIconProps>) {
  return (
    <Box
      component="span"
      data-execution-mode={mode}
      sx={{ display: 'inline-flex', alignItems: 'center' }}
    >
      {mode === 'manual' ? (
        <PhaseIcon type="manual" size={size} color={WF_FOG} />
      ) : (
        <RadarMark size={size} variant={mode} sweep={live} sweepDuration="2.2s" />
      )}
    </Box>
  )
}
