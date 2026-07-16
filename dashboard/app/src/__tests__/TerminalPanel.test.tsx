// TerminalPanel — xterm.js component test suite.
// Mocks @xterm/xterm, @xterm/addon-fit, and useTerminalSocket because
// jsdom lacks Canvas and ResizeObserver.

import {
  describe,
  it,
  expect,
  vi,
  beforeEach,
  afterEach,
} from 'vitest'
import {
  render,
  screen,
  cleanup,
  act,
  waitFor,
  fireEvent,
  type RenderResult,
} from '@testing-library/react'
import { readFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import type { UseTerminalSocket } from '../hooks/useTerminalSocket'

// === Hoisted mocks (must be set up before module imports) ============

interface SpyTerminalInstance {
  options: unknown
  open: ReturnType<typeof vi.fn>
  write: ReturnType<typeof vi.fn>
  dispose: ReturnType<typeof vi.fn>
  loadAddon: ReturnType<typeof vi.fn>
  getSelection: ReturnType<typeof vi.fn>
  attachCustomKeyEventHandler: ReturnType<typeof vi.fn>
}

interface SpyFitAddonInstance {
  activate: ReturnType<typeof vi.fn>
  fit: ReturnType<typeof vi.fn>
  dispose: ReturnType<typeof vi.fn>
}

const { useTerminalSocketMock, SpyTerminal, SpyFitAddon } = vi.hoisted(() => {
  const useTerminalSocketMock = vi.fn()
  // Use plain factory function (not arrow) so `new SpyTerminal(...)`
  // produces a fresh object — the spread populates the constructed
  // `this` via Object.assign, avoiding the no-this-alias rule.
  const SpyTerminal = vi.fn(function SpyTerminalCtor(
    this: SpyTerminalInstance,
    options: unknown,
  ): SpyTerminalInstance {
    Object.assign(this, {
      options,
      open: vi.fn(),
      write: vi.fn(),
      dispose: vi.fn(),
      loadAddon: vi.fn(),
      getSelection: vi.fn(() => ''),
      attachCustomKeyEventHandler: vi.fn(() => ({ dispose: vi.fn() })),
    })
    return this
  })
  const SpyFitAddon = vi.fn(function SpyFitAddonCtor(
    this: SpyFitAddonInstance,
  ): SpyFitAddonInstance {
    Object.assign(this, {
      activate: vi.fn(),
      fit: vi.fn(),
      dispose: vi.fn(),
    })
    return this
  })
  return { useTerminalSocketMock, SpyTerminal, SpyFitAddon }
})

vi.mock('../hooks/useTerminalSocket', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../hooks/useTerminalSocket')>()
  return { ...actual, useTerminalSocket: useTerminalSocketMock }
})

vi.mock('@xterm/xterm', () => ({ Terminal: SpyTerminal }))
vi.mock('@xterm/addon-fit', () => ({ FitAddon: SpyFitAddon }))
vi.mock('@xterm/xterm/css/xterm.css', () => ({}))

import { TerminalPanel } from '../components/TerminalPanel'

// === Test fixtures =====================================================

function makeHookState(
  overrides?: Partial<UseTerminalSocket>,
): UseTerminalSocket {
  return {
    status: 'connected',
    /* controls-07 #9 — frameQueue + drainFrames replace lastFrame. */
    frameQueue: [],
    drainFrames: vi.fn(),
    sendDisabled: true,
    reconnectAttempt: 0,
    bufferOverflow: null,
    ...overrides,
  }
}

function setMockState(overrides?: Partial<UseTerminalSocket>): UseTerminalSocket {
  const state = makeHookState(overrides)
  useTerminalSocketMock.mockReturnValue(state)
  return state
}

function renderPanel(
  props?: Partial<React.ComponentProps<typeof TerminalPanel>>,
): RenderResult {
  return render(
    <ThemeProvider theme={theme}>
      <TerminalPanel
        targetKind={props?.targetKind ?? 'autopilot'}
        targetId={props?.targetId ?? 'demo'}
        onDetach={props?.onDetach ?? vi.fn()}
      />
    </ThemeProvider>,
  )
}

function stubReduceMotion(matches: boolean): void {
  Object.defineProperty(globalThis, 'matchMedia', {
    configurable: true,
    writable: true,
    value: vi.fn((query: string) => ({
      matches,
      media: query,
      onchange: null,
      // Deprecated MediaQueryList API still used by MUI's
      // useCurrentColorScheme. Both APIs must be present so the
      // ThemeProvider does not throw at mount.
      addListener: vi.fn(),
      removeListener: vi.fn(),
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      dispatchEvent: vi.fn(),
    })),
  })
}

