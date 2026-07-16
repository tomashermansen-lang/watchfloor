import { useMemo, type CSSProperties } from 'react'

/* Watchfloor SubagentRadar — radar-scope data visualization.
   Translates the Recharts pie chart into the brand's radar metaphor
   (handoff §The Brand Mark · Radar Scope): three concentric reference
   rings in wf.fog + Signal Blue center dot + optional rotating sweep
   line, with proportional pie wedges filling the disc as the data
   layer. The single chromatic accent rule is honoured by tinting all
   wedges Signal Blue at decreasing opacities — the radar reads as
   one signal source partitioned into agent types, not a multi-coloured
   pie. The result aligns subagent utilisation with the same visual
   vocabulary as the title bar mark and the empty-state hero scope. */

interface SubagentRadarDatum {
  name: string
  value: number
}

interface SubagentRadarProps {
  /** Rendered size (square). */
  size: number
  /** Pie segments — one per agent type, value = count or share. */
  data: ReadonlyArray<SubagentRadarDatum>
  /** When true, sweep line rotates 360° / 6s — match handoff
     empty-state radar cadence. Use when subagents are still running. */
  sweep?: boolean
  /** Extra style merged onto the root SVG. */
  style?: CSSProperties
}

const WF_SIGNAL = '#3B9EFF'
const WF_FOG = '#5A6472'
const WF_INK = '#0B0E13'

/* Decreasing opacities for proportional wedges. The brand reserves
   Signal Blue as the single accent — partition the same hue at
   varying intensity instead of pulling in unrelated colours. The
   ramp is gentle so adjacent wedges stay distinguishable. */
const WEDGE_OPACITIES = [0.85, 0.65, 0.5, 0.38, 0.28, 0.2] as const

const sweepStyle: CSSProperties = {
  transformOrigin: 'center',
  transformBox: 'view-box',
  animation: 'wf-radar-sweep 6s linear infinite',
}

function polarToCartesian(cx: number, cy: number, r: number, angleDeg: number): [number, number] {
  /* SVG y-axis points down; subtract 90° so 0° lands at 12 o'clock,
     matching every other radar surface in the app. */
  const a = ((angleDeg - 90) * Math.PI) / 180
  return [cx + r * Math.cos(a), cy + r * Math.sin(a)]
}

function wedgePath(cx: number, cy: number, r: number, startDeg: number, endDeg: number): string {
  const [sx, sy] = polarToCartesian(cx, cy, r, startDeg)
  const [ex, ey] = polarToCartesian(cx, cy, r, endDeg)
  const largeArc = endDeg - startDeg > 180 ? 1 : 0
  return `M ${cx} ${cy} L ${sx} ${sy} A ${r} ${r} 0 ${largeArc} 1 ${ex} ${ey} Z`
}

export default function SubagentRadar({
  size,
  data,
  sweep = false,
  style,
}: Readonly<SubagentRadarProps>) {
  /* viewBox is normalised to 200 so geometry constants read cleanly;
     SVG scales uniformly to the consumer's `size`. */
  const VB = 200
  const cx = VB / 2
  const cy = VB / 2
  const wedgeR = 78 // outer wedge radius — sits just inside outer ring
  const ringRs = [90, 60, 30] // outer / mid / inner reference rings

  const total = data.reduce((sum, d) => sum + d.value, 0)
  const hasOne = data.length === 1 && data[0].value > 0

  /* Precompute cumulative start angles per segment so the render
     pass stays pure (no in-loop mutation — eslint react-hooks
     immutability rule). */
  const segments = useMemo(() => {
    const out: { name: string; value: number; start: number; end: number }[] = []
    if (total === 0) return out
    let cursor = 0
    for (const d of data) {
      const angle = (d.value / total) * 360
      out.push({ name: d.name, value: d.value, start: cursor, end: cursor + angle })
      cursor += angle
    }
    return out
  }, [data, total])

  return (
    <svg
      viewBox={`0 0 ${VB} ${VB}`}
      width={size}
      height={size}
      role="img"
      aria-label="Subagent utilisation radar"
      style={{ display: 'block', ...style }}
    >
      {/* Pie wedges (data layer) — drawn first so the rings overlay
          on top and read as instrument graticule. */}
      {segments.map((seg, i) => {
        if (seg.value <= 0) return null
        const opacity = WEDGE_OPACITIES[i % WEDGE_OPACITIES.length]
        if (hasOne) {
          /* Single-segment optimisation: full disc, no path math
             quirks at the 360° wraparound. */
          return (
            <circle
              key={seg.name}
              data-radar-wedge
              data-name={seg.name}
              cx={cx}
              cy={cy}
              r={wedgeR}
              fill={WF_SIGNAL}
              fillOpacity={opacity}
              stroke={WF_INK}
              strokeWidth={0.5}
            />
          )
        }
        return (
          <path
            key={seg.name}
            data-radar-wedge
            data-name={seg.name}
            d={wedgePath(cx, cy, wedgeR, seg.start, seg.end)}
            fill={WF_SIGNAL}
            fillOpacity={opacity}
            stroke={WF_INK}
            strokeWidth={0.5}
          />
        )
      })}

      {/* Reference rings — wf.fog at decreasing opacity, matches
          handoff §The Brand Mark "concentric inner rings" geometry. */}
      <circle
        data-radar-ring
        cx={cx}
        cy={cy}
        r={ringRs[0]}
        fill="none"
        stroke={WF_FOG}
        strokeWidth={1}
        opacity={0.32}
      />
      <circle
        data-radar-ring
        cx={cx}
        cy={cy}
        r={ringRs[1]}
        fill="none"
        stroke={WF_FOG}
        strokeWidth={1}
        opacity={0.22}
      />
      <circle
        data-radar-ring
        cx={cx}
        cy={cy}
        r={ringRs[2]}
        fill="none"
        stroke={WF_FOG}
        strokeWidth={1}
        opacity={0.16}
      />

      {/* Sweep line — only when there are running subagents (live
          state). Static radar otherwise to keep the eye on the data. */}
      {sweep && (
        <line
          data-radar-sweep
          x1={cx}
          y1={cy}
          x2={cx}
          y2={cy - ringRs[0]}
          stroke={WF_SIGNAL}
          strokeWidth={1.5}
          strokeLinecap="round"
          style={sweepStyle}
        />
      )}

      {/* Center dot — Signal Blue, always present; anchors the eye
          and reinforces brand recognition. */}
      <circle data-radar-center cx={cx} cy={cy} r={3} fill={WF_SIGNAL} />
    </svg>
  )
}
