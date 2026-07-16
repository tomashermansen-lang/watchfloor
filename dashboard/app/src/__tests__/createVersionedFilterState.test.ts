import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import {
  createVersionedFilterState,
  type VersionedFilterStateConfig,
} from '../hooks/createVersionedFilterState'

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

type L = 'a' | 'b'
type S = 'x' | 'y'

const LIFECYCLE_VALUES: readonly L[] = ['a', 'b'] as const
const SORT_VALUES: readonly S[] = ['x', 'y'] as const

function makeMinimalConfig(
  overrides: Partial<VersionedFilterStateConfig<L, S>> = {},
): VersionedFilterStateConfig<L, S> {
  return {
    storageKey: 'test.minimal.v1',
    lifecycleValues: LIFECYCLE_VALUES,
    sortValues: SORT_VALUES,
    defaults: {
      lifecycle: new Set<L>(['a']),
      project: new Set<string>(),
      search: '',
      sort: 'x',
    },
    ...overrides,
  }
}

function readStored(key: string): Record<string, unknown> | null {
  const raw = localStorage.getItem(key)
  if (raw === null) return null
  return JSON.parse(raw) as Record<string, unknown>
}

function v1ItemCalls(
  spy: ReturnType<typeof vi.spyOn>,
  storageKey: string,
): Array<[string, string]> {
  return spy.mock.calls.filter(
    (c: unknown[]): c is [string, string] => c[0] === storageKey,
  )
}

beforeEach(() => {
  localStorage.clear()
  vi.restoreAllMocks()
})

afterEach(() => {
  vi.useRealTimers()
  localStorage.clear()
})

describe('createVersionedFilterState — F1: factory shape', () => {
  it('FT-1: factory returns a hook function', () => {
    const useHook = createVersionedFilterState<L, S>(makeMinimalConfig())
    expect(typeof useHook).toBe('function')
  })

  it('FT-2: hook returns object with exactly eight named properties; setters are functions; sets expose .has/.size', () => {
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: 'test.FT-2.v1' }),
    )
    const { result } = renderHook(() => useHook())
    const keys = Object.keys(result.current).sort()
    expect(keys).toEqual(
      [
        'lifecycle',
        'project',
        'search',
        'sort',
        'setLifecycle',
        'setProject',
        'setSearch',
        'setSort',
      ].sort(),
    )
    expect(typeof result.current.setLifecycle).toBe('function')
    expect(typeof result.current.setProject).toBe('function')
    expect(typeof result.current.setSearch).toBe('function')
    expect(typeof result.current.setSort).toBe('function')
    expect(typeof result.current.lifecycle.has).toBe('function')
    expect(typeof result.current.project.has).toBe('function')
    expect(typeof result.current.lifecycle.size).toBe('number')
    expect(typeof result.current.project.size).toBe('number')
    expect(typeof result.current.search).toBe('string')
    expect(typeof result.current.sort).toBe('string')
  })
})

describe('createVersionedFilterState — F2: cold-start defaults & Set freshness', () => {
  it('FT-3: cold start with empty localStorage returns defaults; lifecycle is a defensive copy (not shared reference)', () => {
    const config = makeMinimalConfig({ storageKey: 'test.FT-3.v1' })
    const useHook = createVersionedFilterState<L, S>(config)
    const { result } = renderHook(() => useHook())
    expect(result.current.lifecycle.size).toBe(1)
    expect(result.current.lifecycle.has('a')).toBe(true)
    expect(result.current.project.size).toBe(0)
    expect(result.current.search).toBe('')
    expect(result.current.sort).toBe('x')
    expect(result.current.lifecycle).not.toBe(config.defaults.lifecycle)
    expect(result.current.project).not.toBe(config.defaults.project)
  })

  it('FT-4: two consecutive renderHook calls produce two distinct lifecycle references (fresh Set per mount)', () => {
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: 'test.FT-4.v1' }),
    )
    const r1 = renderHook(() => useHook())
    const r2 = renderHook(() => useHook())
    expect(r1.result.current.lifecycle).not.toBe(r2.result.current.lifecycle)
    expect(r1.result.current.project).not.toBe(r2.result.current.project)
  })
})