function clearMatchMedia(): void {
  // jsdom does not implement matchMedia. Delete any prior stub so the
  // defensive guard in the component (matchMedia?.()) is exercised.
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  delete (globalThis as any).matchMedia
}

function stubClipboard(): { writeText: ReturnType<typeof vi.fn> } {
  const writeText = vi.fn().mockResolvedValue(undefined)
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true,
    value: { clipboard: { writeText } },
  })
  return { writeText }
}

function stubClipboardReject(): { writeText: ReturnType<typeof vi.fn> } {
  const writeText = vi.fn().mockRejectedValue(new Error('denied'))
  Object.defineProperty(globalThis, 'navigator', {
    configurable: true,
    value: { clipboard: { writeText } },
  })
  return { writeText }
}

let resizeCb: ResizeObserverCallback | null = null
let lastResizeObserver: { observe: ReturnType<typeof vi.fn>; unobserve: ReturnType<typeof vi.fn>; disconnect: ReturnType<typeof vi.fn> } | null = null

class StubResizeObserver {
  observe: ReturnType<typeof vi.fn>
  unobserve: ReturnType<typeof vi.fn>
  disconnect: ReturnType<typeof vi.fn>
  constructor(cb: ResizeObserverCallback) {
    resizeCb = cb
    this.observe = vi.fn()
    this.unobserve = vi.fn()
    this.disconnect = vi.fn()
    // Assign via object reference rather than aliasing `this`.
    lastResizeObserver = { observe: this.observe, unobserve: this.unobserve, disconnect: this.disconnect }
  }
}

beforeEach(() => {
  vi.clearAllMocks()
  resizeCb = null
  lastResizeObserver = null
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  ;(globalThis as any).ResizeObserver = StubResizeObserver
  setMockState()
})

afterEach(() => {
  cleanup()
  vi.useRealTimers()
})

// === Source-string helpers =============================================

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)
const COMPONENT_PATH = resolve(__dirname, '..', 'components', 'TerminalPanel.tsx')
const componentSrc = readFileSync(COMPONENT_PATH, 'utf8')

// =====================================================================
// Group 1 — Module shape & invariants
// =====================================================================

