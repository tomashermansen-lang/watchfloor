import { describe, it, expect } from 'vitest'
import { render } from '@testing-library/react'
import StatusDot from '../components/wf/StatusDot'

describe('<StatusDot>', () => {
  it('renders a 6px round element by default', () => {
    const { container } = render(<StatusDot status="running" />)
    const dot = container.querySelector('[data-testid="wf-status-dot"]')
    expect(dot).not.toBeNull()
    const style = getComputedStyle(dot as Element)
    expect(style.width).toBe('6px')
    expect(style.height).toBe('6px')
    expect(style.borderRadius).toBe('50%')
  })

  it('uses signal blue for running', () => {
    const { container } = render(<StatusDot status="running" />)
    const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
    expect(dot.style.backgroundColor).toBe('rgb(59, 158, 255)')
  })

  it('uses green for completed', () => {
    const { container } = render(<StatusDot status="completed" />)
    const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
    expect(dot.style.backgroundColor).toBe('rgb(91, 214, 138)')
  })

  it('uses amber for stalled', () => {
    const { container } = render(<StatusDot status="stalled" />)
    const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
    expect(dot.style.backgroundColor).toBe('rgb(242, 180, 65)')
  })

  it('uses red for fault', () => {
    const { container } = render(<StatusDot status="fault" />)
    const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
    expect(dot.style.backgroundColor).toBe('rgb(239, 77, 77)')
  })

  /* Glow is reserved for LIVE states — running, stalled, fault.
     Completed is a terminal state that shouldn't compete for attention.
     Brand language is "attention/live = signal", and a static checkmark
     borrowing that treatment confuses the eye. */
  it('running glows — live working state', () => {
    const { container } = render(<StatusDot status="running" />)
    const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
    expect(dot.style.boxShadow).toBe('0 0 5px #3B9EFF')
  })

  it('stalled glows — live blocked state, demands user input', () => {
    const { container } = render(<StatusDot status="stalled" />)
    const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
    expect(dot.style.boxShadow).toBe('0 0 5px #F2B441')
  })

  it('fault glows — unresolved error, demands attention', () => {
    const { container } = render(<StatusDot status="fault" />)
    const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
    expect(dot.style.boxShadow).toBe('0 0 5px #EF4D4D')
  })

  it('completed does NOT glow — terminal archive state', () => {
    const { container } = render(<StatusDot status="completed" />)
    const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
    expect(dot.style.boxShadow).toBe('')
  })

  it('glow={true} prop forces glow on completed (override)', () => {
    const { container } = render(<StatusDot status="completed" glow />)
    const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
    expect(dot.style.boxShadow).toBe('0 0 5px #5BD68A')
  })

  it('glow={false} prop suppresses glow on running (override)', () => {
    const { container } = render(<StatusDot status="running" glow={false} />)
    const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
    expect(dot.style.boxShadow).toBe('')
  })

  it('honors custom size', () => {
    const { container } = render(<StatusDot status="running" size={10} />)
    const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
    expect(dot.style.width).toBe('10px')
    expect(dot.style.height).toBe('10px')
  })

  /* `queued` is the inert pre-run state — task scheduled but not started.
     Spec says wf.fog (#5A6472) and no glow: the dot should read as a
     placeholder, not a live signal. */
  it('uses fog grey for queued', () => {
    const { container } = render(<StatusDot status="queued" />)
    const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
    expect(dot.style.backgroundColor).toBe('rgb(90, 100, 114)')
  })

  it('queued does NOT glow — inert pre-run state', () => {
    const { container } = render(<StatusDot status="queued" />)
    const dot = container.querySelector('[data-testid="wf-status-dot"]') as HTMLElement
    expect(dot.style.boxShadow).toBe('')
  })
})
