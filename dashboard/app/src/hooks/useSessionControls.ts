// FIRST frontend consumer of the CSRF double-submit contract
// (csrf_token cookie + X-CSRF-Token header). Polls
// GET /api/{kind}/status via SWR, derives an 8-value SessionUIState
// from the 6-value server status plus two pending-mutation flags,
// and exposes four typed mutation helpers (start, pause, resume,
// cancel) that POST to the predecessor write endpoints.
//
// Pause + Resume are optimistic; Cancel awaits the server (DN-5).
// pauseElapsedSeconds ticks via a 1 s setInterval so the consumer's
// "Pausing… mm:ss" label can render the long-pause UX from DN-13.
//
// State is per-hook-instance; the SWR cache is shared by SWR key.
// Per-instance optimistic flags do NOT cross-broadcast between two
// hook instances mounted with the same (targetKind, targetId). The
// host-plan UX scope ("watchfloor-controls-ui") mounts at most one
// panel per session, so this boundary is acceptable.
//
// CSRF cookie/header names are duplicated by-value from
// dashboard/server/middleware/csrf.py:24-25 — any rename there is a
// one-line correlated edit here.

import { useCallback, useEffect, useMemo, useRef, useState } from 'react'
import useSWR, { useSWRConfig } from 'swr'
// controls-06 #12 — CSRF read/fetch logic shared with useTerminalSocket
// so both hooks see the same body-token cache populated from
// /api/csrf. Aliased to the cycle-5 _readCsrfToken / _resolveCsrfToken
// names so existing call sites + __test__ namespace stay stable.
import {
  readCsrfToken as _readCsrfToken,
  resolveCsrfToken as _resolveCsrfToken,
  _resetCsrfBodyTokenCache,
} from './csrfToken'

// === Type contracts =====================================================

export type SessionUIState =
  | 'idle'
  | 'starting'
  | 'running'
  | 'paused'
  | 'resuming'
  | 'cancelled'
  | 'completed'
  | 'failed'

export type SessionTargetKind = 'autopilot' | 'chain'

// ControlError.slug is `string` (not a closed literal union) intentionally:
// the predecessor server can emit slugs not yet present in
// _DEFAULT_ERROR_COPY, and the runtime branches on equality.
export interface ControlError {
  slug: string
  status: number
  message: string
  hint?: string
  retryAfterSeconds?: number
}

export interface UseSessionControls {
  state: SessionUIState
  isPausing: boolean
  pauseElapsedSeconds: number
  error: ControlError | null
  /* controls-04 #2 — last tmux session name observed via the
     /status SWR poll. `null` either means the server has not seen
     a started event (state === 'idle') OR the lifecycle stream
     reports `running` but the tmux session has exited without a
     terminal event (stale-lifecycle case). Consumers detect the
     latter via `state === 'running' && tmuxSession == null` and
     route to a recovery affordance rather than POSTing
     pause/attach against a dead session. */
  tmuxSession: string | null
  /* controls-05 #3 — derived helper for the stale-lifecycle case
     above. Promoted to a first-class field so parent containers
     (ProjectPanel renders the brand-spec sub-line in chrome.md:140)
     don't re-derive the rule and risk drifting from the canonical
     definition. */
  isStale: boolean
  mutate: {
    start: (opts?: { pipeline?: 'full' | 'light' }) => Promise<void>
    pause: () => Promise<void>
    resume: () => Promise<void>
    cancel: () => Promise<void>
    /* controls-07 #4 — atomic restart for the stale-running affordance.
       Bundles POST /cancel + POST /start; the start leg skips the
       _isAllowed guard because the caller has just cancelled and the
       gate (`state==='running'` rejecting `start`) would race against
       SWR revalidation. Use this instead of `await cancel(); await
       start()` in the component layer — the latter silently drops
       the start POST in ~half the React render cadences. */
    restart: (opts?: { pipeline?: 'full' | 'light' }) => Promise<void>
  }
}

// Server response (file-private — disambiguates from
// dashboard/app/src/types.ts → SessionStatus which is the
// session-monitor enum).
type ServerStatus =
  | 'idle'
  | 'running'
  | 'paused'
  | 'cancelled'
  | 'completed'
  | 'failed'

