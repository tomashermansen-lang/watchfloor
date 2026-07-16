// TerminalPanel — xterm.js host for the read-only pty stream surfaced
// by the predecessor useTerminalSocket hook. Owns the Terminal
// lifecycle, frame ingest, connection-state alerts, buffer-overflow
// sentinel UX, custom-key handler (R14–R17), and the Detach
// affordance. All WebSocket lifecycle is delegated to the hook (C4);
// this file imports no `WebSocket` identifier.
//
// Three-layer read-only defence:
//   1. hook contract — sendDisabled: true literal type (no send API)
//   2. xterm.js layer — disableStdin: true
//   3. custom-key handler returns false for every key event
//
// Mounted by SessionPanel as a third `mode` value ('terminal'); R22's
// `targetId !== null` render gate ensures the construct effect never
// runs against a null target.

import {
  useEffect,
  useRef,
  useState,
  type JSX,
} from 'react'
import Alert from '@mui/material/Alert'
import Box from '@mui/material/Box'
import IconButton from '@mui/material/IconButton'
import Typography from '@mui/material/Typography'
import CloseIcon from '@mui/icons-material/Close'
import { Terminal } from '@xterm/xterm'
import { FitAddon } from '@xterm/addon-fit'
import '@xterm/xterm/css/xterm.css'
import {
  useTerminalSocket,
  type TerminalTargetKind,
} from '../hooks/useTerminalSocket'

export interface TerminalPanelProps {
  targetKind: TerminalTargetKind
  targetId: string | null
  onDetach: () => void
}

// === Module-private constants =========================================

const _SCROLLBACK_ROWS = 2000 // C1 — scrollback: 2000 explicit literal
const _OVERFLOW_LABEL = 'Output buffer overflow'
const _RECONNECTING_LABEL = 'Reconnecting…'
const _LOST_LABEL = 'Connection lost'
const _IDLE_PLACEHOLDER = 'No active session attached'
const _DETACH_ARIA_LABEL = 'Detach terminal'
const _CTRL_C_KEY = 'c'
// controls-06 #14 — when the WS is open but no pty frame has
// arrived yet, the panel looks indistinguishable from a dead
// connection (empty black box). The banner tells the operator
// "the WS is healthy, the chain is just idle right now" — typical
// when the chain is mid-Anthropic-API-call and stdout is silent.
const _WAITING_LABEL = 'Connected — waiting for output…'

// === Component ========================================================

