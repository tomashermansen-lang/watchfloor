import {
  describe,
  it,
  expect,
  vi,
  beforeEach,
  afterEach,
} from 'vitest'
import { renderHook, act } from '@testing-library/react'
import { StrictMode, type ReactNode } from 'react'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

import * as Module from '../hooks/useTerminalSocket'
import {
  useTerminalSocket,
  __test__,
} from '../hooks/useTerminalSocket'
import type { UseTerminalSocket } from '../hooks/useTerminalSocket'

// === Stub WebSocket =====================================================

class StubWebSocket {
  static readonly CONNECTING = 0
  static readonly OPEN = 1
  static readonly CLOSING = 2
  static readonly CLOSED = 3
  static instances: StubWebSocket[] = []

  readonly CONNECTING = StubWebSocket.CONNECTING
  readonly OPEN = StubWebSocket.OPEN
  readonly CLOSING = StubWebSocket.CLOSING
  readonly CLOSED = StubWebSocket.CLOSED

  url: string
  binaryType: BinaryType = 'blob'
  readyState: number = StubWebSocket.CONNECTING
  onopen: ((ev: Event) => void) | null = null
  onmessage: ((ev: MessageEvent) => void) | null = null
  onclose: ((ev: CloseEvent) => void) | null = null
  onerror: ((ev: Event) => void) | null = null
  closeArgs: { code?: number; reason?: string } | null = null

  constructor(url: string) {
    this.url = url
    StubWebSocket.instances.push(this)
  }

  close(code?: number, reason?: string): void {
    this.closeArgs = { code, reason }
    this.readyState = StubWebSocket.CLOSED
  }

  send(): void {
    throw new Error('StubWebSocket.send must not be invoked')
  }

  dispatchOpen(): void {
    this.readyState = StubWebSocket.OPEN
    this.onopen?.(new Event('open'))
  }

  dispatchMessage(data: ArrayBuffer | string | Blob): void {
    this.onmessage?.(new MessageEvent('message', { data }))
  }

  dispatchClose(code: number, reason: string): void {
    this.readyState = StubWebSocket.CLOSED
    this.onclose?.(new CloseEvent('close', { code, reason }))
  }

  dispatchError(): void {
    this.onerror?.(new Event('error'))
  }
}

// === Test fixtures ======================================================

function stubCookie(value: string): void {
  Object.defineProperty(document, 'cookie', {
    configurable: true,
    get: () => value,
    set: () => {},
  })
}

function stubMetaTag(content: string | null): void {
  document.head
    .querySelectorAll('meta[name="csrf-token"]')
    .forEach((n) => n.remove())
  if (content === null) return
  const meta = document.createElement('meta')
  meta.setAttribute('name', 'csrf-token')
  meta.setAttribute('content', content)
  document.head.appendChild(meta)
}

function stubLocation(protocol: 'http:' | 'https:', host: string): void {
  Object.defineProperty(window, 'location', {
    configurable: true,
    value: { protocol, host },
  })
}

const ORIGINAL_LOCATION = Object.getOwnPropertyDescriptor(window, 'location')

beforeEach(() => {
  StubWebSocket.instances = []
  stubCookie('csrf_token=ABC123')
  stubMetaTag(null)
  stubLocation('http:', '127.0.0.1:5175')
})

afterEach(() => {
  vi.restoreAllMocks()
  vi.useRealTimers()
  stubMetaTag(null)
  if (ORIGINAL_LOCATION) {
    Object.defineProperty(window, 'location', ORIGINAL_LOCATION)
  }
})

// === Source-string helpers (T-L grep guards) ============================

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)
const HOOK_SRC_PATH = resolve(__dirname, '..', 'hooks', 'useTerminalSocket.ts')
const SESSION_CONTROLS_SRC_PATH = resolve(
  __dirname,
  '..',
  'hooks',
  'useSessionControls.ts',
)
const TERMINAL_WS_SRC_PATH = resolve(
  __dirname,
  '..',
  '..',
  '..',
  'server',
  'terminal_ws.py',
)
const hookSrc = readFileSync(HOOK_SRC_PATH, 'utf8')

// =========================================================================
// Section T-A — Public surface and module shape
// =========================================================================

describe('useTerminalSocket — T-A: public surface', () => {
  it('T-A1: module exports useTerminalSocket; no default export', () => {
    expect(typeof Module.useTerminalSocket).toBe('function')
    expect(
      (Module as Record<string, unknown>).default,
    ).toBeUndefined()
    const publicKeys = Object.keys(Module)
      .filter((k) => !k.startsWith('__'))
      .sort()
    expect(publicKeys).toEqual(['useTerminalSocket'])
  })

  it('T-A2: return record has exactly 6 keys after mount (controls-07 #9)', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    /* controls-07 #9 — `lastFrame` replaced by `frameQueue` + `drainFrames`. */
    expect(Object.keys(result.current).sort()).toEqual([
      'bufferOverflow',
      'drainFrames',
      'frameQueue',
      'reconnectAttempt',
      'sendDisabled',
      'status',
    ])
    unmount()
  })

  it('T-A3: sendDisabled === true across status transitions', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    vi.useFakeTimers()
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    expect(result.current.sendDisabled).toBe(true)
    expect(result.current.status).toBe('connecting')

    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    expect(result.current.sendDisabled).toBe(true)
    expect(result.current.status).toBe('connected')

    act(() => {
      StubWebSocket.instances[0].dispatchClose(1011, 'pty session closed')
    })
    expect(result.current.sendDisabled).toBe(true)
    expect(result.current.status).toBe('reconnecting')

    unmount()
    vi.useRealTimers()
  })

  it('T-A4: no write-side method names on returned record', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    const record = result.current as unknown as Record<string, unknown>
    for (const name of ['send', 'write', 'feed', 'dispatchEvent']) {
      expect(record[name]).toBeUndefined()
    }
    unmount()
  })

  it('T-A5: __test__ namespace exports exactly the 9 pinned keys', () => {
    expect(Object.keys(__test__).sort()).toEqual(
      [
        '_BACKOFF_BASE_MS',
        '_BACKOFF_FACTOR',
        '_MAX_RECONNECT_ATTEMPTS',
        '_REASON_TABLE',
        '_STOP_REASONS_ON_1011',
        '_buildWsUrl',
        '_classifyClose',
        '_parseBufferOverflow',
        '_readCsrfToken',
      ].sort(),
    )
  })

  it('T-A6: backoff constants pinned', () => {
    expect(__test__._BACKOFF_BASE_MS).toBe(1000)
    expect(__test__._BACKOFF_FACTOR).toBe(2)
    expect(__test__._MAX_RECONNECT_ATTEMPTS).toBe(5)
  })
})

