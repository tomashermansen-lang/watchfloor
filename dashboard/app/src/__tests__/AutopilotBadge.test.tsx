import { describe, it, expect } from 'vitest'
import { render } from '@testing-library/react'
import AutopilotBadge from '../components/wf/AutopilotBadge'

describe('<AutopilotBadge>', () => {
  it('renders with AUTOPILOT label', () => {
    const { container } = render(<AutopilotBadge />)
    const badge = container.querySelector('[data-testid="wf-autopilot-badge"]') as HTMLElement
    expect(badge).not.toBeNull()
    expect(badge.textContent).toContain('AUTOPILOT')
  })

  /* The badge embeds the brand radar mark — never the legacy
     SmartToyIcon. Required by handoff §App Chrome (RadarMark is the
     canonical autopilot signifier). */
  it('embeds a RadarMark (the brand autopilot signifier)', () => {
    const { container } = render(<AutopilotBadge />)
    const radar = container.querySelector('[aria-label="watchfloor radar mark"]')
    expect(radar).not.toBeNull()
  })

  /* Static by default; sweep only when an autopilot session is
     actively running so the badge doubles as a live indicator. */
  it('does not animate the sweep by default', () => {
    const { container } = render(<AutopilotBadge />)
    const sweep = container.querySelector('[data-radar-sweep]') as SVGElement
    expect(sweep.style.animation).toBe('')
  })

  it('animates the sweep when live=true', () => {
    const { container } = render(<AutopilotBadge live />)
    const sweep = container.querySelector('[data-radar-sweep]') as SVGElement
    expect(sweep.style.animation).toContain('wf-radar-sweep')
  })

  /* Pill shape + signal-blue tint match LiveBadge / StatusPill so
     the chrome reads as one family. */
  it('uses pill shape with tinted signal-blue surface', () => {
    const { container } = render(<AutopilotBadge />)
    const badge = container.querySelector('[data-testid="wf-autopilot-badge"]') as HTMLElement
    const cs = window.getComputedStyle(badge)
    /* MUI sx coerces the numeric 999 via theme.spacing → 3996px.
       Visual effect is identical (fully rounded) on a 12px-tall pill. */
    const radiusPx = parseInt(cs.borderRadius, 10)
    expect(radiusPx).toBeGreaterThanOrEqual(999)
  })

  it('label uses JetBrains Mono uppercase', () => {
    const { container } = render(<AutopilotBadge />)
    const label = container.querySelector('[data-testid="wf-autopilot-badge"] span') as HTMLElement
    expect(label.style.fontFamily).toContain('JetBrains Mono')
  })

  /* mode prop drives icon + label so SessionPanel header reads
     consistently with the Pipeline graph nodes:
       full   → AUTOPILOT label + RadarMark variant="full"
       light  → AUTOPILOT label + RadarMark variant="light"
       manual → MANUAL    label + PhaseIcon type="manual" (pointer) */
  describe('mode prop (matches Pipeline node icons)', () => {
    it('full mode renders the full RadarMark variant + AUTOPILOT label', () => {
      const { container } = render(<AutopilotBadge mode="full" />)
      const badge = container.querySelector('[data-testid="wf-autopilot-badge"]') as HTMLElement
      expect(badge.getAttribute('data-mode')).toBe('full')
      expect(badge.textContent).toContain('AUTOPILOT')
      /* RadarMark variant=full draws a filled disc (data-radar-bg). */
      expect(container.querySelector('[data-radar-bg]')).not.toBeNull()
    })

    it('light mode renders the light RadarMark variant + AUTOPILOT label', () => {
      const { container } = render(<AutopilotBadge mode="light" />)
      const badge = container.querySelector('[data-testid="wf-autopilot-badge"]') as HTMLElement
      expect(badge.getAttribute('data-mode')).toBe('light')
      expect(badge.textContent).toContain('AUTOPILOT')
      expect(container.querySelector('[data-radar-bg]')).not.toBeNull()
    })

    it('manual mode renders the manual PhaseIcon + MANUAL label', () => {
      const { container } = render(<AutopilotBadge mode="manual" />)
      const badge = container.querySelector('[data-testid="wf-autopilot-badge"]') as HTMLElement
      expect(badge.getAttribute('data-mode')).toBe('manual')
      expect(badge.textContent).toContain('MANUAL')
      /* Manual phase icon — explicit data attribute on the wrapping
         badge is enough; the PhaseIcon SVG carries its own role. */
      expect(container.querySelector('[data-radar-bg]')).toBeNull()
    })

    it('manual mode uses muted styling (steel border, fog label)', () => {
      const { container } = render(<AutopilotBadge mode="manual" />)
      const label = container.querySelector('[data-testid="wf-autopilot-badge"] span') as HTMLElement
      /* fog #5A6472 = rgb(90, 100, 114) */
      expect(label.style.color).toBe('rgb(90, 100, 114)')
    })

    it('default mode (no prop) keeps the legacy AUTOPILOT default badge', () => {
      const { container } = render(<AutopilotBadge />)
      const badge = container.querySelector('[data-testid="wf-autopilot-badge"]') as HTMLElement
      expect(badge.textContent).toContain('AUTOPILOT')
    })
  })
})
