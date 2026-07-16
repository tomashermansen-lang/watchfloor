import React from 'react'
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { render, screen, fireEvent } from '@testing-library/react'
import userEvent from '@testing-library/user-event'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import PlansFilterBar, {
  type PlansFilterBarProps,
} from '../components/PlansFilterBar'
import type {
  LifecycleChip,
} from '../hooks/usePlanFilters'

/* localStorage shim copied verbatim from FeaturesView.test.tsx so any
   imported module that touches `localStorage` at module load resolves
   cleanly. PlansFilterBar itself is presentational and does not call
   the hook, but the shim removes a hidden environment risk. */
{
  const _store = new Map<string, string>()
  const shim: Storage = {
    getItem: (k: string): string | null =>
      _store.has(k) ? (_store.get(k) as string) : null,
    setItem: (k: string, v: string): void => {
      _store.set(k, String(v))
    },
    removeItem: (k: string): void => {
      _store.delete(k)
    },
    clear: (): void => {
      _store.clear()
    },
    key: (i: number): string | null => Array.from(_store.keys())[i] ?? null,
    get length(): number {
      return _store.size
    },
  }
  Object.defineProperty(globalThis, 'localStorage', {
    value: shim,
    configurable: true,
    writable: true,
  })
  if (typeof window !== 'undefined') {
    Object.defineProperty(window, 'localStorage', {
      value: shim,
      configurable: true,
      writable: true,
    })
  }
}

const defaultBarProps = (
  overrides: Partial<PlansFilterBarProps> = {},
): PlansFilterBarProps => ({
  lifecycle: new Set<LifecycleChip>(['active', 'open']),
  project: new Set<string>(),
  search: '',
  sort: 'group-then-progress-desc',
  chipNames: ['eulex', 'OIH'],
  setLifecycle: vi.fn(),
  setProject: vi.fn(),
  setSearch: vi.fn(),
  setSort: vi.fn(),
  ...overrides,
})

function renderBar(props: PlansFilterBarProps) {
  return render(
    <ThemeProvider theme={theme}>
      <PlansFilterBar {...props} />
    </ThemeProvider>,
  )
}

const lifecycleChip = (v: string): HTMLElement =>
  document.querySelector(
    `[data-filter="lifecycle"][data-value="${v}"] [data-testid="wf-toggle-chip"]`,
  ) as HTMLElement

const projectChip = (v: string): HTMLElement =>
  document.querySelector(
    `[data-filter="project"][data-value="${v}"] [data-testid="wf-toggle-chip"]`,
  ) as HTMLElement

const sortChip = (v: string): HTMLElement =>
  document.querySelector(
    `[data-filter="sort"][data-value="${v}"] [data-testid="wf-toggle-chip"]`,
  ) as HTMLElement

