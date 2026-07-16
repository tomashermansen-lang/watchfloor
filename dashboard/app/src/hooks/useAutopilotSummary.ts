import useSWR from 'swr'
import type { AutopilotSummary } from '../types'

const TERMINAL_STATUSES = new Set(['success', 'failed', 'interrupted'])

const fetcher = (url: string) => fetch(url).then((r) => {
  if (r.status === 404) return null
  if (!r.ok) throw new Error(`HTTP ${r.status}`)
  return r.json()
})

export function useAutopilotSummary(task: string | null) {
  const { data, isLoading, error } = useSWR<AutopilotSummary | null>(
    task ? `/api/autopilot/summary?task=${encodeURIComponent(task)}` : null,
    fetcher,
    {
      refreshInterval: (data) => {
        if (data && TERMINAL_STATUSES.has(data.status)) return 0
        return 5000
      },
      revalidateOnFocus: true,
      isPaused: () => document.hidden,
    }
  )

  return { data: data ?? null, isLoading, error }
}