// =========================================================================
// Section T-B — _buildWsUrl URL construction
// =========================================================================

describe('useTerminalSocket — T-B: _buildWsUrl', () => {
  it('T-B1: http → ws:// scheme', () => {
    expect(
      __test__._buildWsUrl('autopilot', 'demo', 'ABC123', {
        protocol: 'http:',
        host: '127.0.0.1:5175',
      }),
    ).toBe('ws://127.0.0.1:5175/ws/autopilot/terminal?id=demo&csrf=ABC123')
  })

  it('T-B2: https → wss:// scheme', () => {
    expect(
      __test__._buildWsUrl('autopilot', 'demo', 'ABC123', {
        protocol: 'https:',
        host: 'example.com',
      }),
    ).toBe('wss://example.com/ws/autopilot/terminal?id=demo&csrf=ABC123')
  })

  it('T-B3: encodeURIComponent applied to inputs', () => {
    const url = __test__._buildWsUrl('autopilot', 'a b/c', 'x&y=z', {
      protocol: 'http:',
      host: 'h',
    })
    expect(url).toContain('id=a%20b%2Fc')
    expect(url).toContain('csrf=x%26y%3Dz')
  })

  it('T-B4: chain targetKind flows through identically', () => {
    expect(
      __test__._buildWsUrl('chain', 'd', 't', {
        protocol: 'http:',
        host: 'h',
      }),
    ).toBe('ws://h/ws/chain/terminal?id=d&csrf=t')
  })
})

// =========================================================================
// Section T-C — _readCsrfToken CSRF dual-source
// =========================================================================

