// SECOND frontend consumer of the csrf_token cookie + meta-tag
// fallback contract; FIRST consumer of the predecessor's read-only
// pty WebSocket route /ws/{target_kind}/terminal?id=&csrf=.
//
// Opens the socket on mount, sets binaryType='arraybuffer' BEFORE
// listener attach, exposes received binary frames as a single-slot
// lastFrame mailbox plus a separate bufferOverflow slot for the
// server's JSON-text drop-oldest sentinel. Discriminates close on
// (code, reason) per the close-code matrix to choose RECONNECT vs
// STOP; reconnect schedule is
// _BACKOFF_BASE_MS * _BACKOFF_FACTOR ** (attempt - 1) ms with a
// 5-attempt ceiling. NO send() API by design (sendDisabled: true
// literal type) — defence-in-depth atop the bridge's protocol-level
// inbound drain.
//
// REASON_* string table is duplicated by-value from
// dashboard/server/terminal_ws.py:91-98. A vitest cross-file
// drift test (R26 / AS-10) reads terminal_ws.py via node:fs and
// asserts each line matches the TypeScript constant.

import { useCallback, useEffect, useRef, useState } from 'react'
// controls-06 #12 — CSRF read/fetch logic shared with useSessionControls
// so both hooks see the same body-token cache populated from
// /api/csrf. Aliased to the cycle-5 names so the existing
// __test__ namespace export at the bottom of this file stays
// stable (and the corresponding test stays anchored).
import {
  readCsrfToken as _readCsrfToken,
  resolveCsrfToken as _resolveCsrfToken,
} from './csrfToken'

// === Type contracts =====================================================

export type TerminalSocketStatus =
  | 'idle'
  | 'connecting'
  | 'connected'
  | 'reconnecting'
  | 'lost'

export type TerminalTargetKind = 'autopilot' | 'chain'

export interface UseTerminalSocket {
  status: TerminalSocketStatus
  /* controls-07 #9 — replaces the single-slot `lastFrame` mailbox.
     Under React 18 automatic batching, multiple ws.onmessage calls
     in rapid succession (typical scrollback-seed-then-tail attach
     pattern) collapsed into a single render with only the LAST
     frame surviving — frames 1..N-1 were silently dropped and
     xterm received zero scrollback. The functional-update queue
     pattern (`setFrameQueue(prev => [...prev, data])`) is safe
     under batching because each update applies to the previous
     state. Consumers iterate the queue and then call drainFrames
     to release memory. */
  frameQueue: readonly ArrayBuffer[]
  drainFrames: () => void
  sendDisabled: true
  reconnectAttempt: number
  bufferOverflow: { bytesDropped: number; at: number } | null
}

// === Constants ==========================================================

const _BACKOFF_BASE_MS = 1_000
const _BACKOFF_FACTOR = 2
const _MAX_RECONNECT_ATTEMPTS = 5

// WebSocket close codes consumed by the (code, reason) discriminator.
// Mirrored by-value from the predecessor bridge module:
// dashboard/server/terminal_ws.py (1011/1013 emitted; 4001/4400/4404
// are the app-level codes; 1000 normal; 1006 browser-fabricated).
const _WS_CLOSE_NORMAL = 1000
const _WS_CLOSE_ABNORMAL = 1006
const _WS_CLOSE_INTERNAL_ERROR = 1011
const _WS_CLOSE_TRY_AGAIN_LATER = 1013
const _WS_CLOSE_APP_CSRF = 4001
const _WS_CLOSE_APP_INVALID_ID = 4400
const _WS_CLOSE_APP_NOT_FOUND = 4404

const _REASON_TABLE = Object.freeze({
  CSRF: 'csrf',
  INVALID_ID: 'invalid id',
  NOT_FOUND: 'session not running',
  HELPER_CLOSED: 'pty session closed',
  LIFECYCLE_MISSING: 'lifecycle missing tmux_session',
  LOOKUP_INCONSISTENT: 'tmux_session lookup inconsistency',
  PTY_BRINGUP: 'pty bring-up failed',
  SUBSCRIBER_CAP: 'subscriber cap reached',
} as const)

const _STOP_REASONS_ON_1011: ReadonlySet<string> = new Set([
  _REASON_TABLE.PTY_BRINGUP,
])

// === File-private helpers ==============================================


function _buildWsUrl(
  targetKind: TerminalTargetKind,
  targetId: string,
  token: string,
  loc: { protocol: string; host: string },
): string {
  const scheme = loc.protocol === 'http:' ? 'ws:' : 'wss:'
  return (
    `${scheme}//${loc.host}/ws/${encodeURIComponent(targetKind)}` +
    `/terminal?id=${encodeURIComponent(targetId)}` +
    `&csrf=${encodeURIComponent(token)}`
  )
}

