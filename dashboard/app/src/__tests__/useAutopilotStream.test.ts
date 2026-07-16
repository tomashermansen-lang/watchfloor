import { describe, it, expect, vi, afterEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { useAutopilotStream } from '../hooks/useAutopilotStream'
import type { StreamEvent } from '../types'

afterEach(() => { vi.restoreAllMocks() })

const phaseEvent: StreamEvent = {
  type: 'phase',
  phase: 'BA',
  status: 'running',
}

describe('useAutopilotStream', () => {
  it('fetches with offset=0 and accumulates events', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({ events: [phaseEvent], offset: 100, task: 'test' }),
    }))

    const { result } = renderHook(() => useAutopilotStream('test-task'))

    await waitFor(() => {
      expect(result.current.events).toHaveLength(1)
      expect(result.current.events[0].type).toBe('phase')
    })
    expect(fetch).toHaveBeenCalledWith(
      expect.stringContaining('offset=0'),
      expect.any(Object),
    )
  })

  it('sets isLive=true when events arrive', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({ events: [phaseEvent], offset: 100, task: 'test' }),
    }))

    const { result } = renderHook(() => useAutopilotStream('test-task'))

    await waitFor(() => {
      expect(result.current.isLive).toBe(true)
    })
  })

  it('resets state when task changes', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({ events: [phaseEvent], offset: 100, task: 'test' }),
    }))

    const { result, rerender } = renderHook(
      ({ task }) => useAutopilotStream(task),
      { initialProps: { task: 'task-a' as string | null } },
    )

    await waitFor(() => { expect(result.current.events).toHaveLength(1) })

    rerender({ task: 'task-b' })
    expect(result.current.events).toHaveLength(0)
    expect(result.current.hasStream).toBeNull()
  })

  it('hasStream is null before first response', () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({ events: [], offset: 0, task: 'test' }),
    }))
    const { result } = renderHook(() => useAutopilotStream('test-task'))
    expect(result.current.hasStream).toBeNull()
  })

  it('sets hasStream=false on 404', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: false, status: 404,
      json: () => Promise.resolve({}),
    }))

    const { result } = renderHook(() => useAutopilotStream('test-task'))

    await waitFor(() => {
      expect(result.current.hasStream).toBe(false)
    })
  })

  it('silently ignores fetch errors', async () => {
    vi.stubGlobal('fetch', vi.fn().mockRejectedValue(new Error('network error')))

    const { result } = renderHook(() => useAutopilotStream('test-task'))

    await new Promise((r) => setTimeout(r, 100))
    expect(result.current.events).toHaveLength(0)
  })

  it('does not fetch when task is null', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)

    renderHook(() => useAutopilotStream(null))

    await new Promise((r) => setTimeout(r, 100))
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('assigns stable _seq keys to events for React reconciliation', async () => {
    vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
      ok: true, status: 200,
      json: () => Promise.resolve({ events: [phaseEvent, phaseEvent], offset: 200, task: 'test' }),
    }))

    const { result } = renderHook(() => useAutopilotStream('test-task'))

    await waitFor(() => {
      expect(result.current.events).toHaveLength(2)
      expect(result.current.events[0]._seq).toBe(0)
      expect(result.current.events[1]._seq).toBe(1)
    })
  })
})
