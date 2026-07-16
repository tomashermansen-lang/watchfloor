import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import LiveBadge from '../components/wf/LiveBadge'

describe('<LiveBadge>', () => {
  it('renders the LIVE label uppercase', () => {
    render(<LiveBadge />)
    expect(screen.getByText('LIVE')).toBeInTheDocument()
  })

  it('embeds a 12px RadarMark SVG', () => {
    const { container } = render(<LiveBadge />)
    const svg = container.querySelector('svg')
    expect(svg).not.toBeNull()
    expect(svg?.getAttribute('width')).toBe('12')
    expect(svg?.getAttribute('height')).toBe('12')
  })

  it('spins the embedded sweep at 2.2s per revolution', () => {
    const { container } = render(<LiveBadge />)
    const sweep = container.querySelector('svg [data-radar-sweep]')
    const style = sweep?.getAttribute('style') ?? ''
    expect(style).toMatch(/animation/)
    expect(style).toContain('2.2s')
  })

  it('exposes data-testid for downstream layout assertions', () => {
    const { container } = render(<LiveBadge />)
    expect(container.querySelector('[data-testid="wf-live-badge"]')).not.toBeNull()
  })

  /* Padding is top-heavy on purpose — atoms.md spec '4px 10px 3px'
     optically centres mono caps which sit slightly low relative to
     the cap height. The current MUI sx values (8px horizontal / 2px
     vertical) shrink the pill too tightly and lose the optical
     centring trick. Verifying via inline style keeps the test
     independent of the emotion runtime. */
  it('uses spec padding 4px top / 10px sides / 3px bottom', () => {
    const { container } = render(<LiveBadge />)
    const pill = container.querySelector('[data-testid="wf-live-badge"]') as HTMLElement
    expect(pill.style.paddingTop).toBe('4px')
    expect(pill.style.paddingRight).toBe('10px')
    expect(pill.style.paddingBottom).toBe('3px')
    expect(pill.style.paddingLeft).toBe('10px')
  })

  it('label uses 0.16em letter-spacing per atoms.md spec', () => {
    const { container } = render(<LiveBadge />)
    const label = container.querySelector('[data-testid="wf-live-badge"] span') as HTMLElement
    expect(label.style.letterSpacing).toBe('0.16em')
  })
})