function _classifyClose(
  code: number,
  reason: string,
): 'reconnect' | 'stop' | 'clean' {
  if (code === _WS_CLOSE_NORMAL) return 'clean'
  if (code === _WS_CLOSE_INTERNAL_ERROR) {
    if (_STOP_REASONS_ON_1011.has(reason)) return 'stop'
    return 'reconnect'
  }
  if (code === _WS_CLOSE_ABNORMAL) return 'reconnect'
  if (code === _WS_CLOSE_TRY_AGAIN_LATER) return 'reconnect'
  if (code === _WS_CLOSE_APP_CSRF) return 'stop'
  if (code === _WS_CLOSE_APP_INVALID_ID) return 'stop'
  if (code === _WS_CLOSE_APP_NOT_FOUND) return 'stop'
  return 'reconnect'
}

function _parseBufferOverflow(
  raw: string,
): { bytesDropped: number; at: number } | null {
  let obj: unknown
  try {
    obj = JSON.parse(raw)
  } catch {
    return null
  }
  if (typeof obj !== 'object' || obj === null) return null
  const candidate = obj as {
    type?: unknown
    bytes_dropped?: unknown
    at?: unknown
  }
  if (candidate.type !== 'buffer_overflow') return null
  if (!Number.isInteger(candidate.bytes_dropped)) return null
  if (!Number.isInteger(candidate.at)) return null
  const bytesDropped = candidate.bytes_dropped as number
  const at = candidate.at as number
  if (
    bytesDropped > Number.MAX_SAFE_INTEGER ||
    bytesDropped < Number.MIN_SAFE_INTEGER ||
    at > Number.MAX_SAFE_INTEGER ||
    at < Number.MIN_SAFE_INTEGER
  ) {
    return null
  }
  return { bytesDropped, at }
}

// === Hook ===============================================================