describe('Group 1 — module shape', () => {
  it('T-A1.1: TerminalPanel is a named export; no default export', () => {
    expect(typeof TerminalPanel).toBe('function')
    expect(componentSrc).toMatch(/^\s*export\s+function\s+TerminalPanel\b/m)
    expect(componentSrc).not.toMatch(/^\s*export\s+default\b/m)
  })

  it('T-A1.2: TerminalPanelProps is an exported interface', () => {
    expect(componentSrc).toMatch(/^\s*export\s+interface\s+TerminalPanelProps\s*\{/m)
  })

  it('T-A1.3: file imports no WebSocket-related identifiers (R2, C4)', () => {
    expect(componentSrc).not.toMatch(/\bnew\s+WebSocket\s*\(/)
    expect(componentSrc).not.toMatch(/from\s+['"]ws['"]/)
    expect(componentSrc).not.toMatch(/from\s+['"]socket\b/)
  })

  it('T-A1.4: required data-testid surfaces are present', () => {
    const required = [
      'terminal-host',
      'terminal-idle-placeholder',
      'terminal-overflow-alert',
      'terminal-reconnecting-alert',
      'terminal-lost-alert',
      'terminal-detach-button',
    ]
    for (const tid of required) {
      expect(componentSrc).toContain(`data-testid="${tid}"`)
    }
  })
})

// =====================================================================
// Group 2 — xterm.js construction (R4, R5, R6, AS-9)
// =====================================================================

describe('Group 2 — xterm.js construction', () => {
  it('T-A2.1: SpyTerminal constructor called exactly once on mount', () => {
    setMockState({ status: 'connected' })
    renderPanel()
    expect(SpyTerminal).toHaveBeenCalledTimes(1)
  })

  it('T-A2.2: constructor options carry disableStdin: true', () => {
    setMockState({ status: 'connected' })
    renderPanel()
    expect(SpyTerminal.mock.calls[0][0]).toMatchObject({ disableStdin: true })
  })

  it('T-A2.3: constructor options carry scrollback: 2000', () => {
    setMockState({ status: 'connected' })
    renderPanel()
    expect(SpyTerminal.mock.calls[0][0]).toMatchObject({ scrollback: 2000 })
  })

  it('T-A2.4: source file matches the Phase 3 gate regex /scrollback:\\s*[0-9]+/', () => {
    expect(componentSrc).toMatch(/scrollback:\s*[0-9]+/)
  })

  it('T-A2.5: prefers-reduced-motion=true sets cursorBlink: false', () => {
    stubReduceMotion(true)
    setMockState({ status: 'connected' })
    renderPanel()
    expect(SpyTerminal.mock.calls[0][0]).toMatchObject({ cursorBlink: false })
  })

  it('T-A2.6: prefers-reduced-motion=false sets cursorBlink: true', () => {
    stubReduceMotion(false)
    setMockState({ status: 'connected' })
    renderPanel()
    const opts = SpyTerminal.mock.calls[0][0] as { cursorBlink?: boolean }
    expect(opts.cursorBlink === undefined || opts.cursorBlink === true).toBe(true)
  })

  it('T-A2.7: missing matchMedia (jsdom default) does not throw', () => {
    clearMatchMedia()
    setMockState({ status: 'connected' })
    expect(() => renderPanel()).not.toThrow()
  })

  it('T-A2.8: terminal.open() is called with the terminal-host DOM node', () => {
    setMockState({ status: 'connected' })
    renderPanel()
    const inst = SpyTerminal.mock.instances[0] as { open: ReturnType<typeof vi.fn> }
    const host = screen.getByTestId('terminal-host')
    expect(inst.open).toHaveBeenCalledWith(host)
  })

  it('T-A2.9: terminal.loadAddon(fitAddonInstance) is called', () => {
    setMockState({ status: 'connected' })
    renderPanel()
    const tInst = SpyTerminal.mock.instances[0] as { loadAddon: ReturnType<typeof vi.fn> }
    const fInst = SpyFitAddon.mock.instances[0]
    expect(tInst.loadAddon).toHaveBeenCalledWith(fInst)
  })

  it('T-A2.10: fitAddon.fit() is called at least once after mount', async () => {
    setMockState({ status: 'connected' })
    renderPanel()
    await waitFor(() => {
      const fInst = SpyFitAddon.mock.instances[0] as { fit: ReturnType<typeof vi.fn> }
      expect(fInst.fit).toHaveBeenCalled()
    })
  })

  it('T-A2.11: source imports @xterm/xterm/css/xterm.css', () => {
    expect(componentSrc).toMatch(
      /^\s*import\s+['"]@xterm\/xterm\/css\/xterm\.css['"]\s*;?\s*$/m,
    )
  })
})

// =====================================================================
// Group 3 — Lifecycle / cleanup (R7, EC-13, EC-14)
// =====================================================================

describe('Group 3 — lifecycle cleanup', () => {
  it('T-A3.1: terminal.dispose() is called exactly once on unmount', () => {
    setMockState({ status: 'connected' })
    const { unmount } = renderPanel()
    unmount()
    const inst = SpyTerminal.mock.instances[0] as { dispose: ReturnType<typeof vi.fn> }
    expect(inst.dispose).toHaveBeenCalledTimes(1)
  })

  it('T-A3.2: ResizeObserver disconnect runs on unmount', () => {
    setMockState({ status: 'connected' })
    const { unmount } = renderPanel()
    const observer = lastResizeObserver
    unmount()
    expect(observer).not.toBeNull()
    expect(observer!.disconnect).toHaveBeenCalled()
  })

  it('T-A3.3: unmount before any frame still disposes cleanly', () => {
    setMockState({ status: 'connected', frameQueue: [] })
    const { unmount } = renderPanel()
    unmount()
    const inst = SpyTerminal.mock.instances[0] as { dispose: ReturnType<typeof vi.fn> }
    expect(inst.dispose).toHaveBeenCalledTimes(1)
  })

  it('T-A3.4: resize callback triggers a fit() call', async () => {
    setMockState({ status: 'connected' })
    renderPanel()
    const fInst = SpyFitAddon.mock.instances[0] as { fit: ReturnType<typeof vi.fn> }
    await waitFor(() => {
      expect(fInst.fit).toHaveBeenCalled()
    })
    const initialFitCalls = fInst.fit.mock.calls.length
    act(() => {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      resizeCb?.([{ contentRect: { width: 100, height: 100 } } as any] as any, {} as any)
    })
    await waitFor(() => {
      expect(fInst.fit.mock.calls.length).toBeGreaterThan(initialFitCalls)
    })
  })
})

// =====================================================================
// Group 4 — Frame ingest (R8, EC-15)
// =====================================================================

describe('Group 4 — frame ingest', () => {
  it('T-A4.1: a new ArrayBuffer in lastFrame triggers exactly one write', async () => {
    setMockState({ status: 'connected', frameQueue: [] })
    const { rerender } = renderPanel()
    const inst = SpyTerminal.mock.instances[0] as { write: ReturnType<typeof vi.fn> }
    expect(inst.write).not.toHaveBeenCalled()
    const buf = new Uint8Array([1, 2, 3, 4]).buffer
    setMockState({ status: 'connected', frameQueue: [buf]})
    rerender(
      <ThemeProvider theme={theme}>
        <TerminalPanel targetKind="autopilot" targetId="demo" onDetach={vi.fn()} />
      </ThemeProvider>,
    )
    await waitFor(() => {
      expect(inst.write).toHaveBeenCalledTimes(1)
    })
    const arg = inst.write.mock.calls[0][0]
    expect(arg).toBeInstanceOf(Uint8Array)
    expect(Array.from(arg as Uint8Array)).toEqual([1, 2, 3, 4])
  })

  it('T-A4.2: two consecutive non-null lastFrame values produce two writes', async () => {
    setMockState({ status: 'connected', frameQueue: [] })
    const { rerender } = renderPanel()
    const inst = SpyTerminal.mock.instances[0] as { write: ReturnType<typeof vi.fn> }
    setMockState({ status: 'connected', frameQueue: [new Uint8Array([1]).buffer]})
    rerender(
      <ThemeProvider theme={theme}>
        <TerminalPanel targetKind="autopilot" targetId="demo" onDetach={vi.fn()} />
      </ThemeProvider>,
    )
    setMockState({ status: 'connected', frameQueue: [new Uint8Array([2]).buffer]})
    rerender(
      <ThemeProvider theme={theme}>
        <TerminalPanel targetKind="autopilot" targetId="demo" onDetach={vi.fn()} />
      </ThemeProvider>,
    )
    await waitFor(() => {
      expect(inst.write).toHaveBeenCalledTimes(2)
    })
  })

  it('T-A4.3: zero-byte ArrayBuffer is passed through safely', async () => {
    setMockState({ status: 'connected', frameQueue: [] })
    const { rerender } = renderPanel()
    const inst = SpyTerminal.mock.instances[0] as { write: ReturnType<typeof vi.fn> }
    setMockState({ status: 'connected', frameQueue: [new ArrayBuffer(0)]})
    expect(() => {
      rerender(
        <ThemeProvider theme={theme}>
          <TerminalPanel targetKind="autopilot" targetId="demo" onDetach={vi.fn()} />
        </ThemeProvider>,
      )
    }).not.toThrow()
    await waitFor(() => {
      expect(inst.write).toHaveBeenCalledTimes(1)
    })
    const arg = inst.write.mock.calls[0][0] as Uint8Array
    expect(arg.length).toBe(0)
  })

  it('T-A4.4: lastFrame=null does not trigger write', () => {
    setMockState({ status: 'connected', frameQueue: [] })
    renderPanel()
    const inst = SpyTerminal.mock.instances[0] as { write: ReturnType<typeof vi.fn> }
    expect(inst.write).not.toHaveBeenCalled()
  })

  it('T-A4.5: mount-effect constructs Terminal even when initial status=idle (controls-07 #11)', () => {
    /* The bug fixed by controls-07 #11: hostRef host element was
       conditionally rendered (only when status !== 'idle'). React
       effect order:
         1. First render — useTerminalSocket returns status='idle'
            (its initial state) → idle-placeholder renders, host
            element does NOT.
         2. TerminalPanel mount-effect fires (empty deps) → hostRef.
            current is null → bails without calling new Terminal.
         3. Hook's own effect fires setStatus('connecting') → status
            transitions; host element renders for the first time; ref
            is set.
         4. Mount-effect deps=[] so it never re-runs. Terminal is
            never constructed. terminalRef.current stays null. Every
            subsequent frame-ingest effect bails on `if (!terminal)
            return`.

       Empirically observed today: live message-binary events arrive
       in steady stream, audit log confirms 85kB scrollback frames
       enqueued + sent, but xterm shows nothing because Terminal
       was never opened.

       Fix: host element renders unconditionally; idle placeholder
       overlays it. Mount-effect's hostRef.current is therefore
       non-null on first commit. */
    setMockState({ status: 'idle' })
    renderPanel()
    expect(SpyTerminal).toHaveBeenCalledTimes(1)
  })
})

// =====================================================================
// Group 5 — Connection-state alerts (R10–R13, EC-1..EC-4)
// =====================================================================

describe('Group 5 — connection-state alerts', () => {
  it('T-A5.1: status=reconnecting renders the reconnecting alert', () => {
    setMockState({ status: 'reconnecting' })
    renderPanel()
    expect(screen.getByTestId('terminal-reconnecting-alert')).toHaveTextContent(/Reconnecting/)
  })

  it('T-A5.2: status flip reconnecting → connected removes the alert', () => {
    setMockState({ status: 'reconnecting' })
    const { rerender } = renderPanel()
    setMockState({ status: 'connected' })
    rerender(
      <ThemeProvider theme={theme}>
        <TerminalPanel targetKind="autopilot" targetId="demo" onDetach={vi.fn()} />
      </ThemeProvider>,
    )
    expect(screen.queryByTestId('terminal-reconnecting-alert')).toBeNull()
  })

  it('T-A5.3: status=lost renders the connection-lost alert', () => {
    setMockState({ status: 'lost' })
    renderPanel()
    expect(screen.getByTestId('terminal-lost-alert')).toHaveTextContent(/Connection lost/)
  })

  it('T-A5.4: status=connected renders neither alert', () => {
    setMockState({ status: 'connected' })
    renderPanel()
    expect(screen.queryByTestId('terminal-reconnecting-alert')).toBeNull()
    expect(screen.queryByTestId('terminal-lost-alert')).toBeNull()
  })

  it('T-A5.5: status=connecting renders neither alert', () => {
    setMockState({ status: 'connecting' })
    renderPanel()
    expect(screen.queryByTestId('terminal-reconnecting-alert')).toBeNull()
    expect(screen.queryByTestId('terminal-lost-alert')).toBeNull()
  })

  /* T-A5.4b (controls-06 #14): when the WS is connected but no
     pty frame has arrived yet, surface a small "waiting" banner
     so the operator can distinguish "healthy but idle" (Anthropic
     mid-call, no stdout) from "broken" (lost connection). Without
     the banner the panel looks identical to a dead WS — an empty
     black box. */
  it('T-A5.4b: connected + no frames → waiting-for-output banner', () => {
    setMockState({ status: 'connected', frameQueue: [] })
    renderPanel()
    expect(screen.getByTestId('terminal-waiting-banner')).toHaveTextContent(
      /Connected.*waiting/i,
    )
  })

  it('T-A5.4c: connected + frame received → waiting banner disappears', () => {
    setMockState({
      status: 'connected',
      frameQueue: [new TextEncoder().encode('hello').buffer],
    })
    renderPanel()
    expect(screen.queryByTestId('terminal-waiting-banner')).toBeNull()
  })

  it('T-A5.4d: connecting → waiting-for-output banner shown', () => {
    /* While the WS handshake is still in flight the operator sees
       the same "waiting" affordance — distinguishes from idle (no
       attach) and lost (broken). */
    setMockState({ status: 'connecting', frameQueue: [] })
    renderPanel()
    expect(screen.getByTestId('terminal-waiting-banner')).toBeInTheDocument()
  })

  /* T-A5.4e (controls-06 #14b): always-visible status pill in the
     top-right corner. The cycle-14 waiting banner only renders for
     connected/connecting + no-frame; if the panel mounts with
     status='idle' the operator sees a blank box. The pill is the
     belt-and-braces signal: ALWAYS reflects the current WS state
     so "broken" is distinguishable from "no data yet" at a glance.
     Pinned via `data-status` so jsdom can read the live value
     without MUI sx introspection. */
  it.each([
    ['idle', 'idle'],
    ['connecting', 'connecting'],
    ['connected', 'connected'],
    ['reconnecting', 'reconnecting'],
    ['lost', 'lost'],
  ])("T-A5.4e: status=%s renders a status pill with data-status=%s", (s, expectedAttr) => {
    setMockState({ status: s as 'idle' | 'connecting' | 'connected' | 'reconnecting' | 'lost' })
    renderPanel()
    const pill = screen.getByTestId('terminal-status-pill')
    expect(pill.getAttribute('data-status')).toBe(expectedAttr)
  })

  it('T-A5.6: status=idle renders idle placeholder overlaid on the host (controls-07 #11)', () => {
    /* controls-07 #11 — host element is now unconditional so the
       Terminal mount-effect always has a target. Idle placeholder
       overlays the host (absolute positioning, pointer-events:none)
       so the visual is unchanged when status='idle'. */
    setMockState({ status: 'idle' })
    renderPanel()
    expect(screen.getByTestId('terminal-idle-placeholder')).toHaveTextContent(/No active session/)
    expect(screen.getByTestId('terminal-host')).toBeInTheDocument()
  })

  it('T-A5.7: status=lost at mount renders alert and Detach is clickable', () => {
    setMockState({ status: 'lost' })
    const onDetach = vi.fn()
    renderPanel({ onDetach })
    expect(screen.getByTestId('terminal-lost-alert')).toBeInTheDocument()
    fireEvent.click(screen.getByTestId('terminal-detach-button'))
    expect(onDetach).toHaveBeenCalledTimes(1)
  })

  it('T-A5.8: connecting → connected with no frames renders no alert and no placeholder', () => {
    setMockState({ status: 'connecting' })
    const { rerender } = renderPanel()
    setMockState({ status: 'connected' })
    rerender(
      <ThemeProvider theme={theme}>
        <TerminalPanel targetKind="autopilot" targetId="demo" onDetach={vi.fn()} />
      </ThemeProvider>,
    )
    expect(screen.queryByTestId('terminal-reconnecting-alert')).toBeNull()
    expect(screen.queryByTestId('terminal-lost-alert')).toBeNull()
    expect(screen.queryByTestId('terminal-idle-placeholder')).toBeNull()
  })

  it('T-A5.9: rapid reconnecting → connected → reconnecting flips the alert in lockstep', () => {
    setMockState({ status: 'reconnecting' })
    const { rerender } = renderPanel()
    expect(screen.getByTestId('terminal-reconnecting-alert')).toBeInTheDocument()
    setMockState({ status: 'connected' })
    rerender(
      <ThemeProvider theme={theme}>
        <TerminalPanel targetKind="autopilot" targetId="demo" onDetach={vi.fn()} />
      </ThemeProvider>,
    )
    expect(screen.queryByTestId('terminal-reconnecting-alert')).toBeNull()
    setMockState({ status: 'reconnecting' })
    rerender(
      <ThemeProvider theme={theme}>
        <TerminalPanel targetKind="autopilot" targetId="demo" onDetach={vi.fn()} />
      </ThemeProvider>,
    )
    expect(screen.getByTestId('terminal-reconnecting-alert')).toBeInTheDocument()
  })

  it('T-A5.10: overflow + reconnecting both render; overflow appears above reconnecting in DOM order', () => {
    setMockState({
      status: 'reconnecting',
      bufferOverflow: { bytesDropped: 256, at: 1 },
    })
    renderPanel()
    const overflow = screen.getByTestId('terminal-overflow-alert')
    const reconnect = screen.getByTestId('terminal-reconnecting-alert')
    // overflow must precede reconnecting in DOM order.
    const order = overflow.compareDocumentPosition(reconnect)
    expect(order & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })
})

// =====================================================================
// Group 6 — Buffer-overflow sentinel (R9, AS-11)
// =====================================================================

describe('Group 6 — buffer-overflow alert', () => {
  it('T-A6.1: bufferOverflow={bytesDropped:4096, at:T} renders the alert with byte count', () => {
    setMockState({
      status: 'connected',
      bufferOverflow: { bytesDropped: 4096, at: 100 },
    })
    renderPanel()
    expect(screen.getByTestId('terminal-overflow-alert')).toHaveTextContent(/4096 bytes dropped/)
  })

  it('T-A6.2: fresh lastFrame after overflow auto-dismisses the alert', async () => {
    setMockState({
      status: 'connected',
      bufferOverflow: { bytesDropped: 4096, at: 100 },
      frameQueue: [],
    })
    const { rerender } = renderPanel()
    expect(screen.getByTestId('terminal-overflow-alert')).toBeInTheDocument()
    setMockState({
      status: 'connected',
      bufferOverflow: { bytesDropped: 4096, at: 100 },
      frameQueue: [new Uint8Array([1, 2, 3]).buffer],
    })
    rerender(
      <ThemeProvider theme={theme}>
        <TerminalPanel targetKind="autopilot" targetId="demo" onDetach={vi.fn()} />
      </ThemeProvider>,
    )
    await waitFor(() => {
      expect(screen.queryByTestId('terminal-overflow-alert')).toBeNull()
    })
  })

  it('T-A6.3: a new overflow event after dismiss renders the alert again', async () => {
    setMockState({
      status: 'connected',
      bufferOverflow: { bytesDropped: 4096, at: 100 },
      frameQueue: [],
    })
    const { rerender } = renderPanel()
    expect(screen.getByTestId('terminal-overflow-alert')).toBeInTheDocument()
    setMockState({
      status: 'connected',
      bufferOverflow: { bytesDropped: 4096, at: 100 },
      frameQueue: [new Uint8Array([1]).buffer],
    })
    rerender(
      <ThemeProvider theme={theme}>
        <TerminalPanel targetKind="autopilot" targetId="demo" onDetach={vi.fn()} />
      </ThemeProvider>,
    )
    await waitFor(() => {
      expect(screen.queryByTestId('terminal-overflow-alert')).toBeNull()
    })
    setMockState({
      status: 'connected',
      bufferOverflow: { bytesDropped: 8192, at: 200 },
      frameQueue: [new Uint8Array([1]).buffer],
    })
    rerender(
      <ThemeProvider theme={theme}>
        <TerminalPanel targetKind="autopilot" targetId="demo" onDetach={vi.fn()} />
      </ThemeProvider>,
    )
    expect(screen.getByTestId('terminal-overflow-alert')).toHaveTextContent(/8192 bytes dropped/)
  })
})

// =====================================================================
// Group 7 — Read-only key handling (R14–R17, AS-7, AS-8, EC-9..EC-12)
// =====================================================================

describe('Group 7 — read-only key handling', () => {
  function getHandler(): (ev: KeyboardEvent) => boolean {
    const inst = SpyTerminal.mock.instances[0] as { attachCustomKeyEventHandler: ReturnType<typeof vi.fn> }
    return inst.attachCustomKeyEventHandler.mock.calls[0][0] as (ev: KeyboardEvent) => boolean
  }

  it('T-A7.1: attachCustomKeyEventHandler is called once with a function', () => {
    setMockState({ status: 'connected' })
    renderPanel()
    const inst = SpyTerminal.mock.instances[0] as { attachCustomKeyEventHandler: ReturnType<typeof vi.fn> }
    expect(inst.attachCustomKeyEventHandler).toHaveBeenCalledTimes(1)
    expect(typeof inst.attachCustomKeyEventHandler.mock.calls[0][0]).toBe('function')
  })

  it('T-A7.2: handler returns false for every key event invoked', () => {
    setMockState({ status: 'connected' })
    renderPanel()
    const handler = getHandler()
    const events: KeyboardEvent[] = [
      new KeyboardEvent('keydown', { key: 'c', ctrlKey: true }),
      new KeyboardEvent('keydown', { key: 'c', ctrlKey: true, shiftKey: true }),
      new KeyboardEvent('keydown', { key: 'v', ctrlKey: true }),
      new KeyboardEvent('keydown', { key: 'Tab' }),
      new KeyboardEvent('keydown', { key: 'a' }),
      new KeyboardEvent('keyup', { key: 'c', ctrlKey: true }),
    ]
    for (const ev of events) {
      expect(handler(ev)).toBe(false)
    }
  })

  it('T-A7.3: Ctrl+C with non-empty selection writes selection to clipboard', () => {
    stubClipboard()
    setMockState({ status: 'connected' })
    renderPanel()
    const tInst = SpyTerminal.mock.instances[0] as { getSelection: ReturnType<typeof vi.fn> }
    tInst.getSelection.mockReturnValue('hello world')
    const handler = getHandler()
    const writeText = (globalThis.navigator as unknown as { clipboard: { writeText: ReturnType<typeof vi.fn> } }).clipboard.writeText
    handler(new KeyboardEvent('keydown', { key: 'c', ctrlKey: true }))
    expect(writeText).toHaveBeenCalledTimes(1)
    expect(writeText).toHaveBeenCalledWith('hello world')
  })

  it('T-A7.4: Ctrl+C with empty selection does NOT call writeText', () => {
    stubClipboard()
    setMockState({ status: 'connected' })
    renderPanel()
    const tInst = SpyTerminal.mock.instances[0] as { getSelection: ReturnType<typeof vi.fn> }
    tInst.getSelection.mockReturnValue('')
    const handler = getHandler()
    const writeText = (globalThis.navigator as unknown as { clipboard: { writeText: ReturnType<typeof vi.fn> } }).clipboard.writeText
    handler(new KeyboardEvent('keydown', { key: 'c', ctrlKey: true }))
    expect(writeText).not.toHaveBeenCalled()
  })

  it('T-A7.5: hook sendDisabled is true and component imports no WebSocket', () => {
    const state = setMockState({ status: 'connected' })
    renderPanel()
    expect(state.sendDisabled).toBe(true)
    expect(componentSrc).not.toMatch(/\bnew\s+WebSocket\s*\(/)
  })

  it('T-A7.6: clipboard rejection is swallowed; no console.error', async () => {
    stubClipboardReject()
    const consoleSpy = vi.spyOn(console, 'error').mockImplementation(() => {})
    setMockState({ status: 'connected' })
    renderPanel()
    const tInst = SpyTerminal.mock.instances[0] as { getSelection: ReturnType<typeof vi.fn> }
    tInst.getSelection.mockReturnValue('sel')
    const handler = getHandler()
    expect(() =>
      handler(new KeyboardEvent('keydown', { key: 'c', ctrlKey: true })),
    ).not.toThrow()
    // Yield a microtask for the rejected promise.
    await Promise.resolve()
    await Promise.resolve()
    expect(consoleSpy).not.toHaveBeenCalled()
    consoleSpy.mockRestore()
  })

  it('T-A7.7: Tab key returns false from the handler', () => {
    setMockState({ status: 'connected' })
    renderPanel()
    const handler = getHandler()
    expect(handler(new KeyboardEvent('keydown', { key: 'Tab' }))).toBe(false)
  })

  it('T-A7.8: Ctrl+Shift+C / Ctrl+V / plain key produce no clipboard write', () => {
    stubClipboard()
    setMockState({ status: 'connected' })
    renderPanel()
    const tInst = SpyTerminal.mock.instances[0] as { getSelection: ReturnType<typeof vi.fn> }
    tInst.getSelection.mockReturnValue('selection-here')
    const handler = getHandler()
    const writeText = (globalThis.navigator as unknown as { clipboard: { writeText: ReturnType<typeof vi.fn> } }).clipboard.writeText
    handler(new KeyboardEvent('keydown', { key: 'c', ctrlKey: true, shiftKey: true }))
    handler(new KeyboardEvent('keydown', { key: 'v', ctrlKey: true }))
    handler(new KeyboardEvent('keydown', { key: 'a' }))
    expect(writeText).not.toHaveBeenCalled()
  })
})

// =====================================================================
// Group 8 — Detach affordance (R18, AS-5)
// =====================================================================

describe('Group 8 — Detach button', () => {
  it('T-A8.1: detach button exists with aria-label "Detach terminal"', () => {
    setMockState({ status: 'connected' })
    renderPanel()
    const btn = screen.getByTestId('terminal-detach-button')
    expect(btn.getAttribute('aria-label')).toBe('Detach terminal')
  })

  it('T-A8.2: clicking detach invokes onDetach exactly once', () => {
    setMockState({ status: 'connected' })
    const onDetach = vi.fn()
    renderPanel({ onDetach })
    fireEvent.click(screen.getByTestId('terminal-detach-button'))
    expect(onDetach).toHaveBeenCalledTimes(1)
  })

  it('T-A8.3: detach button is visible in every status', () => {
    const statuses: UseTerminalSocket['status'][] = ['idle', 'connecting', 'connected', 'reconnecting', 'lost']
    for (const s of statuses) {
      cleanup()
      setMockState({ status: s })
      renderPanel()
      expect(screen.getByTestId('terminal-detach-button')).toBeInTheDocument()
    }
  })
})

// =====================================================================
// Group 9 — Source-grep guards (Open Question #3 — visible overflow surface)
// =====================================================================

describe('Group 9 — source guards', () => {
  it('T-A9.1: bufferOverflow surface is rendered as a JSX Alert (not console-only)', () => {
    // R9 / Open Question #3 — implementation choice locked: bufferOverflow
    // must reach the UI via an Alert. A future refactor to console-only
    // would silently regress this requirement; this guard fails first.
    expect(componentSrc).toMatch(/bufferOverflow[\s\S]*?<Alert/)
  })

  it('T-C1: test file lives at dashboard/app/src/__tests__/TerminalPanel.test.tsx (R27)', () => {
    // The test file existing is implicit (this is that file); the
    // assertion records the project-convention path so a future
    // discovery-time move surfaces the precedent.
    expect(__filename).toMatch(/\/src\/__tests__\/TerminalPanel\.test\.tsx$/)
  })
})