describe('createVersionedFilterState — F3: hydration from valid stored state', () => {
  it('FT-5: valid stored entry hydrates Sets and primitives', () => {
    const key = 'test.FT-5.v1'
    localStorage.setItem(
      key,
      JSON.stringify({
        lifecycle: ['b'],
        project: ['p'],
        search: 'q',
        sort: 'y',
      }),
    )
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    expect(result.current.lifecycle.has('b')).toBe(true)
    expect(result.current.lifecycle.size).toBe(1)
    expect(result.current.project.has('p')).toBe(true)
    expect(result.current.project.size).toBe(1)
    expect(result.current.search).toBe('q')
    expect(result.current.sort).toBe('y')
  })

  it('FT-6: stored entry with extra unknown property hydrates and silently ignores the unknown', () => {
    const key = 'test.FT-6.v1'
    localStorage.setItem(
      key,
      JSON.stringify({
        lifecycle: ['a'],
        project: [],
        search: '',
        sort: 'x',
        x_future: true,
      }),
    )
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    expect(result.current.lifecycle.has('a')).toBe(true)
    expect((result.current as unknown as Record<string, unknown>).x_future).toBeUndefined()
  })

  it('FT-7: stored lifecycle with duplicate entries deduplicates via Set', () => {
    const key = 'test.FT-7.v1'
    localStorage.setItem(
      key,
      JSON.stringify({
        lifecycle: ['a', 'a', 'b'],
        project: [],
        search: '',
        sort: 'x',
      }),
    )
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    expect(result.current.lifecycle.size).toBe(2)
    expect(result.current.lifecycle.has('a')).toBe(true)
    expect(result.current.lifecycle.has('b')).toBe(true)
  })
})

describe('createVersionedFilterState — F4: fail-closed validation paths', () => {
  it('FT-8: malformed JSON falls back to defaults; no console.error', () => {
    const key = 'test.FT-8.v1'
    localStorage.setItem(key, 'not-json{')
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    let captured: { sort: S } | null = null
    expect(() => {
      const r = renderHook(() => useHook())
      captured = { sort: r.result.current.sort }
    }).not.toThrow()
    expect(captured!.sort).toBe('x')
    expect(errSpy).not.toHaveBeenCalled()
  })

  it('FT-9: out-of-enum sort triggers fail-closed', () => {
    const key = 'test.FT-9.v1'
    localStorage.setItem(
      key,
      JSON.stringify({
        lifecycle: ['a'],
        project: [],
        search: '',
        sort: 'z',
      }),
    )
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    expect(result.current.sort).toBe('x')
    expect(result.current.lifecycle.has('a')).toBe(true)
    expect(result.current.lifecycle.size).toBe(1)
  })

  it('FT-10: out-of-enum lifecycle member rejects entire entry', () => {
    const key = 'test.FT-10.v1'
    localStorage.setItem(
      key,
      JSON.stringify({
        lifecycle: ['a', 'archived'],
        project: [],
        search: '',
        sort: 'x',
      }),
    )
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    expect(result.current.lifecycle.size).toBe(1)
    expect(result.current.lifecycle.has('a')).toBe(true)
    expect(result.current.lifecycle.has('b')).toBe(false)
  })

  it('FT-11: stored project: null triggers fail-closed', () => {
    const key = 'test.FT-11.v1'
    localStorage.setItem(
      key,
      JSON.stringify({
        lifecycle: ['a'],
        project: null,
        search: '',
        sort: 'x',
      }),
    )
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    expect(result.current.lifecycle.size).toBe(1)
    expect(result.current.lifecycle.has('a')).toBe(true)
    expect(result.current.project.size).toBe(0)
    expect(result.current.search).toBe('')
    expect(result.current.sort).toBe('x')
  })

  it('FT-12: stored search: 123 triggers fail-closed', () => {
    const key = 'test.FT-12.v1'
    localStorage.setItem(
      key,
      JSON.stringify({
        lifecycle: ['a'],
        project: [],
        search: 123,
        sort: 'x',
      }),
    )
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    expect(result.current.search).toBe('')
    expect(result.current.sort).toBe('x')
  })

  it('FT-13: stored top-level value as JSON array triggers fail-closed', () => {
    const key = 'test.FT-13.v1'
    localStorage.setItem(key, JSON.stringify([1, 2, 3]))
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    expect(result.current.sort).toBe('x')
    expect(result.current.lifecycle.has('a')).toBe(true)
  })

  it('FT-14: stored entry missing required field triggers fail-closed', () => {
    const key = 'test.FT-14.v1'
    localStorage.setItem(
      key,
      JSON.stringify({
        lifecycle: ['a'],
        project: [],
        search: '',
      }),
    )
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    expect(result.current.sort).toBe('x')
    expect(result.current.lifecycle.has('a')).toBe(true)
  })

  it('FT-15: localStorage.getItem throws SecurityError; defaults returned, no propagation', () => {
    const key = 'test.FT-15.v1'
    vi.spyOn(localStorage, 'getItem').mockImplementationOnce(() => {
      throw new Error('SecurityError')
    })
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    let captured: { sort: S } | null = null
    expect(() => {
      const r = renderHook(() => useHook())
      captured = { sort: r.result.current.sort }
    }).not.toThrow()
    expect(captured!.sort).toBe('x')
    expect(errSpy).not.toHaveBeenCalled()
  })
})

