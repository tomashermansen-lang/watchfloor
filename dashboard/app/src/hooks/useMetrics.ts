import useSWR from 'swr'
import type { MetricsResponse } from '../types'

const fetcher = (url: string) => fetch(url).then((r) => {
  if (!r.ok) throw new Error(`HTTP ${r.status}`)
  return r.json()
})

export function useMetrics(sid?: string, since?: string) {
  const params = new URLSearchParams()
  if (sid) params.set('sid', sid)
  if (since) params.set('since', since)
  const query = params.toString()
  const key = `/api/metrics${query ? `?${query}` : ''}`

  return useSWR<MetricsResponse>(key, fetcher, {
    refreshInterval: 5000,
    revalidateOnFocus: true,
    isPaused: () => document.hidden,
  })
}
