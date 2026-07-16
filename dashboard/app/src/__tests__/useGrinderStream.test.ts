import { describe, it, expect, vi, afterEach } from 'vitest'
import { renderHook } from '@testing-library/react'

// Mock useStreamPolling to verify URL construction
vi.mock('../hooks/useStreamPolling', () => ({
  useStreamPolling: vi.fn().mockReturnValue({ events: [], isLive: false, hasStream: null }),
}))

import { useGrinderStream } from '../hooks/useGrinderStream'
import { useStreamPolling } from '../hooks/useStreamPolling'
import type { Mock } from 'vitest'

const mockPolling = useStreamPolling as Mock

afterEach(() => { vi.restoreAllMocks() })

describe('useGrinderStream', () => {
  it('C5b.1: constructs URL without batch', () => {
    renderHook(() => useGrinderStream('OIH'))

    expect(mockPolling).toHaveBeenCalledWith(
      '/api/grinder/stream?project=OIH',
    )
  })

  it('C5b.2: constructs URL with batch', () => {
    renderHook(() => useGrinderStream('OIH', 'b1'))

    expect(mockPolling).toHaveBeenCalledWith(
      '/api/grinder/stream?project=OIH&batch=b1',
    )
  })

  it('C5b.3: null project disables polling', () => {
    renderHook(() => useGrinderStream(null))

    expect(mockPolling).toHaveBeenCalledWith(null)
  })

  it('C5b.4: reset on project change', () => {
    const { rerender } = renderHook(
      ({ project }) => useGrinderStream(project),
      { initialProps: { project: 'OIH' as string | null } },
    )

    rerender({ project: 'dotfiles' })

    const lastCall = mockPolling.mock.calls[mockPolling.mock.calls.length - 1]
    expect(lastCall[0]).toBe('/api/grinder/stream?project=dotfiles')
  })

  it('C5b.5: reset on batchId change', () => {
    const { rerender } = renderHook(
      ({ batch }) => useGrinderStream('OIH', batch),
      { initialProps: { batch: 'b1' as string | undefined } },
    )

    rerender({ batch: 'b2' })

    const lastCall = mockPolling.mock.calls[mockPolling.mock.calls.length - 1]
    expect(lastCall[0]).toBe('/api/grinder/stream?project=OIH&batch=b2')
  })
})
