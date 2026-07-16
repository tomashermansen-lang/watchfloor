import { useState, useRef, useEffect, useCallback } from 'react'
import type { StreamEvent } from '../types'

// Polling interval in ms — balances responsiveness with server load
const POLL_INTERVAL = 1500
// Memory cap to prevent unbounded growth in long-running streams
const MAX_EVENTS = 10_000
// Bound the cold-load payload (dashboard-perf 2026-06-02 #5): on the first
// (offset 0) poll the server is asked to return only the trailing
// INITIAL_TAIL_BYTES of the stream instead of re-parsing a multi-MB file.
// Subsequent polls advance the byte offset and stream deltas as before.
const INITIAL_TAIL_BYTES = 262_144 // 256 KiB
// 5 consecutive empty polls (~7.5s) marks the stream as inactive
const CONSECUTIVE_EMPTY_THRESHOLD = 5

export interface KeyedStreamEvent extends StreamEvent {
  _seq: number
}

export interface StreamState {
  events: KeyedStreamEvent[]
  isLive: boolean
  hasStream: boolean | null
}

/**
 * Generic byte-offset NDJSON stream polling hook.
 *
 * Callers provide a base URL (without `offset`); the hook appends
 * `&offset=${currentOffset}` on each poll cycle.
 *
 * When `baseUrl` is `null`, polling is disabled (idle state).
 */
export function useStreamPolling(baseUrl: string | null): StreamState {
  const offsetRef = useRef(0)
  const eventsRef = useRef<KeyedStreamEvent[]>([])
  const seqRef = useRef(0)
  const [displayEvents, setDisplayEvents] = useState<KeyedStreamEvent[]>([])
  const [isLive, setIsLive] = useState(false)
  const [hasStream, setHasStream] = useState<boolean | null>(null)
  const consecutiveEmptyRef = useRef(0)

  const reset = useCallback(() => {
    offsetRef.current = 0
    eventsRef.current = []
    seqRef.current = 0
    consecutiveEmptyRef.current = 0
    setDisplayEvents([])
    setIsLive(false)
    setHasStream(null)
  }, [])

  // Reset when baseUrl changes — setState in cleanup is the recommended
  // pattern for resetting state tied to an effect's dependencies.
  // eslint-disable-next-line react-hooks/set-state-in-effect
  useEffect(() => { reset() }, [baseUrl, reset])

  useEffect(() => {
    if (!baseUrl) return

    let cancelled = false
    let inFlight = false
    const controller = new AbortController()

    const separator = baseUrl.includes('?') ? '&' : '?'

    const poll = async () => {
      /* Skip if a previous poll is still awaiting its response —
         without this guard the 1500ms interval can re-enter poll()
         before offsetRef.current is advanced, both fetches return the
         same byte range, and eventsRef.concat duplicates every event.
         Observed on cold-cache first mount with multi-hundred-kB
         streams (see C5a.11). */
      if (inFlight) return
      inFlight = true
      try {
        const tailParam =
          offsetRef.current === 0 ? `&tail=${INITIAL_TAIL_BYTES}` : ''
        const res = await fetch(
          `${baseUrl}${separator}offset=${offsetRef.current}${tailParam}`,
          { signal: controller.signal },
        )
        if (cancelled) return

        if (res.status === 404) {
          setHasStream(false)
          return
        }
        if (!res.ok) return

        const data = await res.json()
        if (cancelled) return

        setHasStream(true)
        const rawEvents: StreamEvent[] = data.events
        offsetRef.current = data.offset

        if (rawEvents.length > 0) {
          consecutiveEmptyRef.current = 0
          const keyed = rawEvents.map((e) => ({ ...e, _seq: seqRef.current++ }))
          eventsRef.current = eventsRef.current.concat(keyed)
          if (eventsRef.current.length > MAX_EVENTS) {
            eventsRef.current = eventsRef.current.slice(-MAX_EVENTS)
          }
          setDisplayEvents([...eventsRef.current])
          setIsLive(true)
        } else {
          consecutiveEmptyRef.current++
          if (consecutiveEmptyRef.current >= CONSECUTIVE_EMPTY_THRESHOLD) {
            setIsLive(false)
          }
        }
      } catch {
        // Ignore fetch errors and aborts silently
      } finally {
        inFlight = false
      }
    }

    const id = setInterval(poll, POLL_INTERVAL)
    poll()

    return () => {
      cancelled = true
      controller.abort()
      clearInterval(id)
    }
  }, [baseUrl])

  return { events: displayEvents, isLive, hasStream }
}
