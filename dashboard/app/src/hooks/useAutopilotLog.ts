import { useState, useRef, useEffect, useCallback } from 'react'

const POLL_INTERVAL = 1500
const MAX_BUFFER_BYTES = 500 * 1024 // 500KB
// Bound the cold-load payload (dashboard-perf 2026-06-02 #5): the first
// (offset 0) fetch asks the server for only the trailing INITIAL_TAIL_BYTES
// instead of reading a multi-MB log from byte 0. Subsequent polls advance the
// offset and stream deltas. Kept <= MAX_BUFFER_BYTES so the buffer never
// trims the entire initial payload on the first paint.
const INITIAL_TAIL_BYTES = 262_144 // 256 KiB

export interface LogLine {
  id: number
  text: string
}

interface LogState {
  lines: LogLine[]
  totalBytes: number
  reset: () => void
}

export function useAutopilotLog(task: string | null): LogState {
  const offsetRef = useRef(0)
  const linesRef = useRef<LogLine[]>([])
  const bytesRef = useRef(0)
  const lineCounterRef = useRef(0)
  const [displayLines, setDisplayLines] = useState<LogLine[]>([])
  const [totalBytes, setTotalBytes] = useState(0)
  const reset = useCallback(() => {
    offsetRef.current = 0
    linesRef.current = []
    bytesRef.current = 0
    lineCounterRef.current = 0
    setDisplayLines([])
    setTotalBytes(0)
  }, [])

  // Reset when task changes — resetting state tied to an effect's
  // dependencies is the recommended pattern (mirrors useStreamPolling).
  useEffect(() => {
    // eslint-disable-next-line react-hooks/set-state-in-effect
    reset()
  }, [task, reset])

  useEffect(() => {
    if (!task) return

    let cancelled = false
    const controller = new AbortController()
    const encoder = new TextEncoder()

    const poll = async () => {
      try {
        const tailParam =
          offsetRef.current === 0 ? `&tail=${INITIAL_TAIL_BYTES}` : ''
        const res = await fetch(
          `/api/autopilot/log?task=${encodeURIComponent(task)}&offset=${offsetRef.current}${tailParam}`,
          { signal: controller.signal }
        )
        if (cancelled || !res.ok) return
        const data = await res.json()
        if (cancelled) return
        const content: string = data.content
        if (!content) return

        offsetRef.current = data.offset
        const rawLines = content.split('\n')
        // Remove trailing empty string from split
        if (rawLines.length > 0 && rawLines[rawLines.length - 1] === '') {
          rawLines.pop()
        }

        const newBytes = encoder.encode(content).length
        bytesRef.current += newBytes

        const newLogLines = rawLines.map((text) => ({
          id: lineCounterRef.current++,
          text,
        }))
        linesRef.current = linesRef.current.concat(newLogLines)

        // Trim from start if over buffer cap
        while (bytesRef.current > MAX_BUFFER_BYTES && linesRef.current.length > 1) {
          const removed = linesRef.current.shift()!
          bytesRef.current -= encoder.encode(removed.text + '\n').length
        }

        setDisplayLines([...linesRef.current])
        setTotalBytes(bytesRef.current)
      } catch {
        // Ignore fetch errors and aborts silently
      }
    }

    const id = setInterval(poll, POLL_INTERVAL)
    // Initial fetch immediately
    poll()

    return () => {
      cancelled = true
      controller.abort()
      clearInterval(id)
    }
  }, [task])

  return { lines: displayLines, totalBytes, reset }
}