describe('createVersionedFilterState — F5: same-render-cycle persistence (non-search)', () => {
  it('FT-16: setLifecycle persists synchronously inside same act', () => {
    const key = 'test.FT-16.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    act(() => {
      result.current.setLifecycle(new Set<L>(['b']))
    })
    const stored = readStored(key)
    expect(stored).not.toBeNull()
    expect(stored!.lifecycle).toEqual(['b'])
  })

  it('FT-17: setProject and setSort each persist within same render cycle', () => {
    const key = 'test.FT-17.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    act(() => {
      result.current.setProject(new Set<string>(['p']))
    })
    let stored = readStored(key)
    expect(stored!.project).toEqual(['p'])
    act(() => {
      result.current.setSort('y')
    })
    stored = readStored(key)
    expect(stored!.sort).toBe('y')
  })
})

describe('createVersionedFilterState — F6: search debounce semantics', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  it('FT-18: setSearch updates result.current.search synchronously before timer advance', () => {
    const key = 'test.FT-18.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    act(() => {
      result.current.setSearch('typed')
    })
    expect(result.current.search).toBe('typed')
  })

  it('FT-19: 5 setSearch calls inside one act produce one debounced setItem after 300ms with last value', () => {
    const key = 'test.FT-19.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    const setItemSpy = vi.spyOn(localStorage, 'setItem')
    act(() => {
      for (let i = 0; i < 5; i++) {
        result.current.setSearch('q' + i)
      }
    })
    expect(v1ItemCalls(setItemSpy, key).length).toBe(0)
    expect(result.current.search).toBe('q4')
    act(() => {
      vi.advanceTimersByTime(300)
    })
    const calls = v1ItemCalls(setItemSpy, key)
    expect(calls.length).toBe(1)
    const parsed = JSON.parse(calls[0][1]) as { search: string }
    expect(parsed.search).toBe('q4')
  })

  it('FT-20: two bursts ≥300ms apart yield two distinct setItem calls', () => {
    const key = 'test.FT-20.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    const setItemSpy = vi.spyOn(localStorage, 'setItem')
    act(() => {
      result.current.setSearch('a')
    })
    act(() => {
      vi.advanceTimersByTime(300)
    })
    act(() => {
      result.current.setSearch('ab')
    })
    act(() => {
      vi.advanceTimersByTime(300)
    })
    const calls = v1ItemCalls(setItemSpy, key)
    expect(calls.length).toBe(2)
  })

  it('FT-21: non-search setter during pending debounce produces sync write with current snapshot; debounce later writes same snapshot', () => {
    const key = 'test.FT-21.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    const setItemSpy = vi.spyOn(localStorage, 'setItem')
    act(() => {
      result.current.setSearch('abc')
    })
    act(() => {
      result.current.setSort('y')
    })
    let calls = v1ItemCalls(setItemSpy, key)
    expect(calls.length).toBe(1)
    let parsed = JSON.parse(calls[0][1]) as { search: string; sort: string }
    expect(parsed.search).toBe('abc')
    expect(parsed.sort).toBe('y')
    act(() => {
      vi.advanceTimersByTime(300)
    })
    calls = v1ItemCalls(setItemSpy, key)
    expect(calls.length).toBe(2)
    parsed = JSON.parse(calls[1][1]) as { search: string; sort: string }
    expect(parsed.search).toBe('abc')
    expect(parsed.sort).toBe('y')
  })

  it('FT-22: pending debounce timer cleared on unmount; advancing 500ms produces no further setItem', () => {
    const key = 'test.FT-22.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result, unmount } = renderHook(() => useHook())
    const setItemSpy = vi.spyOn(localStorage, 'setItem')
    act(() => {
      result.current.setSearch('typing')
    })
    unmount()
    act(() => {
      vi.advanceTimersByTime(500)
    })
    const calls = v1ItemCalls(setItemSpy, key)
    expect(calls.length).toBe(0)
  })
})

