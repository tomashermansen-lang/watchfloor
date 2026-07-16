import {
  describe,
  it,
  expect,
  vi,
  beforeEach,
  afterEach,
  type MockInstance,
} from 'vitest'
import { renderHook, act, waitFor } from '@testing-library/react'
import type { RenderHookResult } from '@testing-library/react'
import { SWRConfig } from 'swr'
import type { ReactNode } from 'react'
import * as Module from '../hooks/useSessionControls'
import {
  useSessionControls,
  __test__,
} from '../hooks/useSessionControls'
import type { UseSessionControls } from '../hooks/useSessionControls'

type ControlsResult = RenderHookResult<UseSessionControls, unknown>['result']

// SWRConfig wrapper isolates SWR's global cache per test, preventing
// status responses from one test (e.g. running) leaking into the next.
function swrWrapper(): ({ children }: { children: ReactNode }) => ReactNode {
  const provider = new Map()
  return ({ children }) => (
    <SWRConfig value={{ provider: () => provider }}>{children}</SWRConfig>
  )
}

function renderHookIsolated<TProps, TResult>(
  hook: (props: TProps) => TResult,
  options?: { initialProps?: TProps },
): ReturnType<typeof renderHook<TResult, TProps>> {
  return renderHook(hook, { wrapper: swrWrapper(), ...options })
}

// === Test fixtures ============================================

type SessionStatus =
  | 'idle'
  | 'running'
  | 'paused'
  | 'cancelled'
  | 'completed'
  | 'failed'

type FetchInput = Parameters<typeof fetch>[0]
type FetchInit = Parameters<typeof fetch>[1]

interface StubResponse {
  ok: boolean
  status: number
  json: () => Promise<unknown>
  headers: { get: (k: string) => string | null }
  statusText: string
}

function statusOk(status: SessionStatus): StubResponse {
  return {
    ok: true,
    status: 200,
    json: () =>
      Promise.resolve({
        status,
        started_at: '2026-05-15T00:00:00Z',
        tmux_session: 'autopilot-demo',
        phase_at_pause: null,
        last_phase_complete: null,
      }),
    headers: { get: () => null },
    statusText: 'OK',
  }
}

function mutationOk(body: object = {}): StubResponse {
  return {
    ok: true,
    status: 200,
    json: () => Promise.resolve(body),
    headers: { get: () => null },
    statusText: 'OK',
  }
}

function mutationErr(
  status: number,
  body: object,
  retryAfter?: string,
): StubResponse {
  return {
    ok: false,
    status,
    json: () => Promise.resolve(body),
    headers: {
      get: (k: string) =>
        k.toLowerCase() === 'retry-after' && retryAfter ? retryAfter : null,
    },
    statusText: 'Error',
  }
}

function mutationBadJson(status: number, statusText = 'Bad Gateway'): StubResponse {
  return {
    ok: false,
    status,
    json: () => Promise.reject(new SyntaxError('not JSON')),
    headers: { get: () => null },
    statusText,
  }
}

function stubCookie(value: string): void {
  Object.defineProperty(document, 'cookie', {
    configurable: true,
    get: () => value,
    set: () => {},
  })
}

function stubMetaTag(content: string | null): HTMLMetaElement | null {
  document.head
    .querySelectorAll('meta[name="csrf-token"]')
    .forEach((n) => n.remove())
  if (content === null) return null
  const meta = document.createElement('meta')
  meta.setAttribute('name', 'csrf-token')
  meta.setAttribute('content', content)
  document.head.appendChild(meta)
  return meta
}

function urlOf(input: FetchInput): string {
  if (typeof input === 'string') return input
  if (input instanceof URL) return input.toString()
  return (input as Request).url
}

function calls(
  fetchMock: ReturnType<typeof vi.fn>,
  filter: (url: string) => boolean,
): Array<[string, FetchInit]> {
  return (fetchMock.mock.calls as Array<[FetchInput, FetchInit]>)
    .filter(([u]) => filter(urlOf(u)))
    .map(([u, init]) => [urlOf(u), init] as [string, FetchInit])
}

interface RouteFn {
  (url: string, init: FetchInit | undefined): StubResponse | Promise<StubResponse>
}

function makeRouter(routes: RouteFn): ReturnType<typeof vi.fn> {
  return vi.fn().mockImplementation((input: FetchInput, init?: FetchInit) => {
    return Promise.resolve(routes(urlOf(input), init))
  })
}

function getHeader(init: FetchInit | undefined, name: string): string | undefined {
  const h = init?.headers
  if (!h) return undefined
  if (h instanceof Headers) return h.get(name) ?? undefined
  if (Array.isArray(h)) {
    const found = h.find(([k]) => k.toLowerCase() === name.toLowerCase())
    return found?.[1]
  }
  const rec = h as Record<string, string>
  if (rec[name] !== undefined) return rec[name]
  const k = Object.keys(rec).find((x) => x.toLowerCase() === name.toLowerCase())
  return k ? rec[k] : undefined
}

const ORIGINAL_HIDDEN = Object.getOwnPropertyDescriptor(
  Document.prototype,
  'hidden',
)

afterEach(() => {
  vi.restoreAllMocks()
  vi.useRealTimers()
  stubCookie('csrf_token=ABC123')
  stubMetaTag(null)
  if (ORIGINAL_HIDDEN) {
    Object.defineProperty(document, 'hidden', ORIGINAL_HIDDEN)
  }
})

beforeEach(() => {
  stubCookie('csrf_token=ABC123')
})

// === Section A — Public surface & SWR wiring (C1, C8) =========

