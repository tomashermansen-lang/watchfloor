import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { usePlanFilters } from '../hooks/usePlanFilters'

// Must match STORAGE_KEY in ../hooks/usePlanFilters.ts — update both together.
const STORAGE_KEY = 'wf.planFilters.v1'

class MockStorage {
  private data = new Map<string, string>()
  getItem(key: string): string | null {
    return this.data.has(key) ? (this.data.get(key) as string) : null
  }
  setItem(key: string, value: string): void {
    this.data.set(key, String(value))
  }
  removeItem(key: string): void {
    this.data.delete(key)
  }
  clear(): void {
    this.data.clear()
  }
  get length(): number {
    return this.data.size
  }
  key(n: number): string | null {
    return Array.from(this.data.keys())[n] ?? null
  }
}

Object.defineProperty(globalThis, 'localStorage', {
  value: new MockStorage(),
  writable: true,
  configurable: true,
})

beforeEach(() => {
  localStorage.clear()
  vi.restoreAllMocks()
})

afterEach(() => {
  vi.useRealTimers()
  localStorage.clear()
})

describe('usePlanFilters — Group A: defaults & cold start (REQ-1)', () => {
  it('T-A1 — empty localStorage yields the documented defaults', () => {
    const { result } = renderHook(() => usePlanFilters())
    expect(result.current.lifecycle.size).toBe(2)
    expect(result.current.lifecycle.has('active')).toBe(true)
    expect(result.current.lifecycle.has('open')).toBe(true)
    expect(result.current.project.size).toBe(0)
    expect(result.current.search).toBe('')
    expect(result.current.sort).toBe('group-then-progress-desc')
  })

  it('T-A2 — default lifecycle Set is a fresh instance per mount', () => {
    const r1 = renderHook(() => usePlanFilters())
    const r2 = renderHook(() => usePlanFilters())
    expect(r1.result.current.lifecycle).not.toBe(r2.result.current.lifecycle)
    expect(r1.result.current.project).not.toBe(r2.result.current.project)
  })
})

describe('usePlanFilters — Group B: persistence on non-debounced setters (REQ-2)', () => {
  it('T-B1 — setLifecycle writes v1 JSON within the same render cycle', () => {
    const { result } = renderHook(() => usePlanFilters())
    act(() => result.current.setLifecycle(new Set(['done'])))
    const raw = localStorage.getItem(STORAGE_KEY)
    expect(raw).not.toBeNull()
    const parsed = JSON.parse(raw!) as { lifecycle: string[] }
    expect(parsed.lifecycle).toEqual(['done'])
    expect(result.current.lifecycle.size).toBe(1)
    expect(result.current.lifecycle.has('done')).toBe(true)
  })

  it('T-B2 — setProject + setSort persist both slices', () => {
    const { result } = renderHook(() => usePlanFilters())
    act(() => result.current.setProject(new Set(['OIH'])))
    act(() => result.current.setSort('name-asc'))
    const parsed = JSON.parse(localStorage.getItem(STORAGE_KEY)!) as {
      project: string[]
      sort: string
    }
    expect(parsed.project).toEqual(['OIH'])
    expect(parsed.sort).toBe('name-asc')
  })

  it('T-B3 — empty-Set lifecycle persists as [] and re-hydrates to empty Set', () => {
    const first = renderHook(() => usePlanFilters())
    act(() => first.result.current.setLifecycle(new Set()))
    first.unmount()
    const second = renderHook(() => usePlanFilters())
    expect(second.result.current.lifecycle.size).toBe(0)
  })

  it('T-B4 — setSearch updates in-memory search synchronously', () => {
    const { result } = renderHook(() => usePlanFilters())
    act(() => result.current.setSearch('a'))
    expect(result.current.search).toBe('a')
  })
})

