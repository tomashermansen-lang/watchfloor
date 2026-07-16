import StatusDot from './StatusDot'
import type { WfStatus } from './StatusDot'

/* Watchfloor status pill — handoff README §UI Primitives "Status pills".
   Fully rounded (999px) tinted surface with matching border. The pill
   carries the same status-color semantics as StatusDot but communicates
   a stable state rather than a live indicator — used for "completed",
   "failed", phase-state filter chips, etc. Optional 5px dot prefix
   (withDot) re-uses StatusDot to combine the two signals.

   Tint math is fixed by the brand spec:
     surface = color @ 12%
     border  = color @ 50%
     text    = color (full saturation)

   Pass status={null} for the MUTED variant — for inert states that are
   intentionally outside the 4-color palette (e.g. "paused"). Keeps the
   pill shape so column alignment stays consistent; uses fog/steel
   tokens to read as a deliberate non-event. */

const STATUS_RGB: Record<WfStatus, string> = {
  running: '59, 158, 255',
  completed: '91, 214, 138',
  stalled: '242, 180, 65',
  fault: '239, 77, 77',
  queued: '90, 100, 114',
}

const STATUS_HEX: Record<WfStatus, string> = {
  running: '#3B9EFF',
  completed: '#5BD68A',
  stalled: '#F2B441',
  fault: '#EF4D4D',
  queued: '#5A6472',
}

const WF_STEEL = '#2A3340'
const WF_FOG = '#5A6472'
const WF_INK = '#0B0E13'

interface StatusPillProps {
  status: WfStatus | null
  label: string
  /** Prepend a small StatusDot inside the pill — useful when the
     same color appears multiple times in a row and the pill alone
     doesn't draw enough attention. Ignored in the muted and solid
     variants (muted has no live signal; solid IS the signal). */
  withDot?: boolean
  /** Clip overflow with ellipsis instead of overflowing the parent.
     Adds a title attribute exposing the full label on hover. Use
     in narrow surfaces (sidebar, dependency lists). */
  truncate?: boolean
  /** Render the high-emphasis filled treatment: signal-blue surface,
     ink text, no dot. Use sparingly — reserved for chips that need
     to read as a primary affordance (autopilot mode chip,
     LIVE-adjacent labels). The status colour is ignored visually
     because the spec mandates wf.signal regardless of state. */
  solid?: boolean
  /** Animate the embedded StatusDot via the global wf-pulse keyframes.
     No-op without withDot (nothing to animate) and ignored in muted
     and solid variants (no dot is rendered). */
  pulse?: boolean
}

export default function StatusPill({
  status,
  label,
  withDot = false,
  truncate = false,
  solid = false,
  pulse = false,
}: Readonly<StatusPillProps>) {
  const isMuted = status === null
  const showDot = withDot && !isMuted && !solid
  const bg = solid
    ? '#3B9EFF'
    : isMuted
      ? 'transparent'
      : `rgba(${STATUS_RGB[status]}, 0.12)`
  const borderColor = solid
    ? '#3B9EFF'
    : isMuted
      ? WF_STEEL
      : `rgba(${STATUS_RGB[status]}, 0.5)`
  const textColor = solid ? WF_INK : isMuted ? WF_FOG : STATUS_HEX[status]
  const dataStatus = solid ? 'solid' : isMuted ? 'muted' : status
  return (
    <span
      data-testid="wf-status-pill"
      data-status={dataStatus}
      title={truncate ? label : undefined}
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: showDot ? '6px' : 0,
        paddingTop: '3px',
        paddingBottom: '3px',
        paddingLeft: '10px',
        paddingRight: '10px',
        backgroundColor: bg,
        border: `1px solid ${borderColor}`,
        borderRadius: '999px',
        lineHeight: 1,
        whiteSpace: 'nowrap',
        maxWidth: truncate ? '100%' : undefined,
        overflow: truncate ? 'hidden' : undefined,
      }}
    >
      {showDot && <StatusDot status={status} size={5} pulse={pulse} />}
      <span
        style={{
          fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
          fontSize: '10px',
          fontWeight: 500,
          letterSpacing: '0.06em',
          textTransform: 'uppercase',
          color: textColor,
          ...(truncate
            ? {
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
                minWidth: 0,
              }
            : {}),
        }}
      >
        {label}
      </span>
    </span>
  )
}