export function TerminalPanel({
  targetKind,
  targetId,
  onDetach,
}: Readonly<TerminalPanelProps>): JSX.Element {
  const { status, frameQueue, drainFrames, bufferOverflow } = useTerminalSocket(
    targetKind,
    targetId,
  )

  const hostRef = useRef<HTMLDivElement | null>(null)
  const terminalRef = useRef<Terminal | null>(null)
  const fitAddonRef = useRef<FitAddon | null>(null)
  const resizeObserverRef = useRef<ResizeObserver | null>(null)
  const rafRef = useRef<number | null>(null)
  // Tracks the bufferOverflow.at value seen in the previous render.
  // Used to skip dismissal when the overflow itself just changed in
  // the same commit as a new lastFrame — otherwise a fresh overflow
  // event would be auto-dismissed before the operator could see it.
  const prevBufferOverflowAtRef = useRef<number | null>(null)

  const [dismissedOverflowAt, setDismissedOverflowAt] = useState<number | null>(null)
  /* controls-07 #9 — one-way latch for the waiting-banner gate.
     The queue-drain pattern means `frameQueue.length === 0` is the
     post-write steady state; this flag stays true once any frame
     has been written so the banner does not flicker. Ref mirrors
     the state value so the frame-ingest effect can check the latch
     synchronously without taking it as a dep (which would re-fire
     the write loop and double-count frames). */
  const [hasReceivedFrame, setHasReceivedFrame] = useState(false)
  const hasReceivedFrameRef = useRef(false)

  // Mount-only effect — Terminal construction, addon wiring, key
  // handler, ResizeObserver. Empty deps; targetId changes are
  // structurally a remount (SessionPanel resets mode on taskId change,
  // R24), so the closure cannot outlive its target.
  useEffect(() => {
    if (!hostRef.current) return

    const reduceMotion =
      typeof globalThis.matchMedia === 'function'
        ? globalThis.matchMedia('(prefers-reduced-motion: reduce)').matches
        : false

    // scrollback: 2000 rows — Phase 3 gate constraint C1.
    const terminal = new Terminal({
      disableStdin: true,
      scrollback: _SCROLLBACK_ROWS,
      cursorBlink: !reduceMotion,
    })
    const fitAddon = new FitAddon()
    terminal.loadAddon(fitAddon)
    terminal.open(hostRef.current)

    terminal.attachCustomKeyEventHandler((ev: KeyboardEvent): boolean => {
      // R14 — return false for every key; xterm.js default is cancelled.
      // R15 — Ctrl+C with non-empty selection routes to clipboard;
      // empty selection is a silent no-op. Never reaches the pty.
      if (
        ev.type === 'keydown' &&
        ev.key === _CTRL_C_KEY &&
        ev.ctrlKey &&
        !ev.shiftKey
      ) {
        const sel = terminal.getSelection()
        if (sel.length > 0) {
          // R17 — swallow clipboard failures silently.
          globalThis.navigator?.clipboard?.writeText(sel).catch(() => {})
        }
      }
      // R16 — Tab cancelled; browser default focus traversal applies.
      return false
    })

    terminalRef.current = terminal
    fitAddonRef.current = fitAddon

    const scheduleFit = (): void => {
      if (rafRef.current !== null) return
      rafRef.current = globalThis.requestAnimationFrame(() => {
        rafRef.current = null
        try {
          fitAddon.fit()
        } catch {
          // jsdom or detached host — fit is best-effort.
        }
      })
    }
    scheduleFit()

    const observer = new ResizeObserver(() => scheduleFit())
    observer.observe(hostRef.current)
    resizeObserverRef.current = observer

    return () => {
      if (rafRef.current !== null) {
        globalThis.cancelAnimationFrame(rafRef.current)
        rafRef.current = null
      }
      observer.disconnect()
      resizeObserverRef.current = null
      terminal.dispose()
      terminalRef.current = null
      fitAddonRef.current = null
    }
  }, [])

  // Frame ingest — controls-07 #9 drains a functional-update queue
  // instead of the old single-slot mailbox. React 18 automatic
  // batching used to collapse multiple ws.onmessage setLastFrame
  // calls into a single render with only the LAST frame surviving;
  // a scrollback-seed-then-tail attach would lose the 27kB seed and
  // the terminal stayed blank. The queue pattern guarantees all
  // arrived frames are written to xterm in order, then released
  // via drainFrames so the queue does not grow unbounded.
  useEffect(() => {
    if (frameQueue.length === 0) return
    const terminal = terminalRef.current
    if (!terminal) return
    for (const frame of frameQueue) {
      terminal.write(new Uint8Array(frame))
    }
    if (!hasReceivedFrameRef.current) {
      hasReceivedFrameRef.current = true
      setHasReceivedFrame(true)
    }
    drainFrames()
  }, [frameQueue, drainFrames])

  // Overflow auto-dismiss — when a fresh frame batch arrives WHILE the
  // overflow.at value has been stable for at least one commit, mark
  // it dismissed so the render branch hides the alert. If overflow.at
  // just changed in the same commit, the new event is brand-new and
  // must remain visible until the next frame batch.
  useEffect(() => {
    const currentAt = bufferOverflow?.at ?? null
    const prevAt = prevBufferOverflowAtRef.current
    prevBufferOverflowAtRef.current = currentAt
    if (frameQueue.length === 0 || !bufferOverflow) return
    if (prevAt !== bufferOverflow.at) return
    setDismissedOverflowAt(bufferOverflow.at)
  }, [frameQueue, bufferOverflow])

  const bufferOverflowVisible =
    bufferOverflow !== null && bufferOverflow.at !== dismissedOverflowAt

  return (
    <Box
      sx={{
        position: 'relative',
        flex: 1,
        display: 'flex',
        flexDirection: 'column',
        minHeight: 0,
      }}
    >
      {/* controls-06 #14b — always-visible WS connection-status
          pill. The cycle-14 waiting banner only renders for
          connected/connecting + no-frame; if the panel mounts with
          status='idle' or some other path the operator sees nothing
          and can't tell "broken" from "no data yet". This pill ALWAYS
          reflects the live `status` value so the connection state is
          readable at a glance. Sits next to the Detach icon so it
          stays out of the terminal content area. */}
      <Box
        data-testid="terminal-status-pill"
        data-status={status}
        sx={{
          position: 'absolute',
          top: 8,
          right: 44,
          zIndex: 1,
          display: 'inline-flex',
          alignItems: 'center',
          gap: 0.5,
          px: 1,
          py: 0.25,
          fontFamily:
            '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
          fontSize: '10px',
          letterSpacing: '0.06em',
          textTransform: 'uppercase',
          color:
            status === 'connected'
              ? '#5BD68A'
              : status === 'connecting'
                ? '#3B9EFF'
                : status === 'reconnecting'
                  ? '#F2B441'
                  : status === 'lost'
                    ? '#EF4D4D'
                    : '#5A6472',
        }}
      >
        ● {status}
      </Box>
      <IconButton
        size="small"
        data-testid="terminal-detach-button"
        aria-label={_DETACH_ARIA_LABEL}
        onClick={onDetach}
        sx={{ position: 'absolute', top: 8, right: 8, zIndex: 1 }}
      >
        <CloseIcon fontSize="small" />
      </IconButton>

      {bufferOverflowVisible && bufferOverflow && (
        <Alert
          data-testid="terminal-overflow-alert"
          severity="warning"
          sx={{ borderRadius: 0 }}
        >
          {`${_OVERFLOW_LABEL} — ${bufferOverflow.bytesDropped} bytes dropped`}
        </Alert>
      )}
      {status === 'reconnecting' && (
        <Alert
          data-testid="terminal-reconnecting-alert"
          severity="warning"
          sx={{ borderRadius: 0 }}
        >
          {_RECONNECTING_LABEL}
        </Alert>
      )}
      {status === 'lost' && (
        <Alert
          data-testid="terminal-lost-alert"
          severity="error"
          sx={{ borderRadius: 0 }}
        >
          {_LOST_LABEL}
        </Alert>
      )}
      {(status === 'connected' || status === 'connecting') && !hasReceivedFrame && (
        /* controls-06 #14 — diagnostic banner. Operator can tell
           "WS healthy, chain idle" from "WS broken, no signal".
           Hidden as soon as the first frame arrives.
           controls-07 #9 — `hasReceivedFrame` is a one-way latch
           because the queue is drained after each ingest; gating
           the banner on `frameQueue.length === 0` would re-show
           it on every render between batches. */
        <Alert
          data-testid="terminal-waiting-banner"
          severity="info"
          icon={false}
          sx={{ borderRadius: 0 }}
        >
          {_WAITING_LABEL}
        </Alert>
      )}

      {/* controls-07 #11 — host element renders UNCONDITIONALLY.
         Pre-#11 the host was rendered only when status !== 'idle';
         since useTerminalSocket returns 'idle' on first render and
         this component's mount-effect has empty deps, the effect
         fired before the host existed, bailed with hostRef.current
         null, and never re-ran when status transitioned. Terminal
         was therefore never constructed and every frame-ingest
         effect bailed at `if (!terminal) return`. The idle
         placeholder now overlays the host so the visual is
         unchanged when status='idle' but xterm has a mount target
         from the first commit. */}
      <Box
        ref={hostRef}
        data-testid="terminal-host"
        sx={{ flex: 1, minHeight: 0, p: 1, position: 'relative' }}
      >
        {status === 'idle' && (
          <Box
            data-testid="terminal-idle-placeholder"
            sx={{
              position: 'absolute',
              inset: 0,
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'center',
              pointerEvents: 'none',
              zIndex: 1,
            }}
          >
            <Typography variant="body2" color="text.secondary">
              {_IDLE_PLACEHOLDER}
            </Typography>
          </Box>
        )}
      </Box>
    </Box>
  )
}