describe('useTerminalSocket — T-C: _readCsrfToken', () => {
  it('T-C1: cookie present → returns cookie value', () => {
    stubCookie('csrf_token=ABC123')
    expect(__test__._readCsrfToken()).toBe('ABC123')
  })

  it('T-C2: cookie URL-decoded', () => {
    stubCookie('csrf_token=A%20B')
    expect(__test__._readCsrfToken()).toBe('A B')
  })

  it('T-C3: cookie absent, meta present → returns meta content', () => {
    stubCookie('')
    stubMetaTag('META_TOKEN')
    expect(__test__._readCsrfToken()).toBe('META_TOKEN')
  })

  it('T-C4: both absent → returns null', () => {
    stubCookie('')
    stubMetaTag(null)
    expect(__test__._readCsrfToken()).toBeNull()
  })

  it('T-C5: cookie empty after decode treated as absent', () => {
    stubCookie('csrf_token=')
    stubMetaTag(null)
    expect(__test__._readCsrfToken()).toBeNull()
  })

  it('T-C6: meta content empty string treated as absent', () => {
    stubCookie('')
    stubMetaTag('')
    expect(__test__._readCsrfToken()).toBeNull()
  })

  it('T-C7: document.cookie access throwing → falls through to meta', () => {
    Object.defineProperty(document, 'cookie', {
      configurable: true,
      get: () => {
        throw new Error('opaque origin')
      },
      set: () => {},
    })
    stubMetaTag('FALLBACK')
    expect(__test__._readCsrfToken()).toBe('FALLBACK')
  })

  it('T-C8: multiple cookies; csrf_token is the second one', () => {
    stubCookie('foo=bar; csrf_token=ZZZ')
    expect(__test__._readCsrfToken()).toBe('ZZZ')
  })

  it('T-C9: cookie-name drift detection lives in the shared csrfToken module', () => {
    /* controls-06 #12: the CSRF cookie name moved to the shared
       hooks/csrfToken module so useSessionControls and
       useTerminalSocket cannot drift independently. T-C9 still
       enforces the byte equality with the server constant
       (dashboard/server/middleware/csrf.py:24), now anchored on
       the single source of truth. */
    const csrfTokenSrc = readFileSync(
      __dirname.replace(/__tests__$/, 'hooks/csrfToken.ts'),
      'utf8',
    )
    expect(csrfTokenSrc).toMatch(
      /_CSRF_COOKIE_NAME\s*=\s*['"]csrf_token['"]/,
    )
    /* Both hook files must import from the shared module — drift
       in one without the other is a hazard the move was meant to
       eliminate. */
    const sessionControlsSrc = readFileSync(SESSION_CONTROLS_SRC_PATH, 'utf8')
    expect(sessionControlsSrc).toMatch(/from ['"]\.\/csrfToken['"]/)
    expect(hookSrc).toMatch(/from ['"]\.\/csrfToken['"]/)
  })
})

// =========================================================================
// Section T-D — _classifyClose close-code matrix
// =========================================================================

describe('useTerminalSocket — T-D: _classifyClose', () => {
  const rows: Array<
    [string, number, string, 'reconnect' | 'stop' | 'clean']
  > = [
    ['T-D1', 1000, '', 'clean'],
    ['T-D2', 1000, 'anything', 'clean'],
    ['T-D3', 1011, 'pty session closed', 'reconnect'],
    ['T-D4', 1011, 'lifecycle missing tmux_session', 'reconnect'],
    ['T-D5', 1011, 'tmux_session lookup inconsistency', 'reconnect'],
    ['T-D6', 1011, 'pty bring-up failed', 'stop'],
    ['T-D7', 1011, '', 'reconnect'],
    ['T-D8', 1011, 'something not in the table', 'reconnect'],
    ['T-D9', 1006, '', 'reconnect'],
    ['T-D10', 1013, 'subscriber cap reached', 'reconnect'],
    ['T-D11', 4001, 'csrf', 'stop'],
    ['T-D12', 4400, 'invalid id', 'stop'],
    ['T-D13', 4404, 'session not running', 'stop'],
    ['T-D14', 4500, 'future code', 'reconnect'],
  ]
  it.each(rows)(
    '%s: _classifyClose(%d, %j) === %j',
    (_label, code, reason, expected) => {
      expect(__test__._classifyClose(code, reason)).toBe(expected)
    },
  )
})

// =========================================================================
// Section T-E — _parseBufferOverflow JSON sentinel parsing
// =========================================================================

describe('useTerminalSocket — T-E: _parseBufferOverflow', () => {
  it('T-E1: valid sentinel parses to camelCase record', () => {
    expect(
      __test__._parseBufferOverflow(
        '{"type":"buffer_overflow","bytes_dropped":4096,"at":1715800000000}',
      ),
    ).toEqual({ bytesDropped: 4096, at: 1715800000000 })
  })

  it('T-E2: non-JSON returns null', () => {
    expect(__test__._parseBufferOverflow('not json')).toBeNull()
  })

  it('T-E3: wrong type returns null', () => {
    expect(
      __test__._parseBufferOverflow(
        '{"type":"other","bytes_dropped":1,"at":1}',
      ),
    ).toBeNull()
  })

  it('T-E4: missing type returns null', () => {
    expect(
      __test__._parseBufferOverflow('{"bytes_dropped":1,"at":1}'),
    ).toBeNull()
  })

  it('T-E5: float bytes_dropped returns null', () => {
    expect(
      __test__._parseBufferOverflow(
        '{"type":"buffer_overflow","bytes_dropped":1.5,"at":1}',
      ),
    ).toBeNull()
  })

  it('T-E6: Infinity-magnitude bytes_dropped returns null', () => {
    expect(
      __test__._parseBufferOverflow(
        '{"type":"buffer_overflow","bytes_dropped":1e308,"at":1}',
      ),
    ).toBeNull()
  })

  it('T-E7: missing at returns null', () => {
    expect(
      __test__._parseBufferOverflow(
        '{"type":"buffer_overflow","bytes_dropped":1}',
      ),
    ).toBeNull()
  })

  it('T-E8: non-numeric at returns null', () => {
    expect(
      __test__._parseBufferOverflow(
        '{"type":"buffer_overflow","bytes_dropped":1,"at":"now"}',
      ),
    ).toBeNull()
  })

  it('T-E9: empty string returns null', () => {
    expect(__test__._parseBufferOverflow('')).toBeNull()
  })

  it('T-E10: empty object returns null', () => {
    expect(__test__._parseBufferOverflow('{}')).toBeNull()
  })
})

// =========================================================================
// Section T-F — _REASON_TABLE drift detection
// =========================================================================

describe('useTerminalSocket — T-F: REASON_TABLE drift', () => {
  it('T-F1: all eight reason keys present with pinned values', () => {
    expect(__test__._REASON_TABLE).toEqual({
      CSRF: 'csrf',
      INVALID_ID: 'invalid id',
      NOT_FOUND: 'session not running',
      HELPER_CLOSED: 'pty session closed',
      LIFECYCLE_MISSING: 'lifecycle missing tmux_session',
      LOOKUP_INCONSISTENT: 'tmux_session lookup inconsistency',
      PTY_BRINGUP: 'pty bring-up failed',
      SUBSCRIBER_CAP: 'subscriber cap reached',
    })
  })

  it('T-F2: _REASON_TABLE is read-only at runtime', () => {
    const before = __test__._REASON_TABLE.CSRF
    try {
      ;(__test__._REASON_TABLE as Record<string, string>).CSRF = 'mutated'
    } catch {
      // strict-mode TypeError from attempting to mutate a frozen object
    }
    expect(__test__._REASON_TABLE.CSRF).toBe(before)
  })

  it('T-F2b: _STOP_REASONS_ON_1011 has exactly one entry (PTY_BRINGUP)', () => {
    expect(__test__._STOP_REASONS_ON_1011.size).toBe(1)
    expect(
      __test__._STOP_REASONS_ON_1011.has(__test__._REASON_TABLE.PTY_BRINGUP),
    ).toBe(true)
    expect(
      __test__._STOP_REASONS_ON_1011.has(__test__._REASON_TABLE.HELPER_CLOSED),
    ).toBe(false)
  })

  it('T-F3: Python REASON_* lines match TypeScript constants', () => {
    const src = readFileSync(TERMINAL_WS_SRC_PATH, 'utf8')
    expect(src).toContain('REASON_CSRF:')
    const lineRe = /^(REASON_\w+):\s*Final\[str\]\s*=\s*"([^"]*)"$/gm
    const found: Record<string, string> = {}
    for (const match of src.matchAll(lineRe)) {
      found[match[1]] = match[2]
    }
    const expectations: Record<string, string> = {
      REASON_CSRF: __test__._REASON_TABLE.CSRF,
      REASON_INVALID_ID: __test__._REASON_TABLE.INVALID_ID,
      REASON_NOT_FOUND: __test__._REASON_TABLE.NOT_FOUND,
      REASON_HELPER_CLOSED: __test__._REASON_TABLE.HELPER_CLOSED,
      REASON_LIFECYCLE_MISSING: __test__._REASON_TABLE.LIFECYCLE_MISSING,
      REASON_LOOKUP_INCONSISTENT: __test__._REASON_TABLE.LOOKUP_INCONSISTENT,
      REASON_PTY_BRINGUP: __test__._REASON_TABLE.PTY_BRINGUP,
      REASON_SUBSCRIBER_CAP: __test__._REASON_TABLE.SUBSCRIBER_CAP,
    }
    for (const [pyName, tsValue] of Object.entries(expectations)) {
      expect(found[pyName], `drift on ${pyName}`).toBe(tsValue)
    }
  })

  it('T-F4: terminal_ws.py path resolves and content size > 100 bytes', () => {
    const src = readFileSync(TERMINAL_WS_SRC_PATH, 'utf8')
    expect(src.length).toBeGreaterThan(100)
  })
})

// =========================================================================
// Section T-G — Connection lifecycle
// =========================================================================

function bytes(...vals: number[]): ArrayBuffer {
  return new Uint8Array(vals).buffer
}

describe('useTerminalSocket — T-G: connection lifecycle', () => {
  it('T-G1: mount with valid cookie constructs one WebSocket with exact URL', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    expect(StubWebSocket.instances).toHaveLength(1)
    expect(StubWebSocket.instances[0].url).toBe(
      'ws://127.0.0.1:5175/ws/autopilot/terminal?id=demo&csrf=ABC123',
    )
    unmount()
  })

  it('T-G2: status is connecting synchronously after mount', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    expect(result.current.status).toBe('connecting')
    unmount()
  })

  it('T-G3: binaryType is arraybuffer after construction', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    expect(StubWebSocket.instances[0].binaryType).toBe('arraybuffer')
    expect(StubWebSocket.instances[0].onopen).not.toBeNull()
    unmount()
  })

  it('T-G4: all four listeners are property-assigned after mount', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    const ws = StubWebSocket.instances[0]
    expect(typeof ws.onopen).toBe('function')
    expect(typeof ws.onmessage).toBe('function')
    expect(typeof ws.onclose).toBe('function')
    expect(typeof ws.onerror).toBe('function')
    unmount()
  })

  it('T-G5: dispatchOpen → status=connected, reconnectAttempt=0', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    expect(result.current.status).toBe('connected')
    expect(result.current.reconnectAttempt).toBe(0)
    unmount()
  })

  it('T-G6: dispatchMessage(ArrayBuffer) → frameQueue contains the frame', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    const frame = bytes(0x68, 0x69)
    act(() => {
      StubWebSocket.instances[0].dispatchMessage(frame)
    })
    expect(result.current.frameQueue.length).toBe(1)
    expect(Object.is(result.current.frameQueue[0], frame)).toBe(true)
    expect(result.current.status).toBe('connected')
    expect(result.current.bufferOverflow).toBeNull()
    unmount()
  })

  it('T-G6b: multiple frames in one act() batch all survive (controls-07 #9)', () => {
    /* The bug fixed in controls-07 #9: single-slot `lastFrame: ArrayBuffer | null`
       lost intermediate frames under React 18 automatic batching. When
       ws.onmessage fires 6 times in rapid succession (typical for a
       scrollback-seed-then-tail attach: one 27.5kB seed + several live
       chunks), all 6 setLastFrame() calls would batch into a single
       render with only the LAST frame's value, silently dropping
       frames 1..5. The terminal panel would write at most one tail
       chunk to xterm and the user saw an empty terminal even though
       bytes were arriving on the wire.

       The fix: replace single-slot mailbox with a functional-update
       queue. setFrameQueue(prev => [...prev, data]) is idempotent
       under batching — each call applies to the previous state, so
       even if React collapses 6 renders into 1 the queue contains
       all 6 frames in order. */
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    const f1 = bytes(1, 2, 3)
    const f2 = bytes(4, 5, 6)
    const f3 = bytes(7, 8, 9)
    // All three frames dispatched inside ONE act() block — this is
    // the React 18 batching scenario. Pre-#9, only f3 survives.
    act(() => {
      const ws = StubWebSocket.instances[0]
      ws.dispatchMessage(f1)
      ws.dispatchMessage(f2)
      ws.dispatchMessage(f3)
    })
    expect(result.current.frameQueue.length).toBe(3)
    expect(Object.is(result.current.frameQueue[0], f1)).toBe(true)
    expect(Object.is(result.current.frameQueue[1], f2)).toBe(true)
    expect(Object.is(result.current.frameQueue[2], f3)).toBe(true)
    unmount()
  })

  it('T-G6c: drainFrames() empties the queue (controls-07 #9)', () => {
    /* Consumers (TerminalPanel) drain after writing to xterm so the
       queue does not grow unbounded. drainFrames is a stable callback. */
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
      StubWebSocket.instances[0].dispatchMessage(bytes(0x41))
    })
    expect(result.current.frameQueue.length).toBe(1)
    act(() => {
      result.current.drainFrames()
    })
    expect(result.current.frameQueue.length).toBe(0)
    unmount()
  })

  it('T-G7: text overflow sentinel updates bufferOverflow, leaves lastFrame', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    const prior = bytes(1, 2, 3)
    act(() => {
      StubWebSocket.instances[0].dispatchMessage(prior)
    })
    act(() => {
      StubWebSocket.instances[0].dispatchMessage(
        '{"type":"buffer_overflow","bytes_dropped":4096,"at":1715800000000}',
      )
    })
    expect(result.current.bufferOverflow).toEqual({
      bytesDropped: 4096,
      at: 1715800000000,
    })
    /* controls-07 #9 — text frames do not push to the binary queue. */
    expect(result.current.frameQueue.length).toBe(1)
    expect(Object.is(result.current.frameQueue[0], prior)).toBe(true)
    expect(result.current.status).toBe('connected')
    unmount()
  })

  it('T-G8: malformed text frame → console.warn; state unchanged', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchMessage('not json')
    })
    /* controls-07 #9 — malformed text never appends to binary queue. */
    expect(result.current.frameQueue.length).toBe(0)
    expect(result.current.bufferOverflow).toBeNull()
    expect(result.current.status).toBe('connected')
    expect(
      warnSpy.mock.calls.some((c) =>
        String(c[0]).includes('unrecognized text frame'),
      ),
    ).toBe(true)
    unmount()
  })

  it('T-G9: mixed binary → text-overflow → binary → text-malformed', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    const f1 = bytes(1)
    const f2 = bytes(2)
    act(() => {
      StubWebSocket.instances[0].dispatchMessage(f1)
    })
    act(() => {
      StubWebSocket.instances[0].dispatchMessage(
        '{"type":"buffer_overflow","bytes_dropped":10,"at":100}',
      )
    })
    act(() => {
      StubWebSocket.instances[0].dispatchMessage(f2)
    })
    act(() => {
      StubWebSocket.instances[0].dispatchMessage('garbage')
    })
    /* controls-07 #9 — queue accumulates BOTH binary frames in order;
       text frames (overflow + garbage) do not append. */
    expect(result.current.frameQueue.length).toBe(2)
    expect(Object.is(result.current.frameQueue[0], f1)).toBe(true)
    expect(Object.is(result.current.frameQueue[1], f2)).toBe(true)
    expect(result.current.bufferOverflow).toEqual({
      bytesDropped: 10,
      at: 100,
    })
    expect(
      warnSpy.mock.calls.filter((c) =>
        String(c[0]).includes('unrecognized text frame'),
      ).length,
    ).toBe(1)
    unmount()
  })

  it('T-G10: Blob frame → console.warn; connection stays open', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchMessage(new Blob(['data']))
    })
    /* controls-07 #9 — Blob is not appended. */
    expect(result.current.frameQueue.length).toBe(0)
    expect(result.current.bufferOverflow).toBeNull()
    expect(result.current.status).toBe('connected')
    expect(
      warnSpy.mock.calls.some((c) =>
        String(c[0]).includes('unexpected Blob frame'),
      ),
    ).toBe(true)
    unmount()
  })

  it('T-G11: onerror does NOT mutate status; emits one warn', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchError()
    })
    expect(result.current.status).toBe('connected')
    expect(
      warnSpy.mock.calls.some((c) => String(c[0]).includes('socket error')),
    ).toBe(true)
    unmount()
  })
})

