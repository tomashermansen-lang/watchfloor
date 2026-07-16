import { describe, it, expect } from 'vitest'
import { render } from '@testing-library/react'
import PhaseIcon from '../components/wf/PhaseIcon'

describe('<PhaseIcon>', () => {
  it('renders an SVG sized to the requested dimension', () => {
    const { container } = render(<PhaseIcon type="development" size={14} />)
    const svg = container.querySelector('svg')
    expect(svg).not.toBeNull()
    expect(svg?.getAttribute('width')).toBe('14')
    expect(svg?.getAttribute('height')).toBe('14')
    expect(svg?.getAttribute('viewBox')).toBe('0 0 24 24')
  })

  it('honors color via stroke (defaults to currentColor)', () => {
    const { container } = render(<PhaseIcon type="development" />)
    const svg = container.querySelector('svg')
    expect(svg?.getAttribute('stroke')).toBe('currentColor')
  })

  it('renders nothing for unknown phase types', () => {
    /* Defensive — backend may emit a value the brand set doesn't
       cover (e.g. legacy task_type). Fail open: no icon. */
    const { container } = render(<PhaseIcon type={'mysterious' as never} />)
    expect(container.querySelector('svg')).toBeNull()
  })

  it('exposes the 8 brand keys via the lookup map', () => {
    const wanted = ['autopilot', 'development', 'refactor', 'review', 'documentation', 'manual', 'setup', 'gate']
    for (const key of wanted) {
      const { container, unmount } = render(<PhaseIcon type={key as never} />)
      expect(container.querySelector('svg')).not.toBeNull()
      unmount()
    }
  })

  it('marks the active accent on supported icons (development, refactor, documentation, etc.)', () => {
    /* When active, the small inner accent dot turns Signal Blue.
       Easiest assertion: a circle with fill #3B9EFF appears
       somewhere in the SVG. */
    const { container } = render(<PhaseIcon type="development" active />)
    const accent = Array.from(container.querySelectorAll('svg circle'))
      .find((c) => c.getAttribute('fill')?.toUpperCase() === '#3B9EFF')
    expect(accent).toBeTruthy()
  })

  it('static (active=false) icons do not emit a signal-blue accent', () => {
    const { container } = render(<PhaseIcon type="development" />)
    const accent = Array.from(container.querySelectorAll('svg circle'))
      .find((c) => c.getAttribute('fill')?.toUpperCase() === '#3B9EFF')
    expect(accent).toBeFalsy()
  })

  /* PHASE_TYPE_ICON map should be callable for every WfPhaseType. The
     map's value type was previously declared as JSX.Element which is
     not in scope under React 19's TS config — broke `pnpm run build`
     until ReactElement was used (BACKLOG #56 dashboard-build-hygiene). */
  it('PHASE_TYPE_ICON renders every WfPhaseType without throwing', () => {
    const types: Array<'autopilot' | 'development' | 'refactor' | 'review' | 'documentation' | 'manual' | 'setup' | 'gate'> = [
      'autopilot', 'development', 'refactor', 'review',
      'documentation', 'manual', 'setup', 'gate',
    ]
    for (const t of types) {
      const { container } = render(<PhaseIcon type={t} />)
      expect(container.querySelector('svg')).toBeTruthy()
    }
  })
})
