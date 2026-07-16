import { useMemo } from 'react'
import { useStreamPolling } from './useStreamPolling'
import type { StreamState, KeyedStreamEvent } from './useStreamPolling'

export type { StreamState, KeyedStreamEvent }
export type { StreamEvent, StreamContentBlock } from '../types'

/**
 * Autopilot stream polling hook. Constructs the autopilot stream URL
 * and delegates to useStreamPolling for byte-offset incremental reads.
 */
export function useAutopilotStream(task: string | null): StreamState {
  const baseUrl = useMemo(() => {
    if (!task) return null
    return `/api/autopilot/stream?task=${encodeURIComponent(task)}`
  }, [task])

  return useStreamPolling(baseUrl)
}
