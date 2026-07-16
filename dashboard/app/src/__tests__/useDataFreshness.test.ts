import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook } from '@testing-library/react'
import { useDataFreshness } from '../hooks/useDataFreshness'

describe('useDataFreshness', () => {
  beforeEach(() => { vi.useFakeTimers() })
  afterEach(() => { vi.useRealTimers() })

  it('returns null lastFetchTime when data is undefined', () => {
    const { result } = renderHook(() => useDataFreshness(undefined))
    expect(result.current.lastFetchTime).toBeNull()
  })

  it('sets lastFetchTime when data changes', () => {
    const now = Date.now()
    vi.setSystemTime(now)
    const { result, rerender } = renderHook(({ d }) => useDataFreshness(d), {
      initialProps: { d: undefined as unknown },
    })
    expect(result.current.lastFetchTime).toBeNull()

    rerender({ d: [{ id: 1 }] })
    expect(result.current.lastFetchTime).toBe(now)
  })

  it('tracks tab visibility', () => {
    const { result } = renderHook(() => useDataFreshness(undefined))
    expect(result.current.isTabVisible).toBe(true)
  })
})
