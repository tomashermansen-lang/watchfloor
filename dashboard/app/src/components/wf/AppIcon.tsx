import type { CSSProperties, ReactElement, ReactNode } from 'react'

/* Watchfloor app icons — handoff README §App Chrome "App icons set".
   24px native viewBox, 1.5px strokes, sharp corners, single-color
   (currentColor). Each icon has a quiet "static" version and a subtle
   accent dot for the "active" state — when the operator is currently
   on that view, the active dot reads as a soft orientation cue
   without competing with the surrounding chrome. */

const WF_SIGNAL = '#3B9EFF'

export const APP_ICON_TYPES = [
  'vision',
  'plan',
  'features',
  'deviations',
  'pipeline',
  'metrics',
  'sessions',
  'document',
] as const

export type AppIconType = (typeof APP_ICON_TYPES)[number]

interface AppIconProps {
  type: AppIconType
  size?: number
  active?: boolean
  /** Override the active-state accent color. */
  accent?: string
  /** Stroke color. Defaults to currentColor so callers control via CSS. */
  color?: string
  style?: CSSProperties
}

interface FrameProps {
  type: AppIconType
  size: number
  color: string
  style?: CSSProperties
  children: ReactNode
}

function Frame({ type, size, color, style, children }: Readonly<FrameProps>) {
  return (
    <svg
      data-icon={type}
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

interface BodyProps {
  size: number
  color: string
  active: boolean
  accent: string
  style?: CSSProperties
}

/* ── Vision ──
   A reticle / target — the long-arc thing you're aiming at. */
function Vision({ size, color, active, accent, style }: Readonly<BodyProps>) {
  return (
    <Frame type="vision" size={size} color={color} style={style}>
      <circle cx="12" cy="12" r="8" />
      <circle cx="12" cy="12" r="3.5" opacity="0.55" />
      <line x1="12" y1="2.5" x2="12" y2="5" />
      <line x1="12" y1="19" x2="12" y2="21.5" />
      <line x1="2.5" y1="12" x2="5" y2="12" />
      <line x1="19" y1="12" x2="21.5" y2="12" />
      <circle cx="12" cy="12" r="1.1" fill={active ? accent : color} stroke="none" />
    </Frame>
  )
}

/* ── Plan ──
   Stacked horizontal lines with a leading mono-tick — outline / sequence. */
function Plan({ size, color, active, accent, style }: Readonly<BodyProps>) {
  return (
    <Frame type="plan" size={size} color={color} style={style}>
      <line x1="6" y1="5" x2="6" y2="19" opacity="0.5" />
      <line x1="9" y1="7.5" x2="19" y2="7.5" />
      <line x1="9" y1="12" x2="17" y2="12" />
      <line x1="9" y1="16.5" x2="18" y2="16.5" />
      <rect x="3.5" y="6.75" width="1.5" height="1.5" fill={active ? accent : color} stroke="none" />
      <rect x="3.5" y="11.25" width="1.5" height="1.5" fill={color} stroke="none" opacity="0.5" />
      <rect x="3.5" y="15.75" width="1.5" height="1.5" fill={color} stroke="none" opacity="0.5" />
    </Frame>
  )
}

/* ── Features ──
   Two stacked feature-cards with a small "open / current" indicator. */
function Features({ size, color, active, accent, style }: Readonly<BodyProps>) {
  return (
    <Frame type="features" size={size} color={color} style={style}>
      <rect x="4" y="4" width="14" height="6" />
      <rect x="6" y="11" width="14" height="9" />
      <circle cx="9" cy="14.5" r="1.1" fill={active ? accent : color} stroke="none" />
      <line x1="11.5" y1="14.5" x2="17.5" y2="14.5" opacity="0.55" />
      <line x1="9" y1="17.5" x2="15" y2="17.5" opacity="0.4" />
    </Frame>
  )
}

/* ── Deviations ──
   A baseline with a forking divergence — expected path vs actual. */
function Deviations({ size, color, active, accent, style }: Readonly<BodyProps>) {
  return (
    <Frame type="deviations" size={size} color={color} style={style}>
      <line x1="3" y1="12" x2="21" y2="12" opacity="0.5" strokeDasharray="2 2" />
      <circle cx="6" cy="12" r="1.6" fill={color} stroke="none" />
      <path d="M6 12 Q 11 12, 13 7.5 T 21 6" />
      <circle cx="21" cy="6" r="1.6" fill={active ? accent : color} stroke="none" />
      <circle cx="21" cy="12" r="1.4" fill="none" />
    </Frame>
  )
}

/* ── Pipeline ──
   Three connected nodes in a DAG — direct echo of the pipeline graph. */
function Pipeline({ size, color, active, accent, style }: Readonly<BodyProps>) {
  return (
    <Frame type="pipeline" size={size} color={color} style={style}>
      <line x1="6.5" y1="6" x2="11" y2="12" />
      <line x1="6.5" y1="18" x2="11" y2="12" />
      <line x1="13" y1="12" x2="17.5" y2="12" />
      <circle cx="5" cy="6" r="2" />
      <circle cx="5" cy="18" r="2" />
      <circle cx="12" cy="12" r="2" />
      <circle
        cx="19" cy="12" r="2"
        fill={active ? accent : 'none'} stroke={active ? accent : color}
      />
    </Frame>
  )
}

/* ── Metrics ──
   Three vertical bars + a baseline — throughput / pass rate. */
function Metrics({ size, color, active, accent, style }: Readonly<BodyProps>) {
  return (
    <Frame type="metrics" size={size} color={color} style={style}>
      <line x1="3" y1="20" x2="21" y2="20" />
      <rect x="5.5" y="13" width="3" height="6" />
      <rect
        x="10.5" y="8.5" width="3" height="10.5"
        fill={active ? accent : 'none'} stroke={active ? accent : color}
      />
      <rect x="15.5" y="11" width="3" height="8" />
    </Frame>
  )
}

/* ── Sessions ──
   Concentric ripples + center dot — matches the LIVE pill DNA. */
function Sessions({ size, color, active, accent, style }: Readonly<BodyProps>) {
  return (
    <Frame type="sessions" size={size} color={color} style={style}>
      <circle cx="12" cy="12" r="8.5" opacity="0.35" />
      <circle cx="12" cy="12" r="5.5" opacity="0.7" />
      <circle cx="12" cy="12" r="2.2" fill={active ? accent : color} stroke="none" />
    </Frame>
  )
}

/* ── Document ──
   A document with a fold — for the DOCUMENTS list in the session drawer. */
function Document({ size, color, active, accent, style }: Readonly<BodyProps>) {
  return (
    <Frame type="document" size={size} color={color} style={style}>
      <path d="M5 3.5 L15 3.5 L19 7.5 L19 20.5 L5 20.5 Z" />
      <path d="M15 3.5 L15 7.5 L19 7.5" opacity="0.55" />
      <line x1="8" y1="12" x2="16" y2="12" opacity="0.6" />
      <line x1="8" y1="15" x2="16" y2="15" opacity="0.45" />
      <line x1="8" y1="18" x2="13" y2="18" opacity="0.45" />
      {active ? <rect x="6.5" y="5" width="1.5" height="1.5" fill={accent} stroke="none" /> : null}
    </Frame>
  )
}

const ICON_BY_TYPE: Record<AppIconType, (p: BodyProps) => ReactElement> = {
  vision: Vision,
  plan: Plan,
  features: Features,
  deviations: Deviations,
  pipeline: Pipeline,
  metrics: Metrics,
  sessions: Sessions,
  document: Document,
}

export default function AppIcon({
  type,
  size = 18,
  active = false,
  accent = WF_SIGNAL,
  color = 'currentColor',
  style,
}: Readonly<AppIconProps>) {
  const Cmp = ICON_BY_TYPE[type]
  if (!Cmp) return null
  return <Cmp size={size} color={color} active={active} accent={accent} style={style} />
}
