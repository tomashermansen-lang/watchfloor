import Box from '@mui/material/Box'
import RadarMark from './RadarMark'
import PhaseIcon from './PhaseIcon'

/* Watchfloor execution-mode pill — handoff README §App Chrome.
   Mirrors LiveBadge structure (12px icon + mono uppercase label on a
   tinted pill) so the chrome reads as one family with the Pipeline
   graph node icons:

     mode='full'   — RadarMark variant=full (filled signal-blue disc),
                     AUTOPILOT label, signal-blue tint
     mode='light'  — RadarMark variant=light (filled carbon disc with
                     signal-blue lines), AUTOPILOT label, signal-blue
                     tint
     mode='manual' — manual phase icon (sharp pointer), MANUAL label,
                     muted (steel border + fog text) since manual
                     work isn't a "live" signal

   Pass live=true (only meaningful for full/light) when an autopilot
   session is actively running so the radar sweep doubles as a live
   indicator. */

export type AutopilotBadgeMode = 'full' | 'light' | 'manual'

interface AutopilotBadgeProps {
  /** full / light = autopilot + which pipeline; manual = no autopilot.
      Defaults to 'full' for backwards compatibility. */
  mode?: AutopilotBadgeMode
  /** Spin the radar sweep — only honored when mode is full or light. */
  live?: boolean
}

const SIGNAL_BLUE = '#3B9EFF'
const WF_FOG = '#5A6472'
const WF_STEEL = '#2A3340'

const MONO_STACK =
  '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace'

export default function AutopilotBadge({
  mode = 'full',
  live = false,
}: Readonly<AutopilotBadgeProps>) {
  const isManual = mode === 'manual'
  const label = isManual ? 'MANUAL' : 'AUTOPILOT'
  const bg = isManual ? 'transparent' : 'rgba(59,158,255,0.10)'
  const borderColor = isManual ? WF_STEEL : 'rgba(59,158,255,0.35)'
  const labelColor = isManual ? WF_FOG : SIGNAL_BLUE
  return (
    <Box
      data-testid="wf-autopilot-badge"
      data-mode={mode}
      sx={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 0.75,
        px: 1,
        py: 0.25,
        bgcolor: bg,
        border: `1px solid ${borderColor}`,
        borderRadius: 999,
        lineHeight: 1,
      }}
    >
      {isManual ? (
        <PhaseIcon type="manual" size={12} color={WF_FOG} />
      ) : (
        <RadarMark size={12} variant={mode} sweep={live} sweepDuration="2.2s" />
      )}
      <span
        style={{
          fontFamily: MONO_STACK,
          fontSize: '10px',
          fontWeight: 500,
          letterSpacing: '0.08em',
          color: labelColor,
        }}
      >
        {label}
      </span>
    </Box>
  )
}
