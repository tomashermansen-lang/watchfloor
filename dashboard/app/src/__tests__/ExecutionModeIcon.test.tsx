import { describe, it, expect } from 'vitest'
import { render } from '@testing-library/react'
import ExecutionModeIcon from '../components/wf/ExecutionModeIcon'

describe('<ExecutionModeIcon>', () => {
  /* Icon-only mode indicator — no label, used in compact surfaces
     (Pipeline task nodes, FeatureCard) where the AutopilotBadge pill
     is too heavy. The triplet matches AutopilotBadge.mode 1:1. */

  it('full mode renders the full RadarMark variant (filled disc)', () => {
    const { container } = render(<ExecutionModeIcon mode="full" />)
    expect(container.querySelector('[data-radar-bg]')).not.toBeNull()
    /* AppIcon-style data attribute on the wrapping span lets callers
       query without coupling to the inner SVG. */
    expect(container.querySelector('[data-execution-mode="full"]')).not.toBeNull()
  })

  it('light mode renders the light RadarMark variant (filled disc)', () => {
    const { container } = render(<ExecutionModeIcon mode="light" />)
    expect(container.querySelector('[data-radar-bg]')).not.toBeNull()
    expect(container.querySelector('[data-execution-mode="light"]')).not.toBeNull()
  })

  it('manual mode renders the manual phase icon (no radar)', () => {
    const { container } = render(<ExecutionModeIcon mode="manual" />)
    expect(container.querySelector('[data-radar-bg]')).toBeNull()
    expect(container.querySelector('[data-execution-mode="manual"]')).not.toBeNull()
  })

  it('honors the size prop', () => {
    const { container } = render(<ExecutionModeIcon mode="full" size={20} />)
    const svg = container.querySelector('svg')
    expect(svg?.getAttribute('width')).toBe('20')
    expect(svg?.getAttribute('height')).toBe('20')
  })

  it('full/light radar can sweep when live=true', () => {
    const { container } = render(<ExecutionModeIcon mode="full" live />)
    const sweep = container.querySelector('[data-radar-sweep]') as SVGElement
    expect(sweep.style.animation).toContain('wf-radar-sweep')
  })

  it('manual ignores live (no sweep)', () => {
    const { container } = render(<ExecutionModeIcon mode="manual" live />)
    expect(container.querySelector('[data-radar-sweep]')).toBeNull()
  })
})