describe('useSessionControls — Section A: public surface', () => {
  it('A1: exports useSessionControls; no default export', () => {
    expect(typeof Module.useSessionControls).toBe('function')
    expect((Module as Record<string, unknown>).default).toBeUndefined()
    const publicKeys = Object.keys(Module)
      .filter((k) => !k.startsWith('__'))
      .sort()
    expect(publicKeys).toEqual(['useSessionControls'])
  })

  it('A2: return shape contains exactly the pinned 7 keys', async () => {
    const fetchMock = makeRouter(() => statusOk('idle'))
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))

    /* controls-04 #2 — tmuxSession added so consumers (SessionControls)
       can detect a stale-lifecycle state (server claims `running`
       but no live tmux session) and route to a recovery affordance
       rather than POSTing pause/attach against a dead session.
       controls-05 #3 — isStale promoted to a derived value on the
       hook so parent containers (ProjectPanel) can render the
       brand-spec sub-line (chrome.md:140) without re-deriving the
       rule locally. */
    expect(Object.keys(result.current).sort()).toEqual([
      'error',
      'isPausing',
      'isStale',
      'mutate',
      'pauseElapsedSeconds',
      'state',
      'tmuxSession',
    ])
  })

  /* A2d (controls-05 #3): isStale = state === 'running' && tmuxSession == null. */
  it('A2d (controls-05 #3): isStale is true when running with null tmux_session', async () => {
    const fetchMock = makeRouter(() => ({
      ok: true,
      status: 200,
      json: () =>
        Promise.resolve({
          status: 'running',
          started_at: '2026-05-15T00:00:00Z',
          tmux_session: null,
          phase_at_pause: null,
          last_phase_complete: null,
        }),
      headers: { get: () => null },
      statusText: 'OK',
    }))
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() => useSessionControls('chain', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('running'))
    expect(result.current.isStale).toBe(true)
  })

  /* A2e (controls-05 #3): isStale is false in every other combination
     — healthy running, idle, paused, terminal. */
  it('A2e (controls-05 #3): isStale is false when running with populated tmux_session', async () => {
    const fetchMock = makeRouter(() => statusOk('running'))
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() => useSessionControls('chain', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('running'))
    expect(result.current.isStale).toBe(false)
  })

  it('A2f (controls-05 #3): isStale is false when idle (no tmux yet)', async () => {
    const fetchMock = makeRouter(() => statusOk('idle'))
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() => useSessionControls('chain', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))
    expect(result.current.isStale).toBe(false)
  })

  it('A2b (controls-04 #2): tmuxSession surfaces from SWR data when populated', async () => {
    const fetchMock = makeRouter(() => statusOk('running'))
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() => useSessionControls('chain', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('running'))
    /* statusOk() fixture returns tmux_session: 'autopilot-demo' */
    expect(result.current.tmuxSession).toBe('autopilot-demo')
  })

  it('A2c (controls-04 #2): tmuxSession is null when SWR returns tmux_session: null', async () => {
    const fetchMock = makeRouter(() => ({
      ok: true,
      status: 200,
      json: () =>
        Promise.resolve({
          status: 'running',
          started_at: '2026-05-15T00:00:00Z',
          tmux_session: null,
          phase_at_pause: null,
          last_phase_complete: null,
        }),
      headers: { get: () => null },
      statusText: 'OK',
    }))
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() => useSessionControls('chain', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('running'))
    expect(result.current.tmuxSession).toBe(null)
  })

  it('A3: mutate contains exactly start, pause, resume, cancel, restart', async () => {
    const fetchMock = makeRouter(() => statusOk('idle'))
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))

    /* controls-07 #4 — `restart` added for the stale-running
       atomic-restart affordance; see Section L. */
    expect(Object.keys(result.current.mutate).sort()).toEqual([
      'cancel',
      'pause',
      'restart',
      'resume',
      'start',
    ])
    for (const v of ['start', 'pause', 'resume', 'cancel', 'restart'] as const) {
      expect(typeof result.current.mutate[v]).toBe('function')
    }
  })

  it('A4: mutate.* keep referential identity across re-renders when args are stable', async () => {
    const fetchMock = makeRouter(() => statusOk('idle'))
    vi.stubGlobal('fetch', fetchMock)

    const { result, rerender } = renderHookIsolated(
      ({ k, id }: { k: 'autopilot' | 'chain'; id: string | null }) =>
        useSessionControls(k, id),
      { initialProps: { k: 'autopilot' as const, id: 'demo' as string | null } },
    )
    await waitFor(() => expect(result.current.state).toBe('idle'))
    const prev = result.current.mutate
    rerender({ k: 'autopilot', id: 'demo' })
    const next = result.current.mutate
    expect(Object.is(prev.start, next.start)).toBe(true)
    expect(Object.is(prev.pause, next.pause)).toBe(true)
    expect(Object.is(prev.resume, next.resume)).toBe(true)
    expect(Object.is(prev.cancel, next.cancel)).toBe(true)
  })

  it('A5: mutate.* get a new identity when targetId changes', async () => {
    const fetchMock = makeRouter(() => statusOk('idle'))
    vi.stubGlobal('fetch', fetchMock)

    const { result, rerender } = renderHookIsolated(
      ({ id }: { id: string | null }) =>
        useSessionControls('autopilot', id),
      { initialProps: { id: 'demo' as string | null } },
    )
    await waitFor(() => expect(result.current.state).toBe('idle'))
    const prev = result.current.mutate
    rerender({ id: 'other' })
    await waitFor(() => expect(result.current.state).toBe('idle'))
    const next = result.current.mutate
    expect(Object.is(prev.start, next.start)).toBe(false)
    expect(Object.is(prev.pause, next.pause)).toBe(false)
    expect(Object.is(prev.resume, next.resume)).toBe(false)
    expect(Object.is(prev.cancel, next.cancel)).toBe(false)
  })

  it('A6: targetId=null short-circuits SWR (no /status request fires)', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)

    renderHookIsolated(() => useSessionControls('autopilot', null))

    await new Promise((r) => setTimeout(r, 50))
    const statusCalls = calls(fetchMock, (u) => u.includes('/status'))
    expect(statusCalls).toHaveLength(0)
  })

  it('A7: URL is /api/{kind}/status?id=<encoded>', async () => {
    const fetchMock = makeRouter(() => statusOk('idle'))
    vi.stubGlobal('fetch', fetchMock)

    renderHookIsolated(() => useSessionControls('autopilot', 'a b'))
    await waitFor(() => {
      const c = calls(fetchMock, (u) => u.includes('/status'))
      expect(c.length).toBeGreaterThan(0)
    })
    const first = calls(fetchMock, (u) => u.includes('/status'))[0]
    expect(first[0]).toBe('/api/autopilot/status?id=a%20b')
  })

  it('A8: SWR isPaused returns document.hidden — no fetch while hidden', async () => {
    vi.useFakeTimers()
    const fetchMock = makeRouter(() => statusOk('running'))
    vi.stubGlobal('fetch', fetchMock)

    Object.defineProperty(document, 'hidden', {
      configurable: true,
      get: () => true,
    })

    renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await vi.advanceTimersByTimeAsync(10_000)
    const statusCalls = calls(fetchMock, (u) => u.includes('/status'))
    expect(statusCalls).toHaveLength(0)
  })

  it('A9: _REFRESH_INTERVAL_MS map has pinned values 2000/15000/30000', () => {
    expect(__test__._REFRESH_INTERVAL_MS).toEqual({
      active: 2_000,
      idle: 15_000,
      terminal: 30_000,
    })
  })
})

// === Section B — State derivation (C3) ========================
// Pure-function tests against __test__._deriveState (the 9-row table).

describe('useSessionControls — Section B: state derivation table', () => {
  const d = __test__._deriveState

  it('B0: server status undefined → idle (initial render)', () => {
    expect(d(undefined, false, false)).toBe('idle')
  })

  it('B1: idle + neither → idle', () => {
    expect(d('idle', false, false)).toBe('idle')
  })

  it('B2: idle + isStarting → starting', () => {
    expect(d('idle', true, false)).toBe('starting')
  })

  it('B3: idle + isResuming → resuming (logical row)', () => {
    expect(d('idle', false, true)).toBe('resuming')
  })

  it('B4: running → running', () => {
    expect(d('running', false, false)).toBe('running')
  })

  it('B5: running + both flags → running (server-authoritative)', () => {
    expect(d('running', true, true)).toBe('running')
  })

  it('B6: paused + neither → paused', () => {
    expect(d('paused', false, false)).toBe('paused')
  })

  it('B7: paused + isResuming → resuming', () => {
    expect(d('paused', false, true)).toBe('resuming')
  })

  it('B8: cancelled is terminal (flags ignored)', () => {
    expect(d('cancelled', true, true)).toBe('cancelled')
  })

  it('B9: completed is terminal (flags ignored)', () => {
    expect(d('completed', true, false)).toBe('completed')
  })

  it('B10: failed is terminal (flags ignored)', () => {
    expect(d('failed', false, true)).toBe('failed')
  })

  it('B0b: mount + immediate unmount with never-resolving fetch produces no console warnings', async () => {
    vi.stubGlobal('fetch', vi.fn().mockImplementation(() => new Promise(() => {})))
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    const { unmount } = renderHookIsolated(() =>
      useSessionControls('autopilot', 'demo'),
    )
    unmount()
    await new Promise((r) => setTimeout(r, 30))

    expect(errSpy).not.toHaveBeenCalled()
    expect(warnSpy).not.toHaveBeenCalled()
  })
})

// === Section C — Reconciliation effect (C1) ===================