interface SessionStatusResponse {
  status: ServerStatus
  started_at: string | null
  tmux_session: string | null
  phase_at_pause: string | null
  last_phase_complete: string | null
}

// === Constants ==========================================================

const _REFRESH_INTERVAL_MS = {
  active: 2_000,
  idle: 15_000,
  terminal: 30_000,
} as const

const _TICK_INTERVAL_MS = 1_000

const _CSRF_HEADER_NAME = 'X-CSRF-Token'

const _DEFAULT_ERROR_COPY: Record<string, string> = {
  target_not_found: 'Session target not found',
  concurrent_cap_reached: 'Concurrent autopilot cap reached',
  already_running: 'Session is already running',
  cannot_resume_cancelled: 'Cannot resume a cancelled session',
  cannot_resume_completed: 'Cannot resume a completed session',
  cannot_resume_running: 'Cannot resume — session is already running',
  stream_unavailable: 'Resume stream unavailable',
  pause_write_failed: 'Failed to write pause file',
  tmux_error: 'tmux subsystem error',
  origin: 'Origin not allowed',
  /* controls-07 #3 — terse primary; "reload the page" is misleading
     because the body-token fallback runs fresh on every click. The
     secondary hint (set per-callsite) points at the real recovery
     path: browser console (csrfToken: warnings from controls-07 #2)
     for transport failures, server cookie/header refresh on 403. */
  csrf: 'CSRF token unavailable',
  network: 'Network error — check the dashboard server',
  http: 'Request failed',
  pydantic: 'Request body rejected by validator',
}

// === File-private helpers ==============================================

function _deriveState(
  serverStatus: ServerStatus | undefined,
  isStarting: boolean,
  isResuming: boolean,
): SessionUIState {
  switch (serverStatus) {
    case undefined:
      return 'idle'
    case 'idle':
      if (isStarting) return 'starting'
      if (isResuming) return 'resuming'
      return 'idle'
    case 'running':
      return 'running'
    case 'paused':
      return isResuming ? 'resuming' : 'paused'
    case 'cancelled':
      return 'cancelled'
    case 'completed':
      return 'completed'
    case 'failed':
      return 'failed'
  }
}

function _refreshCategory(
  state: SessionUIState,
  isPausing: boolean,
): keyof typeof _REFRESH_INTERVAL_MS {
  if (isPausing) return 'active'
  switch (state) {
    case 'starting':
    case 'running':
    case 'resuming':
    case 'paused':
      return 'active'
    case 'idle':
      return 'idle'
    case 'cancelled':
    case 'completed':
    case 'failed':
      return 'terminal'
  }
}

async function _parseControlError(res: Response): Promise<ControlError> {
  let body: Record<string, unknown> | null = null
  try {
    body = (await res.json()) as Record<string, unknown>
  } catch {
    /* controls-06 #9 — non-JSON error body (HTML 500 page, plain
       text from a misbehaving middleware, etc.) routes through the
       same friendly-copy preference the JSON path uses. The raw
       statusText "Internal Server Error" / "Bad Gateway" reads as
       scary server-jargon to operators; the brand vocabulary phrase
       "Request failed" sits next to the status code (error.status
       carries 500/502/etc for anyone who wants the raw signal). */
    return {
      slug: 'http',
      status: res.status,
      message: _DEFAULT_ERROR_COPY.http,
    }
  }

  let slug: string
  if (body && Array.isArray(body.detail)) {
    slug = 'pydantic'
  } else if (body && typeof body.error === 'string') {
    slug = body.error
  } else {
    slug = 'http'
  }

  const bodyMessage =
    body && typeof body.message === 'string' ? body.message : null
  /* controls-06 #9 — known semantic slugs (csrf, origin, target_not_
     found, etc.) carry friendly recovery copy in _DEFAULT_ERROR_COPY;
     prefer that over the raw HTTP statusText so a 403 CSRF reject
     reads "CSRF token unavailable — reload the page" instead of the
     unhelpful "Forbidden". Unknown slugs still fall through to
     statusText (G7), and an explicit body.message from the server
     still wins over both (G8). */
  const friendly = _DEFAULT_ERROR_COPY[slug]
  const message =
    bodyMessage ??
    friendly ??
    res.statusText ??
    _DEFAULT_ERROR_COPY.http

  const err: ControlError = { slug, status: res.status, message }

  if (body && typeof body.hint === 'string') {
    err.hint = body.hint
  }

  /* controls-07 #5 — invalidate the body-token cache on a server-side
     csrf 403 so the NEXT mutation hits /api/csrf for a fresh pair.
     Without this, the cache holds the stale token forever, every
     retry sends the same wrong header, every retry 403s, and the
     only escape is a full page reload — the exact dead-end the
     controls-07 #3 copy fix told the operator not to take. */
  if (slug === 'csrf') {
    _resetCsrfBodyTokenCache()
  }

  if (res.status === 429) {
    const raw = res.headers.get('Retry-After') ?? ''
    const parsed = Number.parseInt(raw, 10)
    if (Number.isFinite(parsed) && parsed > 0) {
      err.retryAfterSeconds = parsed
    }
  }

  return err
}