// =========================================================================
// Section T-H — Reconnect and STOP discrimination
// =========================================================================

describe('useTerminalSocket — T-H: reconnect / STOP', () => {
  it('T-H1: close (1011, helper-closed) → reconnecting, attempt=1, no new WS yet', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1011, 'pty session closed')
    })
    expect(result.current.status).toBe('reconnecting')
    expect(result.current.reconnectAttempt).toBe(1)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(999)
    })
    expect(StubWebSocket.instances).toHaveLength(1)
    unmount()
    vi.useRealTimers()
  })

  it('T-H2: advance 1000ms after T-H1 → fresh WebSocket constructed', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1011, 'pty session closed')
    })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1000)
    })
    expect(StubWebSocket.instances).toHaveLength(2)
    expect(StubWebSocket.instances[1].url).toBe(
      StubWebSocket.instances[0].url,
    )
    unmount()
    vi.useRealTimers()
  })

  it('T-H3: 5 close-retry cycles produce 6 total instances; delays 1,2,4,8,16s', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    const delays = [1000, 2000, 4000, 8000, 16000]
    for (let i = 0; i < 5; i++) {
      const idx = StubWebSocket.instances.length - 1
      act(() => {
        StubWebSocket.instances[idx].dispatchClose(1011, 'pty session closed')
      })
      await act(async () => {
        await vi.advanceTimersByTimeAsync(delays[i] - 1)
      })
      expect(StubWebSocket.instances.length).toBe(i + 1)
      await act(async () => {
        await vi.advanceTimersByTimeAsync(1)
      })
      expect(StubWebSocket.instances.length).toBe(i + 2)
    }
    expect(StubWebSocket.instances).toHaveLength(6)
    unmount()
    vi.useRealTimers()
  })

  it('T-H4: after 5th close (no open) → status=lost; no further constructions', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    const delays = [1000, 2000, 4000, 8000, 16000]
    for (let i = 0; i < 5; i++) {
      const idx = StubWebSocket.instances.length - 1
      act(() => {
        StubWebSocket.instances[idx].dispatchClose(1011, 'pty session closed')
      })
      await act(async () => {
        await vi.advanceTimersByTimeAsync(delays[i])
      })
    }
    act(() => {
      StubWebSocket.instances[5].dispatchClose(1011, 'pty session closed')
    })
    expect(result.current.status).toBe('lost')
    expect(result.current.reconnectAttempt).toBe(5)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000)
    })
    expect(StubWebSocket.instances).toHaveLength(6)
    unmount()
    vi.useRealTimers()
  })

  it('T-H5: successful onopen resets counter (EC-7)', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1011, 'pty session closed')
    })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1000)
    })
    act(() => {
      StubWebSocket.instances[1].dispatchClose(1011, 'pty session closed')
    })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(2000)
    })
    act(() => {
      StubWebSocket.instances[2].dispatchClose(1011, 'pty session closed')
    })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(4000)
    })
    act(() => {
      StubWebSocket.instances[3].dispatchOpen()
    })
    expect(result.current.reconnectAttempt).toBe(0)
    act(() => {
      StubWebSocket.instances[3].dispatchClose(1011, 'pty session closed')
    })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(999)
    })
    expect(StubWebSocket.instances).toHaveLength(4)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1)
    })
    expect(StubWebSocket.instances).toHaveLength(5)
    unmount()
    vi.useRealTimers()
  })

  it('T-H6: REASON_PTY_BRINGUP → status=lost; no retry scheduled', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1011, 'pty bring-up failed')
    })
    expect(result.current.status).toBe('lost')
    expect(result.current.reconnectAttempt).toBe(0)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000)
    })
    expect(StubWebSocket.instances).toHaveLength(1)
    unmount()
    vi.useRealTimers()
  })

  it('T-H7: (4001, csrf) → status=lost', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchClose(4001, 'csrf')
    })
    expect(result.current.status).toBe('lost')
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000)
    })
    expect(StubWebSocket.instances).toHaveLength(1)
    unmount()
    vi.useRealTimers()
  })

  it('T-H8: (4400, invalid id) → status=lost', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchClose(4400, 'invalid id')
    })
    expect(result.current.status).toBe('lost')
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000)
    })
    expect(StubWebSocket.instances).toHaveLength(1)
    unmount()
    vi.useRealTimers()
  })

  it('T-H9: (4404, session not running) → status=lost', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchClose(4404, 'session not running')
    })
    expect(result.current.status).toBe('lost')
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000)
    })
    expect(StubWebSocket.instances).toHaveLength(1)
    unmount()
    vi.useRealTimers()
  })

  it('T-H10: (1006, "") → reconnecting; retry fires after 1s', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1006, '')
    })
    expect(result.current.status).toBe('reconnecting')
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1000)
    })
    expect(StubWebSocket.instances).toHaveLength(2)
    unmount()
    vi.useRealTimers()
  })

  it('T-H11: (1013, subscriber cap) → reconnecting', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1013, 'subscriber cap reached')
    })
    expect(result.current.status).toBe('reconnecting')
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1000)
    })
    expect(StubWebSocket.instances).toHaveLength(2)
    unmount()
    vi.useRealTimers()
  })

  it('T-H12: unknown code (4500) → reconnecting', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchClose(4500, 'future code')
    })
    expect(result.current.status).toBe('reconnecting')
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1000)
    })
    expect(StubWebSocket.instances).toHaveLength(2)
    unmount()
    vi.useRealTimers()
  })

  it('T-H13: (1011, "") empty reason → reconnecting (fail-open)', () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1011, '')
    })
    expect(result.current.status).toBe('reconnecting')
    unmount()
    vi.useRealTimers()
  })

  it('T-H14: clean close (1000) → status=idle; no retry', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1000, '')
    })
    expect(result.current.status).toBe('idle')
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000)
    })
    expect(StubWebSocket.instances).toHaveLength(1)
    unmount()
    vi.useRealTimers()
  })

  it('T-H15: onclose then onerror — error does not change status', () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1011, 'pty session closed')
    })
    expect(result.current.status).toBe('reconnecting')
    act(() => {
      StubWebSocket.instances[0].dispatchError()
    })
    expect(result.current.status).toBe('reconnecting')
    expect(
      warnSpy.mock.calls.some((c) => String(c[0]).includes('socket error')),
    ).toBe(true)
    unmount()
    vi.useRealTimers()
  })

  it('T-H16: attemptRef stale-closure regression — delays remain 1,2,4', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1011, 'pty session closed')
    })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(999)
    })
    expect(StubWebSocket.instances).toHaveLength(1)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1)
    })
    expect(StubWebSocket.instances).toHaveLength(2)
    act(() => {
      StubWebSocket.instances[1].dispatchClose(1011, 'pty session closed')
    })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1999)
    })
    expect(StubWebSocket.instances).toHaveLength(2)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1)
    })
    expect(StubWebSocket.instances).toHaveLength(3)
    act(() => {
      StubWebSocket.instances[2].dispatchClose(1011, 'pty session closed')
    })
    await act(async () => {
      await vi.advanceTimersByTimeAsync(3999)
    })
    expect(StubWebSocket.instances).toHaveLength(3)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1)
    })
    expect(StubWebSocket.instances).toHaveLength(4)
    unmount()
    vi.useRealTimers()
  })
})

