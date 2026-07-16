import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { useRelativeTimer } from '../hooks/useRelativeTimer'

describe('useRelativeTimer', () => {
  beforeEach(() => { vi.useFakeTimers() })
  afterEach(() => { vi.useRealTimers() })

  it('returns empty string for null timestamp', () => {
    const { result } = renderHook(() => useRelativeTimer(null))
    expect(result.current).toBe('')
  })

  it('formats seconds ago', () => {
    const now = Date.now()
    vi.setSystemTime(now)
    const { result } = renderHook(() => useRelativeTimer(now - 5000))
    expect(result.current).toBe('5s ago')
  })

  it('updates every second', () => {
    const now = Date.now()
    vi.setSystemTime(now)
    const { result } = renderHook(() => useRelativeTimer(now - 3000))
    expect(result.current).toBe('3s ago')

    act(() => { vi.advanceTimersByTime(1000) })
    expect(result.current).toBe('4s ago')
  })

  it('formats minutes for values > 60s', () => {
    const now = Date.now()
    vi.setSystemTime(now)
    const { result } = renderHook(() => useRelativeTimer(now - 90000))
    expect(result.current).toBe('1m ago')
  })
})