describe('useSessionControls — Section C: reconciliation effect', () => {
  it('C1: status flips to running → isStarting/isResuming clear', async () => {
    let phase: SessionStatus = 'idle'
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk(phase)
      if (url.endsWith('/start')) return new Promise<StubResponse>(() => {}) as unknown as StubResponse
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))

    await act(async () => {
      void result.current.mutate.start()
    })
    expect(result.current.state).toBe('starting')

    phase = 'running'
    await waitFor(
      () => expect(result.current.state).toBe('running'),
      { timeout: 5000 },
    )
  })

  it('C2: status flips to paused → pauseRequestedAt clears, isPausing→false', async () => {
    vi.useFakeTimers()
    let phase: SessionStatus = 'running'
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk(phase)
      if (url.endsWith('/pause')) return mutationOk({ status: 'pausing' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await vi.waitFor(() => expect(result.current.state).toBe('running'))

    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.isPausing).toBe(true)

    phase = 'paused'
    await act(async () => {
      await vi.advanceTimersByTimeAsync(2_500)
    })
    await vi.waitFor(() => expect(result.current.isPausing).toBe(false))
  })

  it('C3: status terminal (cancelled/completed/failed) clears all pending flags', async () => {
    vi.useFakeTimers()
    let phase: SessionStatus = 'running'
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk(phase)
      if (url.endsWith('/pause')) return mutationOk({ status: 'pausing' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await vi.waitFor(() => expect(result.current.state).toBe('running'))

    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.isPausing).toBe(true)

    phase = 'cancelled'
    await act(async () => {
      await vi.advanceTimersByTimeAsync(2_500)
    })
    await vi.waitFor(() => expect(result.current.state).toBe('cancelled'))
    expect(result.current.isPausing).toBe(false)
    expect(result.current.pauseElapsedSeconds).toBe(0)
  })

  it('C4: SWR /status 500 → state stays idle, error.slug = http', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) {
        return {
          ok: false,
          status: 500,
          json: () => Promise.resolve({}),
          headers: { get: () => null },
          statusText: 'Server Error',
        }
      }
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.error).not.toBeNull())
    expect(result.current.state).toBe('idle')
    expect(result.current.error?.slug).toBe('http')
    expect(result.current.error?.status).toBe(500)
  })

  it('C5: /status error while isPausing → counter keeps incrementing', async () => {
    vi.useFakeTimers()
    let statusOkOnce = true
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) {
        if (statusOkOnce) return statusOk('running')
        return {
          ok: false,
          status: 500,
          json: () => Promise.resolve({}),
          headers: { get: () => null },
          statusText: 'Server Error',
        }
      }
      if (url.endsWith('/pause')) return mutationOk({ status: 'pausing' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await vi.waitFor(() => expect(result.current.state).toBe('running'))

    const t0 = Date.now()
    vi.setSystemTime(t0)
    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.isPausing).toBe(true)

    statusOkOnce = false
    vi.setSystemTime(t0 + 2_000)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(2_000)
    })

    expect(result.current.isPausing).toBe(true)
    expect(result.current.pauseElapsedSeconds).toBeGreaterThanOrEqual(1)
  })
})

// === Section D — Pause-elapsed counter (C1 tick) ==============

describe('useSessionControls — Section D: pause counter', () => {
  beforeEach(() => {
    vi.useFakeTimers()
  })

  async function preFlush(
    fetchMock: ReturnType<typeof vi.fn>,
    result: ReturnType<typeof renderHook>['result'],
  ): Promise<void> {
    await vi.waitFor(() => {
      const r = (result as { current: { state: string } }).current
      expect(r.state).toBe('running')
    })
    fetchMock.mockClear()
  }

  it('D1: pauseElapsedSeconds increments 1/sec monotonically', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause')) return mutationOk({ status: 'pausing' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await preFlush(fetchMock, result)

    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.pauseElapsedSeconds).toBe(0)

    const seq: number[] = []
    for (let i = 1; i <= 5; i++) {
      // advanceTimersByTimeAsync advances Date.now() AND fires timers;
      // no separate setSystemTime call is needed (it would
      // double-advance and produce 6,7,8,9,10 instead of 1..5).
      await act(async () => {
        await vi.advanceTimersByTimeAsync(1_000)
      })
      seq.push(result.current.pauseElapsedSeconds)
    }
    expect(seq).toEqual([1, 2, 3, 4, 5])
  })

  it('D2: pauseElapsedSeconds is 0 before pause() is invoked', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    expect(result.current.pauseElapsedSeconds).toBe(0)
    await preFlush(fetchMock, result)
    expect(result.current.pauseElapsedSeconds).toBe(0)
  })

  it('D3: after 5s single-jump, counter equals 5 (no skipped ticks)', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause')) return mutationOk({ status: 'pausing' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await preFlush(fetchMock, result)

    await act(async () => {
      await result.current.mutate.pause()
    })

    await act(async () => {
      await vi.advanceTimersByTimeAsync(5_000)
    })
    expect(result.current.pauseElapsedSeconds).toBe(5)
  })

  it('D4: 409 pause rejection → pauseElapsedSeconds=0, isPausing=false', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause'))
        return mutationErr(409, { error: 'already_running' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await preFlush(fetchMock, result)

    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.isPausing).toBe(false)
    expect(result.current.pauseElapsedSeconds).toBe(0)
    expect(result.current.error?.slug).toBe('already_running')
  })

  it('D5: tick interval cleared on unmount — no exceptions after timer advance', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause')) return mutationOk({ status: 'pausing' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})

    const { result, unmount } = renderHookIsolated(() =>
      useSessionControls('autopilot', 'demo'),
    )
    await preFlush(fetchMock, result)
    await act(async () => {
      await result.current.mutate.pause()
    })

    const errsBeforeUnmount = errSpy.mock.calls.length
    unmount()
    await act(async () => {
      await vi.advanceTimersByTimeAsync(10_000)
    })
    // Filter React-19's act warnings emitted by SWR's deferred
    // mount-teardown — not a defect in this hook (R10/EC-T1 invariant
    // is "no leaked tick interval", not "zero React noise").
    const nonActErrors = errSpy.mock.calls
      .slice(errsBeforeUnmount)
      .filter((args) => !String(args[0]).includes('not wrapped in act'))
    expect(nonActErrors).toHaveLength(0)
  })

  it('D6: failed pause + successful retry — counter restarts from 0', async () => {
    let failNext = true
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause')) {
        if (failNext) {
          failNext = false
          return mutationErr(409, { error: 'already_running' })
        }
        return mutationOk({ status: 'pausing' })
      }
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await preFlush(fetchMock, result)

    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.isPausing).toBe(false)

    await act(async () => {
      await vi.advanceTimersByTimeAsync(30_000)
    })
    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.isPausing).toBe(true)
    expect(result.current.pauseElapsedSeconds).toBe(0)
  })

  it('D7: clock skew (Date.now jumps backwards) clamps counter to 0', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause')) return mutationOk({ status: 'pausing' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await preFlush(fetchMock, result)
    await act(async () => {
      await result.current.mutate.pause()
    })

    // Capture the pause-request timestamp, then explicitly rewind 30s.
    const pausedAt = Date.now()
    vi.setSystemTime(pausedAt - 30_000)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1_000)
    })
    expect(result.current.pauseElapsedSeconds).toBe(0)
  })
})

// === Section E — CSRF retrieval (C2) ==========================

