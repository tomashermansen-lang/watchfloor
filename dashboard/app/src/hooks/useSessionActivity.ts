import { useState, useRef, useEffect } from 'react'

const POLL_INTERVAL = 3000

export interface ToolActivity {
  tool: string
  summary: string
  ts: string
  sid: string
}

interface ActivityState {
  events: ToolActivity[]
  isActive: boolean
}

/**
 * Polls /api/autopilot/activity for recent tool calls from sessions.jsonl
 * matching a feature branch. Used to show real-time activity when the
 * NDJSON stream goes stale during long-running phases.
 *
 * Only polls when `enabled` is true (stream is stale but session is running).
 */
export function useSessionActivity(task: string | null, enabled: boolean): ActivityState {
  const [events, setEvents] = useState<ToolActivity[]>([])
  const [isActive, setIsActive] = useState(false)
  const prevTaskRef = useRef(task)

  // Reset when task changes
  useEffect(() => {
    if (task !== prevTaskRef.current) {
      prevTaskRef.current = task
      setEvents([])
      setIsActive(false)
    }
  }, [task])

  useEffect(() => {
    if (!task || !enabled) {
      setIsActive(false)
      return
    }

    let cancelled = false
    const controller = new AbortController()

    const poll = async () => {
      try {
        const res = await fetch(
          `/api/autopilot/activity?task=${encodeURIComponent(task)}`,
          { signal: controller.signal },
        )
        if (cancelled || !res.ok) return

        const data = await res.json()
        if (cancelled) return

        const newEvents: ToolActivity[] = data.events ?? []
        setEvents(newEvents)
        // Active if we got events and the newest is < 30s old
        if (newEvents.length > 0 && newEvents[0].ts) {
          const age = Date.now() - new Date(newEvents[0].ts).getTime()
          setIsActive(age < 30_000)
        } else {
          setIsActive(false)
        }
      } catch {
        // Ignore fetch errors
      }
    }

    const id = setInterval(poll, POLL_INTERVAL)
    poll()

    return () => {
      cancelled = true
      controller.abort()
      clearInterval(id)
    }
  }, [task, enabled])

  return { events, isActive }
}
