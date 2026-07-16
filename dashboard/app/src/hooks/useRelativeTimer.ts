import { useState, useEffect } from 'react'

export function useRelativeTimer(timestamp: number | null): string {
  const [, setTick] = useState(0)

  useEffect(() => {
    if (timestamp === null) return
    const id = setInterval(() => setTick((t) => t + 1), 1000)
    return () => clearInterval(id)
  }, [timestamp])

  if (timestamp === null) return ''

  const seconds = Math.floor((Date.now() - timestamp) / 1000)
  if (seconds < 60) return `${seconds}s ago`
  const minutes = Math.floor(seconds / 60)
  return `${minutes}m ago`
}
