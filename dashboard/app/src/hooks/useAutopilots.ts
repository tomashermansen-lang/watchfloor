import useSWR from 'swr'
import type { AutopilotSession } from '../types'

const fetcher = (url: string) => fetch(url).then((r) => {
  if (!r.ok) throw new Error(`HTTP ${r.status}`)
  return r.json()
})

export function useAutopilots() {
  return useSWR<AutopilotSession[]>('/api/autopilots', fetcher, {
    refreshInterval: 3000,
    revalidateOnFocus: true,
    isPaused: () => document.hidden,
  })
}