// =========================================================================
// Section T-I — Unmount and cleanup
// =========================================================================

describe('useTerminalSocket — T-I: unmount / cleanup', () => {
  it('T-I1: unmount while connected closes with (1000, "unmount"), nulls listeners', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    const ws = StubWebSocket.instances[0]
    unmount()
    expect(ws.closeArgs).toEqual({ code: 1000, reason: 'unmount' })
    expect(ws.onopen).toBeNull()
    expect(ws.onmessage).toBeNull()
    expect(ws.onclose).toBeNull()
    expect(ws.onerror).toBeNull()
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000)
    })
    expect(StubWebSocket.instances).toHaveLength(1)
    vi.useRealTimers()
  })

  it('T-I2: unmount while reconnecting cancels pending timer', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1011, 'pty session closed')
    })
    unmount()
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000)
    })
    expect(StubWebSocket.instances).toHaveLength(1)
    vi.useRealTimers()
  })

  it('T-I3: late-arriving dispatch after unmount is a no-op', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const debugSpy = vi.spyOn(console, 'debug').mockImplementation(() => {})
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    const ws = StubWebSocket.instances[0]
    unmount()
    debugSpy.mockClear()
    warnSpy.mockClear()
    ws.dispatchClose(1011, 'pty session closed')
    expect(StubWebSocket.instances).toHaveLength(1)
    expect(debugSpy).not.toHaveBeenCalled()
    expect(warnSpy).not.toHaveBeenCalled()
  })

  it('T-I4: targetId=null quiescent path — no WS construction, no timers', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', null),
    )
    expect(StubWebSocket.instances).toHaveLength(0)
    expect(result.current.status).toBe('idle')
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000)
    })
    expect(StubWebSocket.instances).toHaveLength(0)
    unmount()
    vi.useRealTimers()
  })

  it('T-I5: targetId change closes old WS and opens fresh one', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, rerender, unmount } = renderHook(
      ({ id }: { id: string }) => useTerminalSocket('autopilot', id),
      { initialProps: { id: 'demo' } },
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    expect(result.current.status).toBe('connected')
    rerender({ id: 'other' })
    expect(StubWebSocket.instances).toHaveLength(2)
    expect(StubWebSocket.instances[0].closeArgs).toEqual({
      code: 1000,
      reason: 'unmount',
    })
    expect(StubWebSocket.instances[1].url).toContain('id=other')
    expect(result.current.reconnectAttempt).toBe(0)
    unmount()
  })

  it('T-I6: targetId null → demo creates one WS, no close fires', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { rerender, unmount } = renderHook(
      ({ id }: { id: string | null }) => useTerminalSocket('autopilot', id),
      { initialProps: { id: null as string | null } },
    )
    expect(StubWebSocket.instances).toHaveLength(0)
    rerender({ id: 'demo' })
    expect(StubWebSocket.instances).toHaveLength(1)
    unmount()
  })

  it('T-I7: React StrictMode double-invoke idempotency', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const wrapper = ({ children }: { children: ReactNode }) => (
      <StrictMode>{children}</StrictMode>
    )
    const { unmount } = renderHook(
      () => useTerminalSocket('autopilot', 'demo'),
      { wrapper },
    )
    const openInstances = StubWebSocket.instances.filter(
      (w) => w.closeArgs === null && w.readyState !== StubWebSocket.CLOSED,
    )
    expect(openInstances.length).toBeLessThanOrEqual(1)
    unmount()
  })

  it('T-I8: demo → null → demo cycle', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { rerender, unmount } = renderHook(
      ({ id }: { id: string | null }) => useTerminalSocket('autopilot', id),
      { initialProps: { id: 'demo' as string | null } },
    )
    expect(StubWebSocket.instances).toHaveLength(1)
    rerender({ id: null })
    expect(StubWebSocket.instances[0].closeArgs).toEqual({
      code: 1000,
      reason: 'unmount',
    })
    rerender({ id: 'demo' })
    expect(StubWebSocket.instances).toHaveLength(2)
    unmount()
  })

  it('T-I9: unmount during status=lost — no additional close', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchClose(4001, 'csrf')
    })
    expect(result.current.status).toBe('lost')
    const closedWs = StubWebSocket.instances[0]
    closedWs.closeArgs = null
    unmount()
    expect(closedWs.closeArgs).toBeNull()
    await act(async () => {
      await vi.advanceTimersByTimeAsync(60_000)
    })
    expect(StubWebSocket.instances).toHaveLength(1)
    vi.useRealTimers()
  })
})

