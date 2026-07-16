import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import {
  useTaskBriefFilters,
  type BriefSection,
  type BriefMode,
} from '../hooks/useTaskBriefFilters'

const STORAGE_KEY = 'wf.taskBriefFilters.v1'

/* Audit-19 #6 - BriefSection union extended with six additional
   plan-2.0 fields: task_type, manualtest_scenarios, manual_test,
   scope_change, delivered_beyond_plan, remaining_gaps. */
const ALL_SECTIONS: readonly BriefSection[] = [
  'task_type',
  'what',
  'why',
  'where',
  'constraints',
  'acceptance',
  'manualtest_scenarios',
  'manual_test',
  'estimate',
  'description',
  'scope_change',
  'delivered_beyond_plan',
  'remaining_gaps',
] as const

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

describe('useTaskBriefFilters', () => {
  beforeEach(() => {
    for (const k of Object.keys(storageMock)) delete storageMock[k]
    setItemSpy.mockReset()
    setItemSpy.mockImplementation((key: string, value: string) => {
      storageMock[key] = value
    })
    getItemSpy.mockReset()
    getItemSpy.mockImplementation((key: string) => storageMock[key] ?? null)
  })

  afterEach(() => {
    vi.restoreAllMocks()
  })

  it('returns defaults on a fresh localStorage (mode=brief, all sections visible)', () => {
    const { result } = renderHook(() => useTaskBriefFilters())
    expect(result.current.mode).toBe<BriefMode>('brief')
    expect(result.current.visibleSections).toEqual(new Set<BriefSection>(ALL_SECTIONS))
  })

  it('setMode persists synchronously to wf.taskBriefFilters.v1', () => {
    const { result } = renderHook(() => useTaskBriefFilters())
    act(() => { result.current.setMode('stream') })
    const stored = readStored()
    expect(stored).not.toBeNull()
    expect(stored?.mode).toBe('stream')
    expect(result.current.mode).toBe<BriefMode>('stream')
  })

  it('setVisibleSections persists synchronously to wf.taskBriefFilters.v1', () => {
    const { result } = renderHook(() => useTaskBriefFilters())
    act(() => {
      result.current.setVisibleSections(new Set<BriefSection>(['what', 'why']))
    })
    const stored = readStored()
    expect(stored).not.toBeNull()
    const sections = stored?.visibleSections as string[]
    expect([...sections].sort()).toEqual(['what', 'why'])
  })

  it('hydrates on mount from a valid v1 entry', () => {
    storageMock[STORAGE_KEY] = JSON.stringify({
      mode: 'stream',
      visibleSections: ['what', 'acceptance'],
    })
    const { result } = renderHook(() => useTaskBriefFilters())
    expect(result.current.mode).toBe<BriefMode>('stream')
    expect(result.current.visibleSections).toEqual(new Set<BriefSection>(['what', 'acceptance']))
  })

  it('malformed JSON falls back silently to defaults', () => {
    storageMock[STORAGE_KEY] = '{not valid json'
    let threw = false
    let result: ReturnType<typeof renderHook<ReturnType<typeof useTaskBriefFilters>, unknown>> | undefined
    try {
      result = renderHook(() => useTaskBriefFilters())
    } catch {
      threw = true
    }
    expect(threw).toBe(false)
    expect(result?.result.current.mode).toBe<BriefMode>('brief')
    expect(result?.result.current.visibleSections).toEqual(new Set<BriefSection>(ALL_SECTIONS))
  })

  it('wrong-shape stored value falls back silently', () => {
    storageMock[STORAGE_KEY] = JSON.stringify({ mode: 42, visibleSections: 'what' })
    const { result } = renderHook(() => useTaskBriefFilters())
    expect(result.current.mode).toBe<BriefMode>('brief')
    expect(result.current.visibleSections).toEqual(new Set<BriefSection>(ALL_SECTIONS))
  })

  it('out-of-union mode value falls back silently', () => {
    storageMock[STORAGE_KEY] = JSON.stringify({
      mode: 'graph',
      visibleSections: ALL_SECTIONS,
    })
    const { result } = renderHook(() => useTaskBriefFilters())
    expect(result.current.mode).toBe<BriefMode>('brief')
    expect(result.current.visibleSections).toEqual(new Set<BriefSection>(ALL_SECTIONS))
  })

  it('unknown section in stored visibleSections triggers full fallback (no partial salvage)', () => {
    storageMock[STORAGE_KEY] = JSON.stringify({
      mode: 'brief',
      visibleSections: ['what', 'foo'],
    })
    const { result } = renderHook(() => useTaskBriefFilters())
    expect(result.current.mode).toBe<BriefMode>('brief')
    expect(result.current.visibleSections).toEqual(new Set<BriefSection>(ALL_SECTIONS))
  })

  it('setItem quota exception is swallowed; in-memory state still updates', () => {
    setItemSpy.mockImplementation(() => { throw new Error('QuotaExceededError') })
    const { result } = renderHook(() => useTaskBriefFilters())
    let threw = false
    try {
      act(() => { result.current.setMode('stream') })
    } catch {
      threw = true
    }
    expect(threw).toBe(false)
    expect(result.current.mode).toBe<BriefMode>('stream')
  })

  it('localStorage.getItem throws on access; hook returns defaults', () => {
    getItemSpy.mockImplementation(() => { throw new Error('SecurityError') })
    let threw = false
    let hook: ReturnType<typeof renderHook<ReturnType<typeof useTaskBriefFilters>, unknown>> | undefined
    try {
      hook = renderHook(() => useTaskBriefFilters())
    } catch {
      threw = true
    }
    expect(threw).toBe(false)
    expect(hook?.result.current.mode).toBe<BriefMode>('brief')
    expect(hook?.result.current.visibleSections).toEqual(new Set<BriefSection>(ALL_SECTIONS))
  })

  it('setter references are stable across renders', () => {
    const { result, rerender } = renderHook(() => useTaskBriefFilters())
    const captured = {
      setMode: result.current.setMode,
      setVisibleSections: result.current.setVisibleSections,
    }
    rerender()
    expect(result.current.setMode).toBe(captured.setMode)
    expect(result.current.setVisibleSections).toBe(captured.setVisibleSections)
  })

  it('state Set identity is preserved on idle re-render', () => {
    const { result, rerender } = renderHook(() => useTaskBriefFilters())
    const captured = result.current.visibleSections
    rerender()
    expect(result.current.visibleSections).toBe(captured)
  })

  it('empty visibleSections Set round-trips through persist+hydrate', () => {
    const first = renderHook(() => useTaskBriefFilters())
    act(() => { first.result.current.setVisibleSections(new Set<BriefSection>()) })
    const stored = readStored()
    expect(stored).not.toBeNull()
    expect(stored?.visibleSections).toEqual([])
    first.unmount()
    const second = renderHook(() => useTaskBriefFilters())
    expect(second.result.current.visibleSections).toBeInstanceOf(Set)
    expect(second.result.current.visibleSections.size).toBe(0)
  })
})