describe('useSessionControls — Section E: CSRF retrieval', () => {
  async function setupRunning(): Promise<{
    fetchMock: ReturnType<typeof vi.fn>
    result: ControlsResult
  }> {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause')) return mutationOk({ status: 'pausing' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() =>
      useSessionControls('autopilot', 'demo'),
    )
    await waitFor(() => expect(result.current.state).toBe('running'))
    return { fetchMock, result }
  }

  it('E1: cookie csrf_token=ABC123 → X-CSRF-Token: ABC123', async () => {
    stubCookie('csrf_token=ABC123')
    stubMetaTag(null)
    const { fetchMock, result } = await setupRunning()

    await act(async () => {
      await result.current.mutate.pause()
    })
    const c = calls(fetchMock, (u) => u.endsWith('/pause'))
    expect(c).toHaveLength(1)
    expect(getHeader(c[0][1], 'X-CSRF-Token')).toBe('ABC123')
  })

  it('E2: meta-tag-only retrieval (cookie empty) → header from meta', async () => {
    stubCookie('')
    stubMetaTag('META456')
    const { fetchMock, result } = await setupRunning()

    await act(async () => {
      await result.current.mutate.pause()
    })
    const c = calls(fetchMock, (u) => u.endsWith('/pause'))
    expect(c).toHaveLength(1)
    expect(getHeader(c[0][1], 'X-CSRF-Token')).toBe('META456')
  })

  it('E3: both missing → no fetch fires, error.slug=csrf, status=0', async () => {
    stubCookie('')
    stubMetaTag(null)
    const { fetchMock, result } = await setupRunning()

    await act(async () => {
      await result.current.mutate.pause()
    })
    const c = calls(fetchMock, (u) => u.endsWith('/pause'))
    expect(c).toHaveLength(0)
    expect(result.current.error?.slug).toBe('csrf')
    expect(result.current.error?.status).toBe(0)
  })

  it('E4: empty cookie value falls through to meta-tag fallback', async () => {
    stubCookie('csrf_token=')
    stubMetaTag('M')
    const { fetchMock, result } = await setupRunning()

    await act(async () => {
      await result.current.mutate.pause()
    })
    const c = calls(fetchMock, (u) => u.endsWith('/pause'))
    expect(c).toHaveLength(1)
    expect(getHeader(c[0][1], 'X-CSRF-Token')).toBe('M')
  })

  it('E5: prefix collision csrf_tokenX=foo; csrf_token=bar → bar', async () => {
    stubCookie('csrf_tokenX=foo; csrf_token=bar')
    stubMetaTag(null)
    const { fetchMock, result } = await setupRunning()

    await act(async () => {
      await result.current.mutate.pause()
    })
    const c = calls(fetchMock, (u) => u.endsWith('/pause'))
    expect(getHeader(c[0][1], 'X-CSRF-Token')).toBe('bar')
  })

  it('E6: URL-encoded cookie value csrf_token=A%3DB → decoded A=B', async () => {
    stubCookie('csrf_token=A%3DB')
    stubMetaTag(null)
    const { fetchMock, result } = await setupRunning()

    await act(async () => {
      await result.current.mutate.pause()
    })
    const c = calls(fetchMock, (u) => u.endsWith('/pause'))
    expect(getHeader(c[0][1], 'X-CSRF-Token')).toBe('A=B')
  })

  it('E7: meta tag present but content empty → fail-fast (no fetch)', async () => {
    stubCookie('')
    stubMetaTag('')
    const { fetchMock, result } = await setupRunning()

    await act(async () => {
      await result.current.mutate.pause()
    })
    const c = calls(fetchMock, (u) => u.endsWith('/pause'))
    expect(c).toHaveLength(0)
    expect(result.current.error?.slug).toBe('csrf')
  })

  it('E8: document.cookie throws → meta-tag fallback engages cleanly', async () => {
    Object.defineProperty(document, 'cookie', {
      configurable: true,
      get: () => {
        throw new Error('SecurityError')
      },
    })
    stubMetaTag('M')
    const { fetchMock, result } = await setupRunning()

    await act(async () => {
      await result.current.mutate.pause()
    })
    const c = calls(fetchMock, (u) => u.endsWith('/pause'))
    expect(c).toHaveLength(1)
    expect(getHeader(c[0][1], 'X-CSRF-Token')).toBe('M')
  })

  it('E9: token read fresh on every mutation (no caching)', async () => {
    stubCookie('csrf_token=T1')
    stubMetaTag(null)
    const { fetchMock, result } = await setupRunning()

    await act(async () => {
      await result.current.mutate.pause()
    })
    stubCookie('csrf_token=T2')
    await act(async () => {
      await result.current.mutate.pause()
    })
    const c = calls(fetchMock, (u) => u.endsWith('/pause'))
    expect(c).toHaveLength(2)
    expect(getHeader(c[0][1], 'X-CSRF-Token')).toBe('T1')
    expect(getHeader(c[1][1], 'X-CSRF-Token')).toBe('T2')
  })
})

// === Section F — Mutation helpers — happy paths (C6) =========