describe('usePlanFilters — Group C: hydration from valid stored state (REQ-3)', () => {
  it('T-C1 — valid v1 entry hydrates Sets and primitives correctly', () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        lifecycle: ['done', 'pending'],
        project: ['watchfloor-list-filters'],
        search: 'autopilot',
        sort: 'last-activity-desc',
      }),
    )
    const { result } = renderHook(() => usePlanFilters())
    expect(result.current.lifecycle.has('done')).toBe(true)
    expect(result.current.lifecycle.has('pending')).toBe(true)
    expect(result.current.lifecycle.size).toBe(2)
    expect(result.current.project.has('watchfloor-list-filters')).toBe(true)
    expect(result.current.search).toBe('autopilot')
    expect(result.current.sort).toBe('last-activity-desc')
  })

  it('T-C2 — duplicate lifecycle entries naturally deduplicate via Set', () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        lifecycle: ['active', 'active', 'done'],
        project: [],
        search: '',
        sort: 'group-then-progress-desc',
      }),
    )
    const { result } = renderHook(() => usePlanFilters())
    expect(result.current.lifecycle.size).toBe(2)
    expect(result.current.lifecycle.has('active')).toBe(true)
    expect(result.current.lifecycle.has('done')).toBe(true)
  })

  it('T-C3 — extra unknown property is ignored, hydration succeeds', () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        lifecycle: ['active'],
        project: [],
        search: '',
        sort: 'group-then-progress-desc',
        x_future_field: true,
      }),
    )
    const { result } = renderHook(() => usePlanFilters())
    expect(result.current.lifecycle.has('active')).toBe(true)
    expect((result.current as unknown as Record<string, unknown>).x_future_field).toBeUndefined()
  })
})

describe('usePlanFilters — Group D: fail-closed on invalid stored state (REQ-4)', () => {
  it('T-D1 — malformed JSON falls back silently to defaults', () => {
    localStorage.setItem(STORAGE_KEY, 'not-json{')
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    let captured: ReturnType<typeof usePlanFilters> | null = null
    expect(() => {
      const r = renderHook(() => usePlanFilters())
      captured = r.result.current
    }).not.toThrow()
    expect(captured!.sort).toBe('group-then-progress-desc')
    expect(captured!.lifecycle.has('active')).toBe(true)
    expect(captured!.lifecycle.has('open')).toBe(true)
    expect(errSpy).not.toHaveBeenCalled()
  })

  it('T-D2 — out-of-enum sort triggers fail-closed', () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        lifecycle: ['active'],
        project: [],
        search: '',
        sort: 'created-desc',
      }),
    )
    const { result } = renderHook(() => usePlanFilters())
    expect(result.current.sort).toBe('group-then-progress-desc')
    expect(result.current.lifecycle.has('active')).toBe(true)
    expect(result.current.lifecycle.has('open')).toBe(true)
  })

  it('T-D3 — out-of-enum lifecycle member rejects entire entry', () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        lifecycle: ['active', 'archived'],
        project: [],
        search: '',
        sort: 'group-then-progress-desc',
      }),
    )
    const { result } = renderHook(() => usePlanFilters())
    expect(result.current.lifecycle.size).toBe(2)
    expect(result.current.lifecycle.has('active')).toBe(true)
    expect(result.current.lifecycle.has('open')).toBe(true)
  })

  it('T-D4 — project: null triggers fail-closed', () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        lifecycle: ['active'],
        project: null,
        search: '',
        sort: 'group-then-progress-desc',
      }),
    )
    const { result } = renderHook(() => usePlanFilters())
    expect(result.current.lifecycle.size).toBe(2)
    expect(result.current.lifecycle.has('active')).toBe(true)
    expect(result.current.lifecycle.has('open')).toBe(true)
    expect(result.current.project.size).toBe(0)
  })

  it('T-D5 — search: 123 (number) triggers fail-closed', () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        lifecycle: ['active'],
        project: [],
        search: 123,
        sort: 'group-then-progress-desc',
      }),
    )
    const { result } = renderHook(() => usePlanFilters())
    expect(result.current.search).toBe('')
    expect(result.current.lifecycle.has('open')).toBe(true)
  })

  it('T-D6 — JSON array (not object) triggers fail-closed', () => {
    localStorage.setItem(STORAGE_KEY, JSON.stringify([1, 2, 3]))
    const { result } = renderHook(() => usePlanFilters())
    expect(result.current.sort).toBe('group-then-progress-desc')
    expect(result.current.lifecycle.has('open')).toBe(true)
  })

  it('T-D7 — missing required field triggers fail-closed', () => {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        lifecycle: ['active'],
        project: [],
        search: '',
      }),
    )
    const { result } = renderHook(() => usePlanFilters())
    expect(result.current.sort).toBe('group-then-progress-desc')
    expect(result.current.lifecycle.has('open')).toBe(true)
  })
})

