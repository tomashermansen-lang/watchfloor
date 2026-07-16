import { describe, it, expect } from 'vitest'
import { render } from '@testing-library/react'
import RadarMark from '../components/wf/RadarMark'

describe('<RadarMark>', () => {
  it('renders an SVG with the requested size on both axes', () => {
    const { container } = render(<RadarMark size={18} />)
    const svg = container.querySelector('svg')
    expect(svg).not.toBeNull()
    expect(svg?.getAttribute('width')).toBe('18')
    expect(svg?.getAttribute('height')).toBe('18')
    expect(svg?.getAttribute('viewBox')).toBe('0 0 64 64')
  })

  it('renders the radar geometry — three rings, sweep line, center dot, two blips', () => {
    const { container } = render(<RadarMark size={96} />)
    /* 3 rings + center dot + 2 blip dots = 6 circles, plus the sweep line */
    expect(container.querySelectorAll('svg circle').length).toBe(6)
    expect(container.querySelectorAll('svg line').length).toBe(1)
  })

  it('static sweep — no animation transform applied to the line', () => {
    const { container } = render(<RadarMark size={18} />)
    const sweepGroup = container.querySelector('svg [data-radar-sweep]')
    expect(sweepGroup).not.toBeNull()
    const style = sweepGroup?.getAttribute('style') ?? ''
    expect(style).not.toContain('animation')
  })

  it('sweep prop applies a CSS rotate animation with the given duration', () => {
    const { container } = render(<RadarMark size={12} sweep sweepDuration="2.2s" />)
    const sweepGroup = container.querySelector('svg [data-radar-sweep]')
    expect(sweepGroup).not.toBeNull()
    const style = sweepGroup?.getAttribute('style') ?? ''
    expect(style).toMatch(/animation/)
    expect(style).toContain('2.2s')
  })

  it('uses signal blue for the sweep + center dot', () => {
    const { container } = render(<RadarMark size={96} />)
    const line = container.querySelector('svg line')
    expect(line?.getAttribute('stroke')?.toUpperCase()).toBe('#3B9EFF')
  })

  /* Three variants drive the autopilot light/full distinction.
     'default' is the chrome lockup look (transparent bg, fog rings,
     signal sweep). 'light' inverts to filled-grey-bg with signal-
     blue lines for autopilot light pipeline. 'full' inverts the
     other way: filled-signal-blue-bg with fog/bone lines for
     autopilot full pipeline. The filled background is the dominant
     differentiator at small sizes. */
  it('default variant has no background fill', () => {
    const { container } = render(<RadarMark size={48} />)
    const bgFill = container.querySelector('svg circle[data-radar-bg]')
    expect(bgFill).toBeNull()
  })

  it('variant="light" fills the radar disc with grey carbon, lines in signal blue', () => {
    const { container } = render(<RadarMark size={48} variant="light" />)
    const bg = container.querySelector('svg circle[data-radar-bg]')
    expect(bg?.getAttribute('fill')?.toUpperCase()).toBe('#10141B')
    const ring = container.querySelector('svg circle[r="28"]')
    expect(ring?.getAttribute('stroke')?.toUpperCase()).toBe('#3B9EFF')
    const line = container.querySelector('svg line')
    expect(line?.getAttribute('stroke')?.toUpperCase()).toBe('#3B9EFF')
  })

  it('variant="full" fills disc with signalDim (toned-down blue), lines in bone (high-contrast white)', () => {
    /* signalDim instead of pure signal — full variant should pop
       without screaming. Bone lines instead of ink — white-on-blue
       reads as "active scope", much more visible than dark-on-blue. */
    const { container } = render(<RadarMark size={48} variant="full" />)
    const bg = container.querySelector('svg circle[data-radar-bg]')
    expect(bg?.getAttribute('fill')?.toUpperCase()).toBe('#1F6FBF')
    const ring = container.querySelector('svg circle[r="28"]')
    expect(ring?.getAttribute('stroke')?.toUpperCase()).toBe('#E6EBF2')
    const line = container.querySelector('svg line')
    expect(line?.getAttribute('stroke')?.toUpperCase()).toBe('#E6EBF2')
  })

  /* At 14px the default's 1px inner-ring strokes + 0.4/0.6 opacities
     vanish into sub-pixel territory. Filled-disc variants bump
     strokes and remove opacity reduction so all three rings stay
     readable at small inline sizes. Default (chrome use at 18-36px+)
     keeps the original subtle treatment. */
  it('filled variants render inner rings at full opacity (no fade)', () => {
    const { container: light } = render(<RadarMark size={14} variant="light" />)
    const lightInnerRings = light.querySelectorAll('svg circle[r="19"], svg circle[r="10"]')
    lightInnerRings.forEach((r) => {
      const op = r.getAttribute('opacity')
      expect(op === null || op === '1').toBe(true)
    })

    const { container: full } = render(<RadarMark size={14} variant="full" />)
    const fullInnerRings = full.querySelectorAll('svg circle[r="19"], svg circle[r="10"]')
    fullInnerRings.forEach((r) => {
      const op = r.getAttribute('opacity')
      expect(op === null || op === '1').toBe(true)
    })
  })

  it('default variant keeps the subtle 0.6/0.4 inner-ring opacities', () => {
    const { container } = render(<RadarMark size={48} />)
    const mid = container.querySelector('svg circle[r="19"]')
    const inner = container.querySelector('svg circle[r="10"]')
    expect(mid?.getAttribute('opacity')).toBe('0.6')
    expect(inner?.getAttribute('opacity')).toBe('0.4')
  })
})
