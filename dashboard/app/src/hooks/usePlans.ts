import useSWR from 'swr'
import type { ProjectSummary } from '../types'

const fetcher = (url: string) => fetch(url).then((r) => {
  if (!r.ok) throw new Error(`HTTP ${r.status}`)
  return r.json()
})

export function usePlans() {
  return useSWR<ProjectSummary[]>('/api/plans', fetcher, {
    refreshInterval: 10000,
    revalidateOnFocus: true,
    isPaused: () => document.hidden,
  })
}