// =========================================================================
// Section T-J — CSRF observability and security
// =========================================================================

describe('useTerminalSocket — T-J: CSRF & token leak', () => {
  it('T-J1: no CSRF cookie / meta / body-token → status=lost; warn; no WS constructed', async () => {
    /* controls-06 #12: when the sync read comes up empty, the hook
       now falls through to GET /api/csrf and reads the token out of
       the JSON body (Vite-dev SameSite=Strict workaround). To pin
       the "all three layers empty" failure mode, stub fetch to
       return an ok:false response. The hook then settles into
       status='lost' asynchronously. */
    stubCookie('')
    stubMetaTag(null)
    vi.stubGlobal('WebSocket', StubWebSocket)
    const fetchMock = vi.fn().mockResolvedValue({
      ok: false,
      json: () => Promise.resolve({}),
    })
    vi.stubGlobal('fetch', fetchMock)
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    await vi.waitFor(() => {
      expect(result.current.status).toBe('lost')
    })
    expect(StubWebSocket.instances).toHaveLength(0)
    expect(
      warnSpy.mock.calls.some((c) =>
        String(c[0]).includes('CSRF token unavailable'),
      ),
    ).toBe(true)
    unmount()
  })

  it('T-J2: meta-only token flows into URL', () => {
    stubCookie('')
    stubMetaTag('FROM_META')
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    expect(StubWebSocket.instances).toHaveLength(1)
    expect(StubWebSocket.instances[0].url).toContain('csrf=FROM_META')
    unmount()
  })

  it('T-J2b: empty cookie + empty meta + /api/csrf body token → URL carries body token (controls-06 #12)', async () => {
    /* The Vite-dev fix path end-to-end. The cycle-5 sync chain
       returns null (cookie + meta both empty); the hook falls
       through to GET /api/csrf, reads the JSON `token` field, and
       opens the WS with that value embedded in the query string.
       Pins the per-hook autopilot/chain stream surface — the same
       fallback the cycle-11 useSessionControls test (K1) verified
       for POSTs. */
    stubCookie('')
    stubMetaTag(null)
    vi.stubGlobal('WebSocket', StubWebSocket)
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ token: 'BODY_TOKEN_Z' }),
    })
    vi.stubGlobal('fetch', fetchMock)
    const { unmount } = renderHook(() =>
      useTerminalSocket('chain', 'demo-chain'),
    )
    await vi.waitFor(() => {
      expect(StubWebSocket.instances).toHaveLength(1)
    })
    expect(StubWebSocket.instances[0].url).toContain('csrf=BODY_TOKEN_Z')
    expect(StubWebSocket.instances[0].url).toContain('/ws/chain/terminal')
    unmount()
  })

  it('T-J3: token never appears in console.debug payloads', () => {
    stubCookie('csrf_token=SECRETXYZ')
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const debugSpy = vi.spyOn(console, 'debug').mockImplementation(() => {})
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchMessage(bytes(1, 2))
    })
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1011, 'pty session closed')
    })
    unmount()
    for (const call of debugSpy.mock.calls) {
      const serialized = JSON.stringify(call)
      expect(serialized).not.toContain('SECRETXYZ')
    }
    vi.useRealTimers()
  })

  it('T-J4: token never appears in console.warn payloads', () => {
    stubCookie('csrf_token=SECRETXYZ')
    vi.stubGlobal('WebSocket', StubWebSocket)
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchMessage('garbage')
    })
    act(() => {
      StubWebSocket.instances[0].dispatchMessage(new Blob(['x']))
    })
    act(() => {
      StubWebSocket.instances[0].dispatchError()
    })
    unmount()
    for (const call of warnSpy.mock.calls) {
      const serialized = JSON.stringify(call)
      expect(serialized).not.toContain('SECRETXYZ')
    }
  })

  it('T-J5: no fetch / localStorage writes', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const fetchSpy = vi
      .spyOn(globalThis, 'fetch')
      .mockImplementation(() => Promise.reject(new Error('no fetch')))
    const setItemSpy = vi.spyOn(Storage.prototype, 'setItem')
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchMessage(bytes(1))
    })
    unmount()
    expect(fetchSpy).not.toHaveBeenCalled()
    expect(setItemSpy).not.toHaveBeenCalled()
  })

  it('T-J6: cookie rotated between close and retry → new URL has new token', async () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    stubCookie('csrf_token=OLD')
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    expect(StubWebSocket.instances[0].url).toContain('csrf=OLD')
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1011, 'pty session closed')
    })
    stubCookie('csrf_token=NEW')
    await act(async () => {
      await vi.advanceTimersByTimeAsync(1000)
    })
    expect(StubWebSocket.instances).toHaveLength(2)
    expect(StubWebSocket.instances[1].url).toContain('csrf=NEW')
    unmount()
    vi.useRealTimers()
  })
})