describe('useSessionControls — Section F: mutation happy paths', () => {
  it('F1: mutate.start POSTs /api/autopilot/start with body and CSRF header', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('idle')
      if (url.endsWith('/start')) return mutationOk({ status: 'started' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))

    await act(async () => {
      await result.current.mutate.start()
    })
    const c = calls(fetchMock, (u) => u.endsWith('/start'))
    expect(c).toHaveLength(1)
    expect(c[0][0]).toBe('/api/autopilot/start')
    expect(c[0][1]?.method).toBe('POST')
    expect(getHeader(c[0][1], 'X-CSRF-Token')).toBe('ABC123')
    expect(getHeader(c[0][1], 'Content-Type')).toBe('application/json')
    const body = JSON.parse(c[0][1]?.body as string)
    expect(body).toEqual({ target_id: 'demo', pipeline: 'full' })
  })

  it('F2: mutate.start({pipeline:"light"}) sends pipeline=light', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('idle')
      if (url.endsWith('/start')) return mutationOk({ status: 'started' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))

    await act(async () => {
      await result.current.mutate.start({ pipeline: 'light' })
    })
    const c = calls(fetchMock, (u) => u.endsWith('/start'))
    const body = JSON.parse(c[0][1]?.body as string)
    expect(body.pipeline).toBe('light')
  })

  // controls-03 #5 — chain start MUST NOT send the pipeline field.
  // autopilot-chain.sh ignores it, so emitting it would mislead any
  // future server-side parser into thinking chain accepts a pipeline.
  it('F2b: mutate.start omits pipeline field when targetKind=chain', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('idle')
      if (url.endsWith('/start')) return mutationOk({ status: 'started' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('chain', 'demo-plan'))
    await waitFor(() => expect(result.current.state).toBe('idle'))

    await act(async () => {
      await result.current.mutate.start()
    })
    const c = calls(fetchMock, (u) => u.endsWith('/start'))
    expect(c).toHaveLength(1)
    expect(c[0][0]).toBe('/api/chain/start')
    const body = JSON.parse(c[0][1]?.body as string)
    expect(body).toEqual({ target_id: 'demo-plan' })
    expect('pipeline' in body).toBe(false)
  })

  it('F2c: chain start ignores a stray opts.pipeline argument', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('idle')
      if (url.endsWith('/start')) return mutationOk({ status: 'started' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('chain', 'demo-plan'))
    await waitFor(() => expect(result.current.state).toBe('idle'))

    await act(async () => {
      await result.current.mutate.start({ pipeline: 'light' })
    })
    const c = calls(fetchMock, (u) => u.endsWith('/start'))
    const body = JSON.parse(c[0][1]?.body as string)
    expect('pipeline' in body).toBe(false)
  })

  it('F3: mutate.start flips state to starting before POST resolves', async () => {
    let resolveStart: (v: StubResponse) => void = () => {}
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('idle')
      if (url.endsWith('/start'))
        return new Promise<StubResponse>((res) => {
          resolveStart = res
        })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))

    let p: Promise<void> = Promise.resolve()
    await act(async () => {
      p = result.current.mutate.start()
    })
    expect(result.current.state).toBe('starting')

    resolveStart(mutationOk({ status: 'started' }))
    await act(async () => {
      await p
    })
  })

  it('F4: /status flipping to running clears isStarting → state=running', async () => {
    let phase: SessionStatus = 'idle'
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk(phase)
      if (url.endsWith('/start')) return mutationOk({ status: 'started' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))
    await act(async () => {
      await result.current.mutate.start()
    })
    phase = 'running'
    await waitFor(
      () => expect(result.current.state).toBe('running'),
      { timeout: 5000 },
    )
  })

  it('F5: mutate.pause POSTs /api/chain/pause with body {target_id:"p1"}', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause')) return mutationOk({ status: 'pausing' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('chain', 'p1'))
    await waitFor(() => expect(result.current.state).toBe('running'))
    await act(async () => {
      await result.current.mutate.pause()
    })
    const c = calls(fetchMock, (u) => u.endsWith('/pause'))
    expect(c[0][0]).toBe('/api/chain/pause')
    expect(JSON.parse(c[0][1]?.body as string)).toEqual({ target_id: 'p1' })
  })

  it('F6: pause 200 then status=running → isPausing stays true', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause')) return mutationOk({ status: 'pausing' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('running'))
    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.isPausing).toBe(true)
    expect(result.current.state).toBe('running')
  })

  it('F7: mutate.resume POSTs and sets isResuming optimistically', async () => {
    let resolveResume: (v: StubResponse) => void = () => {}
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('paused')
      if (url.endsWith('/resume'))
        return new Promise<StubResponse>((res) => {
          resolveResume = res
        })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('paused'))

    let p: Promise<void> = Promise.resolve()
    await act(async () => {
      p = result.current.mutate.resume()
    })
    expect(result.current.state).toBe('resuming')

    const c = calls(fetchMock, (u) => u.endsWith('/resume'))
    expect(c[0][0]).toBe('/api/autopilot/resume')
    expect(JSON.parse(c[0][1]?.body as string)).toEqual({ target_id: 'demo' })
    expect(getHeader(c[0][1], 'X-CSRF-Token')).toBe('ABC123')

    resolveResume(mutationOk({ status: 'resumed' }))
    await act(async () => {
      await p
    })
  })

  it('F8: resume 200 → next status=running clears isResuming', async () => {
    let phase: SessionStatus = 'paused'
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk(phase)
      if (url.endsWith('/resume')) return mutationOk({ status: 'resumed' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('paused'))
    await act(async () => {
      await result.current.mutate.resume()
    })
    phase = 'running'
    await waitFor(
      () => expect(result.current.state).toBe('running'),
      { timeout: 5000 },
    )
  })

  it('F9: mutate.cancel POSTs without optimistic flag — state stays running', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/cancel')) return mutationOk({ status: 'cancelled' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('running'))

    await act(async () => {
      await result.current.mutate.cancel()
    })
    const c = calls(fetchMock, (u) => u.endsWith('/cancel'))
    expect(c).toHaveLength(1)
    expect(c[0][0]).toBe('/api/autopilot/cancel')
    expect(JSON.parse(c[0][1]?.body as string)).toEqual({ target_id: 'demo' })
    expect(result.current.state).toBe('running')
  })

  it('F10: after cancel 200 hook revalidates /status before further timer advance', async () => {
    let phase: SessionStatus = 'running'
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk(phase)
      if (url.endsWith('/cancel')) return mutationOk({ status: 'cancelled' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('running'))

    fetchMock.mockClear()
    await act(async () => {
      await result.current.mutate.cancel()
    })
    phase = 'cancelled'
    await waitFor(() => {
      const after = fetchMock.mock.calls.map(([u]) =>
        urlOf(u as FetchInput),
      )
      const cancelIdx = after.findIndex((u) => u.endsWith('/cancel'))
      const statusIdx = after.findIndex(
        (u, i) => i > cancelIdx && u.includes('/status'),
      )
      expect(cancelIdx).toBeGreaterThanOrEqual(0)
      expect(statusIdx).toBeGreaterThan(cancelIdx)
    })
  })

  it('F11: cancel state lands on cancelled only after /status poll observes it', async () => {
    let phase: SessionStatus = 'running'
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk(phase)
      if (url.endsWith('/cancel')) return mutationOk({ status: 'cancelled' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('running'))
    await act(async () => {
      await result.current.mutate.cancel()
    })
    expect(result.current.state).toBe('running')
    phase = 'cancelled'
    // Cancel's scoped-mutate revalidation triggers an immediate /status
    // poll; the assertion can resolve within the natural SWR cadence
    // but the default waitFor 1 s is too tight under jsdom.
    await waitFor(
      () => expect(result.current.state).toBe('cancelled'),
      { timeout: 5000 },
    )
  })

  it('F12: cancelled vs already_cancelled both map to UI state cancelled', async () => {
    let phase: SessionStatus = 'running'
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk(phase)
      if (url.endsWith('/cancel'))
        return mutationOk({ status: 'already_cancelled' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('running'))
    await act(async () => {
      await result.current.mutate.cancel()
    })
    phase = 'cancelled'
    await waitFor(
      () => expect(result.current.state).toBe('cancelled'),
      { timeout: 5000 },
    )
  })

  it('F13: mutation promise resolves (does not throw) on error path', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause'))
        return mutationErr(500, { error: 'tmux_error' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('running'))

    await expect(
      (async () => {
        await act(async () => {
          await result.current.mutate.pause()
        })
      })(),
    ).resolves.toBeUndefined()
    expect(result.current.error?.slug).toBe('tmux_error')
  })
})

// === Section G — Error surface (C5) ===========================

describe('useSessionControls — Section G: error surface', () => {
  async function setupRunning(routes: RouteFn): Promise<{
    fetchMock: ReturnType<typeof vi.fn>
    result: ControlsResult
  }> {
    const fetchMock = makeRouter((url, init) => {
      if (url.includes('/status')) return statusOk('running')
      return routes(url, init)
    })
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() =>
      useSessionControls('autopilot', 'demo'),
    )
    await waitFor(() => expect(result.current.state).toBe('running'))
    return { fetchMock, result }
  }

  it('G1: pause 409 already_running → error mapped', async () => {
    const { result } = await setupRunning((url) =>
      url.endsWith('/pause')
        ? mutationErr(409, { error: 'already_running' })
        : mutationOk(),
    )
    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.error?.slug).toBe('already_running')
    expect(result.current.error?.status).toBe(409)
    expect(result.current.error?.message).toBeTruthy()
  })

  it('G2: start 422 target_not_found with hint', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('idle')
      if (url.endsWith('/start'))
        return mutationErr(422, {
          error: 'target_not_found',
          hint: 'Add it to the plan',
        })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))
    await act(async () => {
      await result.current.mutate.start()
    })
    expect(result.current.error?.slug).toBe('target_not_found')
    expect(result.current.error?.hint).toBe('Add it to the plan')
  })

  it('G3: start 429 with Retry-After:30 → retryAfterSeconds=30', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('idle')
      if (url.endsWith('/start'))
        return mutationErr(
          429,
          { error: 'concurrent_cap_reached', cap: 3, active: 3 },
          '30',
        )
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))
    await act(async () => {
      await result.current.mutate.start()
    })
    expect(result.current.error?.retryAfterSeconds).toBe(30)
  })

  it('G4: 429 without parseable Retry-After omits retryAfterSeconds', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('idle')
      if (url.endsWith('/start'))
        return mutationErr(
          429,
          { error: 'concurrent_cap_reached' },
          'soon',
        )
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))
    await act(async () => {
      await result.current.mutate.start()
    })
    expect(
      'retryAfterSeconds' in (result.current.error as object),
    ).toBe(false)
  })

  it('G5: 400 Pydantic envelope → error.slug=pydantic', async () => {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('idle')
      if (url.endsWith('/start'))
        return mutationErr(400, {
          detail: [{ type: 'string_type', loc: ['body', 'target_id'] }],
        })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))
    await act(async () => {
      await result.current.mutate.start()
    })
    expect(result.current.error?.slug).toBe('pydantic')
  })

  it('G6: non-JSON response body → error.slug=http, console silent', async () => {
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const { result } = await setupRunning((url) =>
      url.endsWith('/pause') ? mutationBadJson(502) : mutationOk(),
    )
    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.error?.slug).toBe('http')
    expect(result.current.error?.status).toBe(502)
    expect(errSpy).not.toHaveBeenCalled()
    expect(warnSpy).not.toHaveBeenCalled()
  })

  /* G6b (controls-06 #9): non-JSON error bodies (e.g. the stdlib
     HTML 500 page when a FastAPI handler raises uncaught) must also
     surface the friendly _DEFAULT_ERROR_COPY phrase rather than the
     raw HTTP statusText. The reported "Internal Server Error" Alert
     came from this code path. */
  it('G6b: non-JSON 500 → message is friendly copy, not statusText', async () => {
    const { result } = await setupRunning((url) =>
      url.endsWith('/pause')
        ? {
            ok: false,
            status: 500,
            json: () => Promise.reject(new SyntaxError('Unexpected token <')),
            headers: { get: () => null },
            statusText: 'Internal Server Error',
          }
        : mutationOk(),
    )
    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.error?.slug).toBe('http')
    expect(result.current.error?.status).toBe(500)
    expect(result.current.error?.message).toBe('Request failed')
  })

  /* G7b (controls-06 #9): known semantic slugs (csrf, origin, etc.)
     surface the friendly _DEFAULT_ERROR_COPY phrase, NOT the raw
     HTTP statusText. The cycle-5 fallback chain put statusText
     ahead of the friendly copy, so a 403 CSRF reject leaked
     "Forbidden" into the operator-facing Alert (visible bug
     screenshot, cycle-6 #9). Anti-regression: when the server
     replies `{"error":"csrf"}` + statusText="Forbidden", message
     must be the friendly copy. G7 (unknown slug) stays green
     because the unknown-slug branch still falls through. */
  it('G7b: known slug (csrf) → message uses friendly copy, not statusText', async () => {
    const { result } = await setupRunning((url) =>
      url.endsWith('/pause')
        ? {
            ok: false,
            status: 403,
            json: () => Promise.resolve({ error: 'csrf' }),
            headers: { get: () => null },
            statusText: 'Forbidden',
          }
        : mutationOk(),
    )
    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.error?.slug).toBe('csrf')
    /* controls-07 #3 — terser primary copy; "reload the page" was
       misdirection because the body-token fallback runs fresh on
       every click. */
    expect(result.current.error?.message).toBe(
      'CSRF token unavailable',
    )
  })

  it('G7c: known slug (origin) → message uses friendly copy, not statusText', async () => {
    const { result } = await setupRunning((url) =>
      url.endsWith('/pause')
        ? {
            ok: false,
            status: 403,
            json: () => Promise.resolve({ error: 'origin' }),
            headers: { get: () => null },
            statusText: 'Forbidden',
          }
        : mutationOk(),
    )
    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.error?.slug).toBe('origin')
    expect(result.current.error?.message).toBe('Origin not allowed')
  })

  it('G7: unknown slug → message falls through to statusText', async () => {
    const { result } = await setupRunning((url) =>
      url.endsWith('/pause')
        ? {
            ok: false,
            status: 409,
            json: () => Promise.resolve({ error: 'unrecognised_slug' }),
            headers: { get: () => null },
            statusText: 'Conflict',
          }
        : mutationOk(),
    )
    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.error?.message).toBe('Conflict')
  })

  it('G8: server body message overrides default copy', async () => {
    const { result } = await setupRunning((url) =>
      url.endsWith('/pause')
        ? mutationErr(500, {
            error: 'tmux_error',
            message: 'tmux daemon offline',
          })
        : mutationOk(),
    )
    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.error?.message).toBe('tmux daemon offline')
  })

  it('G9: network failure → slug=network, no exception escapes', async () => {
    const fetchMock = vi.fn().mockImplementation((input: FetchInput) => {
      const u = urlOf(input)
      if (u.includes('/status')) return Promise.resolve(statusOk('running'))
      return Promise.reject(new TypeError('Network failure'))
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('running'))

    await expect(
      (async () => {
        await act(async () => {
          await result.current.mutate.pause()
        })
      })(),
    ).resolves.toBeUndefined()
    expect(result.current.error?.slug).toBe('network')
    expect(result.current.error?.status).toBe(0)
  })

  it('G10: error cleared at start of new mutation BEFORE optimistic flip', async () => {
    let firstCall = true
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause')) {
        if (firstCall) {
          firstCall = false
          return mutationErr(409, { error: 'already_running' })
        }
        return mutationOk({ status: 'pausing' })
      }
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('running'))
    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.error?.slug).toBe('already_running')

    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.error).toBeNull()
    expect(result.current.isPausing).toBe(true)
  })

  it('G11: a successful mutation does NOT auto-clear a prior error before next mutation', async () => {
    let phase: SessionStatus = 'running'
    let pauseFails = true
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk(phase)
      if (url.endsWith('/pause')) {
        if (pauseFails) {
          pauseFails = false
          return mutationErr(409, { error: 'already_running' })
        }
        return mutationOk({ status: 'pausing' })
      }
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('running'))
    await act(async () => {
      await result.current.mutate.pause()
    })
    expect(result.current.error?.slug).toBe('already_running')

    phase = 'running'
    await new Promise((r) => setTimeout(r, 50))
    expect(result.current.error?.slug).toBe('already_running')
  })
})

