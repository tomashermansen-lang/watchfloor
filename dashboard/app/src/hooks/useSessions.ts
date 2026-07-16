import useSWR from 'swr'
import type { Session } from '../types'

const fetcher = (url: string) => fetch(url).then((r) => {
  if (!r.ok) throw new Error(`HTTP ${r.status}`)
  return r.json()
})

export function useSessions() {
  return useSWR<Session[]>('/api/sessions', fetcher, {
    refreshInterval: 2000,
    revalidateOnFocus: true,
    isPaused: () => document.hidden,
  })
}