// =========================================================================
// Section T-K — Lifecycle console diagnostics
// =========================================================================

describe('useTerminalSocket — T-K: console diagnostics', () => {
  function findEvent(
    spy: ReturnType<typeof vi.spyOn>,
    event: string,
  ): unknown[][] {
    return (spy.mock.calls as unknown[][]).filter(
      (c: unknown[]) =>
        typeof c[0] === 'object' &&
        c[0] !== null &&
        (c[0] as { event?: string }).event === event,
    )
  }

  it('T-K1: open emits one debug with event=open + base triple', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const debugSpy = vi.spyOn(console, 'debug').mockImplementation(() => {})
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    const opens = findEvent(debugSpy, 'open')
    expect(opens).toHaveLength(1)
    const payload = opens[0][0] as Record<string, unknown>
    expect(payload).toMatchObject({
      event: 'open',
      targetKind: 'autopilot',
      targetId: 'demo',
      attempt: 0,
    })
    expect(payload.url).toBeUndefined()
    unmount()
  })

  it('T-K2: message-binary emits one debug per dispatch', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const debugSpy = vi.spyOn(console, 'debug').mockImplementation(() => {})
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchMessage(bytes(1, 2))
    })
    act(() => {
      StubWebSocket.instances[0].dispatchMessage(bytes(3, 4, 5))
    })
    const binEvents = findEvent(debugSpy, 'message-binary')
    expect(binEvents).toHaveLength(2)
    expect((binEvents[0][0] as Record<string, unknown>).byteLength).toBe(2)
    expect((binEvents[1][0] as Record<string, unknown>).byteLength).toBe(3)
    unmount()
  })

  it('T-K3: message-text emits one debug per valid overflow', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const debugSpy = vi.spyOn(console, 'debug').mockImplementation(() => {})
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchMessage(
        '{"type":"buffer_overflow","bytes_dropped":7,"at":99}',
      )
    })
    const evts = findEvent(debugSpy, 'message-text')
    expect(evts).toHaveLength(1)
    expect((evts[0][0] as Record<string, unknown>).bytesDropped).toBe(7)
    unmount()
  })

  it('T-K4: close-reconnect emits with code, reason, attempt, delayMs', () => {
    vi.useFakeTimers()
    vi.stubGlobal('WebSocket', StubWebSocket)
    const debugSpy = vi.spyOn(console, 'debug').mockImplementation(() => {})
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1011, 'pty session closed')
    })
    const evts = findEvent(debugSpy, 'close-reconnect')
    expect(evts).toHaveLength(1)
    const payload = evts[0][0] as Record<string, unknown>
    expect(payload).toMatchObject({
      event: 'close-reconnect',
      code: 1011,
      reason: 'pty session closed',
      attempt: 1,
      delayMs: 1000,
    })
    unmount()
    vi.useRealTimers()
  })

  it('T-K5: STOP path emits close-stop or close-stop-ceiling', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const debugSpy = vi.spyOn(console, 'debug').mockImplementation(() => {})
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1011, 'pty bring-up failed')
    })
    const stopEvents = [
      ...findEvent(debugSpy, 'close-stop'),
      ...findEvent(debugSpy, 'close-stop-ceiling'),
    ]
    expect(stopEvents.length).toBeGreaterThan(0)
    const payload = stopEvents[0][0] as Record<string, unknown>
    expect(payload.code).toBe(1011)
    expect(payload.reason).toBe('pty bring-up failed')
    unmount()
  })

  it('T-K6: clean close emits event=close-clean code=1000', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const debugSpy = vi.spyOn(console, 'debug').mockImplementation(() => {})
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1000, '')
    })
    const evts = findEvent(debugSpy, 'close-clean')
    expect(evts).toHaveLength(1)
    expect((evts[0][0] as Record<string, unknown>).code).toBe(1000)
    unmount()
  })

  it('T-K7: unmount emits one debug with event=unmount', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const debugSpy = vi.spyOn(console, 'debug').mockImplementation(() => {})
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    unmount()
    const evts = findEvent(debugSpy, 'unmount')
    expect(evts).toHaveLength(1)
    expect(evts[0][0]).toMatchObject({
      event: 'unmount',
      targetKind: 'autopilot',
      targetId: 'demo',
    })
  })

  it('T-K8: console.error is never called', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const errorSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    act(() => {
      StubWebSocket.instances[0].dispatchMessage('not json')
    })
    act(() => {
      StubWebSocket.instances[0].dispatchClose(1011, 'pty session closed')
    })
    unmount()
    expect(errorSpy).not.toHaveBeenCalled()
  })

  it('T-K9: console.log is never called', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const logSpy = vi.spyOn(console, 'log').mockImplementation(() => {})
    const { unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    act(() => {
      StubWebSocket.instances[0].dispatchOpen()
    })
    unmount()
    expect(logSpy).not.toHaveBeenCalled()
  })
})

