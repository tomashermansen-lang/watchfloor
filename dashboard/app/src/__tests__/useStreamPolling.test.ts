import { describe, it, expect, vi, afterEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { useStreamPolling } from '../hooks/useStreamPolling'
import type { StreamEvent } from '../types'

afterEach(() => {
  vi.restoreAllMocks()
  vi.useRealTimers()
})

const phaseEvent: StreamEvent = {
  type: 'phase',
  phase: 'BA',
  status: 'running',
}

describe('useStreamPolling', () => {
  it('C5a.1: fetches with offset=0 on first poll', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({ events: [phaseEvent], offset: 100 }),
    }))

    renderHook(() => useStreamPolling('/api/test?project=X'))

    await waitFor(() => {
      expect(fetch).toHaveBeenCalledWith(
        expect.stringContaining('&offset=0'),
        expect.any(Object),
      )
    })
  })

  it('perf #5: first poll (offset 0) requests a bounded tail', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({ events: [phaseEvent], offset: 100 }),
    }))

    renderHook(() => useStreamPolling('/api/test?project=X'))

    await waitFor(() => {
      expect(fetch).toHaveBeenCalledWith(
        expect.stringContaining('&tail='),
        expect.any(Object),
      )
    })
  })

  it('perf #5: subsequent polls (offset > 0) omit the tail param', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({ events: [phaseEvent], offset: 100 }),
    }))

    renderHook(() => useStreamPolling('/api/test?project=X'))

    await vi.advanceTimersByTimeAsync(0)        // first poll: offset=0 → tail present
    await vi.advanceTimersByTimeAsync(1500)     // second poll: offset=100 → no tail
    const secondCallUrl = (fetch as unknown as ReturnType<typeof vi.fn>).mock.calls[1][0]
    expect(secondCallUrl).toContain('&offset=100')
    expect(secondCallUrl).not.toContain('tail=')
  })

  it('C5a.3: accumulates events', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({ events: [phaseEvent, phaseEvent], offset: 200 }),
    }))

    const { result } = renderHook(() => useStreamPolling('/api/test?project=X'))

    await waitFor(() => {
      expect(result.current.events).toHaveLength(2)
      expect(result.current.events[0]._seq).toBe(0)
      expect(result.current.events[1]._seq).toBe(1)
    })
  })

  it('C5a.6: resets on baseUrl change', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({ events: [phaseEvent], offset: 100 }),
    }))

    const { result, rerender } = renderHook(
      ({ url }) => useStreamPolling(url),
      { initialProps: { url: '/api/test?a=1' as string | null } },
    )

    await waitFor(() => { expect(result.current.events).toHaveLength(1) })

    rerender({ url: '/api/test?a=2' })
    expect(result.current.events).toHaveLength(0)
    expect(result.current.hasStream).toBeNull()
  })

  it('C5a.7: null baseUrl disables polling', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)

    renderHook(() => useStreamPolling(null))

    await new Promise((r) => setTimeout(r, 100))
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('C5a.8: fetch error handled silently', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('network error')))

    const { result } = renderHook(() => useStreamPolling('/api/test?project=X'))

    await new Promise((r) => setTimeout(r, 100))
    expect(result.current.events).toHaveLength(0)
  })

  it('C5a.10: hasStream null initially, false on 404', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: false, status: 404,
      json: () => Promise.resolve({}),
    }))

    const { result } = renderHook(() => useStreamPolling('/api/test?project=X'))

    expect(result.current.hasStream).toBeNull()

    await waitFor(() => {
      expect(result.current.hasStream).toBe(false)
    })
  })

  it('C5a.10b: hasStream true on successful response', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({ events: [], offset: 0 }),
    }))

    const { result } = renderHook(() => useStreamPolling('/api/test?project=X'))

    await waitFor(() => {
      expect(result.current.hasStream).toBe(true)
    })
  })

  it('C5a.1b: isLive true when events arrive', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({ events: [phaseEvent], offset: 100 }),
    }))

    const { result } = renderHook(() => useStreamPolling('/api/test?project=X'))

    await waitFor(() => {
      expect(result.current.isLive).toBe(true)
    })
  })

  it('C5a.2: second fetch uses updated offset from first response', async () => {
    vi.useFakeTimers()
    let callCount = 0
    vi.stubGlobal('fetch', vi.fn().mockImplementation(() => {
      callCount++
      return Promise.resolve({
        ok: true, status: 200,
        json: () => Promise.resolve({ events: [phaseEvent], offset: 100 }),
      })
    }))

    renderHook(() => useStreamPolling('/api/test?project=X'))

    // First poll fires immediately
    await vi.advanceTimersByTimeAsync(0)
    expect(fetch).toHaveBeenCalledWith(
      expect.stringContaining('&offset=0'),
      expect.any(Object),
    )

    // Advance to next poll interval (1500ms)
    await vi.advanceTimersByTimeAsync(1500)
    expect(fetch).toHaveBeenCalledWith(
      expect.stringContaining('&offset=100'),
      expect.any(Object),
    )
  })

  it('C5a.4: caps accumulated events at 10,000', async () => {
    // Generate >10,000 events in one response
    const manyEvents: StreamEvent[] = Array.from({ length: 10_500 }, () => ({
      ...phaseEvent,
    }))
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({ events: manyEvents, offset: 50000 }),
    }))

    const { result } = renderHook(() => useStreamPolling('/api/test?project=X'))

    await waitFor(() => {
      expect(result.current.events.length).toBeLessThanOrEqual(10_000)
    })
  })

  it('C5a.5: isLive becomes false after 5 consecutive empty responses', async () => {
    let callCount = 0
    vi.stubGlobal('fetch', vi.fn().mockImplementation(() => {
      callCount++
      // First call returns events (sets isLive=true), rest return empty
      if (callCount === 1) {
        return Promise.resolve({
          ok: true, status: 200,
          json: () => Promise.resolve({ events: [phaseEvent], offset: 100 }),
        })
      }
      return Promise.resolve({
        ok: true, status: 200,
        json: () => Promise.resolve({ events: [], offset: 100 }),
      })
    }))

    const { result } = renderHook(() => useStreamPolling('/api/test?project=X'))

    // Wait for first poll with events — isLive=true
    await waitFor(() => { expect(result.current.isLive).toBe(true) })

    // Wait for 5+ empty polls to mark isLive=false
    // POLL_INTERVAL is 1500ms, we need 5 empty responses
    await waitFor(() => {
      expect(result.current.isLive).toBe(false)
    }, { timeout: 10_000 })
  }, 15_000)

  it('C5a.11: skips interval poll while previous fetch is still in-flight', async () => {
    /* Repro for the duplicate-events race we hit in the live dashboard:
       the immediate poll() and the 1500ms interval poll() both fire
       with offset=0 because offsetRef hasn't been updated yet. Both
       responses then concat the same events with different _seq keys,
       and the UI renders each event twice. The in-flight guard must
       skip the interval-driven poll while the first fetch is pending. */
    vi.useFakeTimers()
    let resolveFirst: ((v: unknown) => void) | null = null
    const fetchMock = vi.fn().mockImplementation(() => {
      if (!resolveFirst) {
        return new Promise((resolve) => { resolveFirst = resolve })
      }
      return Promise.resolve({
        ok: true, status: 200,
        json: () => Promise.resolve({ events: [], offset: 100 }),
      })
    })
    vi.stubGlobal('fetch', fetchMock)

    renderHook(() => useStreamPolling('/api/test?project=X'))

    await vi.advanceTimersByTimeAsync(0)
    expect(fetchMock).toHaveBeenCalledTimes(1)

    await vi.advanceTimersByTimeAsync(1500)
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('C5a.9: aborts fetch on unmount', async () => {
    const abortSpy = vi.spyOn(AbortController.prototype, 'abort')
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({ events: [], offset: 0 }),
    }))

    const { unmount } = renderHook(() => useStreamPolling('/api/test?project=X'))

    await waitFor(() => { expect(fetch).toHaveBeenCalled() })

    unmount()
    expect(abortSpy).toHaveBeenCalled()
  })
})
