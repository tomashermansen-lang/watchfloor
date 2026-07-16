import useSWR from 'swr'
import type { Feature } from '../types'

const fetcher = (url: string) => fetch(url).then((r) => {
  if (!r.ok) throw new Error(`HTTP ${r.status}`)
  return r.json()
})

export function useFeatures() {
  return useSWR<Feature[]>('/api/features', fetcher, {
    refreshInterval: 3000,
    revalidateOnFocus: true,
    isPaused: () => document.hidden,
  })
}
