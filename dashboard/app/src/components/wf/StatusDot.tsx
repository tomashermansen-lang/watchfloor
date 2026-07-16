/* Watchfloor status dot — handoff README "Color · Status".
   The atomic indicator used wherever the four product-states need
   a glance-readable signal: agent-running (signal blue), completed
   (green), stalled/awaiting-input (amber), fault (red). The glow
   (box-shadow 0 0 5px in-color) is part of the brand spec — it's
   what makes the dot feel "live" rather than a flat dot. */

export type WfStatus = 'running' | 'completed' | 'stalled' | 'fault' | 'queued'

const STATUS_COLOR: Record<WfStatus, string> = {
  running: '#3B9EFF',
  completed: '#5BD68A',
  stalled: '#F2B441',
  fault: '#EF4D4D',
  queued: '#5A6472',
}

/* Glow is reserved for LIVE states. Brand language is
   "attention/live = signal" — a static checkmark in the same
   visual treatment as the working/blocked indicators confuses the
   eye. completed is terminal (archive, no action), queued is
   pre-run (placeholder); the other three are unresolved and
   demand attention. */
const STATUS_IS_LIVE: Record<WfStatus, boolean> = {
  running: true,
  stalled: true,
  fault: true,
  completed: false,
  queued: false,
}

interface StatusDotProps {
  status: WfStatus
  /** Diameter in pixels. Default 6 per handoff "6px dot indicators". */
  size?: number
  /** Override the glow default. Pass true on completed when celebrating
     a fresh win, or false on running to render a flat indicator inside
     a parent that already conveys liveness. */
  glow?: boolean
  /** Animate via the global wf-pulse keyframes (1.4s ease-in-out). Use
     for time-sensitive unresolved states inside dense lists where the
     glow alone doesn't draw enough attention. */
  pulse?: boolean
}

export default function StatusDot({ status, size = 6, glow, pulse }: Readonly<StatusDotProps>) {
  const color = STATUS_COLOR[status]
  const showGlow = glow ?? STATUS_IS_LIVE[status]
  return (
    <span
      data-testid="wf-status-dot"
      data-status={status}
      style={{
        display: 'inline-block',
        flexShrink: 0,
        width: `${size}px`,
        height: `${size}px`,
        borderRadius: '50%',
        backgroundColor: color,
        boxShadow: showGlow ? `0 0 5px ${color}` : undefined,
        animation: pulse ? 'wf-pulse 1.4s ease-in-out infinite' : undefined,
      }}
    />
  )
}
