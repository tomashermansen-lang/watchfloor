import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import {
  useFeatureFilters,
  type LifecycleFilterChip,
  type SortMode,
} from '../hooks/useFeatureFilters'

const STORAGE_KEY = 'wf.featureFilters.v1'

const storageMock: Record<string, string> = {}
const setItemSpy = vi.fn((key: string, value: string) => {
  storageMock[key] = value
})
const getItemSpy = vi.fn((key: string) => storageMock[key] ?? null)

Object.defineProperty(globalThis, 'localStorage', {
  value: {
    getItem: getItemSpy,
    setItem: setItemSpy,
    removeItem: vi.fn((key: string) => { delete storageMock[key] }),
    clear: vi.fn(() => { for (const k of Object.keys(storageMock)) delete storageMock[k] }),
    get length() { return Object.keys(storageMock).length },
    key: vi.fn(() => null),
  },
  writable: true,
})

function readStored(): Record<string, unknown> | null {
  const raw = storageMock[STORAGE_KEY]
  if (raw === undefined) return null
  return JSON.parse(raw) as Record<string, unknown>
}

function v1ItemCalls(): Array<[string, string]> {
  return setItemSpy.mock.calls.filter((c): c is [string, string] => c[0] === STORAGE_KEY)
}

describe('useFeatureFilters', () => {
  beforeEach(() => {
    for (const k of Object.keys(storageMock)) delete storageMock[k]
    setItemSpy.mockReset()
    setItemSpy.mockImplementation((key: string, value: string) => {
      storageMock[key] = value
    })
    getItemSpy.mockReset()
    getItemSpy.mockImplementation((key: string) => storageMock[key] ?? null)
    vi.useFakeTimers()
  })

  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  // AS-1 (REQ-6)
  it('AS-1: returns documented defaults on a fresh localStorage', () => {
    const { result } = renderHook(() => useFeatureFilters())
    expect(result.current.lifecycle).toEqual(new Set<LifecycleFilterChip>(['active', 'paused']))
    expect(result.current.project).toEqual(new Set<string>())
    expect(result.current.search).toBe('')
    expect(result.current.sort).toBe<SortMode>('urgency-then-completion')
  })

  // AS-2 (REQ-7, REQ-8)
  it('AS-2: setLifecycle persists synchronously to wf.featureFilters.v1', () => {
    const { result } = renderHook(() => useFeatureFilters())
    act(() => {
      result.current.setLifecycle(new Set<LifecycleFilterChip>(['active', 'paused', 'done']))
    })
    const stored = readStored()
    expect(stored).not.toBeNull()
    const lifecycle = stored!.lifecycle as string[]
    expect([...lifecycle].sort()).toEqual(['active', 'done', 'paused'])
  })

  // AS-3 (REQ-7, REQ-8)
  it('AS-3: setProject persists synchronously to wf.featureFilters.v1', () => {
    const { result } = renderHook(() => useFeatureFilters())
    act(() => {
      result.current.setProject(new Set<string>(['oih', 'eulex']))
    })
    const stored = readStored()
    expect(stored).not.toBeNull()
    const project = stored!.project as string[]
    expect([...project].sort()).toEqual(['eulex', 'oih'])
  })

  // AS-4 (REQ-7, REQ-8)
  it('AS-4: setSort persists synchronously to wf.featureFilters.v1', () => {
    const { result } = renderHook(() => useFeatureFilters())
    act(() => {
      result.current.setSort('name-asc')
    })
    const stored = readStored()
    expect(stored).not.toBeNull()
    expect(stored!.sort).toBe('name-asc')
  })

  // AS-5 (REQ-9)
  it('AS-5: setSearch updates in-memory synchronously but persists with 300ms debounce', () => {
    const { result } = renderHook(() => useFeatureFilters())
    act(() => {
      result.current.setSearch('a')
      result.current.setSearch('ab')
      result.current.setSearch('abc')
    })
    expect(result.current.search).toBe('abc')
    const beforeAdvance = readStored()
    expect((beforeAdvance?.search as string | undefined) ?? '').not.toBe('abc')
    act(() => { vi.advanceTimersByTime(300) })
    const afterAdvance = readStored()
    expect(afterAdvance).not.toBeNull()
    expect(afterAdvance!.search).toBe('abc')
  })

  // AS-6 (REQ-9)
  it('AS-6: ten setSearch calls within 100ms coalesce into at-most-one debounce write', () => {
    const { result } = renderHook(() => useFeatureFilters())
    setItemSpy.mockClear()
    act(() => {
      for (let i = 0; i < 10; i++) {
        result.current.setSearch('q' + i)
      }
    })
    act(() => { vi.advanceTimersByTime(300) })
    expect(v1ItemCalls().length).toBeLessThanOrEqual(1)
  })

  // AS-7 (REQ-10)
  it('AS-7: hydrates on mount from a valid v1 entry', () => {
    storageMock[STORAGE_KEY] = JSON.stringify({
      lifecycle: ['done'],
      project: ['oih'],
      search: 'foo',
      sort: 'name-asc',
    })
    const { result } = renderHook(() => useFeatureFilters())
    expect(result.current.lifecycle).toEqual(new Set<LifecycleFilterChip>(['done']))
    expect(result.current.project).toEqual(new Set<string>(['oih']))
    expect(result.current.search).toBe('foo')
    expect(result.current.sort).toBe<SortMode>('name-asc')
  })

  // AS-8 (REQ-11)
  it('AS-8: malformed JSON falls back silently to defaults', () => {
    storageMock[STORAGE_KEY] = '{not valid json'
    let threw = false
    let result: ReturnType<typeof renderHook<ReturnType<typeof useFeatureFilters>, unknown>> | undefined
    try {
      result = renderHook(() => useFeatureFilters())
    } catch {
      threw = true
    }
    expect(threw).toBe(false)
    expect(result!.result.current.lifecycle).toEqual(new Set<LifecycleFilterChip>(['active', 'paused']))
    expect(result!.result.current.project).toEqual(new Set<string>())
    expect(result!.result.current.search).toBe('')
    expect(result!.result.current.sort).toBe<SortMode>('urgency-then-completion')
  })

  // AS-9 (REQ-11)
  it('AS-9: wrong-shape stored value falls back silently', () => {
    storageMock[STORAGE_KEY] = JSON.stringify({ lifecycle: 'active', sort: 42 })
    const { result } = renderHook(() => useFeatureFilters())
    expect(result.current.lifecycle).toEqual(new Set<LifecycleFilterChip>(['active', 'paused']))
    expect(result.current.project).toEqual(new Set<string>())
    expect(result.current.search).toBe('')
    expect(result.current.sort).toBe<SortMode>('urgency-then-completion')
  })

  // AS-10 (REQ-11)
  it('AS-10: out-of-union sort value falls back silently', () => {
    storageMock[STORAGE_KEY] = JSON.stringify({
      lifecycle: ['active'],
      project: [],
      search: '',
      sort: 'progress-desc',
    })
    const { result } = renderHook(() => useFeatureFilters())
    expect(result.current.lifecycle).toEqual(new Set<LifecycleFilterChip>(['active', 'paused']))
    expect(result.current.project).toEqual(new Set<string>())
    expect(result.current.search).toBe('')
    expect(result.current.sort).toBe<SortMode>('urgency-then-completion')
  })

  // AS-11 (REQ-12)
  it('AS-11: setItem quota exception is swallowed; in-memory state still updates', () => {
    setItemSpy.mockImplementation(() => { throw new Error('QuotaExceededError') })
    const { result } = renderHook(() => useFeatureFilters())
    let threw = false
    try {
      act(() => { result.current.setSort('name-asc') })
    } catch {
      threw = true
    }
    expect(threw).toBe(false)
    expect(result.current.sort).toBe<SortMode>('name-asc')
  })

  // AS-12 (REQ-13)
  it('AS-12: setter references are stable across renders', () => {
    const { result, rerender } = renderHook(() => useFeatureFilters())
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

  // AS-13 (REQ-14)
  it('AS-13: state Set / string identities are preserved on idle re-render', () => {
    const { result, rerender } = renderHook(() => useFeatureFilters())
    const captured = {
      lifecycle: result.current.lifecycle,
      project: result.current.project,
      result: result.current,
    }
    rerender()
    expect(result.current.lifecycle).toBe(captured.lifecycle)
    expect(result.current.project).toBe(captured.project)
    expect(result.current).toBe(captured.result)
  })

  // AS-14 (REQ-15)
  it('AS-14: pending search-debounce timer is cleared on unmount', () => {
    const { result, unmount } = renderHook(() => useFeatureFilters())
    act(() => { result.current.setSearch('typing') })
    setItemSpy.mockClear()
    unmount()
    act(() => { vi.advanceTimersByTime(500) })
    expect(v1ItemCalls().length).toBe(0)
  })

  // EC-1 — empty lifecycle Set round-trips
  it('EC-1: empty lifecycle Set round-trips through persist+hydrate', () => {
    const first = renderHook(() => useFeatureFilters())
    act(() => { first.result.current.setLifecycle(new Set<LifecycleFilterChip>()) })
    const stored = readStored()
    expect(stored).not.toBeNull()
    expect(stored!.lifecycle).toEqual([])
    first.unmount()
    const second = renderHook(() => useFeatureFilters())
    expect(second.result.current.lifecycle).toBeInstanceOf(Set)
    expect(second.result.current.lifecycle.size).toBe(0)
  })

  // EC-2 — all four lifecycle chips selected round-trips
  it('EC-2: all four lifecycle chips selected round-trips without collapsing', () => {
    const first = renderHook(() => useFeatureFilters())
    act(() => {
      first.result.current.setLifecycle(
        new Set<LifecycleFilterChip>(['active', 'paused', 'pending', 'done'])
      )
    })
    first.unmount()
    const second = renderHook(() => useFeatureFilters())
    expect(second.result.current.lifecycle.size).toBe(4)
    expect(second.result.current.lifecycle.has('active')).toBe(true)
    expect(second.result.current.lifecycle.has('paused')).toBe(true)
    expect(second.result.current.lifecycle.has('pending')).toBe(true)
    expect(second.result.current.lifecycle.has('done')).toBe(true)
  })

  // EC-3 — unknown lifecycle chip triggers full fallback
  it('EC-3: unknown lifecycle chip in stored value triggers full fallback (no partial salvage)', () => {
    storageMock[STORAGE_KEY] = JSON.stringify({
      lifecycle: ['active', 'archived'],
      project: [],
      search: '',
      sort: 'urgency-then-completion',
    })
    const { result } = renderHook(() => useFeatureFilters())
    expect(result.current.lifecycle).toEqual(new Set<LifecycleFilterChip>(['active', 'paused']))
  })

  // EC-6 — JSON-significant characters in search round-trip
  it('EC-6: search string containing JSON-significant characters round-trips', () => {
    const exotic = '"weird\\nvalue"'
    const first = renderHook(() => useFeatureFilters())
    act(() => { first.result.current.setSearch(exotic) })
    act(() => { vi.advanceTimersByTime(300) })
    first.unmount()
    const second = renderHook(() => useFeatureFilters())
    expect(second.result.current.search).toBe(exotic)
  })

  // EC-7 — very-long search accepted, setItem rejection swallowed
  it('EC-7: very-long search is accepted by the hook even if setItem rejects it', () => {
    const huge = 'x'.repeat(100_000)
    setItemSpy.mockImplementation(() => { throw new Error('QuotaExceededError') })
    const { result } = renderHook(() => useFeatureFilters())
    let threw = false
    try {
      act(() => { result.current.setSearch(huge) })
      act(() => { vi.advanceTimersByTime(300) })
    } catch {
      threw = true
    }
    expect(threw).toBe(false)
    expect(result.current.search).toBe(huge)
  })

  // EC-12 — setLifecycle with same Set reference is a no-op
  it('EC-12: setLifecycle called with the same Set reference is a no-op (no setItem)', () => {
    const { result } = renderHook(() => useFeatureFilters())
    const captured = result.current.lifecycle
    setItemSpy.mockClear()
    act(() => { result.current.setLifecycle(captured) })
    expect(v1ItemCalls().length).toBe(0)
  })

  // EC-13 — setLifecycle with structurally-equal new Set reference triggers duplicate persist
  it('EC-13: setLifecycle with a new Set reference triggers a (harmless) duplicate persist', () => {
    const { result } = renderHook(() => useFeatureFilters())
    const previousJson = storageMock[STORAGE_KEY]
    setItemSpy.mockClear()
    act(() => {
      result.current.setLifecycle(new Set<LifecycleFilterChip>(result.current.lifecycle))
    })
    const calls = v1ItemCalls()
    expect(calls.length).toBe(1)
    if (previousJson !== undefined) {
      expect(calls[0][1]).toBe(previousJson)
    }
  })

  // EC-17 — same-tick setSort + setSearch persist full snapshot synchronously
  it('EC-17: same-tick setSort + setSearch persist the full snapshot synchronously then debounced idempotent write', () => {
    const { result } = renderHook(() => useFeatureFilters())
    setItemSpy.mockClear()
    act(() => {
      result.current.setSort('name-asc')
      result.current.setSearch('abc')
    })
    const afterSync = readStored()
    expect(afterSync).not.toBeNull()
    expect(afterSync!.sort).toBe('name-asc')
    expect(afterSync!.search).toBe('abc')
    const syncCalls = v1ItemCalls()
    expect(syncCalls.length).toBe(1)
    const syncPayload = syncCalls[0][1]
    act(() => { vi.advanceTimersByTime(300) })
    const afterDebounce = readStored()
    expect(afterDebounce!.sort).toBe('name-asc')
    expect(afterDebounce!.search).toBe('abc')
    const allCalls = v1ItemCalls()
    expect(allCalls.length).toBe(2)
    expect(allCalls[0][1]).toBe(syncPayload)
    expect(allCalls[1][1]).toBe(syncPayload)
  })

  // EC-10 — localStorage.getItem throws on access
  it('EC-10: localStorage.getItem throws on access; hook returns defaults', () => {
    getItemSpy.mockImplementation(() => { throw new Error('SecurityError') })
    let threw = false
    let hook: ReturnType<typeof renderHook<ReturnType<typeof useFeatureFilters>, unknown>> | undefined
    try {
      hook = renderHook(() => useFeatureFilters())
    } catch {
      threw = true
    }
    expect(threw).toBe(false)
    expect(hook!.result.current.lifecycle).toEqual(new Set<LifecycleFilterChip>(['active', 'paused']))
    expect(hook!.result.current.project).toEqual(new Set<string>())
    expect(hook!.result.current.search).toBe('')
    expect(hook!.result.current.sort).toBe<SortMode>('urgency-then-completion')
  })
})
