import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import StatusPill from '../components/wf/StatusPill'

describe('<StatusPill>', () => {
  it('renders the label text', () => {
    render(<StatusPill status="running" label="working" />)
    expect(screen.getByText('working')).toBeInTheDocument()
  })

  it('is fully rounded (border-radius 999)', () => {
    const { container } = render(<StatusPill status="running" label="x" />)
    const pill = container.querySelector('[data-testid="wf-status-pill"]') as HTMLElement
    expect(pill.style.borderRadius).toBe('999px')
  })

  it('uses tinted signal-blue surface and border for running', () => {
    const { container } = render(<StatusPill status="running" label="working" />)
    const pill = container.querySelector('[data-testid="wf-status-pill"]') as HTMLElement
    /* 12% bg + 50% border — handoff "Color · Status" usage notes. */
    expect(pill.style.backgroundColor).toBe('rgba(59, 158, 255, 0.12)')
    expect(pill.style.border).toContain('rgba(59, 158, 255, 0.5)')
  })

  it('uses green tint for completed', () => {
    const { container } = render(<StatusPill status="completed" label="done" />)
    const pill = container.querySelector('[data-testid="wf-status-pill"]') as HTMLElement
    expect(pill.style.backgroundColor).toBe('rgba(91, 214, 138, 0.12)')
  })

  it('uses amber tint for stalled', () => {
    const { container } = render(<StatusPill status="stalled" label="needs input" />)
    const pill = container.querySelector('[data-testid="wf-status-pill"]') as HTMLElement
    expect(pill.style.backgroundColor).toBe('rgba(242, 180, 65, 0.12)')
  })

  it('uses red tint for fault', () => {
    const { container } = render(<StatusPill status="fault" label="error" />)
    const pill = container.querySelector('[data-testid="wf-status-pill"]') as HTMLElement
    expect(pill.style.backgroundColor).toBe('rgba(239, 77, 77, 0.12)')
  })

  /* WfStatus 'queued' — pre-run placeholder. Same fog/steel color as
     StatusDot's queued treatment. Without this entry in STATUS_RGB and
     STATUS_HEX, StatusPill throws at runtime when rendered with queued
     status (regression: BACKLOG #56 dashboard-build-hygiene). */
  it('uses fog/steel tint for queued', () => {
    const { container } = render(<StatusPill status="queued" label="waiting" />)
    const pill = container.querySelector('[data-testid="wf-status-pill"]') as HTMLElement
    expect(pill.style.backgroundColor).toBe('rgba(90, 100, 114, 0.12)')
    expect(pill.style.border).toContain('rgba(90, 100, 114, 0.5)')
  })

  it('embeds a 5px StatusDot prefix when withDot is true', () => {
    const { container } = render(<StatusPill status="running" label="working" withDot />)
    expect(container.querySelector('[data-testid="wf-status-dot"]')).not.toBeNull()
  })

  it('omits the dot prefix by default', () => {
    const { container } = render(<StatusPill status="running" label="working" />)
    expect(container.querySelector('[data-testid="wf-status-dot"]')).toBeNull()
  })

  it('label uses JetBrains Mono uppercase per handoff pill spec', () => {
    const { container } = render(<StatusPill status="running" label="working" />)
    const label = container.querySelector('[data-testid="wf-status-pill"] span') as HTMLElement
    const fontFamily = label.style.fontFamily
    expect(fontFamily).toContain('JetBrains Mono')
    expect(label.style.textTransform).toBe('uppercase')
  })

  /* Muted variant — for inert states that are intentionally outside
     the 4-color status palette (e.g. "paused"). Keeps the pill shape
     so column alignment stays consistent, drops the colour saturation
     so it reads as a deliberate non-event. */
  describe('muted variant (status=null)', () => {
    it('renders a pill with data-status="muted" when status is null', () => {
      const { container } = render(<StatusPill status={null} label="paused" />)
      const pill = container.querySelector('[data-testid="wf-status-pill"]') as HTMLElement
      expect(pill).not.toBeNull()
      expect(pill.getAttribute('data-status')).toBe('muted')
    })

    it('uses transparent bg + steel border + fog text for the muted variant', () => {
      const { container } = render(<StatusPill status={null} label="paused" />)
      const pill = container.querySelector('[data-testid="wf-status-pill"]') as HTMLElement
      const label = container.querySelector('[data-testid="wf-status-pill"] span') as HTMLElement
      /* Background is "transparent" — jsdom may serialize as "" */
      expect(['', 'transparent', 'rgba(0, 0, 0, 0)']).toContain(pill.style.backgroundColor)
      /* Border = wf.steel #2A3340 — jsdom normalises hex → rgb(42, 51, 64) */
      expect(pill.style.border).toContain('rgb(42, 51, 64)')
      /* Text = wf.fog #5A6472 → rgb(90, 100, 114) */
      expect(label.style.color).toBe('rgb(90, 100, 114)')
    })

    it('still uses mono uppercase for the muted variant', () => {
      const { container } = render(<StatusPill status={null} label="paused" />)
      const label = container.querySelector('[data-testid="wf-status-pill"] span') as HTMLElement
      expect(label.style.fontFamily).toContain('JetBrains Mono')
      expect(label.style.textTransform).toBe('uppercase')
    })
  })

  /* solid variant — for high-emphasis chips (autopilot mode chip,
     LIVE-adjacent affordances). Filled signal-blue surface with ink
     (carbon) text instead of the tinted treatment. Per atoms.md spec
     the dot is omitted in this variant since the whole pill is signal. */
  describe('solid prop', () => {
    it('renders with wf.signal bg, wf.signal border, wf.ink text', () => {
      const { container } = render(<StatusPill status="running" label="AUTOPILOT" solid />)
      const pill = container.querySelector('[data-testid="wf-status-pill"]') as HTMLElement
      const label = container.querySelector('[data-testid="wf-status-pill"] span') as HTMLElement
      /* bg = wf.signal #3B9EFF → rgb(59, 158, 255) */
      expect(pill.style.backgroundColor).toBe('rgb(59, 158, 255)')
      /* border = wf.signal */
      expect(pill.style.border).toContain('rgb(59, 158, 255)')
      /* text = wf.ink #0B0E13 → rgb(11, 14, 19) */
      expect(label.style.color).toBe('rgb(11, 14, 19)')
    })

    it('omits the dot even when withDot is set', () => {
      const { container } = render(<StatusPill status="running" label="X" solid withDot />)
      expect(container.querySelector('[data-testid="wf-status-dot"]')).toBeNull()
    })

    it('exposes data-status="solid" so consumers can target it', () => {
      const { container } = render(<StatusPill status="running" label="X" solid />)
      const pill = container.querySelector('[data-testid="wf-status-pill"]') as HTMLElement
      expect(pill.getAttribute('data-status')).toBe('solid')
    })

    it('falls back to tinted treatment when solid is not set', () => {
      const { container } = render(<StatusPill status="running" label="X" />)
      const pill = container.querySelector('[data-testid="wf-status-pill"]') as HTMLElement
      expect(pill.style.backgroundColor).toBe('rgba(59, 158, 255, 0.12)')
    })
  })

  /* pulse prop — wraps StatusDot in a wf-pulse animation. Used when
     the row state is unresolved AND time-sensitive (running, needs
     input). Without withDot the prop is a no-op since there's nothing
     to animate — the pill itself never pulses, only the dot. */
  describe('pulse prop', () => {
    it('animates the dot when withDot + pulse are both set', () => {
      const { container } = render(<StatusPill status="running" label="X" withDot pulse />)
      const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
      expect(dot).not.toBeNull()
      expect(dot.style.animation).toContain('wf-pulse')
    })

    it('omits the animation when pulse is false', () => {
      const { container } = render(<StatusPill status="running" label="X" withDot />)
      const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
      expect(dot.style.animation).toBe('')
    })

    it('does nothing when pulse is set without withDot (no dot to animate)', () => {
      const { container } = render(<StatusPill status="running" label="X" pulse />)
      expect(container.querySelector('[data-testid="wf-status-dot"]')).toBeNull()
    })
  })

  /* truncate prop — long labels in narrow surfaces (sidebar After-gate
     pill, dependency lists) should clip with ellipsis instead of
     overflowing the container. */
  describe('truncate prop', () => {
    it('does not truncate by default', () => {
      const { container } = render(<StatusPill status="completed" label="x" />)
      const label = container.querySelector('[data-testid="wf-status-pill"] span') as HTMLElement
      expect(label.style.textOverflow).not.toBe('ellipsis')
    })

    it('truncate=true sets ellipsis + min-width: 0 + title attribute', () => {
      const longLabel = 'PHASE 1 GATE: $ID RENAME INTEGRATION'
      const { container } = render(<StatusPill status="completed" label={longLabel} truncate />)
      const pill = container.querySelector('[data-testid="wf-status-pill"]') as HTMLElement
      const label = container.querySelector('[data-testid="wf-status-pill"] span') as HTMLElement
      expect(label.style.textOverflow).toBe('ellipsis')
      expect(label.style.overflow).toBe('hidden')
      expect(label.style.whiteSpace).toBe('nowrap')
      /* min-width: 0 lets the inner span actually shrink inside flex */
      expect(label.style.minWidth).toBe('0px')
      /* maxWidth: 100% on the pill so it doesn't overflow its parent */
      expect(pill.style.maxWidth).toBe('100%')
      /* title attribute exposes the full text on hover */
      expect(pill.getAttribute('title')).toBe(longLabel)
    })
  })
})
