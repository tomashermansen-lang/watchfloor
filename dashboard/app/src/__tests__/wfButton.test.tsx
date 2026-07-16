import { describe, it, expect, vi, afterEach } from 'vitest'
import { render, screen, fireEvent, cleanup } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import WfButton from '../components/wf/Button'

afterEach(() => {
  cleanup()
})

function renderButton(props?: Partial<React.ComponentProps<typeof WfButton>>) {
  return render(
    <ThemeProvider theme={theme}>
      <WfButton
        label={props?.label ?? 'Go'}
        onClick={props?.onClick ?? vi.fn()}
        variant={props?.variant ?? 'primary'}
        size={props?.size ?? 'md'}
        icon={props?.icon}
        title={props?.title}
        disabled={props?.disabled}
      />
    </ThemeProvider>,
  )
}

describe('wf/Button — primary primitive (controls-01 #1, #5)', () => {
  it('T-WB.1: renders a real <button> with role="button" and the label as the accessible name', () => {
    renderButton({ label: 'Start autopilot' })
    const btn = screen.getByRole('button', { name: /^Start autopilot$/i })
    expect(btn.tagName).toBe('BUTTON')
  })

  it('T-WB.2: primary variant uses solid signal-blue background and ink text (inline style — jsdom-introspectable)', () => {
    renderButton({ variant: 'primary' })
    const btn = screen.getByRole('button')
    // Inline style ensures jsdom can read the resolved colors.
    expect(btn.style.backgroundColor).toBe('rgb(59, 158, 255)') // wf.signal #3B9EFF
    expect(btn.style.color).toBe('rgb(11, 14, 19)') // wf.ink #0B0E13
    // `style.border` shorthand reads back as "medium" when border-width
    // is default; borderStyle is the deterministic check for "no visible border".
    expect(btn.style.borderStyle).toBe('none')
    expect(btn.style.borderRadius).toBe('0px')
  })

  /* T-WB.3 (controls-05 #2): sizes match watchfloor spec
     `docs/design_handoff_watchfloor_v2/specs/ui-primitives.md`
     § Buttons exactly. `sm` = 4px×10px padding + 10px font ⇒ 18px;
     `md` = 6px×12px padding + 11px font ⇒ 23px. The legacy
     `default`/`large` (32px/40px) overshot the spec by 30–60% and
     made the START CHAIN button visually dominate plan headers. */
  it('T-WB.3: size=sm → 18px height, 10px font; size=md → 23px height, 11px font', () => {
    const { unmount } = renderButton({ size: 'sm' })
    let btn = screen.getByRole('button')
    expect(btn.style.height).toBe('18px')
    expect(btn.style.fontSize).toBe('10px')
    unmount()
    renderButton({ size: 'md' })
    btn = screen.getByRole('button')
    expect(btn.style.height).toBe('23px')
    expect(btn.style.fontSize).toBe('11px')
  })

  it('T-WB.4: invokes onClick when clicked, no-ops when disabled', () => {
    const onClick = vi.fn()
    const { rerender } = renderButton({ onClick })
    fireEvent.click(screen.getByRole('button'))
    expect(onClick).toHaveBeenCalledTimes(1)

    rerender(
      <ThemeProvider theme={theme}>
        <WfButton label="Go" onClick={onClick} variant="primary" size="md" disabled />
      </ThemeProvider>,
    )
    fireEvent.click(screen.getByRole('button'))
    // disabled buttons swallow native click events
    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it('T-WB.5: title attribute is forwarded to the underlying button', () => {
    renderButton({ title: 'spawn tmux session' })
    expect(screen.getByRole('button').getAttribute('title')).toBe('spawn tmux session')
  })

  it('T-WB.6: icon prop renders before the label and shares the same button as accessible name', () => {
    renderButton({
      label: 'Start',
      icon: <span data-testid="wf-icon">PLAY</span>,
    })
    const btn = screen.getByRole('button', { name: /Start/ })
    const icon = screen.getByTestId('wf-icon')
    expect(btn.contains(icon)).toBe(true)
    // Icon must precede the label in DOM order
    const labelNode = btn.querySelector('[data-testid="wf-button-label"]')
    expect(labelNode).not.toBeNull()
    if (icon && labelNode) {
      expect(icon.compareDocumentPosition(labelNode) & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
    }
  })

  it('T-WB.7: primary fill is visually distinct from an active ToggleChip (no rgba(59,158,255,0.12) collision)', () => {
    renderButton({ variant: 'primary' })
    const btn = screen.getByRole('button')
    // ToggleChip active uses rgba(59,158,255,0.12); primary must be solid.
    expect(btn.style.backgroundColor).not.toMatch(/0\.12/)
    expect(btn.style.backgroundColor).not.toMatch(/^rgba/)
  })
})