// === Section H — Disabled-state no-ops ========================

describe('useSessionControls — Section H: disabled-state no-ops', () => {
  async function setupAtStatus(
    s: SessionStatus,
  ): Promise<{
    fetchMock: ReturnType<typeof vi.fn>
    result: ControlsResult
  }> {
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk(s)
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() =>
      useSessionControls('autopilot', 'demo'),
    )
    await waitFor(() =>
      expect(result.current.state).toBe(s as string),
    )
    return { fetchMock, result }
  }

  const forbiddenForPause: SessionStatus[] = [
    'idle',
    'paused',
    'cancelled',
    'completed',
    'failed',
  ]
  for (const s of forbiddenForPause) {
    it(`H1[${s}]: mutate.pause from ${s} → no-op (no fetch, no error)`, async () => {
      const { fetchMock, result } = await setupAtStatus(s)
      fetchMock.mockClear()
      let returned: unknown = 'sentinel'
      await act(async () => {
        returned = await result.current.mutate.pause()
      })
      expect(returned).toBeUndefined()
      expect(calls(fetchMock, (u) => u.endsWith('/pause'))).toHaveLength(0)
      expect(result.current.error).toBeNull()
    })
  }

  const forbiddenForResume: SessionStatus[] = [
    'idle',
    'running',
    'cancelled',
    'completed',
    'failed',
  ]
  for (const s of forbiddenForResume) {
    it(`H2[${s}]: mutate.resume from ${s} → no-op`, async () => {
      const { fetchMock, result } = await setupAtStatus(s)
      fetchMock.mockClear()
      let returned: unknown = 'sentinel'
      await act(async () => {
        returned = await result.current.mutate.resume()
      })
      expect(returned).toBeUndefined()
      expect(calls(fetchMock, (u) => u.endsWith('/resume'))).toHaveLength(0)
      expect(result.current.error).toBeNull()
    })
  }

  const forbiddenForStart: SessionStatus[] = ['running', 'paused']
  for (const s of forbiddenForStart) {
    it(`H3[${s}]: mutate.start from ${s} → no-op`, async () => {
      const { fetchMock, result } = await setupAtStatus(s)
      fetchMock.mockClear()
      let returned: unknown = 'sentinel'
      await act(async () => {
        returned = await result.current.mutate.start()
      })
      expect(returned).toBeUndefined()
      expect(calls(fetchMock, (u) => u.endsWith('/start'))).toHaveLength(0)
      expect(result.current.error).toBeNull()
    })
  }

  const forbiddenForCancel: SessionStatus[] = [
    'idle',
    'cancelled',
    'completed',
    'failed',
  ]
  for (const s of forbiddenForCancel) {
    it(`H4[${s}]: mutate.cancel from ${s} → no-op`, async () => {
      const { fetchMock, result } = await setupAtStatus(s)
      fetchMock.mockClear()
      let returned: unknown = 'sentinel'
      await act(async () => {
        returned = await result.current.mutate.cancel()
      })
      expect(returned).toBeUndefined()
      expect(calls(fetchMock, (u) => u.endsWith('/cancel'))).toHaveLength(0)
      expect(result.current.error).toBeNull()
    })
  }

  it('H5: targetId=null → all mutate.* are no-ops (zero fetches)', async () => {
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', null))
    await new Promise((r) => setTimeout(r, 20))

    for (const verb of ['start', 'pause', 'resume', 'cancel'] as const) {
      let returned: unknown = 'sentinel'
      await act(async () => {
        returned = await result.current.mutate[verb]()
      })
      expect(returned).toBeUndefined()
    }
    expect(fetchMock).not.toHaveBeenCalled()
    expect(result.current.error).toBeNull()
  })
})

// === Section I — Concurrency edges ============================

