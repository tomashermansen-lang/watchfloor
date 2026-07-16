import { describe, it, expect } from 'vitest'
import { render } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import CornerReticles from '../components/wf/CornerReticles'

function renderReticles(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

describe('wf/CornerReticles', () => {
  it('renders four L-shaped corner marks', () => {
    const { container } = renderReticles(<CornerReticles />)
    const reticles = container.querySelectorAll('[data-testid="wf-corner-reticle"]')
    expect(reticles.length).toBe(4)
  })

  it('exposes the corner position via data-corner', () => {
    const { container } = renderReticles(<CornerReticles />)
    const corners = Array.from(
      container.querySelectorAll('[data-testid="wf-corner-reticle"]')
    ).map((n) => n.getAttribute('data-corner'))
    expect(new Set(corners)).toEqual(new Set(['tl', 'tr', 'bl', 'br']))
  })

  it('size and color props flow to the reticle dimensions', () => {
    const { container } = renderReticles(<CornerReticles size={20} color="#abcdef" />)
    const tl = container.querySelector(
      '[data-testid="wf-corner-reticle"][data-corner="tl"]'
    ) as HTMLElement
    expect(tl.style.width).toBe('20px')
    expect(tl.style.height).toBe('20px')
    /* The L-shape is rendered as two abutting borders — the
       reticle color should appear in the rendered border style. */
    expect(tl.style.borderTopColor).toBe('rgb(171, 205, 239)')
  })

  /* Each corner's L-shape must use exactly two borders — the two that
     define its corner, with the other two unset. Regression: type-level
     narrowing failed under strict TS (BACKLOG #56) and motivated the
     uniform Partial-shape refactor of the CORNERS table. */
  it('each corner uses only the two borders that define its L-shape', () => {
    const { container } = renderReticles(<CornerReticles color="#000000" />)
    const get = (id: string): HTMLElement =>
      container.querySelector(`[data-testid="wf-corner-reticle"][data-corner="${id}"]`) as HTMLElement
    const tl = get('tl')
    expect(tl.style.borderTopWidth).not.toBe('')
    expect(tl.style.borderLeftWidth).not.toBe('')
    expect(tl.style.borderBottomWidth).toBe('')
    expect(tl.style.borderRightWidth).toBe('')
    const br = get('br')
    expect(br.style.borderBottomWidth).not.toBe('')
    expect(br.style.borderRightWidth).not.toBe('')
    expect(br.style.borderTopWidth).toBe('')
    expect(br.style.borderLeftWidth).toBe('')
  })
})
