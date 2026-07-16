import { describe, it, expect } from 'vitest'
import { render } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import SubagentRadar from '../components/wf/SubagentRadar'

function renderRadar(props: Parameters<typeof SubagentRadar>[0]) {
  return render(
    <ThemeProvider theme={theme}>
      <SubagentRadar {...props} />
    </ThemeProvider>,
  )
}

describe('SubagentRadar (brand)', () => {
  it('renders three concentric brand rings + center dot', () => {
    /* Watchfloor radar geometry: three reference rings (outer/mid/inner)
       in wf.fog at decreasing opacity, plus a Signal Blue center dot —
       same skeleton as RadarMark so the chart and the brand mark read
       as the same family. */
    const { container } = renderRadar({
      size: 200,
      data: [{ name: 'general-purpose', value: 1 }],
    })
    const rings = container.querySelectorAll('[data-radar-ring]')
    expect(rings.length).toBe(3)
    expect(container.querySelector('[data-radar-center]')).toBeTruthy()
  })

  it('renders one pie wedge path per agent type', () => {
    const { container } = renderRadar({
      size: 200,
      data: [
        { name: 'general-purpose', value: 7 },
        { name: 'explore', value: 3 },
        { name: 'fixer', value: 2 },
      ],
    })
    const wedges = container.querySelectorAll('[data-radar-wedge]')
    expect(wedges.length).toBe(3)
    /* Each wedge carries its agent name as data attribute so the
       legend / tooltips can correlate by name without parsing the
       path string. */
    const names = Array.from(wedges).map((w) => w.getAttribute('data-name'))
    expect(names).toEqual(['general-purpose', 'explore', 'fixer'])
  })

  it('renders a single full-disc wedge when only one agent type exists', () => {
    /* Single-segment edge case: emit a circle (or full-arc path) so
       the disc fills cleanly without zero-area rendering quirks. */
    const { container } = renderRadar({
      size: 200,
      data: [{ name: 'general-purpose', value: 5 }],
    })
    const wedges = container.querySelectorAll('[data-radar-wedge]')
    expect(wedges.length).toBe(1)
  })

  it('renders sweep line only when sweep=true (running subagents)', () => {
    const { container, rerender } = renderRadar({
      size: 200,
      data: [{ name: 'a', value: 1 }],
      sweep: false,
    })
    expect(container.querySelector('[data-radar-sweep]')).toBeFalsy()
    rerender(
      <ThemeProvider theme={theme}>
        <SubagentRadar size={200} data={[{ name: 'a', value: 1 }]} sweep />
      </ThemeProvider>,
    )
    expect(container.querySelector('[data-radar-sweep]')).toBeTruthy()
  })

  it('renders nothing when data is empty', () => {
    const { container } = renderRadar({ size: 200, data: [] })
    expect(container.querySelector('[data-radar-wedge]')).toBeFalsy()
  })
})
