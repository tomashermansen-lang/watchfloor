import { useState, useEffect } from 'react'

export function useDataFreshness(data: unknown): { lastFetchTime: number | null; isTabVisible: boolean } {
  const [lastFetchTime, setLastFetchTime] = useState<number | null>(null)
  const [isTabVisible, setIsTabVisible] = useState(true)

  useEffect(() => {
    if (data !== undefined) {
      setLastFetchTime(Date.now())
    }
  }, [data])

  useEffect(() => {
    const handleVisibility = () => setIsTabVisible(!document.hidden)
    document.addEventListener('visibilitychange', handleVisibility)
    return () => document.removeEventListener('visibilitychange', handleVisibility)
  }, [])

  return { lastFetchTime, isTabVisible }
}
