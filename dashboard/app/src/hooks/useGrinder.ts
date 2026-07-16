import { useCallback, useState } from 'react'
import useSWR, { mutate as globalMutate } from 'swr'
import type { GrinderProjectSummary, GrinderProjectDetail } from '../types'

const fetcher = (url: string) => fetch(url).then((r) => {
  if (!r.ok) throw new Error(`HTTP ${r.status}`)
  return r.json()
})

export function useGrinderList() {
  return useSWR<GrinderProjectSummary[]>('/api/grinder', fetcher, {
    refreshInterval: 10_000,
    revalidateOnFocus: true,
    isPaused: () => document.hidden,
  })
}

export function useGrinderDetail(project: string | null) {
  const result = useSWR<GrinderProjectDetail>(
    project ? `/api/grinder?project=${encodeURIComponent(project)}` : null,
    fetcher,
    {
      refreshInterval: (data) => {
        if (!data) return 10_000
        const hasActive = data.passes.some((p) => p.status === 'in_progress')
        return hasActive ? 2_000 : 30_000
      },
      revalidateOnFocus: true,
      isPaused: () => document.hidden,
    },
  )
  return result
}

export function usePauseGrinder() {
  const [isLoading, setIsLoading] = useState(false)

  const pause = useCallback(async (project: string) => {
    setIsLoading(true)
    try {
      await fetch(`/api/grinder/pause?project=${encodeURIComponent(project)}`, { method: 'POST' })
      await globalMutate((key) => typeof key === 'string' && key.startsWith('/api/grinder'))
    } finally {
      setIsLoading(false)
    }
  }, [])

  const resume = useCallback(async (project: string) => {
    setIsLoading(true)
    try {
      await fetch(`/api/grinder/pause?project=${encodeURIComponent(project)}`, { method: 'DELETE' })
      await globalMutate((key) => typeof key === 'string' && key.startsWith('/api/grinder'))
    } finally {
      setIsLoading(false)
    }
  }, [])

  return { pause, resume, isLoading }
}