export function useTerminalSocket(
  targetKind: TerminalTargetKind,
  targetId: string | null,
): UseTerminalSocket {
  const [status, setStatus] = useState<TerminalSocketStatus>('idle')
  /* controls-07 #9 — functional-update queue replaces single-slot
     mailbox. See UseTerminalSocket.frameQueue docstring. */
  const [frameQueue, setFrameQueue] = useState<readonly ArrayBuffer[]>([])
  const [reconnectAttempt, setReconnectAttempt] = useState(0)
  const [bufferOverflow, setBufferOverflow] = useState<
    { bytesDropped: number; at: number } | null
  >(null)

  const wsRef = useRef<WebSocket | null>(null)
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null)
  const mountedRef = useRef<boolean>(true)
  const attemptRef = useRef<number>(0)

  // The synchronous setState calls in this effect are the
  // synchronise-with-WebSocket-lifecycle case: a target swap MUST
  // reset reconnectAttempt and status to the new connect cycle's
  // starting values before the first close listener fires. Same
  // pattern as useSessionControls.ts effects.
  /* eslint-disable react-hooks/set-state-in-effect */
  useEffect(() => {
    mountedRef.current = true
    attemptRef.current = 0
    setReconnectAttempt(0)

    if (targetId === null) {
      setStatus('idle')
      return () => {
        mountedRef.current = false
      }
    }

    const _openSocket = (token: string): void => {
      const url = _buildWsUrl(targetKind, targetId, token, globalThis.location)
      const ws = new globalThis.WebSocket(url)
      ws.binaryType = 'arraybuffer'
      _wireWebSocket(ws)
    }
    const connect = (): void => {
      /* controls-06 #12 — sync-fast / async-fallback CSRF resolve.
         When the cookie / meta / in-memory cache has a token the
         WebSocket opens synchronously (preserving the cycle-5
         test contract that asserts status='connecting' on the very
         first render). When all three layers come up empty (the
         Vite-dev case where SameSite=Strict + proxy hop hides the
         cookie from document.cookie), we fall through to the body
         token from `/api/csrf`. The `fetchCsrfBodyToken` Promise
         singleton collapses concurrent calls into one round-trip
         so multiple TerminalPanel mounts on the same page never
         burn extra requests. The mountedRef gate after the await
         prevents a target swap mid-fetch from opening a WS against
         the previous target. */
      const syncToken = _readCsrfToken()
      if (syncToken !== null) {
        _openSocket(syncToken)
        return
      }
      void (async () => {
        const token = await _resolveCsrfToken()
        if (!mountedRef.current) return
        if (token === null) {
          setStatus('lost')
          console.warn('useTerminalSocket: CSRF token unavailable')
          return
        }
        _openSocket(token)
      })()
    }
    /* The actual WS event wiring (onopen/onmessage/onclose) is
       hoisted to a closure so the async branch above and any
       future sync branch share one source of truth. */
    function _wireWebSocket(ws: WebSocket): void {

      ws.onopen = (): void => {
        if (!mountedRef.current) return
        attemptRef.current = 0
        setStatus('connected')
        setReconnectAttempt(0)
        console.debug({
          event: 'open',
          targetKind,
          targetId,
          attempt: 0,
        })
      }

      ws.onmessage = (ev: MessageEvent): void => {
        if (!mountedRef.current) return
        const data = ev.data
        if (data instanceof ArrayBuffer) {
          /* controls-07 #9 — functional setState so React batching
             never collapses two ws.onmessage callbacks into one
             surviving frame. */
          setFrameQueue((prev) => [...prev, data])
          console.debug({
            event: 'message-binary',
            targetKind,
            targetId,
            attempt: attemptRef.current,
            byteLength: data.byteLength,
          })
          return
        }
        if (typeof data === 'string') {
          const parsed = _parseBufferOverflow(data)
          if (parsed === null) {
            console.warn('useTerminalSocket: unrecognized text frame')
            return
          }
          setBufferOverflow(parsed)
          console.debug({
            event: 'message-text',
            targetKind,
            targetId,
            attempt: attemptRef.current,
            bytesDropped: parsed.bytesDropped,
          })
          return
        }
        if (typeof Blob !== 'undefined' && data instanceof Blob) {
          console.warn('useTerminalSocket: unexpected Blob frame; discarding')
        }
      }

      ws.onclose = (ev: CloseEvent): void => {
        if (!mountedRef.current) return
        const decision = _classifyClose(ev.code, ev.reason)
        if (decision === 'clean') {
          setStatus('idle')
          console.debug({
            event: 'close-clean',
            targetKind,
            targetId,
            attempt: attemptRef.current,
            code: ev.code,
            reason: ev.reason,
          })
          return
        }
        if (decision === 'stop') {
          setStatus('lost')
          console.debug({
            event: 'close-stop',
            targetKind,
            targetId,
            attempt: attemptRef.current,
            code: ev.code,
            reason: ev.reason,
          })
          return
        }
        const nextAttempt = attemptRef.current + 1
        if (nextAttempt > _MAX_RECONNECT_ATTEMPTS) {
          setStatus('lost')
          console.debug({
            event: 'close-stop-ceiling',
            targetKind,
            targetId,
            attempt: attemptRef.current,
            code: ev.code,
            reason: ev.reason,
          })
          return
        }
        setStatus('reconnecting')
        attemptRef.current = nextAttempt
        setReconnectAttempt(nextAttempt)
        const delayMs =
          _BACKOFF_BASE_MS * _BACKOFF_FACTOR ** (nextAttempt - 1)
        timerRef.current = globalThis.setTimeout(connect, delayMs)
        console.debug({
          event: 'close-reconnect',
          targetKind,
          targetId,
          attempt: nextAttempt,
          code: ev.code,
          reason: ev.reason,
          delayMs,
        })
      }

      ws.onerror = (): void => {
        if (!mountedRef.current) return
        console.warn('useTerminalSocket: socket error')
      }

      wsRef.current = ws
      setStatus('connecting')
    }

    connect()

    return (): void => {
      mountedRef.current = false
      if (timerRef.current !== null) {
        globalThis.clearTimeout(timerRef.current)
        timerRef.current = null
      }
      const ws = wsRef.current
      if (ws !== null) {
        ws.onopen = null
        ws.onmessage = null
        ws.onclose = null
        ws.onerror = null
        if (
          ws.readyState === ws.OPEN ||
          ws.readyState === ws.CONNECTING
        ) {
          ws.close(_WS_CLOSE_NORMAL, 'unmount')
        }
        wsRef.current = null
      }
      console.debug({
        event: 'unmount',
        targetKind,
        targetId,
        attempt: attemptRef.current,
      })
    }
  }, [targetKind, targetId])
  /* eslint-enable react-hooks/set-state-in-effect */

  /* controls-07 #9 — stable callback so consumer's useEffect deps
     do not invalidate every render. */
  const drainFrames = useCallback((): void => {
    setFrameQueue([])
  }, [])

  return {
    status,
    frameQueue,
    drainFrames,
    sendDisabled: true,
    reconnectAttempt,
    bufferOverflow,
  }
}

// === Test-only internals ===============================================
// @internal — exposed for vitest unit coverage of pure helpers; do
// NOT import outside __tests__/.

export const __test__ = {
  _readCsrfToken,
  _classifyClose,
  _buildWsUrl,
  _parseBufferOverflow,
  _REASON_TABLE,
  _STOP_REASONS_ON_1011,
  _BACKOFF_BASE_MS,
  _BACKOFF_FACTOR,
  _MAX_RECONNECT_ATTEMPTS,
} as const
