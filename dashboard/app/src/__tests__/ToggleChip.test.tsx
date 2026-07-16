import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import ToggleChip from '../components/wf/ToggleChip'

function renderChip(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

describe('wf/ToggleChip', () => {
  it('renders the label inside a wf-toggle-chip button', () => {
    renderChip(<ToggleChip label="phases" active onClick={() => {}} />)
    const node = screen.getByTestId('wf-toggle-chip')
    expect(node.tagName).toBe('BUTTON')
    expect(node.textContent).toMatch(/phases/i)
  })

  it('exposes active state via data-active and aria-pressed', () => {
    renderChip(<ToggleChip label="x" active onClick={() => {}} />)
    const node = screen.getByTestId('wf-toggle-chip')
    expect(node.getAttribute('data-active')).toBe('true')
    expect(node.getAttribute('aria-pressed')).toBe('true')
  })

  it('inactive state reads false', () => {
    renderChip(<ToggleChip label="x" active={false} onClick={() => {}} />)
    const node = screen.getByTestId('wf-toggle-chip')
    expect(node.getAttribute('data-active')).toBe('false')
    expect(node.getAttribute('aria-pressed')).toBe('false')
  })

  it('fires onClick when clicked', () => {
    const onClick = vi.fn()
    renderChip(<ToggleChip label="x" active onClick={onClick} />)
    fireEvent.click(screen.getByTestId('wf-toggle-chip'))
    expect(onClick).toHaveBeenCalledTimes(1)
  })

  /* Optional icon slot — used by SessionPanel sidebar (Documents,
     SESSION HISTORY) so navigation buttons can include a glyph
     prefix while sharing the chip vocabulary. Per design audit
     screen 5 #1+#2+#3: previously these buttons used
     borderRadius:999 pills, breaking visual continuity with the
     SHOW filter row. ToggleChip is the only sharp-corner button
     primitive — extending it lets us converge without inventing
     a second component. */
  describe('icon slot', () => {
    it('renders the icon node before the label when provided', () => {
      renderChip(
        <ToggleChip
          label="history"
          active={false}
          onClick={() => {}}
          icon={<span data-testid="chip-icon">★</span>}
        />,
      )
      const node = screen.getByTestId('wf-toggle-chip')
      const icon = screen.getByTestId('chip-icon')
      expect(icon).toBeInTheDocument()
      // Icon must be inside the button, before the label text
      expect(node.contains(icon)).toBe(true)
      const buttonText = node.textContent ?? ''
      expect(buttonText.indexOf('★')).toBeLessThan(buttonText.indexOf('history'))
    })

    it('omits the icon slot when no icon is provided', () => {
      renderChip(<ToggleChip label="x" active={false} onClick={() => {}} />)
      expect(screen.queryByTestId('chip-icon')).toBeNull()
    })
  })

  it('disabled forwards to button + skips click', () => {
    const onClick = vi.fn()
    renderChip(<ToggleChip label="x" active disabled onClick={onClick} />)
    const node = screen.getByTestId('wf-toggle-chip') as HTMLButtonElement
    expect(node.disabled).toBe(true)
    fireEvent.click(node)
    expect(onClick).not.toHaveBeenCalled()
  })
})