describe('useSessionControls — Section I: concurrency edges', () => {
  it('I1: two rapid pause clicks — pauseRequestedAt set by FIRST call only', async () => {
    vi.useFakeTimers()
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause')) return mutationOk({ status: 'pausing' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const t0 = 1_700_000_000_000
    vi.setSystemTime(t0)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await vi.waitFor(() => expect(result.current.state).toBe('running'))

    await act(async () => {
      void result.current.mutate.pause()
    })
    vi.setSystemTime(t0 + 50)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(50)
    })
    await act(async () => {
      void result.current.mutate.pause()
    })

    vi.setSystemTime(t0 + 1_050)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1_000)
    })
    expect(result.current.pauseElapsedSeconds).toBe(1)
    expect(calls(fetchMock, (u) => u.endsWith('/pause')).length).toBe(2)
  })

  it('I2: pause then cancel before pause resolves — both POSTs fire', async () => {
    vi.useFakeTimers()
    let resolvePause: (v: StubResponse) => void = () => {}
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause'))
        return new Promise<StubResponse>((res) => {
          resolvePause = res
        })
      if (url.endsWith('/cancel'))
        return mutationOk({ status: 'cancelled' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await vi.waitFor(() => expect(result.current.state).toBe('running'))

    await act(async () => {
      void result.current.mutate.pause()
    })
    await act(async () => {
      await result.current.mutate.cancel()
    })
    resolvePause(mutationOk({ status: 'pausing' }))
    await act(async () => {
      await vi.advanceTimersByTimeAsync(50)
    })

    expect(calls(fetchMock, (u) => u.endsWith('/pause')).length).toBe(1)
    expect(calls(fetchMock, (u) => u.endsWith('/cancel')).length).toBe(1)
  })

  it('I3: pause in flight + status flips to cancelled — pause resolves cleanly, isPausing clears', async () => {
    vi.useFakeTimers()
    let phase: SessionStatus = 'running'
    let resolvePause: (v: StubResponse) => void = () => {}
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk(phase)
      if (url.endsWith('/pause'))
        return new Promise<StubResponse>((res) => {
          resolvePause = res
        })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await vi.waitFor(() => expect(result.current.state).toBe('running'))

    let p: Promise<void> = Promise.resolve()
    await act(async () => {
      p = result.current.mutate.pause()
    })
    expect(result.current.isPausing).toBe(true)

    phase = 'cancelled'
    // Advance past SWR's active-cadence poll interval (2 s) so the
    // /status poll lands and the reconciliation effect clears
    // isPausing on the terminal-state observation.
    await act(async () => {
      await vi.advanceTimersByTimeAsync(3_000)
    })
    expect(result.current.isPausing).toBe(false)

    resolvePause(mutationOk({ status: 'pausing' }))
    await expect(p).resolves.toBeUndefined()
  })

  it('I4: unmount mid-fetch — no console warnings, no uncaught rejections', async () => {
    const errSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})

    let resolvePause: (v: StubResponse) => void = () => {}
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause'))
        return new Promise<StubResponse>((res) => {
          resolvePause = res
        })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result, unmount } = renderHookIsolated(() =>
      useSessionControls('autopilot', 'demo'),
    )
    await waitFor(() => expect(result.current.state).toBe('running'))
    let p: Promise<void> = Promise.resolve()
    await act(async () => {
      p = result.current.mutate.pause()
    })
    unmount()
    resolvePause(mutationOk({ status: 'pausing' }))
    await p
    await new Promise((r) => setTimeout(r, 20))

    expect(errSpy).not.toHaveBeenCalled()
    expect(warnSpy).not.toHaveBeenCalled()
  })
})

// === Section J — Refresh interval =============================

describe('useSessionControls — Section J: refresh interval', () => {
  it('J1: idle state — poll cadence is 15000 ms (slow)', async () => {
    vi.useFakeTimers()
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('idle')
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    // Flush mount-time microtasks; the initial fetch resolves.
    await vi.advanceTimersByTimeAsync(100)
    const initialCount = calls(fetchMock, (u) => u.includes('/status')).length
    expect(initialCount).toBeGreaterThanOrEqual(1)

    // Within the next 14 s — well before the idle 15 s threshold — at
    // most one extra revalidation (SWR's mount-stale re-check) is
    // tolerated; a runaway 2 s active-cadence poll would produce 7+.
    await vi.advanceTimersByTimeAsync(14_000)
    const midCount = calls(fetchMock, (u) => u.includes('/status')).length
    expect(midCount - initialCount).toBeLessThanOrEqual(1)

    // Cross the 15 s threshold — another poll fires.
    await vi.advanceTimersByTimeAsync(2_000)
    const lateCount = calls(fetchMock, (u) => u.includes('/status')).length
    expect(lateCount).toBeGreaterThan(midCount)
  })

  it('J2: running state — second poll within 2000 ms', async () => {
    vi.useFakeTimers()
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await vi.advanceTimersByTimeAsync(0)
    await vi.waitFor(() => {
      expect(calls(fetchMock, (u) => u.includes('/status')).length).toBe(1)
    })
    await vi.advanceTimersByTimeAsync(2_500)
    await vi.waitFor(() => {
      expect(
        calls(fetchMock, (u) => u.includes('/status')).length,
      ).toBeGreaterThanOrEqual(2)
    })
  })

  it('J3: terminal state (cancelled) — poll cadence is 30 000 ms', async () => {
    vi.useFakeTimers()
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('cancelled')
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await vi.advanceTimersByTimeAsync(100)
    const initialCount = calls(fetchMock, (u) => u.includes('/status')).length
    expect(initialCount).toBeGreaterThanOrEqual(1)

    // Within the next 29 s — well below the terminal 30 s threshold —
    // at most one extra revalidation is tolerated (SWR mount-stale
    // re-check). Active or idle cadence would produce many more.
    await vi.advanceTimersByTimeAsync(29_000)
    const midCount = calls(fetchMock, (u) => u.includes('/status')).length
    expect(midCount - initialCount).toBeLessThanOrEqual(1)
  })

  it('J4: isPausing=true keeps active cadence (>=3 polls over 6000 ms)', async () => {
    vi.useFakeTimers()
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/pause')) return mutationOk({ status: 'pausing' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await vi.waitFor(() => expect(result.current.state).toBe('running'))
    await act(async () => {
      await result.current.mutate.pause()
    })
    fetchMock.mockClear()
    await act(async () => {
      await vi.advanceTimersByTimeAsync(6_000)
    })
    expect(
      calls(fetchMock, (u) => u.includes('/status')).length,
    ).toBeGreaterThanOrEqual(3)
  })

  it('J5: targetId=null — no poll fires regardless of timer advance', async () => {
    vi.useFakeTimers()
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)

    renderHookIsolated(() => useSessionControls('autopilot', null))
    await vi.advanceTimersByTimeAsync(60_000)
    expect(calls(fetchMock, (u) => u.includes('/status'))).toHaveLength(0)
  })

  it('J6: cancel triggers immediate revalidation (bypasses 30 s terminal interval)', async () => {
    vi.useFakeTimers()
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) return statusOk('running')
      if (url.endsWith('/cancel')) return mutationOk({ status: 'cancelled' })
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)

    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await vi.waitFor(() => expect(result.current.state).toBe('running'))
    fetchMock.mockClear()
    await act(async () => {
      await result.current.mutate.cancel()
    })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(50)
    })
    expect(
      calls(fetchMock, (u) => u.includes('/status')).length,
    ).toBeGreaterThanOrEqual(1)
  })
})

/* controls-06 #11 — Vite-dev operators (localhost:5175 proxying to
   FastAPI on 127.0.0.1:8787) hit a SameSite=Strict + proxy-hop
   interaction where the csrf_token cookie IS set by the server but
   document.cookie comes up empty in the page script. Section K
   pins the fallback that fetches the token from the new /api/csrf
   body and caches it in memory so the mutation POST still carries
   a valid X-CSRF-Token. */