// =========================================================================
// Section T-L — Source-grep invariants
// =========================================================================

describe('useTerminalSocket — T-L: source-grep invariants', () => {
  it('T-L1: hook source does NOT contain ".send(" substring', () => {
    expect(hookSrc).not.toMatch(/\.send\(/)
  })

  it('T-L2: hook source does NOT import from @xterm/*', () => {
    expect(hookSrc).not.toMatch(/from\s+['"]@xterm/)
  })

  it('T-L3: hook source does NOT hardcode 127.0.0.1 or port 8787', () => {
    expect(hookSrc).not.toMatch(/127\.0\.0\.1/)
    expect(hookSrc).not.toMatch(/:\s*8787/)
  })

  it('T-L4: binaryType assignment appears before listener assignments', () => {
    const binIdx = hookSrc.indexOf('binaryType')
    expect(binIdx).toBeGreaterThan(0)
    for (const name of ['onopen', 'onmessage', 'onclose', 'onerror']) {
      const listenerIdx = hookSrc.indexOf(`ws.${name} =`)
      expect(listenerIdx).toBeGreaterThan(binIdx)
    }
  })

  it('T-L5: cleanup contains clearTimeout + four null-assignments', () => {
    expect(hookSrc).toContain('clearTimeout')
    for (const name of ['onopen', 'onmessage', 'onclose', 'onerror']) {
      const pattern = new RegExp(`ws\\.${name}\\s*=\\s*null`)
      expect(hookSrc).toMatch(pattern)
    }
  })

  it('T-L6: hook uses globalThis.WebSocket + globalThis.setTimeout', () => {
    expect(hookSrc).toMatch(/globalThis\.WebSocket/)
    expect(hookSrc).toMatch(/globalThis\.setTimeout/)
    expect(hookSrc).not.toMatch(/^\s*const\s+setTimeout\s*=/m)
  })

  it('T-L7: __test__ has @internal JSDoc tag', () => {
    expect(hookSrc).toMatch(/@internal[\s\S]{0,400}export const __test__/)
  })
})

// =========================================================================
// Section T-M — TypeScript type contracts (compile-time)
// =========================================================================

describe('useTerminalSocket — T-M: type contracts', () => {
  it('T-M1: sendDisabled has literal type true', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', 'demo'),
    )
    const _typecheck: true = result.current.sendDisabled
    void _typecheck
    expect(result.current.sendDisabled).toBe(true)
    unmount()
  })

  it('T-M2: hook accepts null targetId at the type level', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { result, unmount } = renderHook(() =>
      useTerminalSocket('autopilot', null),
    )
    const _r: UseTerminalSocket = result.current
    void _r
    expect(result.current.status).toBe('idle')
    unmount()
  })

  it('T-M3: invalid targetKind is rejected by ts-expect-error', () => {
    vi.stubGlobal('WebSocket', StubWebSocket)
    const { unmount } = renderHook(() =>
      useTerminalSocket(
        // @ts-expect-error — 'invalid' is not in the 2-value union
        'invalid',
        'demo',
      ),
    )
    unmount()
  })

  it('T-M4: hook source contains @internal near __test__', () => {
    expect(hookSrc).toMatch(/@internal[\s\S]{0,400}export const __test__/)
  })
})

// =========================================================================
// Section T-N — package.json + pnpm-lock.yaml
// =========================================================================

describe('useTerminalSocket — T-N: dependency declaration', () => {
  const PKG_JSON_PATH = resolve(
    __dirname,
    '..',
    '..',
    'package.json',
  )
  const LOCKFILE_PATH = resolve(
    __dirname,
    '..',
    '..',
    'pnpm-lock.yaml',
  )

  it('T-N1: @xterm/xterm declared with ^X.0.0 pin', () => {
    const pkg = JSON.parse(readFileSync(PKG_JSON_PATH, 'utf8'))
    expect(pkg.dependencies['@xterm/xterm']).toMatch(/^\^\d+\.\d+\.\d+$/)
  })

  it('T-N2: @xterm/addon-fit declared with ^X.0.0 pin', () => {
    const pkg = JSON.parse(readFileSync(PKG_JSON_PATH, 'utf8'))
    expect(pkg.dependencies['@xterm/addon-fit']).toMatch(/^\^\d+\.\d+\.\d+$/)
  })

  it('T-N3: pnpm-lock.yaml records @xterm/xterm and @xterm/addon-fit', () => {
    const lock = readFileSync(LOCKFILE_PATH, 'utf8')
    expect(lock).toContain('@xterm/xterm')
    expect(lock).toContain('@xterm/addon-fit')
  })

  it('T-N4: no @xterm import in hook source (cross-listed)', () => {
    expect(hookSrc).not.toMatch(/from\s+['"]@xterm/)
  })
})
