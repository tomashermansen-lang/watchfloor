import { describe, it, expect, vi, afterEach } from 'vitest'
import { renderHook, waitFor } from '@testing-library/react'
import { useAutopilotLog } from '../hooks/useAutopilotLog'

afterEach(() => { vi.restoreAllMocks() })

function stubFetch(content: string, offset: number) {
  vi.stubGlobal('fetch', vi.fn().mockResolvedValue({
    ok: true,
    json: () => Promise.resolve({ content, offset, task: 'test' }),
  }))
}

describe('useAutopilotLog', () => {
  it('does not duplicate content on double-mount (Strict Mode)', async () => {
    stubFetch('line1\nline2\n', 12)

    const { result } = renderHook(() => useAutopilotLog('test-task'))

    await waitFor(() => {
      expect(result.current.lines.length).toBeGreaterThan(0)
    })

    const line1Count = result.current.lines.filter((l) => l.text === 'line1').length
    expect(line1Count).toBe(1)
  })

  it('returns empty lines when task is null', () => {
    const { result } = renderHook(() => useAutopilotLog(null))
    expect(result.current.lines).toEqual([])
    expect(result.current.totalBytes).toBe(0)
  })

  it('perf #5: first fetch (offset 0) requests a bounded tail', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ content: 'line1\n', offset: 6, task: 'test' }),
    })
    vi.stubGlobal('fetch', fetchMock)

    renderHook(() => useAutopilotLog('test-task'))

    await waitFor(() => {
      expect(fetchMock).toHaveBeenCalledWith(
        expect.stringContaining('&tail='),
        expect.any(Object),
      )
    })
  })

  it('resets when task changes', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ content: 'old-line\n', offset: 9, task: 'a' }),
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result, rerender } = renderHook(
      ({ task }) => useAutopilotLog(task),
      { initialProps: { task: 'task-a' as string | null } },
    )

    await waitFor(() => {
      expect(result.current.lines.map((l) => l.text)).toContain('old-line')
    })

    // Switch task
    fetchMock.mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ content: 'new-line\n', offset: 9, task: 'b' }),
    })
    rerender({ task: 'task-b' })

    await waitFor(() => {
      expect(result.current.lines.map((l) => l.text)).toContain('new-line')
    })
    expect(result.current.lines.map((l) => l.text)).not.toContain('old-line')
  })

  it('assigns stable monotonic IDs to lines', async () => {
    stubFetch('a\nb\nc\n', 6)

    const { result } = renderHook(() => useAutopilotLog('test-task'))

    await waitFor(() => {
      expect(result.current.lines.length).toBe(3)
    })

    const ids = result.current.lines.map((l) => l.id)
    expect(ids[0]).toBeLessThan(ids[1])
    expect(ids[1]).toBeLessThan(ids[2])
  })
})
