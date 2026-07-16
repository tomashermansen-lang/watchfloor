/* Watchfloor brand toggle chip — handoff §UI Primitives "Toggle".
   Shared chrome for filter rails (StreamViewer Show, GrinderEvents
   filters, DeferredAuditView kind selectors). Sharp 90° corners,
   wf.steel border + wf.fog text at rest, signal-blue tint when
   active. JetBrains Mono UPPERCASE label. Compositional — no MUI
   Chip wrapping so the button reads as honest brand chrome. */

interface ToggleChipProps {
  label: string
  active: boolean
  onClick: () => void
  disabled?: boolean
  /** Optional accessible label override; defaults to the visible label. */
  ariaLabel?: string
  /** Optional glyph rendered before the label. Used by sidebar
     navigation chips (Documents, SESSION HISTORY) to prefix a
     small AppIcon while reusing the chip's chrome. */
  icon?: React.ReactNode
  /** Optional native browser tooltip — surfaces on hover after the
     OS-default delay. Used by the Plans-tab sort chips to explain what
     each sort key means without burning chrome on a permanent legend. */
  title?: string
}

const WF_STEEL = '#2A3340'
const WF_FOG = '#5A6472'
const WF_BONE = '#E6EBF2'
const WF_SIGNAL = '#3B9EFF'
const WF_SIGNAL_DIM_BG = 'rgba(59, 158, 255, 0.12)'
const WF_HOVER_BG = 'rgba(59, 158, 255, 0.06)'

export default function ToggleChip({
  label,
  active,
  onClick,
  disabled = false,
  ariaLabel,
  icon,
  title,
}: Readonly<ToggleChipProps>) {
  const borderColor = active ? WF_SIGNAL : WF_STEEL
  const color = disabled ? WF_FOG : active ? WF_SIGNAL : WF_BONE
  const bg = active ? WF_SIGNAL_DIM_BG : 'transparent'
  return (
    <button
      type="button"
      data-testid="wf-toggle-chip"
      data-active={active ? 'true' : 'false'}
      aria-pressed={active}
      aria-label={ariaLabel ?? label}
      title={title}
      disabled={disabled}
      onClick={onClick}
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: '6px',
        height: 24,
        padding: '0 10px',
        backgroundColor: bg,
        border: `1px solid ${borderColor}`,
        borderRadius: 0,
        cursor: disabled ? 'default' : 'pointer',
        color,
        fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
        fontSize: '10px',
        fontWeight: 500,
        letterSpacing: '0.12em',
        textTransform: 'uppercase',
        opacity: disabled ? 0.5 : 1,
        transition: 'background-color 150ms ease, border-color 150ms ease, color 150ms ease',
      }}
      onMouseEnter={(e) => {
        if (disabled || active) return
        e.currentTarget.style.backgroundColor = WF_HOVER_BG
        e.currentTarget.style.borderColor = WF_SIGNAL
      }}
      onMouseLeave={(e) => {
        if (disabled || active) return
        e.currentTarget.style.backgroundColor = 'transparent'
        e.currentTarget.style.borderColor = WF_STEEL
      }}
    >
      {icon}
      {label}
    </button>
  )
}