describe('PlansFilterBar', () => {
  beforeEach(() => {
    vi.clearAllMocks()
  })

  /* PFB-1 — REQ-26 */
  it('renders the four lifecycle chips in order with data-filter and data-value attributes', () => {
    renderBar(defaultBarProps())
    const wrappers = document.querySelectorAll('[data-filter="lifecycle"]')
    const values = Array.from(wrappers).map((w) => w.getAttribute('data-value'))
    expect(values).toEqual(['active', 'open', 'done', 'pending'])
    wrappers.forEach((w) => {
      expect(w.querySelector('[data-testid="wf-toggle-chip"]')).toBeTruthy()
    })
  })

  /* PFB-2 — REQ-26, REQ-31, AS-19 (selection-render half) */
  it('lifecycle chips reflect selection state via data-active', () => {
    renderBar(defaultBarProps())
    expect(lifecycleChip('active').getAttribute('data-active')).toBe('true')
    expect(lifecycleChip('open').getAttribute('data-active')).toBe('true')
    expect(lifecycleChip('done').getAttribute('data-active')).toBe('false')
    expect(lifecycleChip('pending').getAttribute('data-active')).toBe('false')
  })

  /* PFB-3 — REQ-31, AS-19 (toggle-off branch) */
  it('clicking the active Active chip calls setLifecycle with a new Set excluding active', async () => {
    const setLifecycle = vi.fn()
    const original = new Set<LifecycleChip>(['active', 'open'])
    renderBar(defaultBarProps({ lifecycle: original, setLifecycle }))
    await userEvent.click(lifecycleChip('active'))
    expect(setLifecycle).toHaveBeenCalledTimes(1)
    const arg = setLifecycle.mock.calls[0][0] as Set<LifecycleChip>
    expect(arg).toBeInstanceOf(Set)
    expect(Array.from(arg)).toEqual(['open'])
    expect(Array.from(original)).toEqual(['active', 'open'])
  })

  /* PFB-4 — REQ-31 (toggle-on branch) */
  it('clicking an inactive Done chip calls setLifecycle with a new Set including done', async () => {
    const setLifecycle = vi.fn()
    renderBar(
      defaultBarProps({
        lifecycle: new Set<LifecycleChip>(['active', 'open']),
        setLifecycle,
      }),
    )
    await userEvent.click(lifecycleChip('done'))
    const arg = setLifecycle.mock.calls[0][0] as Set<LifecycleChip>
    expect(Array.from(arg).sort()).toEqual(['active', 'done', 'open'])
  })

  /* PFB-5 — REQ-31 referential identity */
  it('setLifecycle receives a different Set reference than the input prop', async () => {
    const setLifecycle = vi.fn()
    const props = defaultBarProps({ setLifecycle })
    renderBar(props)
    await userEvent.click(lifecycleChip('done'))
    const arg = setLifecycle.mock.calls[0][0]
    expect(Object.is(arg, props.lifecycle)).toBe(false)
  })

  /* PFB-6 — REQ-12, REQ-25 (project row hidden) */
  it('hides the project chip row when chipNames is empty', () => {
    renderBar(defaultBarProps({ chipNames: [] }))
    const wrappers = document.querySelectorAll('[data-filter="project"]')
    expect(wrappers.length).toBe(0)
  })

  /* PFB-7 — REQ-12, REQ-27 */
  it('renders one project chip per chipName with verbatim label and data-value', () => {
    renderBar(defaultBarProps({ chipNames: ['eulex', 'OIH'] }))
    const wrappers = document.querySelectorAll('[data-filter="project"]')
    expect(wrappers.length).toBe(2)
    const values = Array.from(wrappers).map((w) => w.getAttribute('data-value'))
    expect(values).toEqual(['eulex', 'OIH'])
    expect(projectChip('OIH').textContent).toContain('OIH')
    expect(projectChip('eulex').textContent).toContain('eulex')
  })

  /* PFB-8 — REQ-13, REQ-31 */
  it('clicking a project chip toggles its membership in the Set passed to setProject', async () => {
    const setProject = vi.fn()
    renderBar(
      defaultBarProps({
        project: new Set<string>(),
        setProject,
      }),
    )
    await userEvent.click(projectChip('OIH'))
    const arg = setProject.mock.calls[0][0] as Set<string>
    expect(arg).toBeInstanceOf(Set)
    expect(Array.from(arg)).toEqual(['OIH'])
  })

  /* PFB-9 — sort chip labels + ordering. Audit-list-filters #3 renamed
     'Group' → 'Status' to match FeatureList's vocabulary and clarify that
     the chip orders by lifecycle state. */
  it('renders the three sort chips in order with data-filter and data-value', () => {
    renderBar(defaultBarProps())
    const wrappers = document.querySelectorAll('[data-filter="sort"]')
    const values = Array.from(wrappers).map((w) => w.getAttribute('data-value'))
    expect(values).toEqual([
      'group-then-progress-desc',
      'name-asc',
      'last-activity-desc',
    ])
    expect(sortChip('group-then-progress-desc').textContent).toContain('Status')
    expect(sortChip('name-asc').textContent).toContain('Name A→Z')
    expect(sortChip('last-activity-desc').textContent).toContain('Recent')
  })

  /* PFB-9a — audit-list-filters #3. Each sort chip carries a `title`
     attribute explaining what it sorts by, since the labels alone don't
     answer 'A→Z by what?' or 'Group of what?'. */
  it('each sort chip exposes a title attribute describing its sort key', () => {
    renderBar(defaultBarProps())
    const statusTitle = sortChip('group-then-progress-desc').getAttribute('title')
    const nameTitle = sortChip('name-asc').getAttribute('title')
    const recentTitle = sortChip('last-activity-desc').getAttribute('title')
    expect(statusTitle).toMatch(/lifecycle|active|open|done/i)
    expect(nameTitle).toMatch(/name|alphabet/i)
    expect(recentTitle).toMatch(/recent|activity|last/i)
  })

  /* PFB-10 — REQ-30, AS-18 (single-active half) */
  it('exactly one sort chip is active and matches props.sort', () => {
    renderBar(defaultBarProps())
    expect(sortChip('group-then-progress-desc').getAttribute('data-active')).toBe('true')
    expect(sortChip('name-asc').getAttribute('data-active')).toBe('false')
    expect(sortChip('last-activity-desc').getAttribute('data-active')).toBe('false')
  })

  /* PFB-11 — REQ-30 (no-op on active click) */
  it('clicking the active sort chip does not call setSort', async () => {
    const setSort = vi.fn()
    renderBar(defaultBarProps({ setSort }))
    await userEvent.click(sortChip('group-then-progress-desc'))
    expect(setSort).not.toHaveBeenCalled()
  })

  /* PFB-12 — REQ-30, AS-18 (replacement half) */
  it('clicking an inactive sort chip calls setSort with that chip value', async () => {
    const setSort = vi.fn()
    renderBar(defaultBarProps({ setSort }))
    await userEvent.click(sortChip('name-asc'))
    expect(setSort).toHaveBeenCalledTimes(1)
    expect(setSort).toHaveBeenCalledWith('name-asc')
  })

  /* PFB-12a — audit-list-filters #4. Sort chips are useless when the
     post-filter set has 0 or 1 plans (nothing to reorder), so the entire
     row is hidden in those cases. Lifecycle/project chips and the
     search input remain visible so the operator can broaden the filter
     and recover from a too-narrow selection. */
  it('hides sort chip row when visibleCount is 0', () => {
    renderBar(defaultBarProps({ visibleCount: 0 }))
    expect(document.querySelectorAll('[data-filter="sort"]').length).toBe(0)
    /* Lifecycle chips still render so the empty-state can be escaped. */
    expect(document.querySelectorAll('[data-filter="lifecycle"]').length).toBe(4)
    expect(screen.getByTestId('plan-filter-search')).toBeTruthy()
  })

  it('hides sort chip row when visibleCount is 1', () => {
    renderBar(defaultBarProps({ visibleCount: 1 }))
    expect(document.querySelectorAll('[data-filter="sort"]').length).toBe(0)
  })

  it('renders sort chip row when visibleCount is 2 or more', () => {
    renderBar(defaultBarProps({ visibleCount: 2 }))
    expect(document.querySelectorAll('[data-filter="sort"]').length).toBe(3)
  })

  it('defaults to rendering sort row when visibleCount is omitted (back-compat)', () => {
    renderBar(defaultBarProps())
    expect(document.querySelectorAll('[data-filter="sort"]').length).toBe(3)
  })

  /* PFB-13 — REQ-29 */
  it('search input renders with required attributes', () => {
    renderBar(defaultBarProps())
    const input = screen.getByTestId('plan-filter-search') as HTMLInputElement
    expect(input.getAttribute('aria-label')).toBe('Search plans')
    expect(input.getAttribute('placeholder')).toBe('Search name or project')
    expect(input.getAttribute('type')).toBe('text')
  })

  /* PFB-14 — REQ-29 */
  it('search input value is bound to props.search', () => {
    renderBar(defaultBarProps({ search: 'foo' }))
    const input = screen.getByTestId('plan-filter-search') as HTMLInputElement
    expect(input.value).toBe('foo')
  })

  /* PFB-15 — REQ-29, EC-17 */
  it('typing keystrokes updates the controlled search value', async () => {
    const Harness = () => {
      const [value, setValue] = React.useState('')
      const setSearch = (next: string) => setValue(next)
      return (
        <ThemeProvider theme={theme}>
          <PlansFilterBar
            {...defaultBarProps({ search: value, setSearch })}
          />
        </ThemeProvider>
      )
    }
    render(<Harness />)
    const input = screen.getByTestId('plan-filter-search') as HTMLInputElement
    await userEvent.type(input, 'auth')
    expect(input.value).toBe('auth')
  })

  /* PFB-16 — REQ-15, EC-8 */
  it('search input does not trim leading whitespace before forwarding to setSearch', () => {
    const setSearch = vi.fn()
    renderBar(defaultBarProps({ search: '', setSearch }))
    const input = screen.getByTestId('plan-filter-search') as HTMLInputElement
    fireEvent.change(input, { target: { value: ' watchfloor' } })
    expect(setSearch).toHaveBeenCalledWith(' watchfloor')
  })

  /* PFB-17 — REQ-2, REQ-3 */
  it('does not call localStorage.setItem during render', () => {
    const spy = vi.spyOn(localStorage, 'setItem')
    renderBar(defaultBarProps())
    expect(spy).not.toHaveBeenCalled()
    spy.mockRestore()
  })

  /* PFB-18 — REQ-2 (no internal state) */
  it('rerendering with the same props produces the same DOM', () => {
    const props = defaultBarProps()
    const { container, rerender } = render(
      <ThemeProvider theme={theme}>
        <PlansFilterBar {...props} />
      </ThemeProvider>,
    )
    const before = container.innerHTML
    rerender(
      <ThemeProvider theme={theme}>
        <PlansFilterBar {...props} />
      </ThemeProvider>,
    )
    expect(container.innerHTML).toBe(before)
  })

  /* PFB-19 — REQ-25 (layout order) */
  it('layout has lifecycle row, project row, then a flex row with search left and sort right', () => {
    const { container } = renderBar(defaultBarProps())
    const lifecycleAnchor = container.querySelector('[data-filter="lifecycle"]')
    const projectAnchor = container.querySelector('[data-filter="project"]')
    const sortAnchor = container.querySelector('[data-filter="sort"]')
    const searchAnchor = container.querySelector('[data-testid="plan-filter-search"]')
    expect(lifecycleAnchor).toBeTruthy()
    expect(projectAnchor).toBeTruthy()
    expect(sortAnchor).toBeTruthy()
    expect(searchAnchor).toBeTruthy()
    const positions: number[] = [-1, -1, -1, -1]
    container.querySelectorAll('*').forEach((node, idx) => {
      if (node === lifecycleAnchor) positions[0] = idx
      if (node === projectAnchor) positions[1] = idx
      if (node === searchAnchor) positions[2] = idx
      if (node === sortAnchor) positions[3] = idx
    })
    expect(positions[0]).toBeLessThan(positions[1])
    expect(positions[1]).toBeLessThan(positions[2])
    expect(positions[2]).toBeLessThan(positions[3])
  })

  /* PFB-20 — REQ-25 (project row collapses cleanly) */
  it('with empty chipNames the wrapper still has lifecycle + search/sort rows and no project row', () => {
    const { container } = renderBar(defaultBarProps({ chipNames: [] }))
    expect(container.querySelector('[data-filter="lifecycle"]')).toBeTruthy()
    expect(container.querySelector('[data-filter="project"]')).toBeNull()
    expect(container.querySelector('[data-filter="sort"]')).toBeTruthy()
    expect(container.querySelector('[data-testid="plan-filter-search"]')).toBeTruthy()
  })
})
