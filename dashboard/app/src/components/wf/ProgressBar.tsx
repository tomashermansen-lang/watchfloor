/* Watchfloor progress bar — handoff ui-primitives.md §Progress bar.
   Sharp 4px bar; wf.steel track, wf.signal fill with 0 0 6px wf.signal
   glow. Inline style so it survives MUI theme overrides — same
   discipline as StatusDot / StatusPill / LiveBadge / ToggleChip. */

const SIGNAL = '#3B9EFF'
const STEEL = '#1B2230'

interface ProgressBarProps {
  /** Normalised 0..1; values outside range clamp. */
  value: number
  /** Track height in pixels. Default 4 per spec. */
  height?: number
}

export default function ProgressBar({ value, height = 4 }: Readonly<ProgressBarProps>) {
  const clamped = Math.min(1, Math.max(0, value))
  const percent = Math.round(clamped * 100)
  return (
    <span
      data-testid="wf-progress-bar"
      role="progressbar"
      aria-valuenow={percent}
      aria-valuemin={0}
      aria-valuemax={100}
      style={{
        display: 'block',
        width: '100%',
        height: `${height}px`,
        backgroundColor: STEEL,
        overflow: 'hidden',
      }}
    >
      <span
        data-testid="wf-progress-bar-fill"
        style={{
          display: 'block',
          height: '100%',
          width: `${percent}%`,
          backgroundColor: SIGNAL,
          boxShadow: `0 0 6px ${SIGNAL}`,
          transition: 'width var(--motion-short4, 200ms) var(--motion-emphasized, ease)',
        }}
      />
    </span>
  )
}
