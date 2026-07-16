import type { CSSProperties, ReactElement, ReactNode } from 'react'

/* Watchfloor pipeline phase-type icons — handoff
   docs/design_handoff_watchfloor_brand/phase-icons-dropin.

   Eight stroke-only 24×24 icons that classify a phase by what kind
   of work it is (orthogonal to its status). Per handoff design rules:

     1. Status dot first, then icon, then name. The dot is "what
        state", the icon is "what kind of work". Never combine them.
     2. The stroke never carries status color. State (running/done/
        queued/fault) is the dot's job; the icon stays in wf.fog
        (or whatever currentColor inherits) regardless.
     3. When the phase IS the active running one, the small inner
        accent dot turns Signal Blue — the outline stays neutral.
     4. One canonical size per surface: 14px inside phase boxes,
        18px in lists, 24px in specimen / settings UI.

   All icons share PhaseIconFrame: 1.5px stroke, sharp corners,
   square linecaps, no fill outside the optional accent dot. */

export type WfPhaseType =
  | 'autopilot'
  | 'development'
  | 'refactor'
  | 'review'
  | 'documentation'
  | 'manual'
  | 'setup'
  | 'gate'

const WF_SIGNAL = '#3B9EFF'

interface FrameProps {
  size: number
  color: string
  style?: CSSProperties
  children: ReactNode
}

function Frame({ size, color, style, children }: Readonly<FrameProps>) {
  return (
    <svg
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      stroke={color}
      strokeWidth="1.5"
      strokeLinecap="square"
      strokeLinejoin="miter"
      style={{ display: 'block', flexShrink: 0, ...style }}
    >
      {children}
    </svg>
  )
}

interface IconProps {
  size?: number
  active?: boolean
  /** Stroke color. Defaults to currentColor so callers control via CSS. */
  color?: string
  /** Override the active-accent color. */
  accent?: string
  style?: CSSProperties
}

function Autopilot({ size = 14, color = 'currentColor', accent = WF_SIGNAL, active = false, style }: Readonly<IconProps>) {
  return (
    <Frame size={size} color={color} style={style}>
      <circle cx="12" cy="12" r="8.5" />
      <path
        d="M12 12 L12 3.5 A 8.5 8.5 0 0 1 20.5 12 Z"
        fill={active ? accent : color}
        fillOpacity={active ? 0.85 : 0.5}
        stroke="none"
      />
      <line x1="12" y1="12" x2="20.5" y2="12" />
      <circle cx="12" cy="12" r="1.3" fill={active ? accent : color} stroke="none" />
    </Frame>
  )
}

function Development({ size = 14, color = 'currentColor', accent = WF_SIGNAL, active = false, style }: Readonly<IconProps>) {
  return (
    <Frame size={size} color={color} style={style}>
      <polyline points="9,7 4,12 9,17" />
      <polyline points="15,7 20,12 15,17" />
      {active && <circle cx="12" cy="12" r="1.1" fill={accent} stroke="none" />}
    </Frame>
  )
}

function Refactor({ size = 14, color = 'currentColor', accent = WF_SIGNAL, active = false, style }: Readonly<IconProps>) {
  return (
    <Frame size={size} color={color} style={style}>
      <path d="M5 9 A 7 7 0 0 1 17 7" />
      <polyline points="14,4 17,7 14,10" />
      <path d="M19 15 A 7 7 0 0 1 7 17" />
      <polyline points="10,20 7,17 10,14" />
      {active && <circle cx="12" cy="12" r="1.1" fill={accent} stroke="none" />}
    </Frame>
  )
}

function Review({ size = 14, color = 'currentColor', accent = WF_SIGNAL, active = false, style }: Readonly<IconProps>) {
  return (
    <Frame size={size} color={color} style={style}>
      <path d="M3 10 Q 12 3, 21 10 Q 12 17, 3 10 Z" />
      <circle
        cx="12" cy="10" r="2.4"
        fill={active ? accent : 'none'}
        stroke={active ? accent : color}
      />
      <polyline points="8,19 11,22 17,16" />
    </Frame>
  )
}

function Documentation({ size = 14, color = 'currentColor', accent = WF_SIGNAL, active = false, style }: Readonly<IconProps>) {
  return (
    <Frame size={size} color={color} style={style}>
      <line x1="12" y1="6" x2="12" y2="20" />
      <path d="M12 6 L4.5 6.5 L4.5 19.5 L12 20" />
      <path d="M12 6 L19.5 6.5 L19.5 19.5 L12 20" />
      <line x1="6.5" y1="10" x2="10.5" y2="10.2" opacity="0.55" />
      <line x1="6.5" y1="13" x2="10.5" y2="13.2" opacity="0.45" />
      <line x1="13.5" y1="10.2" x2="17.5" y2="10" opacity="0.55" />
      <line x1="13.5" y1="13.2" x2="17.5" y2="13" opacity="0.45" />
      {active && <circle cx="12" cy="20" r="1.1" fill={accent} stroke="none" />}
    </Frame>
  )
}

function Manual({ size = 14, color = 'currentColor', accent = WF_SIGNAL, active = false, style }: Readonly<IconProps>) {
  return (
    <Frame size={size} color={color} style={style}>
      <path
        d="M6 4 L6 17 L9.5 14 L12 20 L14 19 L11.5 13 L16 13 Z"
        fill={active ? accent : 'none'}
        stroke={active ? accent : color}
      />
    </Frame>
  )
}

function TechnicalSetup({ size = 14, color = 'currentColor', accent = WF_SIGNAL, active = false, style }: Readonly<IconProps>) {
  return (
    <Frame size={size} color={color} style={style}>
      <line x1="7" y1="17" x2="14" y2="10" />
      <path d="M14 10 L17 7 L20 10 L17 13 Z" />
      <polyline points="3,15 5.5,17.5 3,20" />
      <line x1="6.5" y1="20" x2="10" y2="20" />
      {active && <circle cx="18.5" cy="10" r="1.1" fill={accent} stroke="none" />}
    </Frame>
  )
}

function Gate({ size = 14, color = 'currentColor', accent = WF_SIGNAL, active = false, style }: Readonly<IconProps>) {
  return (
    <Frame size={size} color={color} style={style}>
      <path d="M8 11 L8 7 Q 12 4, 16 7 L16 11" />
      <rect x="5.5" y="11" width="13" height="9.5" />
      <circle cx="12" cy="15" r="1.2" fill={active ? accent : color} stroke="none" />
      <line x1="12" y1="15.6" x2="12" y2="18" stroke={active ? accent : color} />
    </Frame>
  )
}

export const PHASE_TYPE_ICON: Readonly<Record<WfPhaseType, (p: IconProps) => ReactElement>> = {
  autopilot: Autopilot,
  development: Development,
  refactor: Refactor,
  review: Review,
  documentation: Documentation,
  manual: Manual,
  setup: TechnicalSetup,
  gate: Gate,
}

interface PhaseIconProps extends IconProps {
  type: WfPhaseType
}

export default function PhaseIcon({ type, ...rest }: Readonly<PhaseIconProps>) {
  const Cmp = PHASE_TYPE_ICON[type]
  if (!Cmp) return null
  return <Cmp {...rest} />
}
