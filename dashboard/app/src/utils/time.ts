/**
 * Format a duration in seconds as a human-readable string (e.g., "32 min", "1h 15m").
 * Sub-minute durations show "< 1 min".
 */
export function formatDuration(seconds: number): string {
  if (seconds < 60) return '< 1 min'
  if (seconds < 3600) return `${Math.round(seconds / 60)} min`
  const h = Math.floor(seconds / 3600)
  const m = Math.round((seconds % 3600) / 60)
  return m > 0 ? `${h}h ${m}m` : `${h}h`
}

/**
 * Format a blocked/short duration showing actual seconds for sub-minute values.
 */
export function formatBlockedDuration(seconds: number): string {
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `~${Math.round(seconds / 60)} min`
  return `~${(seconds / 3600).toFixed(1)} hr`
}

/**
 * Format a timestamp as relative time (e.g., "3h ago", "30s ago").
 */
export function relativeTime(isoDate: string): string {
  if (!isoDate) return ''
  try {
    const date = new Date(isoDate)
    const now = Date.now()
    const diffMs = now - date.getTime()
    if (diffMs < 0) return 'just now'
    const seconds = Math.floor(diffMs / 1000)
    if (seconds < 60) return `${seconds}s ago`
    const minutes = Math.floor(seconds / 60)
    if (minutes < 60) return `${minutes}m ago`
    const hours = Math.floor(minutes / 60)
    if (hours < 24) return `${hours}h ago`
    const days = Math.floor(hours / 24)
    return `${days}d ago`
  } catch {
    return ''
  }
}
