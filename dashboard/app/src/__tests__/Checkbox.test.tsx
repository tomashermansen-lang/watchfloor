import { describe, it, expect, vi } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import wfTheme from '../theme'
import Checkbox from '../components/wf/Checkbox'

function renderWithTheme(ui: React.ReactElement) {
  return render(<ThemeProvider theme={wfTheme}>{ui}</ThemeProvider>)
}

describe('wf Checkbox primitive', () => {
  it('renders an input[type=checkbox] for accessibility', () => {
    renderWithTheme(<Checkbox aria-label='accept' />)
    const cb = screen.getByLabelText('accept') as HTMLInputElement
    expect(cb.tagName).toBe('INPUT')
    expect(cb.type).toBe('checkbox')
  })

  it('reflects checked prop', () => {
    renderWithTheme(<Checkbox aria-label='cb' checked readOnly />)
    expect((screen.getByLabelText('cb') as HTMLInputElement).checked).toBe(true)
  })

  it('fires onChange when toggled', () => {
    const onChange = vi.fn()
    renderWithTheme(<Checkbox aria-label='cb' checked={false} onChange={onChange} />)
    fireEvent.click(screen.getByLabelText('cb'))
    expect(onChange).toHaveBeenCalledTimes(1)
  })

  it('exposes data-indeterminate when indeterminate prop is set', () => {
    renderWithTheme(<Checkbox aria-label='cb' indeterminate />)
    const cb = screen.getByLabelText('cb') as HTMLInputElement
    expect(cb.getAttribute('data-indeterminate')).toBe('true')
  })

  it('honours disabled', () => {
    renderWithTheme(<Checkbox aria-label='cb' disabled />)
    expect((screen.getByLabelText('cb') as HTMLInputElement).disabled).toBe(true)
  })
})
