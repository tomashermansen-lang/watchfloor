import { describe, it, expect } from 'vitest'
import { render } from '@testing-library/react'
import AppIcon, { APP_ICON_TYPES } from '../components/wf/AppIcon'
import type { AppIconType } from '../components/wf/AppIcon'

describe('<AppIcon>', () => {
  it('exports the 8 handoff icon types', () => {
    /* Lock the type set so future additions are deliberate. */
    expect([...APP_ICON_TYPES].sort()).toEqual([
      'deviations',
      'document',
      'features',
      'metrics',
      'pipeline',
      'plan',
      'sessions',
      'vision',
    ])
  })

  it.each(APP_ICON_TYPES.map((t) => [t]))(
    'renders a 24x24 viewBox SVG for type=%s',
    (type) => {
      const { container } = render(<AppIcon type={type as AppIconType} />)
      const svg = container.querySelector('svg')
      expect(svg).not.toBeNull()
      expect(svg?.getAttribute('viewBox')).toBe('0 0 24 24')
    },
  )

  it('uses currentColor for stroke so callers control color via CSS', () => {
    const { container } = render(<AppIcon type="vision" />)
    const svg = container.querySelector('svg')
    expect(svg?.getAttribute('stroke')).toBe('currentColor')
  })

  it('honors the size prop on width and height', () => {
    const { container } = render(<AppIcon type="plan" size={32} />)
    const svg = container.querySelector('svg')
    expect(svg?.getAttribute('width')).toBe('32')
    expect(svg?.getAttribute('height')).toBe('32')
  })

  it('exposes data-icon attribute on the SVG so callers can assert which icon rendered', () => {
    const { container } = render(<AppIcon type="metrics" />)
    const svg = container.querySelector('svg')
    expect(svg?.getAttribute('data-icon')).toBe('metrics')
  })

  it('uses 1.5px stroke + sharp linecap/linejoin per handoff spec', () => {
    const { container } = render(<AppIcon type="vision" />)
    const svg = container.querySelector('svg')
    expect(svg?.getAttribute('stroke-width')).toBe('1.5')
    expect(svg?.getAttribute('stroke-linecap')).toBe('square')
    expect(svg?.getAttribute('stroke-linejoin')).toBe('miter')
  })

  it('returns null for unknown icon type (defensive)', () => {
    /* Cast through unknown so the runtime check is testable even though
       TypeScript would normally reject the bad type at the call site. */
    const { container } = render(<AppIcon type={'nope' as unknown as AppIconType} />)
    expect(container.querySelector('svg')).toBeNull()
  })

  /* Active state — adds an accent dot/marker. The icon library doesn't
     mandate a specific selector, but each icon must have *some* DOM
     change between active=false and active=true so the operator can
     visually distinguish the active nav item even before colour is
     considered. */
  it.each(APP_ICON_TYPES.map((t) => [t]))(
    '%s renders different DOM for active vs inactive',
    (type) => {
      const inactive = render(<AppIcon type={type as AppIconType} />).container.innerHTML
      const active = render(<AppIcon type={type as AppIconType} active />).container.innerHTML
      expect(active).not.toBe(inactive)
    },
  )
})
