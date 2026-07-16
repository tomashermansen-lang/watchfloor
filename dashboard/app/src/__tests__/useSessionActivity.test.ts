import { describe, it, expect, vi, afterEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { useSessionActivity } from '../hooks/useSessionActivity'

afterEach(() => { vi.restoreAllMocks() })

describe('useSessionActivity', () => {
  it('polls /api/autopilot/activity when enabled=true', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({
        task: 'test',
        events: [{ tool: 'Bash', summary: 'ls', ts: new Date().toISOString(), sid: 's1' }],
      }),
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHook(() => useSessionActivity('test-task', true))

    await waitFor(() => {
      expect(result.current.events).toHaveLength(1)
      expect(result.current.events[0].tool).toBe('Bash')
    })
    expect(fetchMock).toHaveBeenCalledWith(
      expect.stringContaining('/api/autopilot/activity'),
      expect.any(Object),
    )
  })

  it('does not fetch when enabled=false', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)

    renderHook(() => useSessionActivity('test-task', false))

    await new Promise((r) => setTimeout(r, 100))
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('isActive=true when newest event is recent (< 30s)', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({
        task: 'test',
        events: [{ tool: 'Bash', summary: 'ls', ts: new Date().toISOString(), sid: 's1' }],
      }),
    }))

    const { result } = renderHook(() => useSessionActivity('test-task', true))

    await waitFor(() => {
      expect(result.current.isActive).toBe(true)
    })
  })

  it('isActive=false when newest event is stale (> 30s)', async () => {
    const staleTs = new Date(Date.now() - 60_000).toISOString()
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({
        task: 'test',
        events: [{ tool: 'Bash', summary: 'ls', ts: staleTs, sid: 's1' }],
      }),
    }))

    const { result } = renderHook(() => useSessionActivity('test-task', true))

    await waitFor(() => {
      expect(result.current.events).toHaveLength(1)
    })
    expect(result.current.isActive).toBe(false)
  })

  it('returns empty events on fetch error', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('network error')))

    const { result } = renderHook(() => useSessionActivity('test-task', true))

    await new Promise((r) => setTimeout(r, 100))
    expect(result.current.events).toHaveLength(0)
  })
})