describe('useSessionControls — Section K: CSRF body-token fallback (controls-06 #11)', () => {
  beforeEach(() => {
    /* useSessionControls re-exports a reset for the module-level
       body-token cache. Without it the value populated by a prior
       case leaks into the assertion path of the next one. */
    __test__._resetCsrfBodyTokenCache()
  })

  it('K1: empty cookie + empty meta → fetches /api/csrf and uses body token', async () => {
    stubCookie('')
    stubMetaTag(null)
    const fetchMock = makeRouter((url) => {
      if (url.endsWith('/api/csrf')) return mutationOk({ token: 'BODY-TOKEN-X' })
      if (url.includes('/status')) return statusOk('idle')
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))
    await act(async () => {
      await result.current.mutate.start()
    })
    expect(result.current.error).toBeNull()
    const startCalls = calls(fetchMock, (u) => u.endsWith('/start'))
    expect(startCalls.length).toBe(1)
    expect(getHeader(startCalls[0][1], 'X-CSRF-Token')).toBe('BODY-TOKEN-X')
  })

  it('K2: cookie present → /api/csrf NOT fetched', async () => {
    /* When document.cookie carries the token, the sync read wins
       and the hook MUST NOT burn a round-trip on /api/csrf. */
    stubCookie('csrf_token=COOKIE-TOKEN-A')
    stubMetaTag(null)
    const fetchMock = makeRouter((url) => {
      if (url.endsWith('/api/csrf')) return mutationOk({ token: 'BODY-TOKEN-X' })
      if (url.includes('/status')) return statusOk('idle')
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))
    await act(async () => {
      await result.current.mutate.start()
    })
    expect(calls(fetchMock, (u) => u.endsWith('/api/csrf')).length).toBe(0)
    const startCalls = calls(fetchMock, (u) => u.endsWith('/start'))
    expect(getHeader(startCalls[0][1], 'X-CSRF-Token')).toBe('COOKIE-TOKEN-A')
  })

  it('K3: /api/csrf returns 500 → error.slug=csrf with friendly copy', async () => {
    stubCookie('')
    stubMetaTag(null)
    const fetchMock = makeRouter((url) => {
      if (url.endsWith('/api/csrf')) {
        return {
          ok: false,
          status: 500,
          json: () => Promise.resolve({ detail: 'fail' }),
          headers: { get: () => null },
          statusText: 'Internal Server Error',
        }
      }
      if (url.includes('/status')) return statusOk('idle')
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))
    await act(async () => {
      await result.current.mutate.start()
    })
    expect(result.current.error?.slug).toBe('csrf')
    expect(result.current.error?.message).toBe('CSRF token unavailable')
    /* controls-07 #3 — client-side null path attaches a hint pointing
       to the browser console. The csrfToken module emits a
       console.warn (controls-07 #2) naming the underlying transport
       failure; the hint tells the operator where to look so they
       don't waste a reload on a problem reload won't fix. */
    expect(result.current.error?.hint).toMatch(/console/i)
    /* No START POST went out — the hook short-circuited before
       invoking the unsafe-method path. */
    expect(calls(fetchMock, (u) => u.endsWith('/start')).length).toBe(0)
  })

  it('K3b: server returns 403 csrf → body-token cache is invalidated, next mutation re-fetches /api/csrf (controls-07 #5)', async () => {
    /* Cache invalidation on 403 csrf covers the "server rotated /
       cookie cleared / cookie+header diverged" failure mode. Without
       this, the operator gets stuck in a one-click-403 loop: the
       cache still holds the stale token, every retry sends the same
       wrong header, every retry 403s, and the only escape is a full
       page reload (which is exactly the dead-end the controls-07 #3
       copy fix told them not to take). */
    stubCookie('')
    stubMetaTag(null)
    let csrfCallCount = 0
    let firstStartResponseSent = false
    const fetchMock = makeRouter((url) => {
      if (url.endsWith('/api/csrf')) {
        csrfCallCount += 1
        return mutationOk({ token: `BODY-TOKEN-${csrfCallCount}` })
      }
      if (url.includes('/status')) return statusOk('idle')
      if (url.endsWith('/start')) {
        if (!firstStartResponseSent) {
          firstStartResponseSent = true
          return {
            ok: false,
            status: 403,
            json: () => Promise.resolve({ error: 'csrf' }),
            headers: { get: () => null },
            statusText: 'Forbidden',
          }
        }
        return mutationOk()
      }
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))

    await act(async () => {
      await result.current.mutate.start()
    })
    expect(result.current.error?.slug).toBe('csrf')
    /* First mutation: one /api/csrf round-trip seeds the cache. */
    expect(csrfCallCount).toBe(1)

    await act(async () => {
      await result.current.mutate.start()
    })
    /* THE FIX: the 403 from the first /start invalidated the cache,
       so the second mutation MUST hit /api/csrf again. Without
       controls-07 #5 the cache holds BODY-TOKEN-1 forever, the
       second start re-sends it, and the operator is stuck. */
    expect(csrfCallCount).toBe(2)
    /* And the second start now uses the fresh token. */
    const startCalls = calls(fetchMock, (u) => u.endsWith('/start'))
    expect(getHeader(startCalls[1][1], 'X-CSRF-Token')).toBe('BODY-TOKEN-2')
  })

  it('K4: cache is populated across mutations — only ONE /api/csrf round-trip', async () => {
    stubCookie('')
    stubMetaTag(null)
    const fetchMock = makeRouter((url) => {
      if (url.endsWith('/api/csrf')) return mutationOk({ token: 'BODY-TOKEN-Y' })
      if (url.includes('/status')) return statusOk('idle')
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() => useSessionControls('autopilot', 'demo'))
    await waitFor(() => expect(result.current.state).toBe('idle'))
    await act(async () => {
      await result.current.mutate.start()
    })
    await act(async () => {
      await result.current.mutate.start()
    })
    /* Two start clicks should reuse the cached token; /api/csrf
       must NOT be hit a second time. */
    expect(calls(fetchMock, (u) => u.endsWith('/api/csrf')).length).toBe(1)
  })
})

describe('useSessionControls — Section L: atomic restart (controls-07 #4)', () => {
  /* The cycle-6 #4 stale-running Restart affordance used to do
     `await mutate.cancel(); await mutate.start()` inside the
     component. The start() leg silently no-op'd because it read
     stateRef.current (stale 'running') and `_isAllowed('start',
     'running')` returns false. SWR revalidation updates `state`
     via re-render-then-useEffect, which has not happened by the
     time the next microtask runs `await mutate.start()`.

     The fix is a dedicated `mutate.restart()` on the hook that
     bundles both POSTs and SKIPS the _isAllowed gate on the
     start leg — the caller has already declared "I just
     cancelled, regardless of what stateRef says, start it". */

  it('L1: restart() POSTs both /cancel and /start when the chain is stale-running', async () => {
    stubCookie('csrf_token=COOKIE-TOKEN-L1')
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) {
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: () =>
            Promise.resolve({
              status: 'running',
              started_at: '2026-05-20T00:00:00Z',
              tmux_session: null,
              phase_at_pause: null,
              last_phase_complete: null,
            }),
          statusText: 'OK',
        }
      }
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() => useSessionControls('chain', 'demo-plan'))
    await waitFor(() => expect(result.current.state).toBe('running'))
    expect(result.current.isStale).toBe(true)

    await act(async () => {
      await result.current.mutate.restart()
    })

    const cancelCalls = calls(fetchMock, (u) => u.endsWith('/api/chain/cancel'))
    const startCalls = calls(fetchMock, (u) => u.endsWith('/api/chain/start'))
    expect(cancelCalls.length).toBe(1)
    /* The bug: under the old SessionControls-owned `await cancel;
       await start` sequence, this assertion fails because start()
       sees state='running' in stateRef and exits silently. */
    expect(startCalls.length).toBe(1)
  })

  it('L2: restart() surfaces the cancel error and does NOT POST start when cancel fails', async () => {
    stubCookie('csrf_token=COOKIE-TOKEN-L2')
    const fetchMock = makeRouter((url) => {
      if (url.includes('/status')) {
        return {
          ok: true,
          status: 200,
          headers: { get: () => null },
          json: () =>
            Promise.resolve({
              status: 'running',
              started_at: '2026-05-20T00:00:00Z',
              tmux_session: null,
              phase_at_pause: null,
              last_phase_complete: null,
            }),
          statusText: 'OK',
        }
      }
      if (url.endsWith('/api/chain/cancel')) {
        return {
          ok: false,
          status: 500,
          json: () => Promise.resolve({ error: 'tmux_error', message: 'kaboom' }),
          headers: { get: () => null },
          statusText: 'Internal Server Error',
        }
      }
      return mutationOk()
    })
    vi.stubGlobal('fetch', fetchMock)
    const { result } = renderHookIsolated(() => useSessionControls('chain', 'demo-plan'))
    await waitFor(() => expect(result.current.state).toBe('running'))
    await act(async () => {
      await result.current.mutate.restart()
    })
    expect(result.current.error?.slug).toBe('tmux_error')
    /* Cancel failed → restart MUST NOT proceed to start; otherwise
       we'd attempt to start on top of a still-running chain. */
    expect(calls(fetchMock, (u) => u.endsWith('/api/chain/start')).length).toBe(0)
  })
})

// === Suppress unused-warning placeholders =====================
void (null as MockInstance | null)
