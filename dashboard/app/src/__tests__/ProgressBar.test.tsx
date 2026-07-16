import { describe, it, expect } from 'vitest'
import { render } from '@testing-library/react'
import ProgressBar from '../components/wf/ProgressBar'

describe('<ProgressBar>', () => {
  it('renders a 4px-tall bar by default', () => {
    const { container } = render(<ProgressBar value={0.5} />)
    const root = container.querySelector('[data-testid="wf-progress-bar"]') as HTMLElement
    expect(root).not.toBeNull()
    expect(root.style.height).toBe('4px')
  })

  it('uses wf.steel as track', () => {
    const { container } = render(<ProgressBar value={0.5} />)
    const root = container.querySelector('[data-testid="wf-progress-bar"]') as HTMLElement
    expect(root.style.backgroundColor).toBe('rgb(27, 34, 48)')
  })

  it('uses wf.signal as fill', () => {
    const { container } = render(<ProgressBar value={0.5} />)
    const fill = container.querySelector('[data-testid="wf-progress-bar-fill"]') as HTMLElement
    expect(fill.style.backgroundColor).toBe('rgb(59, 158, 255)')
  })

  it('renders signal glow on fill', () => {
    const { container } = render(<ProgressBar value={0.5} />)
    const fill = container.querySelector('[data-testid="wf-progress-bar-fill"]') as HTMLElement
    expect(fill.style.boxShadow).toBe('0 0 6px #3B9EFF')
  })

  it('uses sharp corners on track and fill', () => {
    const { container } = render(<ProgressBar value={0.5} />)
    const root = container.querySelector('[data-testid="wf-progress-bar"]') as HTMLElement
    const fill = container.querySelector('[data-testid="wf-progress-bar-fill"]') as HTMLElement
    expect(root.style.borderRadius).toBe('')
    expect(fill.style.borderRadius).toBe('')
  })

  it('maps value=0 to 0% width on the fill', () => {
    const { container } = render(<ProgressBar value={0} />)
    const fill = container.querySelector('[data-testid="wf-progress-bar-fill"]') as HTMLElement
    expect(fill.style.width).toBe('0%')
  })

  it('maps value=1 to 100% width on the fill', () => {
    const { container } = render(<ProgressBar value={1} />)
    const fill = container.querySelector('[data-testid="wf-progress-bar-fill"]') as HTMLElement
    expect(fill.style.width).toBe('100%')
  })

  it('clamps value below 0 to 0%', () => {
    const { container } = render(<ProgressBar value={-0.5} />)
    const fill = container.querySelector('[data-testid="wf-progress-bar-fill"]') as HTMLElement
    expect(fill.style.width).toBe('0%')
  })

  it('clamps value above 1 to 100%', () => {
    const { container } = render(<ProgressBar value={1.5} />)
    const fill = container.querySelector('[data-testid="wf-progress-bar-fill"]') as HTMLElement
    expect(fill.style.width).toBe('100%')
  })

  it('honors custom height', () => {
    const { container } = render(<ProgressBar value={0.5} height={6} />)
    const root = container.querySelector('[data-testid="wf-progress-bar"]') as HTMLElement
    expect(root.style.height).toBe('6px')
  })

  it('exposes value via aria attributes for a11y', () => {
    const { container } = render(<ProgressBar value={0.42} />)
    const root = container.querySelector('[data-testid="wf-progress-bar"]') as HTMLElement
    expect(root.getAttribute('role')).toBe('progressbar')
    expect(root.getAttribute('aria-valuenow')).toBe('42')
    expect(root.getAttribute('aria-valuemin')).toBe('0')
    expect(root.getAttribute('aria-valuemax')).toBe('100')
  })
})
