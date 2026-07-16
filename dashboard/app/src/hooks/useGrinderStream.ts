import { useMemo } from 'react'
import { useStreamPolling } from './useStreamPolling'
import type { StreamState } from './useStreamPolling'

/**
 * Grinder stream polling hook. Constructs the stream URL and delegates
 * to useStreamPolling for byte-offset incremental reads.
 */
export function useGrinderStream(
  project: string | null,
  batchId?: string,
): StreamState {
  const baseUrl = useMemo(() => {
    if (!project) return null
    const url = `/api/grinder/stream?project=${encodeURIComponent(project)}`
    return batchId ? `${url}&batch=${encodeURIComponent(batchId)}` : url
  }, [project, batchId])

  return useStreamPolling(baseUrl)
}
