import useSWR from 'swr'
import type { Plan } from '../types'

const fetcher = (url: string) => fetch(url).then((r) => {
  if (!r.ok) throw new Error(`HTTP ${r.status}`)
  return r.json()
})

export function usePlan(cwd: string | null) {
  return useSWR<Plan>(
    cwd ? `/api/plan?cwd=${encodeURIComponent(cwd)}` : null,
    fetcher,
    {
      refreshInterval: 5000,
      revalidateOnFocus: true,
      isPaused: () => document.hidden,
    },
  )
}
