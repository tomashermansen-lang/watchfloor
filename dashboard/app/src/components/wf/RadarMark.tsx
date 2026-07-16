import type { CSSProperties } from 'react'

/* Watchfloor brand mark — concentric rings + sweep line + center dot.
   Lives at three sizes per handoff: 16px favicon, 18-36px chrome,
   120-320px hero. Sweep is opt-in: chrome lockups stay static,
   <LiveBadge> spins it at 2.2s, empty-state hero at 6s. Geometry is
   measured against viewBox 0 0 64 64 — caller picks the rendered px
   via the `size` prop and the SVG scales uniformly. Colors come from
   the wf canvas tokens (steel/fog/bone/signal); kept inline so the
   mark renders correctly even before MUI theme has hydrated. */

interface RadarMarkProps {
  /** Rendered size in CSS pixels — applied to both width and height. */
  size: number
  /** When true the sweep line rotates indefinitely. Off by default. */
  sweep?: boolean
  /** CSS animation-duration for the sweep — only honored when sweep is true. */
  sweepDuration?: string
  /** Visual variant.
       'default' = transparent disc, fog rings, signal sweep — chrome
                   lockup look (title bar / LIVE pill).
       'light'   = filled carbon disc, signal-blue rings + sweep —
                   autopilot light pipeline (subtle but identifiable).
       'full'    = filled signal-blue disc, dark ink rings + sweep —
                   autopilot full pipeline (bold, dominant). */
  variant?: 'default' | 'light' | 'full'
  /** Extra style merged onto the root SVG (e.g. for vertical alignment). */
  style?: CSSProperties
}

const WF_SIGNAL = '#3B9EFF'
const WF_SIGNAL_DIM = '#1F6FBF'
const WF_BONE = '#E6EBF2'
const WF_FOG = '#5A6472'
const WF_CARBON = '#10141B'

const sweepStyle: CSSProperties = {
  transformOrigin: '32px 32px',
  transformBox: 'view-box',
}

/* Color tuples per variant: [bg fill, line stroke, blip fill].
   default keeps the line-art look (transparent bg, fog rings, signal
   sweep+center, bone blips). light fills the disc dark and inverts
   lines to signal blue. full fills the disc signal blue and inverts
   lines to dark ink — both are filled-disc variants where the disc
   color IS the dominant brand signal. */
type VariantColors = {
  bgFill: string | null
  lineStroke: string
  centerFill: string
  blipFill: string
  blipOpacity: number
}
const VARIANT_COLORS: Record<NonNullable<RadarMarkProps['variant']>, VariantColors> = {
  default: { bgFill: null,           lineStroke: WF_FOG,    centerFill: WF_SIGNAL, blipFill: WF_BONE, blipOpacity: 0.7 },
  light:   { bgFill: WF_CARBON,      lineStroke: WF_SIGNAL, centerFill: WF_SIGNAL, blipFill: WF_BONE, blipOpacity: 0.7 },
  /* full uses signalDim (the toned-down brand blue) so the disc
     reads as confident without screaming, and bone lines so the
     radar geometry reads clearly through the saturated background. */
  full:    { bgFill: WF_SIGNAL_DIM,  lineStroke: WF_BONE,   centerFill: WF_BONE,   blipFill: WF_BONE, blipOpacity: 0.7 },
}

export default function RadarMark({
  size,
  sweep = false,
  sweepDuration = '6s',
  variant = 'default',
  style,
}: Readonly<RadarMarkProps>) {
  const lineStyle: CSSProperties = sweep
    ? {
        ...sweepStyle,
        animation: `wf-radar-sweep ${sweepDuration} linear infinite`,
      }
    : sweepStyle
  const c = VARIANT_COLORS[variant]
  const isFilled = c.bgFill !== null
  /* default keeps the original look: rings in fog, sweep + center
     in signal blue. light/full both invert the line color to one
     value (everything draws in lineStroke) so the disc fill is the
     dominant signal at small inline sizes. */
  const sweepColor = variant === 'default' ? WF_SIGNAL : c.lineStroke
  return (
    <svg
      viewBox="0 0 64 64"
      width={size}
      height={size}
      role="img"
      aria-label="watchfloor radar mark"
      style={{ display: 'block', ...style }}
    >
      {c.bgFill && (
        <circle data-radar-bg cx="32" cy="32" r="30" fill={c.bgFill} />
      )}
      {/* Filled variants (light/full) bump stroke widths and remove
          inner-ring opacity reduction so all geometry stays visible
          at 14px inline sizes. Default keeps the original subtle
          treatment for chrome use at 18-36px. */}
      <circle cx="32" cy="32" r="28" fill="none" stroke={c.lineStroke} strokeWidth={isFilled ? 2 : 1.5} />
      <circle cx="32" cy="32" r="19" fill="none" stroke={c.lineStroke} strokeWidth={isFilled ? 1.5 : 1} opacity={isFilled ? 1 : 0.6} />
      <circle cx="32" cy="32" r="10" fill="none" stroke={c.lineStroke} strokeWidth={isFilled ? 1.5 : 1} opacity={isFilled ? 1 : 0.4} />
      <line
        x1="32" y1="32" x2="32" y2="4"
        stroke={sweepColor} strokeWidth={isFilled ? 3 : 2.5} strokeLinecap="round"
        data-radar-sweep
        style={lineStyle}
      />
      <circle cx="32" cy="32" r={isFilled ? 2.8 : 2.2} fill={c.centerFill} />
      <circle cx="46" cy="22" r={isFilled ? 1.6 : 1.2} fill={c.blipFill} />
      <circle cx="22" cy="40" r={isFilled ? 1.6 : 1.2} fill={c.blipFill} opacity={c.blipOpacity} />
    </svg>
  )
}
