/* Watchfloor brand Button primitive — handoff §UI Primitives "Button".
   Brand-native button to host primary / secondary / destructive / ghost
   intents at sm and md sizes. Uses inline style (same pattern as
   ToggleChip) so:
     1. jsdom can introspect resolved colors deterministically in tests
        without an emotion stylesheet round-trip;
     2. Sharp corners, no shadow, and the typographic ramp survive any
        downstream Button theme override.
   controls-01 #1, #5 — primary variant fixes the screenshot collision
   where the MUI 'contained' variant rendered with the same fill+text
   tokens as an active ToggleChip; the size= prop fixes the theme.ts
   override pinning fontSize=11px regardless of size.
   controls-05 #2 — sizes now match the watchfloor spec exactly
   (`docs/design_handoff_watchfloor_v2/specs/ui-primitives.md` §
   Buttons): `sm` = 4px×10px padding + JetBrains Mono 10px/500 ⇒ 18px,
   `md` = 6px×12px padding + JetBrains Mono 11px/500 ⇒ 23px. The
   legacy `default`/`large` (32px/40px) overshot the spec by 30–60%
   and made the START CHAIN button visually dominate plan headers.

   Phase 1 only ships variant='primary'. The other variant literals
   are accepted in the prop type so call sites can be migrated
   incrementally without a downstream type churn pass; their styling
   lands when subsequent screens force them. */

import type { JSX, ReactNode } from 'react'

export type WfButtonVariant = 'primary' | 'secondary' | 'destructive' | 'ghost'
export type WfButtonSize = 'sm' | 'md'

export interface WfButtonProps {
  label: string
  onClick: () => void
  variant: WfButtonVariant
  size: WfButtonSize
  icon?: ReactNode
  title?: string
  disabled?: boolean
}

const WF_SIGNAL = '#3B9EFF'
const WF_INK = '#0B0E13'
const WF_BONE = '#E6EBF2'
const WF_STEEL = '#2A3340'
const WF_FOG = '#5A6472'
const WF_FAULT = '#EF4D4D'
const WF_SIGNAL_HOVER = '#5BB4FF'

interface VariantStyle {
  background: string
  color: string
  border: string
  hoverBackground: string
  hoverColor: string
}

function _variantStyle(variant: WfButtonVariant): VariantStyle {
  switch (variant) {
    case 'primary':
      return {
        background: WF_SIGNAL,
        color: WF_INK,
        border: 'none',
        hoverBackground: WF_SIGNAL_HOVER,
        hoverColor: WF_INK,
      }
    case 'secondary':
      return {
        background: 'transparent',
        color: WF_BONE,
        border: `1px solid ${WF_STEEL}`,
        hoverBackground: 'rgba(59, 158, 255, 0.06)',
        hoverColor: WF_BONE,
      }
    case 'destructive':
      return {
        background: 'transparent',
        color: WF_FAULT,
        border: `1px solid ${WF_FAULT}`,
        hoverBackground: 'rgba(239, 77, 77, 0.08)',
        hoverColor: WF_FAULT,
      }
    case 'ghost':
      return {
        background: 'transparent',
        color: WF_FOG,
        border: 'none',
        hoverBackground: 'rgba(59, 158, 255, 0.06)',
        hoverColor: WF_BONE,
      }
  }
}

interface SizeMetrics {
  height: number
  fontSize: number
  paddingX: number
}

function _sizeMetrics(size: WfButtonSize): SizeMetrics {
  /* Spec: `sm` = 4px×10px padding + 10px font.  height = font + 2×padY
     = 10 + 8 = 18px. `md` = 6px×12px padding + 11px font ⇒ 23px. */
  if (size === 'sm') return { height: 18, fontSize: 10, paddingX: 10 }
  return { height: 23, fontSize: 11, paddingX: 12 }
}

export default function WfButton({
  label,
  onClick,
  variant,
  size,
  icon,
  title,
  disabled = false,
}: Readonly<WfButtonProps>): JSX.Element {
  const v = _variantStyle(variant)
  const m = _sizeMetrics(size)
  return (
    <button
      type="button"
      data-testid="wf-button"
      data-variant={variant}
      data-size={size}
      title={title}
      disabled={disabled}
      onClick={onClick}
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        gap: '8px',
        height: `${m.height}px`,
        padding: `0 ${m.paddingX}px`,
        backgroundColor: v.background,
        color: v.color,
        border: v.border,
        borderRadius: 0,
        cursor: disabled ? 'default' : 'pointer',
        fontFamily:
          '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
        fontSize: `${m.fontSize}px`,
        fontWeight: 500,
        letterSpacing: '0.1em',
        textTransform: 'uppercase',
        opacity: disabled ? 0.4 : 1,
        transition:
          'background-color 150ms ease, color 150ms ease, border-color 150ms ease',
      }}
      onMouseEnter={(e) => {
        if (disabled) return
        e.currentTarget.style.backgroundColor = v.hoverBackground
        e.currentTarget.style.color = v.hoverColor
      }}
      onMouseLeave={(e) => {
        if (disabled) return
        e.currentTarget.style.backgroundColor = v.background
        e.currentTarget.style.color = v.color
      }}
    >
      {icon}
      <span data-testid="wf-button-label">{label}</span>
    </button>
  )
}