describe('usePlanFilters — Group E: search debounce (REQ-6)', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  it('T-E1 — burst of 3 setSearch calls coalesces with final value', () => {
    const { result } = renderHook(() => usePlanFilters())
    const setItemSpy = vi.spyOn(localStorage, 'setItem')
    act(() => result.current.setSearch('a'))
    act(() => result.current.setSearch('ab'))
    act(() => result.current.setSearch('abc'))
    act(() => {
      vi.advanceTimersByTime(300)
    })
    const writes = setItemSpy.mock.calls.filter((call) => call[0] === STORAGE_KEY)
    expect(writes.length).toBe(1)
    const final = JSON.parse(localStorage.getItem(STORAGE_KEY)!) as { search: string }
    expect(final.search).toBe('abc')
  })

  it('T-E2 — two bursts separated by ≥ 300 ms yield two separate persists', () => {
    const { result } = renderHook(() => usePlanFilters())
    act(() => result.current.setSearch('a'))
    act(() => {
      vi.advanceTimersByTime(300)
    })
    const firstSnapshot = JSON.parse(localStorage.getItem(STORAGE_KEY)!) as { search: string }
    expect(firstSnapshot.search).toBe('a')
    act(() => result.current.setSearch('ab'))
    act(() => {
      vi.advanceTimersByTime(300)
    })
    const secondSnapshot = JSON.parse(localStorage.getItem(STORAGE_KEY)!) as { search: string }
    expect(secondSnapshot.search).toBe('ab')
  })

  it('T-E3 — unmount during pending debounce cancels the timer', () => {
    const { result, unmount } = renderHook(() => usePlanFilters())
    const setItemSpy = vi.spyOn(localStorage, 'setItem')
    const preCount = setItemSpy.mock.calls.length
    act(() => result.current.setSearch('abc'))
    unmount()
    act(() => {
      vi.advanceTimersByTime(300)
    })
    const matched = setItemSpy.mock.calls.slice(preCount).filter(
      (call) =>
        call[0] === STORAGE_KEY &&
        (JSON.parse(call[1] as string) as { search: string }).search === 'abc',
    )
    expect(matched.length).toBe(0)
  })

  it('T-E4 — non-search setter while debounce pending uses stateRef for latest state', () => {
    const { result } = renderHook(() => usePlanFilters())
    act(() => result.current.setSearch('abc'))
    act(() => {
      vi.advanceTimersByTime(100)
    })
    act(() => result.current.setLifecycle(new Set(['done'])))
    const synchronousWrite = JSON.parse(localStorage.getItem(STORAGE_KEY)!) as {
      lifecycle: string[]
      search: string
    }
    expect(synchronousWrite.lifecycle).toEqual(['done'])
    expect(synchronousWrite.search).toBe('abc')
    act(() => {
      vi.advanceTimersByTime(200)
    })
    const debounceWrite = JSON.parse(localStorage.getItem(STORAGE_KEY)!) as {
      lifecycle: string[]
      search: string
    }
    expect(debounceWrite.lifecycle).toEqual(['done'])
    expect(debounceWrite.search).toBe('abc')
  })

  it('T-E5 — empty search persists like any other value', () => {
    const { result } = renderHook(() => usePlanFilters())
    act(() => result.current.setSearch('a'))
    act(() => {
      vi.advanceTimersByTime(300)
    })
    act(() => result.current.setSearch(''))
    act(() => {
      vi.advanceTimersByTime(300)
    })
    const persisted = JSON.parse(localStorage.getItem(STORAGE_KEY)!) as { search: string }
    expect(persisted.search).toBe('')
  })
})