describe('createVersionedFilterState — F7: fail-silent persistence', () => {
  it('FT-23: setItem throws QuotaExceeded; in-memory updates, act does not throw', () => {
    const key = 'test.FT-23.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    vi.spyOn(localStorage, 'setItem').mockImplementation(() => {
      throw new Error('QuotaExceededError')
    })
    expect(() => {
      act(() => {
        result.current.setSort('y')
      })
    }).not.toThrow()
    expect(result.current.sort).toBe('y')
  })

  it('FT-24: setItem throws once then succeeds; second setter call persists', () => {
    const key = 'test.FT-24.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    vi.spyOn(localStorage, 'setItem').mockImplementationOnce(() => {
      throw new Error('QuotaExceededError')
    })
    act(() => {
      result.current.setSort('y')
    })
    act(() => {
      result.current.setLifecycle(new Set<L>(['b']))
    })
    const stored = readStored(key)
    expect(stored).not.toBeNull()
    expect(stored!.sort).toBe('y')
    expect(stored!.lifecycle).toEqual(['b'])
  })
})

describe('createVersionedFilterState — F8: reference stability', () => {
  it('FT-25: setter references stable across no-op rerender', () => {
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: 'test.FT-25.v1' }),
    )
    const { result, rerender } = renderHook(() => useHook())
    const captured = {
      setLifecycle: result.current.setLifecycle,
      setProject: result.current.setProject,
      setSearch: result.current.setSearch,
      setSort: result.current.setSort,
    }
    rerender()
    expect(result.current.setLifecycle).toBe(captured.setLifecycle)
    expect(result.current.setProject).toBe(captured.setProject)
    expect(result.current.setSearch).toBe(captured.setSearch)
    expect(result.current.setSort).toBe(captured.setSort)
  })

  it('FT-25b: identity-guard — same-reference setter input is a no-op (zero setItem; slice ref unchanged)', () => {
    const key = 'test.FT-25b.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    const capturedLifecycle = result.current.lifecycle
    const capturedProject = result.current.project
    const capturedSearch = result.current.search
    const capturedSort = result.current.sort
    const setItemSpy = vi.spyOn(localStorage, 'setItem')
    act(() => {
      result.current.setLifecycle(capturedLifecycle)
    })
    expect(v1ItemCalls(setItemSpy, key).length).toBe(0)
    expect(result.current.lifecycle).toBe(capturedLifecycle)
    act(() => {
      result.current.setProject(capturedProject)
    })
    expect(v1ItemCalls(setItemSpy, key).length).toBe(0)
    expect(result.current.project).toBe(capturedProject)
    act(() => {
      result.current.setSearch(capturedSearch)
    })
    expect(v1ItemCalls(setItemSpy, key).length).toBe(0)
    act(() => {
      result.current.setSort(capturedSort)
    })
    expect(v1ItemCalls(setItemSpy, key).length).toBe(0)
  })

  it('FT-26: composite return object stable across no-op rerender', () => {
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: 'test.FT-26.v1' }),
    )
    const { result, rerender } = renderHook(() => useHook())
    const before = result.current
    rerender()
    expect(result.current).toBe(before)
  })
})

