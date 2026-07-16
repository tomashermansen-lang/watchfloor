import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import EmptyScope from '../components/wf/EmptyScope'

function renderScope(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

describe('wf/EmptyScope', () => {
  it('renders the brand headline by default', () => {
    renderScope(<EmptyScope />)
    expect(screen.getByText(/the watchfloor is listening/i)).toBeInTheDocument()
  })

  it('renders a 320px radar scope by default with the sweep enabled', () => {
    const { container } = renderScope(<EmptyScope />)
    const svg = container.querySelector('[aria-label="watchfloor radar mark"]')
    expect(svg).not.toBeNull()
    expect(svg?.getAttribute('width')).toBe('320')
    expect(svg?.querySelector('[data-radar-sweep]')).not.toBeNull()
  })

  it('accepts a custom subtitle', () => {
    renderScope(<EmptyScope subtitle="no projects discovered yet" />)
    expect(screen.getByText(/no projects discovered yet/i)).toBeInTheDocument()
  })

  it('respects size prop for the radar scope', () => {
    const { container } = renderScope(<EmptyScope size={200} />)
    const svg = container.querySelector('[aria-label="watchfloor radar mark"]')
    expect(svg?.getAttribute('width')).toBe('200')
  })

  it('exposes a stable testid for layout assertions', () => {
    renderScope(<EmptyScope />)
    expect(screen.getByTestId('wf-empty-scope')).toBeInTheDocument()
  })
})