describe('usePlanFilters — Group F: stability (REQ-11)', () => {
  it('T-F1 — setter references stay referentially identical across no-op re-renders', () => {
    const { result, rerender } = renderHook(() => usePlanFilters())
    const s1 = {
      setSearch: result.current.setSearch,
      setLifecycle: result.current.setLifecycle,
      setProject: result.current.setProject,
      setSort: result.current.setSort,
    }
    rerender()
    const s2 = {
      setSearch: result.current.setSearch,
      setLifecycle: result.current.setLifecycle,
      setProject: result.current.setProject,
      setSort: result.current.setSort,
    }
    rerender()
    const s3 = {
      setSearch: result.current.setSearch,
      setLifecycle: result.current.setLifecycle,
      setProject: result.current.setProject,
      setSort: result.current.setSort,
    }
    expect(Object.is(s1.setSearch, s2.setSearch)).toBe(true)
    expect(Object.is(s2.setSearch, s3.setSearch)).toBe(true)
    expect(Object.is(s1.setLifecycle, s2.setLifecycle)).toBe(true)
    expect(Object.is(s1.setProject, s2.setProject)).toBe(true)
    expect(Object.is(s1.setSort, s2.setSort)).toBe(true)
  })

  it('T-F2 — composite return identity stable across no-op re-render, changes after setter', () => {
    const { result, rerender } = renderHook(() => usePlanFilters())
    const before = result.current
    rerender()
    expect(Object.is(before, result.current)).toBe(true)
    act(() => result.current.setSearch('x'))
    expect(Object.is(before, result.current)).toBe(false)
  })
})

describe('usePlanFilters — Group G: storage failure tolerance', () => {
  it('T-G1 — quota exceeded once on setItem: in-memory updates, follow-up succeeds', () => {
    const { result } = renderHook(() => usePlanFilters())
    const setItemSpy = vi
      .spyOn(localStorage, 'setItem')
      .mockImplementationOnce(() => {
        throw new Error('QuotaExceeded')
      })
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    act(() => result.current.setLifecycle(new Set(['done'])))
    act(() => result.current.setLifecycle(new Set(['pending'])))
    expect(setItemSpy).toHaveBeenCalledTimes(2)
    expect(result.current.lifecycle.has('pending')).toBe(true)
    expect(result.current.lifecycle.size).toBe(1)
    expect(errSpy).not.toHaveBeenCalled()
    const persisted = JSON.parse(localStorage.getItem(STORAGE_KEY)!) as { lifecycle: string[] }
    expect(persisted.lifecycle).toEqual(['pending'])
  })

  it('T-G2 — getItem throws SecurityError on hydration: defaults returned, no propagation', () => {
    vi.spyOn(localStorage, 'getItem').mockImplementationOnce(() => {
      throw new Error('SecurityError')
    })
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    let captured: ReturnType<typeof usePlanFilters> | null = null
    expect(() => {
      const r = renderHook(() => usePlanFilters())
      captured = r.result.current
    }).not.toThrow()
    expect(captured!.sort).toBe('group-then-progress-desc')
    expect(captured!.lifecycle.has('active')).toBe(true)
    expect(captured!.lifecycle.has('open')).toBe(true)
    expect(errSpy).not.toHaveBeenCalled()
  })

  it('T-G3 — debounced setItem throw: in-memory search remains, no propagation', () => {
    vi.useFakeTimers()
    const { result } = renderHook(() => usePlanFilters())
    vi.spyOn(localStorage, 'setItem').mockImplementationOnce(() => {
      throw new Error('QuotaExceeded')
    })
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    act(() => result.current.setSearch('abc'))
    expect(() => {
      act(() => {
        vi.advanceTimersByTime(300)
      })
    }).not.toThrow()
    expect(result.current.search).toBe('abc')
    expect(errSpy).not.toHaveBeenCalled()
  })
})

describe('usePlanFilters — Group H: TypeScript compile-time gates', () => {
  it('T-H1 — narrowed sort literal type checks and runs', () => {
    const { result } = renderHook(() => usePlanFilters())
    act(() => result.current.setSort('name-asc'))
    if (result.current.sort === 'name-asc') {
      const narrowed: 'name-asc' = result.current.sort
      expect(narrowed).toBe('name-asc')
    } else {
      throw new Error('expected sort to be name-asc')
    }
  })

  it.skip('T-H2 — out-of-enum sort literal must fail tsc', () => {
    const { result } = renderHook(() => usePlanFilters())
    // @ts-expect-error EC-12: out-of-enum sort literal must fail tsc
    result.current.setSort('created-desc')
  })
})