async function _postMutation(
  url: string,
  body: Record<string, unknown>,
): Promise<{ ok: true } | { ok: false; error: ControlError }> {
  /* controls-06 #11 — async token resolution. Sync read (cookie /
     meta / in-memory cache) wins when available; otherwise the
     hook fetches /api/csrf and reuses the cached body token across
     subsequent mutations. The cycle-5 contract (slug='csrf' +
     friendly copy) holds for the truly-unavailable case. */
  const token = await _resolveCsrfToken()
  if (token === null) {
    /* controls-07 #3 — hint points the operator at the diagnostic
       console.warn that csrfToken.ts now emits (controls-07 #2).
       Without this, the Alert reads "CSRF token unavailable" with
       no actionable next step and the operator falls back to the
       reload reflex, which won't fix transport failures (502 from
       a stale proxy, blocked cookies, extension interference, etc). */
    return {
      ok: false,
      error: {
        slug: 'csrf',
        status: 0,
        message: _DEFAULT_ERROR_COPY.csrf,
        hint: 'Open browser DevTools → Console for csrfToken: diagnostics. Reload only helps if the cookie was cleared.',
      },
    }
  }

  let res: Response
  try {
    res = await fetch(url, {
      method: 'POST',
      credentials: 'same-origin',
      headers: {
        'Content-Type': 'application/json',
        [_CSRF_HEADER_NAME]: token,
      },
      body: JSON.stringify(body),
    })
  } catch {
    return {
      ok: false,
      error: {
        slug: 'network',
        status: 0,
        message: _DEFAULT_ERROR_COPY.network,
      },
    }
  }

  if (res.ok) return { ok: true }
  return { ok: false, error: await _parseControlError(res) }
}

interface StatusFetchError extends Error {
  status?: number
}

const _statusFetcher = async (
  url: string,
): Promise<SessionStatusResponse> => {
  const r = await fetch(url, { credentials: 'same-origin' })
  if (!r.ok) {
    const err: StatusFetchError = new Error(`HTTP ${r.status}`)
    err.status = r.status
    throw err
  }
  return r.json()
}

function _isAllowed(
  verb: 'start' | 'pause' | 'resume' | 'cancel',
  state: SessionUIState,
): boolean {
  switch (verb) {
    case 'start':
      return (
        state === 'idle' ||
        state === 'cancelled' ||
        state === 'completed' ||
        state === 'failed'
      )
    case 'pause':
      return state === 'running'
    case 'resume':
      return state === 'paused'
    case 'cancel':
      return (
        state === 'starting' ||
        state === 'running' ||
        state === 'resuming' ||
        state === 'paused'
      )
  }
}

// === Hook ===============================================================