describe('createVersionedFilterState — F9: round-trip and edge-case data shapes', () => {
  it('FT-27: empty lifecycle Set round-trips', () => {
    const key = 'test.FT-27.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const r1 = renderHook(() => useHook())
    act(() => {
      r1.result.current.setLifecycle(new Set<L>())
    })
    const stored = readStored(key)
    expect(stored!.lifecycle).toEqual([])
    r1.unmount()
    const r2 = renderHook(() => useHook())
    expect(r2.result.current.lifecycle).toBeInstanceOf(Set)
    expect(r2.result.current.lifecycle.size).toBe(0)
  })

  it('FT-28: all bounded members round-trip without collapsing', () => {
    const key = 'test.FT-28.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const r1 = renderHook(() => useHook())
    act(() => {
      r1.result.current.setLifecycle(new Set<L>(['a', 'b']))
    })
    r1.unmount()
    const r2 = renderHook(() => useHook())
    expect(r2.result.current.lifecycle.size).toBe(2)
    expect(r2.result.current.lifecycle.has('a')).toBe(true)
    expect(r2.result.current.lifecycle.has('b')).toBe(true)
  })

  it('FT-29: project Set with arbitrary string contents round-trips verbatim', () => {
    const key = 'test.FT-29.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const r1 = renderHook(() => useHook())
    act(() => {
      r1.result.current.setProject(new Set<string>(['oih:1', 'OIH (legacy)']))
    })
    r1.unmount()
    const r2 = renderHook(() => useHook())
    expect(r2.result.current.project.has('oih:1')).toBe(true)
    expect(r2.result.current.project.has('OIH (legacy)')).toBe(true)
    expect(r2.result.current.project.size).toBe(2)
  })

  it('FT-30: search containing JSON-significant characters round-trips', () => {
    vi.useFakeTimers()
    const key = 'test.FT-30.v1'
    const exotic = '"weird\\nvalue"'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const r1 = renderHook(() => useHook())
    act(() => {
      r1.result.current.setSearch(exotic)
    })
    act(() => {
      vi.advanceTimersByTime(300)
    })
    r1.unmount()
    const r2 = renderHook(() => useHook())
    expect(r2.result.current.search).toBe(exotic)
  })

  it('FT-31: empty search after typing-then-clearing persists like any other value', () => {
    vi.useFakeTimers()
    const key = 'test.FT-31.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    act(() => {
      result.current.setSearch('typing')
    })
    act(() => {
      vi.advanceTimersByTime(300)
    })
    act(() => {
      result.current.setSearch('')
    })
    act(() => {
      vi.advanceTimersByTime(300)
    })
    const stored = readStored(key)
    expect(stored!.search).toBe('')
  })

  it('FT-EC17: structurally-equal but referentially distinct Sets each commit', () => {
    const key = 'test.FT-EC17.v1'
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    const { result } = renderHook(() => useHook())
    const setItemSpy = vi.spyOn(localStorage, 'setItem')
    act(() => {
      result.current.setLifecycle(new Set<L>(['a']))
    })
    act(() => {
      result.current.setLifecycle(new Set<L>(['a']))
    })
    const calls = v1ItemCalls(setItemSpy, key)
    expect(calls.length).toBe(2)
    expect(calls[0][1]).toBe(calls[1][1])
  })
})

describe('createVersionedFilterState — F10: skip-initial-mount-write convention', () => {
  it('FT-32: no setItem call between mount and first setter call (skip-initial-mount-write)', () => {
    const key = 'test.FT-32.v1'
    const setItemSpy = vi.spyOn(localStorage, 'setItem')
    const useHook = createVersionedFilterState<L, S>(
      makeMinimalConfig({ storageKey: key }),
    )
    renderHook(() => useHook())
    expect(v1ItemCalls(setItemSpy, key).length).toBe(0)
  })
})