export function useSessionControls(
  targetKind: SessionTargetKind,
  targetId: string | null,
): UseSessionControls {
  const swrKey =
    targetId === null
      ? null
      : `/api/${targetKind}/status?id=${encodeURIComponent(targetId)}`

  const [isStarting, setIsStarting] = useState(false)
  const [isResuming, setIsResuming] = useState(false)
  const [pauseRequestedAt, setPauseRequestedAt] = useState<number | null>(
    null,
  )
  const [pauseElapsedSeconds, setPauseElapsedSeconds] = useState(0)
  const [error, setError] = useState<ControlError | null>(null)

  const isPausing = pauseRequestedAt !== null

  // useSWRConfig().mutate respects the SWRConfig provider in scope —
  // important so cancel-path revalidation hits the same cache the
  // local useSWR is subscribed to (matters under SWRConfig provider
  // isolation in tests; identical to the default cache outside tests).
  const { mutate: scopedMutate } = useSWRConfig()

  const { data: swrData, error: swrError } = useSWR<SessionStatusResponse>(
    swrKey,
    _statusFetcher,
    {
      refreshInterval: (data) =>
        _REFRESH_INTERVAL_MS[
          _refreshCategory(
            _deriveState(data?.status, isStarting, isResuming),
            isPausing,
          )
        ],
      revalidateOnFocus: true,
      isPaused: () => document.hidden,
    },
  )

  const state = _deriveState(swrData?.status, isStarting, isResuming)

  // Refs let callbacks read fresh state without re-creating on every
  // SWR poll (R19). pauseRequestedAtRef is also the EC-F1 first-write
  // guard; it is updated SYNCHRONOUSLY inside mutate.pause() so a
  // second click within the same React render cycle still sees the
  // first call's timestamp.
  const stateRef = useRef(state)
  const pauseRequestedAtRef = useRef(pauseRequestedAt)
  useEffect(() => {
    stateRef.current = state
  }, [state])
  useEffect(() => {
    pauseRequestedAtRef.current = pauseRequestedAt
  }, [pauseRequestedAt])

  // The three effects below intentionally drive setState because they
  // are the cleanup side of the optimistic-mutation contract: the read
  // path (SWR /status poll) reconciles pending-mutation flags, the
  // /status error path maps SWR errors into the ControlError surface,
  // and the tick effect synchronises pauseElapsedSeconds with the
  // pause-request timestamp. Each is a synchronise-with-external-state
  // case — not a derivable value — and follows the same pattern as
  // useStreamPolling.ts at dashboard/app/src/hooks/.
  /* eslint-disable react-hooks/set-state-in-effect */

  // Reconcile pending-mutation flags against server-observed status.
  useEffect(() => {
    const s = swrData?.status
    if (s === 'running') {
      setIsStarting(false)
      setIsResuming(false)
    } else if (s === 'paused') {
      setIsResuming(false)
      setPauseRequestedAt(null)
    } else if (s === 'cancelled' || s === 'completed' || s === 'failed') {
      setIsStarting(false)
      setIsResuming(false)
      setPauseRequestedAt(null)
    }
  }, [swrData?.status])

  // SWR /status errors → ControlError (EC-S2). Mutation-fetch errors
  // route through _parseControlError; SWR errors get their own inline
  // mapping because the fetcher throws a synthetic Error, not a
  // Response. See PLAN.md C5 SRP note.
  useEffect(() => {
    if (!swrError) {
      return
    }
    const fetchErr = swrError as StatusFetchError
    setError({
      slug: 'http',
      status: typeof fetchErr.status === 'number' ? fetchErr.status : 0,
      message: fetchErr.message || _DEFAULT_ERROR_COPY.http,
    })
  }, [swrError])

  // Tick interval for the long-pause UX (DN-13).
  useEffect(() => {
    if (pauseRequestedAt === null) {
      setPauseElapsedSeconds(0)
      return
    }
    const tick = (): void => {
      setPauseElapsedSeconds(
        Math.max(0, Math.floor((Date.now() - pauseRequestedAt) / 1000)),
      )
    }
    tick()
    const id = setInterval(tick, _TICK_INTERVAL_MS)
    return () => clearInterval(id)
  }, [pauseRequestedAt])

  /* eslint-enable react-hooks/set-state-in-effect */

  // === Mutation helpers ================================================

  const start = useCallback(
    async (opts?: { pipeline?: 'full' | 'light' }): Promise<void> => {
      if (targetId === null) return
      if (!_isAllowed('start', stateRef.current)) return
      setError(null)
      setIsStarting(true)
      const url = `/api/${targetKind}/start`
      // controls-03 #5 — chain ignores pipeline (autopilot-chain.sh
      // does not branch on it); omit the field so the wire shape
      // matches what the server actually consumes.
      const body: Record<string, unknown> = { target_id: targetId }
      if (targetKind === 'autopilot') {
        body.pipeline = opts?.pipeline ?? 'full'
      }
      const result = await _postMutation(url, body)
      if (!result.ok) {
        setIsStarting(false)
        setError(result.error)
      }
    },
    [targetKind, targetId],
  )

  const pause = useCallback(async (): Promise<void> => {
    if (targetId === null) return
    if (!_isAllowed('pause', stateRef.current)) return
    setError(null)
    // EC-F1 first-write-wins on rapid repeat clicks.
    if (pauseRequestedAtRef.current === null) {
      const now = Date.now()
      pauseRequestedAtRef.current = now
      setPauseRequestedAt(now)
    }
    const url = `/api/${targetKind}/pause`
    const body = { target_id: targetId }
    const result = await _postMutation(url, body)
    if (!result.ok) {
      pauseRequestedAtRef.current = null
      setPauseRequestedAt(null)
      setError(result.error)
    }
  }, [targetKind, targetId])

  const resume = useCallback(async (): Promise<void> => {
    if (targetId === null) return
    if (!_isAllowed('resume', stateRef.current)) return
    setError(null)
    setIsResuming(true)
    const url = `/api/${targetKind}/resume`
    const body = { target_id: targetId }
    const result = await _postMutation(url, body)
    if (!result.ok) {
      setIsResuming(false)
      setError(result.error)
    }
  }, [targetKind, targetId])

  const cancel = useCallback(async (): Promise<void> => {
    if (targetId === null) return
    if (!_isAllowed('cancel', stateRef.current)) return
    setError(null)
    const url = `/api/${targetKind}/cancel`
    const body = { target_id: targetId }
    const result = await _postMutation(url, body)
    if (result.ok) {
      // Immediate revalidation per R14 — bypass the 30 s terminal-state
      // poll interval so the operator sees the cancelled state without
      // waiting.
      const key = `/api/${targetKind}/status?id=${encodeURIComponent(
        targetId,
      )}`
      await scopedMutate(key)
    } else {
      setError(result.error)
    }
  }, [targetKind, targetId, scopedMutate])

  /* controls-07 #4 — atomic restart. The cycle-6 #4 component-level
     `await cancel; await start` chain failed at the start leg because
     stateRef.current still reads 'running' when `_isAllowed('start',
     'running')` runs (SWR cache updates synchronously in scopedMutate
     but the React re-render + useEffect that copies state→stateRef
     has not happened yet). Bundling both POSTs inside the hook lets
     us bypass the start-guard with first-hand knowledge that cancel
     just succeeded. */
  const restart = useCallback(
    async (opts?: { pipeline?: 'full' | 'light' }): Promise<void> => {
      if (targetId === null) return
      setError(null)
      const cancelResult = await _postMutation(
        `/api/${targetKind}/cancel`,
        { target_id: targetId },
      )
      if (!cancelResult.ok) {
        setError(cancelResult.error)
        return
      }
      setIsStarting(true)
      const body: Record<string, unknown> = { target_id: targetId }
      if (targetKind === 'autopilot') {
        body.pipeline = opts?.pipeline ?? 'full'
      }
      const startResult = await _postMutation(
        `/api/${targetKind}/start`,
        body,
      )
      if (!startResult.ok) {
        setIsStarting(false)
        setError(startResult.error)
      }
      const key = `/api/${targetKind}/status?id=${encodeURIComponent(
        targetId,
      )}`
      await scopedMutate(key)
    },
    [targetKind, targetId, scopedMutate],
  )

  const mutate = useMemo(
    () => ({ start, pause, resume, cancel, restart }),
    [start, pause, resume, cancel, restart],
  )

  const tmuxSession = swrData?.tmux_session ?? null
  return {
    state,
    isPausing,
    pauseElapsedSeconds,
    error,
    tmuxSession,
    isStale: state === 'running' && tmuxSession == null,
    mutate,
  }
}

// === Test-only internals ===============================================
// @internal — exposed for vitest unit coverage of pure helpers; do
// NOT import outside __tests__/.

export const __test__ = {
  _REFRESH_INTERVAL_MS,
  _deriveState,
  _refreshCategory,
  _readCsrfToken,
  _parseControlError,
  _DEFAULT_ERROR_COPY,
  _resetCsrfBodyTokenCache,
} as const
