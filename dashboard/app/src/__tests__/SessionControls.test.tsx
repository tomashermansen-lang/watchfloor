import {
  describe,
  it,
  expect,
  vi,
  beforeEach,
  afterEach,
} from 'vitest'
import { render, screen, within, fireEvent, waitFor, cleanup, act, type RenderResult } from '@testing-library/react'
import { readFileSync } from 'node:fs'
import { resolve, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'

// === Hook mock — R-TEST-3 ============================================
// Hoisted vi.fn so the factory can wire it before module init.
const { useSessionControlsMock } = vi.hoisted(() => ({
  useSessionControlsMock: vi.fn(),
}))

vi.mock('../hooks/useSessionControls', async (importOriginal) => {
  const actual = await importOriginal<typeof import('../hooks/useSessionControls')>()
  return {
    ...actual, // keep type re-exports / __test__ namespace if any consumer needs them
    useSessionControls: useSessionControlsMock,
  }
})

import {
  SessionControls,
  __test__ as SessionControlsInternals,
} from '../components/SessionControls'
import { CancelConfirmDialog } from '../components/CancelConfirmDialog'
import { SessionStateChip } from '../components/SessionStateChip'
import type {
  SessionUIState,
  ControlError,
  UseSessionControls,
} from '../hooks/useSessionControls'

// === Test fixture helpers ============================================

function makeMutate(): UseSessionControls['mutate'] {
  return {
    start: vi.fn().mockResolvedValue(undefined),
    pause: vi.fn().mockResolvedValue(undefined),
    resume: vi.fn().mockResolvedValue(undefined),
    cancel: vi.fn().mockResolvedValue(undefined),
    /* controls-07 #4 — atomic restart for the stale-running affordance. */
    restart: vi.fn().mockResolvedValue(undefined),
  }
}

function makeHookState(
  overrides?: Partial<UseSessionControls>,
): UseSessionControls {
  return {
    state: 'idle',
    isPausing: false,
    pauseElapsedSeconds: 0,
    error: null,
    tmuxSession: 'autopilot-demo',
    isStale: false,
    mutate: makeMutate(),
    ...overrides,
  }
}

function setMockState(overrides?: Partial<UseSessionControls>): UseSessionControls {
  const hookState = makeHookState(overrides)
  useSessionControlsMock.mockReturnValue(hookState)
  return hookState
}

function renderControls(
  props?: Partial<React.ComponentProps<typeof SessionControls>>,
): RenderResult {
  return render(
    <ThemeProvider theme={theme}>
      <SessionControls
        targetKind={props?.targetKind ?? 'autopilot'}
        targetId={props?.targetId ?? 'demo'}
        onAttach={props?.onAttach ?? vi.fn()}
        hideStateChip={props?.hideStateChip}
        autopilotMode={props?.autopilotMode}
        attached={props?.attached}
        density={props?.density}
      />
    </ThemeProvider>,
  )
}

function renderChip(
  state: SessionUIState,
  isPausing = false,
): RenderResult {
  return render(
    <ThemeProvider theme={theme}>
      <SessionStateChip state={state} isPausing={isPausing} />
    </ThemeProvider>,
  )
}

function renderDialog(
  props?: Partial<React.ComponentProps<typeof CancelConfirmDialog>>,
): RenderResult {
  return render(
    <ThemeProvider theme={theme}>
      <CancelConfirmDialog
        open={props?.open ?? true}
        state={props?.state ?? 'running'}
        isCancelling={props?.isCancelling ?? false}
        errorPrimary={props?.errorPrimary ?? null}
        errorSecondary={props?.errorSecondary ?? null}
        onConfirm={props?.onConfirm ?? vi.fn()}
        onClose={props?.onClose ?? vi.fn()}
      />
    </ThemeProvider>,
  )
}

beforeEach(() => {
  vi.clearAllMocks()
  setMockState()
})

afterEach(() => {
  cleanup()
})

// === Source-string helpers (for grep guards) =========================

const __filename = fileURLToPath(import.meta.url)
const __dirname = dirname(__filename)
const SRC_DIR = resolve(__dirname, '..', 'components')
const sessionControlsSrc = readFileSync(
  resolve(SRC_DIR, 'SessionControls.tsx'),
  'utf8',
)
const cancelDialogSrc = readFileSync(
  resolve(SRC_DIR, 'CancelConfirmDialog.tsx'),
  'utf8',
)
const sessionStateChipSrc = readFileSync(
  resolve(SRC_DIR, 'SessionStateChip.tsx'),
  'utf8',
)

// =====================================================================
// Group 1 — Module shape & imports (R1–R3, R-EXT-3..4, R24)
// =====================================================================

describe('Group 1 — module shape', () => {
  it('T-1.1: components are named exports (default exports forbidden)', () => {
    expect(typeof SessionControls).toBe('function')
    expect(typeof CancelConfirmDialog).toBe('function')
    expect(typeof SessionStateChip).toBe('function')
  })

  it('T-1.2: each component file declares an exported <Name>Props interface', () => {
    // TS interfaces are erased at runtime, so we verify the type
    // export via a source-grep — every *.tsx file must contain an
    // `export interface <Name>Props {` line so future composition
    // consumers can type the parent without redeclaring the shape.
    expect(sessionControlsSrc).toMatch(
      /^\s*export\s+interface\s+SessionControlsProps\s*\{/m,
    )
    expect(cancelDialogSrc).toMatch(
      /^\s*export\s+interface\s+CancelConfirmDialogProps\s*\{/m,
    )
    expect(sessionStateChipSrc).toMatch(
      /^\s*export\s+interface\s+SessionStateChipProps\s*\{/m,
    )
  })

  it('T-1.3: SessionControls.tsx has no useSWR / globalMutate / Snackbar / fetch import', () => {
    expect(sessionControlsSrc).not.toMatch(
      /^\s*import[^\n]*\b(useSWR|globalMutate|Snackbar)\b/m,
    )
    expect(sessionControlsSrc).not.toMatch(
      /^\s*from\s+['"](?:swr|@mui\/material\/Snackbar)['"]/m,
    )
    expect(sessionControlsSrc).not.toMatch(
      /\bglobal\.fetch\b|\bwindow\.fetch\b|(?<!\.)\bfetch\(/,
    )
  })

  it('T-1.4: SessionUIState / ControlError imported only from hooks/useSessionControls', () => {
    for (const src of [sessionControlsSrc, cancelDialogSrc, sessionStateChipSrc]) {
      const usesUiState = /\bSessionUIState\b/.test(src)
      const usesControlError = /\bControlError\b/.test(src)
      if (usesUiState || usesControlError) {
        expect(src).toMatch(
          /^\s*import\s+(?:type\s+)?\{[^}]*\b(?:SessionUIState|ControlError)\b[^}]*\}\s+from\s+['"]\.\.?\/hooks\/useSessionControls['"]/m,
        )
      }
    }
  })

  it('T-1.7: every <Button> JSX node carries size="large" OR an sx padding override', () => {
    for (const src of [sessionControlsSrc, cancelDialogSrc]) {
      const lines = src.split('\n')
      for (let i = 0; i < lines.length; i += 1) {
        const line = lines[i]
        if (!/<Button\b/.test(line)) continue
        let block = line
        let j = i
        while (!/>/.test(block) && j + 1 < lines.length) {
          j += 1
          block += '\n' + lines[j]
        }
        const ok = /size="large"/.test(block) || /sx=\{\{[^}]*\b(?:p|py|padding)\b/.test(block)
        expect(ok, `<Button> at line ${i + 1} missing size="large" or padding override:\n${block}`).toBe(true)
      }
    }
  })

  it('T-1.8: no `outline: none` overrides anywhere', () => {
    for (const src of [sessionControlsSrc, cancelDialogSrc, sessionStateChipSrc]) {
      expect(src).not.toMatch(/^\s*outline:\s*none/m)
    }
  })
})

// =====================================================================
// Group 2 — Per-state button visibility (R4–R7, PA-1)
// =====================================================================

describe('Group 2 — button visibility per SessionUIState', () => {
  function buttons() {
    return {
      start: screen.queryByRole('button', { name: /^Start\b/i }),
      restart: screen.queryByRole('button', { name: /^Restart\b/i }),
      pause: screen.queryByRole('button', { name: /pause/i }),
      resume: screen.queryByRole('button', { name: /^resume$/i }),
      cancel: screen.queryByRole('button', { name: /^cancel$/i }),
      attach: screen.queryByRole('button', { name: /^output$/i }),
    }
  }

  it('T-2.1: idle → only Start visible', () => {
    setMockState({ state: 'idle' })
    renderControls()
    const b = buttons()
    expect(b.start).toBeInTheDocument()
    expect(b.pause).not.toBeInTheDocument()
    expect(b.resume).not.toBeInTheDocument()
    expect(b.cancel).not.toBeInTheDocument()
    expect(b.attach).not.toBeInTheDocument()
  })

  it('T-2.2: starting → only Cancel visible', () => {
    setMockState({ state: 'starting' })
    renderControls()
    const b = buttons()
    expect(b.start).not.toBeInTheDocument()
    expect(b.restart).not.toBeInTheDocument()
    expect(b.pause).not.toBeInTheDocument()
    expect(b.resume).not.toBeInTheDocument()
    expect(b.cancel).toBeInTheDocument()
    expect(b.attach).not.toBeInTheDocument()
  })

  it('T-2.3: running, isPausing=false → Pause + Cancel + Attach visible', () => {
    setMockState({ state: 'running', isPausing: false })
    renderControls()
    const b = buttons()
    expect(b.start).not.toBeInTheDocument()
    expect(b.restart).not.toBeInTheDocument()
    expect(b.pause).toBeInTheDocument()
    expect(b.resume).not.toBeInTheDocument()
    expect(b.cancel).toBeInTheDocument()
    expect(b.attach).toBeInTheDocument()
  })

  it('T-2.4: paused → Resume + Cancel + Attach visible', () => {
    setMockState({ state: 'paused' })
    renderControls()
    const b = buttons()
    expect(b.start).not.toBeInTheDocument()
    expect(b.restart).not.toBeInTheDocument()
    expect(b.pause).not.toBeInTheDocument()
    expect(b.resume).toBeInTheDocument()
    expect(b.cancel).toBeInTheDocument()
    expect(b.attach).toBeInTheDocument()
  })

  it('T-2.5: resuming → Cancel + Attach visible', () => {
    setMockState({ state: 'resuming' })
    renderControls()
    const b = buttons()
    expect(b.start).not.toBeInTheDocument()
    expect(b.restart).not.toBeInTheDocument()
    expect(b.pause).not.toBeInTheDocument()
    expect(b.resume).not.toBeInTheDocument()
    expect(b.cancel).toBeInTheDocument()
    expect(b.attach).toBeInTheDocument()
  })

  it.each(['cancelled', 'completed', 'failed'] as const)(
    'T-2.6/7/8: %s → only Restart visible',
    (state) => {
      setMockState({ state })
      renderControls()
      const b = buttons()
      expect(b.restart).toBeInTheDocument()
      expect(b.start).not.toBeInTheDocument()
      expect(b.pause).not.toBeInTheDocument()
      expect(b.resume).not.toBeInTheDocument()
      expect(b.cancel).not.toBeInTheDocument()
      expect(b.attach).not.toBeInTheDocument()
    },
  )

  it('T-2.8 (extra): failed + error → Alert renders alongside Restart', () => {
    setMockState({
      state: 'failed',
      error: { slug: 'tmux_error', status: 500, message: 'tmux subsystem error' },
    })
    renderControls()
    expect(screen.getByRole('alert')).toHaveTextContent(/tmux subsystem error/i)
    expect(screen.getByRole('button', { name: /restart/i })).toBeInTheDocument()
  })

  it('T-2.9: idle Start click invokes mutate.start; rerender to starting hides the button', () => {
    const hook = setMockState({ state: 'idle' })
    const { rerender } = renderControls()
    fireEvent.click(screen.getByRole('button', { name: /start/i }))
    expect(hook.mutate.start).toHaveBeenCalledTimes(1)

    setMockState({ state: 'starting' })
    rerender(
      <ThemeProvider theme={theme}>
        <SessionControls targetKind="autopilot" targetId="demo" onAttach={vi.fn()} />
      </ThemeProvider>,
    )
    expect(screen.queryByRole('button', { name: /^Start\b/i })).not.toBeInTheDocument()
  })

  // controls-01 #2 — START carries a side-effect title so the OS
  // tooltip explains what the click actually does (spawn a tmux
  // session and run the autopilot pipeline end-to-end).
  it('T-2.10: idle START button has a title= describing the side effect', () => {
    setMockState({ state: 'idle' })
    renderControls()
    const start = screen.getByRole('button', { name: /^Start\b/i })
    expect(start).toHaveAttribute('title')
    const t = start.getAttribute('title') ?? ''
    expect(t).toMatch(/tmux/i)
    expect(t).toMatch(/autopilot/i)
  })

  it('T-2.11: terminal-state RESTART button carries the same side-effect title', () => {
    setMockState({ state: 'completed' })
    renderControls()
    const restart = screen.getByRole('button', { name: /^Restart\b/i })
    expect(restart).toHaveAttribute('title')
    expect(restart.getAttribute('title') ?? '').toMatch(/tmux/i)
  })

  // controls-01 #7 — leading glyph disambiguates the primary action
  // at-a-glance from the surrounding filter chrome.
  it('T-2.12: idle START button renders a leading play glyph', () => {
    setMockState({ state: 'idle' })
    renderControls()
    const start = screen.getByRole('button', { name: /^Start\b/i })
    expect(within(start).getByTestId('PlayArrowRoundedIcon')).toBeInTheDocument()
  })

  it('T-2.13: terminal-state RESTART button renders the same leading glyph', () => {
    setMockState({ state: 'completed' })
    renderControls()
    const restart = screen.getByRole('button', { name: /^Restart\b/i })
    expect(within(restart).getByTestId('PlayArrowRoundedIcon')).toBeInTheDocument()
  })

  // controls-01 #6 — contextual label so operators see what pipeline
  // the click actually launches. Mode defaults to "Start autopilot"
  // (no suffix) when the host doesn't pass autopilotMode; renders
  // "Start autopilot · light" / "Start autopilot · full" when known.
  it('T-2.14: idle START label is "Start autopilot" when autopilotMode is omitted', () => {
    setMockState({ state: 'idle' })
    renderControls()
    const btn = screen.getByRole('button', { name: /^Start\b/i })
    expect(btn.textContent).toMatch(/Start autopilot$/)
  })

  it('T-2.15: idle START label is "Start autopilot · light" when autopilotMode=light', () => {
    setMockState({ state: 'idle' })
    renderControls({ autopilotMode: 'light' })
    const btn = screen.getByRole('button', { name: /^Start\b/i })
    expect(btn.textContent).toMatch(/Start autopilot\s*·\s*light$/)
  })

  it('T-2.16: idle START label is "Start autopilot · full" when autopilotMode=full', () => {
    setMockState({ state: 'idle' })
    renderControls({ autopilotMode: 'full' })
    const btn = screen.getByRole('button', { name: /^Start\b/i })
    expect(btn.textContent).toMatch(/Start autopilot\s*·\s*full$/)
  })

  it('T-2.17: terminal-state label is "Restart autopilot · light" when autopilotMode=light', () => {
    setMockState({ state: 'completed' })
    renderControls({ autopilotMode: 'light' })
    const btn = screen.getByRole('button', { name: /^Restart\b/i })
    expect(btn.textContent).toMatch(/Restart autopilot\s*·\s*light$/)
  })

  it('T-2.18: autopilotMode=manual collapses to "Start autopilot" (no suffix)', () => {
    setMockState({ state: 'idle' })
    renderControls({ autopilotMode: 'manual' })
    const btn = screen.getByRole('button', { name: /^Start\b/i })
    expect(btn.textContent).toMatch(/Start autopilot$/)
  })

  // controls-03 #3 — chain primary label honors targetKind. Chain has
  // no light/full pipeline (autopilot-chain.sh ignores it), so the
  // suffix is suppressed even if a stray autopilotMode is passed.
  it('T-2.28: targetKind=chain, idle → label "Start chain"', () => {
    setMockState({ state: 'idle' })
    renderControls({ targetKind: 'chain' })
    const btn = screen.getByRole('button', { name: /^Start\b/i })
    expect(btn.textContent).toMatch(/Start chain$/)
  })

  it('T-2.29: targetKind=chain, completed → label "Restart chain"', () => {
    setMockState({ state: 'completed' })
    renderControls({ targetKind: 'chain' })
    const btn = screen.getByRole('button', { name: /^Restart\b/i })
    expect(btn.textContent).toMatch(/Restart chain$/)
  })

  it('T-2.30: targetKind=chain + autopilotMode=full → suffix suppressed', () => {
    setMockState({ state: 'idle' })
    renderControls({ targetKind: 'chain', autopilotMode: 'full' })
    const btn = screen.getByRole('button', { name: /^Start\b/i })
    expect(btn.textContent).toMatch(/Start chain$/)
    expect(btn.textContent).not.toMatch(/·/)
  })

  // controls-03 #4 — Start tooltip honors targetKind. The autopilot
  // copy talks about "this feature end-to-end through the pipeline";
  // the chain copy must talk about "every autopilot-eligible task in
  // this plan" so the operator knows the click drives a fan-out, not
  // a single feature run.
  it('T-2.31: targetKind=chain → Start tooltip describes the chain fan-out', () => {
    setMockState({ state: 'idle' })
    renderControls({ targetKind: 'chain' })
    const start = screen.getByRole('button', { name: /^Start\b/i })
    const title = start.getAttribute('title') ?? ''
    expect(title).toMatch(/autopilot-chain/i)
    expect(title).toMatch(/plan/i)
    expect(title).not.toMatch(/this feature/i)
  })

  it('T-2.32: targetKind=autopilot → Start tooltip still describes a single feature run', () => {
    setMockState({ state: 'idle' })
    renderControls({ targetKind: 'autopilot' })
    const start = screen.getByRole('button', { name: /^Start\b/i })
    const title = start.getAttribute('title') ?? ''
    expect(title).toMatch(/this feature/i)
    expect(title).not.toMatch(/autopilot-chain/i)
  })

  // controls-01 #4 — visual separation between the mainline action
  // group (Start/Pause/Resume), the destructive group (Cancel) and
  // the utility group (Attach + state chip).
  function dividerCount(): number {
    return screen.queryAllByTestId('controls-divider').length
  }

  it('T-2.19: running renders 2 dividers (Pause | Cancel | Attach)', () => {
    setMockState({ state: 'running' })
    renderControls()
    expect(dividerCount()).toBe(2)
  })

  it('T-2.20: paused renders 2 dividers (Resume | Cancel | Attach)', () => {
    setMockState({ state: 'paused' })
    renderControls()
    expect(dividerCount()).toBe(2)
  })

  it('T-2.21: resuming renders 1 divider (Cancel | Attach, no mainline)', () => {
    setMockState({ state: 'resuming' })
    renderControls()
    expect(dividerCount()).toBe(1)
  })

  it.each(['idle', 'starting', 'cancelled', 'completed', 'failed'] as const)(
    'T-2.22: %s renders no dividers (only one group visible)',
    (state) => {
      setMockState({ state })
      renderControls()
      expect(dividerCount()).toBe(0)
    },
  )

  // controls-02 #2 — the wf/Button size=large was overshooting the
  // hierarchy against surrounding 24px chips (40px button vs 24px chip
  // = 67% taller). size=default (32px) preserves visual dominance via
  // the solid signal-blue fill + glyph without occupying a third of
  // the panel width.
  /* T-2.23 (controls-05 #2): idle START renders the wf/Button primary
     at the spec-compliant `md` size (23px tall, 11px font) instead of
     the legacy 32px `default`. The spec
     (`docs/design_handoff_watchfloor_v2/specs/ui-primitives.md` §
     Buttons) defines exactly two sizes — `sm` and `md` — and our
     primary CTA in a panel header is `md`. */
  it('T-2.23: idle START renders the wf/Button primary at size=md (per spec)', () => {
    setMockState({ state: 'idle' })
    renderControls()
    const btn = screen.getByRole('button', { name: /^Start\b/i })
    expect(btn.getAttribute('data-testid')).toBe('wf-button')
    expect(btn.getAttribute('data-variant')).toBe('primary')
    expect(btn.getAttribute('data-size')).toBe('md')
    expect(btn.style.height).toBe('23px')
  })

  // controls-02 #3 — glyph parity. The play glyph on START set the
  // precedent at controls-01 #7; the ancillary actions now follow so
  // operators can disambiguate Pause/Resume/Cancel/Attach at-a-glance
  // without parsing the JetBrains Mono UPPERCASE labels.
  it('T-2.24: running → Pause carries PauseRounded glyph', () => {
    setMockState({ state: 'running' })
    renderControls()
    const btn = screen.getByTestId('pause-button')
    expect(within(btn).getByTestId('PauseRoundedIcon')).toBeInTheDocument()
  })

  it('T-2.25: paused → Resume carries PlayArrowRounded glyph', () => {
    setMockState({ state: 'paused' })
    renderControls()
    const btn = screen.getByRole('button', { name: /^Resume$/i })
    expect(within(btn).getByTestId('PlayArrowRoundedIcon')).toBeInTheDocument()
  })

  it('T-2.26: running → Cancel carries StopRounded glyph', () => {
    setMockState({ state: 'running' })
    renderControls()
    const btn = screen.getByRole('button', { name: /^Cancel$/i })
    expect(within(btn).getByTestId('StopRoundedIcon')).toBeInTheDocument()
  })

  it('T-2.27: running → Attach carries OpenInNewRounded glyph', () => {
    setMockState({ state: 'running' })
    renderControls()
    const btn = screen.getByRole('button', { name: /^Output$/i })
    expect(within(btn).getByTestId('OpenInNewRoundedIcon')).toBeInTheDocument()
  })
})

// =====================================================================
// Group 3 — Pause UX / long-pause UX (R8–R12, PA-3, EC-P1..3)
// =====================================================================

describe('Group 3 — Pause UX', () => {
  function pauseButton(): HTMLButtonElement {
    return screen.getByTestId('pause-button') as HTMLButtonElement
  }

  it('T-3.1: running, isPausing=false → Pause label is "Pause", no secondary label', () => {
    setMockState({ state: 'running', isPausing: false })
    renderControls()
    expect(pauseButton()).toHaveTextContent(/^Pause$/)
    expect(pauseButton()).not.toBeDisabled()
    expect(screen.queryByTestId('pause-secondary-label')).not.toBeInTheDocument()
  })

  it('T-3.2a: Pause button stays mounted across the isPausing flip', () => {
    setMockState({ state: 'running', isPausing: false })
    const { rerender } = renderControls()
    expect(screen.getByTestId('pause-button')).toBeInTheDocument()

    setMockState({ state: 'running', isPausing: true, pauseElapsedSeconds: 0 })
    rerender(
      <ThemeProvider theme={theme}>
        <SessionControls targetKind="autopilot" targetId="demo" onAttach={vi.fn()} />
      </ThemeProvider>,
    )
    expect(screen.getByTestId('pause-button')).toBeInTheDocument()
  })

  it('T-3.2b: Pause button transitions enabled → disabled across the flip', () => {
    setMockState({ state: 'running', isPausing: false })
    const { rerender } = renderControls()
    expect(pauseButton()).not.toBeDisabled()

    setMockState({ state: 'running', isPausing: true, pauseElapsedSeconds: 0 })
    rerender(
      <ThemeProvider theme={theme}>
        <SessionControls targetKind="autopilot" targetId="demo" onAttach={vi.fn()} />
      </ThemeProvider>,
    )
    expect(pauseButton()).toBeDisabled()
  })

  it('T-3.3: isPausing=true, elapsed=0 → label "Pausing… 0:00" and disabled', () => {
    setMockState({ state: 'running', isPausing: true, pauseElapsedSeconds: 0 })
    renderControls()
    expect(pauseButton()).toBeDisabled()
    expect(pauseButton()).toHaveTextContent(/^Pausing… 0:00$/)
  })

  it('T-3.4: isPausing=true → "Waiting for current phase to finish" caption renders', () => {
    setMockState({ state: 'running', isPausing: true, pauseElapsedSeconds: 0 })
    renderControls()
    expect(screen.getByText('Waiting for current phase to finish')).toBeInTheDocument()
  })

  it('T-3.5: pauseElapsedSeconds=5 → "Pausing… 0:05"', () => {
    setMockState({ state: 'running', isPausing: true, pauseElapsedSeconds: 5 })
    renderControls()
    expect(pauseButton()).toHaveTextContent(/^Pausing… 0:05$/)
  })

  it('T-3.6: pauseElapsedSeconds=125 → "Pausing… 2:05"', () => {
    setMockState({ state: 'running', isPausing: true, pauseElapsedSeconds: 125 })
    renderControls()
    expect(pauseButton()).toHaveTextContent(/^Pausing… 2:05$/)
  })

  it('T-3.7: pauseElapsedSeconds=3725 → "Pausing… 1:02:05"', () => {
    setMockState({ state: 'running', isPausing: true, pauseElapsedSeconds: 3725 })
    renderControls()
    expect(pauseButton()).toHaveTextContent(/^Pausing… 1:02:05$/)
  })

  it('T-3.8: click on disabled Pause is a no-op (mutate.pause called once total)', () => {
    const hook = setMockState({ state: 'running', isPausing: false })
    const { rerender } = renderControls()
    fireEvent.click(pauseButton())
    expect(hook.mutate.pause).toHaveBeenCalledTimes(1)

    setMockState({ state: 'running', isPausing: true, pauseElapsedSeconds: 0, mutate: hook.mutate })
    rerender(
      <ThemeProvider theme={theme}>
        <SessionControls targetKind="autopilot" targetId="demo" onAttach={vi.fn()} />
      </ThemeProvider>,
    )
    fireEvent.click(pauseButton())
    expect(hook.mutate.pause).toHaveBeenCalledTimes(1)
  })

  it('T-3.9: SessionControls.tsx contains zero useEffect calls', () => {
    expect(sessionControlsSrc).not.toMatch(/^\s*useEffect\s*\(/m)
  })
})

// =====================================================================
// Group 4 — _formatPauseElapsed pure helper (R9 table)
// =====================================================================

describe('Group 4 — _formatPauseElapsed', () => {
  const f = SessionControlsInternals._formatPauseElapsed

  it.each([
    [0, 'Pausing… 0:00'],
    [5, 'Pausing… 0:05'],
    [59, 'Pausing… 0:59'],
    [60, 'Pausing… 1:00'],
    [65, 'Pausing… 1:05'],
    [3599, 'Pausing… 59:59'],
    [3600, 'Pausing… 1:00:00'],
    [3725, 'Pausing… 1:02:05'],
    [-1, 'Pausing… 0:00'],
  ])('T-4.x: %s → "%s"', (input, expected) => {
    expect(f(input)).toBe(expected)
  })
})

// =====================================================================
// Group 5 — Cancel flow + dialog (R13–R18, PA-2, EC-D1..4, EC-S3)
// =====================================================================

describe('Group 5 — Cancel flow', () => {
  it('T-5.1: Cancel click does NOT call mutate.cancel; opens dialog with title', () => {
    const hook = setMockState({ state: 'running' })
    renderControls()
    fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }))
    expect(hook.mutate.cancel).not.toHaveBeenCalled()
    const dialog = screen.getByRole('dialog')
    expect(dialog).toBeInTheDocument()
    expect(within(dialog).getByText(/Cancel running session\?/)).toBeInTheDocument()
  })

  it('T-5.2: dialog body contains the warning literal', () => {
    renderDialog({ state: 'running' })
    expect(
      screen.getByText(/This will kill the tmux session immediately/),
    ).toBeInTheDocument()
  })

  it('T-5.3: dialog has exactly two action buttons "Keep running" + "Cancel anyway"', () => {
    renderDialog({ state: 'running' })
    const dialog = screen.getByRole('dialog')
    const actionButtons = within(dialog).getAllByRole('button')
    expect(actionButtons).toHaveLength(2)
    expect(within(dialog).getByRole('button', { name: 'Keep running' })).toBeInTheDocument()
    expect(within(dialog).getByRole('button', { name: 'Cancel anyway' })).toBeInTheDocument()
  })

  it('T-5.4: Keep running has autoFocus on dialog open', async () => {
    renderDialog({ state: 'running' })
    await waitFor(() => {
      const keep = screen.getByRole('button', { name: 'Keep running' })
      expect(document.activeElement).toBe(keep)
    })
  })

  it('T-5.5: Cancel anyway has aria-describedby pointing to the warning Typography id', () => {
    renderDialog({ state: 'running' })
    const button = screen.getByRole('button', { name: 'Cancel anyway' })
    const describedBy = button.getAttribute('aria-describedby')
    expect(describedBy).not.toBeNull()
    const warning = screen.getByText(/This will kill the tmux session immediately/)
    expect(warning.id).toBe(describedBy)
  })

  it('T-5.6: Keep running closes the dialog and does not call mutate.cancel', async () => {
    const hook = setMockState({ state: 'running' })
    renderControls()
    fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }))
    expect(screen.getByRole('dialog')).toBeInTheDocument()

    fireEvent.click(screen.getByRole('button', { name: 'Keep running' }))
    await waitFor(() => {
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    })
    expect(hook.mutate.cancel).not.toHaveBeenCalled()
  })

  it('T-5.7 + T-5.9: Cancel anyway awaits server, shows "Cancelling…", then closes', async () => {
    let resolveCancel!: () => void
    const cancelPromise = new Promise<void>((r) => {
      resolveCancel = r
    })
    const mutate = makeMutate()
    ;(mutate.cancel as ReturnType<typeof vi.fn>).mockReturnValue(cancelPromise)
    setMockState({ state: 'running', mutate })

    renderControls()
    fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }))
    fireEvent.click(screen.getByRole('button', { name: 'Cancel anyway' }))

    await waitFor(() => {
      const button = screen.getByRole('button', { name: /Cancelling/ })
      expect(button).toBeDisabled()
      expect(button).toHaveTextContent('Cancelling…')
    })
    expect(mutate.cancel).toHaveBeenCalledTimes(1)

    resolveCancel()
    await waitFor(() => {
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    })
  })

  it('T-5.8: while isCancelling=true → Keep running is also disabled', () => {
    renderDialog({ state: 'running', isCancelling: true })
    expect(screen.getByRole('button', { name: 'Keep running' })).toBeDisabled()
    expect(screen.getByRole('button', { name: /Cancelling/ })).toBeDisabled()
  })

  it('T-5.10: ESC during isCancelling=true does NOT close the dialog', () => {
    const onClose = vi.fn()
    renderDialog({ state: 'running', isCancelling: true, onClose })
    fireEvent.keyDown(screen.getByRole('dialog'), { key: 'Escape', code: 'Escape' })
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('dialog')).toBeInTheDocument()
  })

  it('T-5.11: backdrop click during isCancelling=true does NOT close the dialog', () => {
    const onClose = vi.fn()
    const { baseElement } = renderDialog({ state: 'running', isCancelling: true, onClose })
    const backdrop = baseElement.querySelector('.MuiBackdrop-root') as HTMLElement
    expect(backdrop).not.toBeNull()
    fireEvent.click(backdrop)
    expect(onClose).not.toHaveBeenCalled()
    expect(screen.getByRole('dialog')).toBeInTheDocument()
  })

  it('T-5.12: ESC after isCancelling resolves → dialog closes via parent', async () => {
    let resolveCancel!: () => void
    const cancelPromise = new Promise<void>((r) => {
      resolveCancel = r
    })
    const mutate = makeMutate()
    ;(mutate.cancel as ReturnType<typeof vi.fn>).mockReturnValue(cancelPromise)
    setMockState({ state: 'running', mutate })

    renderControls()
    fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }))
    fireEvent.click(screen.getByRole('button', { name: 'Cancel anyway' }))
    resolveCancel()

    await waitFor(() => {
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    })
  })

  it('T-5.13: dialog title is "Cancel paused session?" when state=paused', () => {
    renderDialog({ state: 'paused' })
    const dialog = screen.getByRole('dialog')
    expect(within(dialog).getByText('Cancel paused session?')).toBeInTheDocument()
  })

  it('T-5.14b: errorPrimary prop renders an inline Alert ABOVE the action row (R16 step 4)', () => {
    renderDialog({
      state: 'running',
      errorPrimary: 'tmux subsystem error',
      errorSecondary: null,
    })
    const dialog = screen.getByRole('dialog')
    const alert = within(dialog).getByRole('alert')
    expect(alert).toHaveTextContent('tmux subsystem error')
  })

  it('T-5.14c: errorSecondary renders a caption sub-line inside the dialog Alert', () => {
    renderDialog({
      state: 'running',
      errorPrimary: 'Resume stream unavailable',
      errorSecondary: 'fall back to terminal --from <phase>',
    })
    const dialog = screen.getByRole('dialog')
    const alert = within(dialog).getByRole('alert')
    expect(alert).toHaveTextContent('Resume stream unavailable')
    expect(alert).toHaveTextContent('fall back to terminal --from <phase>')
  })

  it('T-5.14: mutate.cancel rejects → isCancelling clears, dialog stays open, outer Alert renders', async () => {
    let rejectCancel!: (e: unknown) => void
    const cancelPromise = new Promise<void>((_, rj) => {
      rejectCancel = rj
    })
    const mutate = makeMutate()
    ;(mutate.cancel as ReturnType<typeof vi.fn>).mockImplementation(() => cancelPromise)
    setMockState({ state: 'running', mutate })

    renderControls()
    fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }))
    fireEvent.click(screen.getByRole('button', { name: 'Cancel anyway' }))

    setMockState({
      state: 'running',
      mutate,
      error: { slug: 'tmux_error', status: 500, message: 'tmux subsystem error' },
    })
    await act(async () => {
      rejectCancel(new Error('rejected'))
      await cancelPromise.catch(() => {})
    })

    await waitFor(() => {
      expect(screen.getByRole('button', { name: 'Cancel anyway' })).toBeInTheDocument()
    })
    const dialog = screen.getByRole('dialog')
    expect(dialog).toBeInTheDocument()
    // R16 step 4 redundancy: the inline Alert lives inside the dialog
    // body so the operator sees the error without dismissing. The outer
    // Alert exists too but is hidden by MUI's aria-hidden on dialog
    // siblings — assert via getAllByRole including hidden nodes.
    await waitFor(() => {
      expect(within(dialog).getByRole('alert')).toHaveTextContent(/tmux subsystem error/)
    })
    const allAlerts = screen.getAllByRole('alert', { hidden: true })
    expect(allAlerts.length).toBeGreaterThanOrEqual(2)
  })

  it('T-5.15: after rejection, "Keep running" is re-enabled and dismisses the dialog (EC-D1, EC-D3)', async () => {
    let rejectCancel!: (e: unknown) => void
    const cancelPromise = new Promise<void>((_, rj) => {
      rejectCancel = rj
    })
    const mutate = makeMutate()
    ;(mutate.cancel as ReturnType<typeof vi.fn>).mockImplementation(() => cancelPromise)
    setMockState({ state: 'running', mutate })

    renderControls()
    fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }))
    fireEvent.click(screen.getByRole('button', { name: 'Cancel anyway' }))

    setMockState({
      state: 'running',
      mutate,
      error: { slug: 'tmux_error', status: 500, message: 'tmux subsystem error' },
    })
    await act(async () => {
      rejectCancel(new Error('rejected'))
      await cancelPromise.catch(() => {})
    })

    await waitFor(() => {
      expect(screen.getByRole('button', { name: 'Keep running' })).not.toBeDisabled()
    })
    fireEvent.click(screen.getByRole('button', { name: 'Keep running' }))
    await waitFor(() => {
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    })
  })

  it('T-5.16: dialog renders zero DOM when open=false', () => {
    renderDialog({ open: false })
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  it('T-5.17: when state externally transitions to cancelled mid-cancel, dialog closes and Cancel button disappears (EC-S3)', async () => {
    let resolveCancel!: () => void
    const cancelPromise = new Promise<void>((r) => {
      resolveCancel = r
    })
    const mutate = makeMutate()
    ;(mutate.cancel as ReturnType<typeof vi.fn>).mockReturnValue(cancelPromise)
    setMockState({ state: 'running', mutate })

    renderControls()
    fireEvent.click(screen.getByRole('button', { name: /^cancel$/i }))
    fireEvent.click(screen.getByRole('button', { name: 'Cancel anyway' }))

    // External cancellation (e.g., another tab) — hook reports cancelled
    // and mutate.cancel resolves on idempotent server response.
    setMockState({ state: 'cancelled', mutate })
    await act(async () => {
      resolveCancel()
      await cancelPromise
    })

    await waitFor(() => {
      expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
    })
    expect(screen.queryByRole('button', { name: /^cancel$/i })).not.toBeInTheDocument()
  })
})

// =====================================================================
// Group 6 — Attach button (R19)
// =====================================================================

describe('Group 6 — Attach button', () => {
  it('T-6.1: clicking Attach calls onAttach exactly once with no args', () => {
    setMockState({ state: 'running' })
    const onAttach = vi.fn()
    renderControls({ onAttach })
    fireEvent.click(screen.getByRole('button', { name: /^output$/i }))
    expect(onAttach).toHaveBeenCalledTimes(1)
    expect(onAttach).toHaveBeenLastCalledWith()
  })

  it('T-6.2: Attach click does not invoke any hook mutation', () => {
    const hook = setMockState({ state: 'running' })
    renderControls()
    fireEvent.click(screen.getByRole('button', { name: /^output$/i }))
    expect(hook.mutate.start).not.toHaveBeenCalled()
    expect(hook.mutate.pause).not.toHaveBeenCalled()
    expect(hook.mutate.resume).not.toHaveBeenCalled()
    expect(hook.mutate.cancel).not.toHaveBeenCalled()
  })

  // controls-03 #9 — toggle UX. The attach button is a single
  // operator-controlled toggle. When attached=false (default), label
  // is "Attach" + OpenInNewRoundedIcon. When attached=true, label is
  // "Detach" + CloseRoundedIcon. The parent interprets onAttach as
  // "toggle" — the primitive stays SRP-pure (one callback, one
  // button, two presentations).
  it('T-6.3: attached=false (default) → label "Attach" + OpenInNewRoundedIcon', () => {
    setMockState({ state: 'running' })
    renderControls()
    const btn = screen.getByRole('button', { name: /^Output$/i })
    expect(btn).toBeInTheDocument()
    expect(within(btn).getByTestId('OpenInNewRoundedIcon')).toBeInTheDocument()
    expect(within(btn).queryByTestId('CloseRoundedIcon')).not.toBeInTheDocument()
  })

  it('T-6.4: attached=true → label "Detach" + CloseRoundedIcon', () => {
    setMockState({ state: 'running' })
    renderControls({ attached: true })
    const btn = screen.getByRole('button', { name: /^Hide$/i })
    expect(btn).toBeInTheDocument()
    expect(within(btn).getByTestId('CloseRoundedIcon')).toBeInTheDocument()
    expect(within(btn).queryByTestId('OpenInNewRoundedIcon')).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^Output$/i })).not.toBeInTheDocument()
  })

  it('T-6.5: attached=true → click still invokes onAttach (parent toggles)', () => {
    setMockState({ state: 'running' })
    const onAttach = vi.fn()
    renderControls({ attached: true, onAttach })
    fireEvent.click(screen.getByRole('button', { name: /^Hide$/i }))
    expect(onAttach).toHaveBeenCalledTimes(1)
    expect(onAttach).toHaveBeenLastCalledWith()
  })
})

// =====================================================================
// Group 6b — hideStateChip opt-out (R20 anti-duplicate contract)
// =====================================================================

describe('Group 6b — hideStateChip opt-out', () => {
  it('T-A2b.1: renders exactly one SessionStateChip when hideStateChip is omitted', () => {
    setMockState({ state: 'running' })
    renderControls()
    expect(screen.getAllByTestId('session-state-chip')).toHaveLength(1)
  })

  it('T-A2b.2: renders zero SessionStateChip when hideStateChip is true', () => {
    setMockState({ state: 'running' })
    render(
      <ThemeProvider theme={theme}>
        <SessionControls
          targetKind="autopilot"
          targetId="demo"
          onAttach={vi.fn()}
          hideStateChip
        />
      </ThemeProvider>,
    )
    expect(screen.queryAllByTestId('session-state-chip')).toHaveLength(0)
  })

  it('T-A2b.3: hideStateChip preserves button visibility and mutation handlers', () => {
    const hook = setMockState({ state: 'running' })
    render(
      <ThemeProvider theme={theme}>
        <SessionControls
          targetKind="autopilot"
          targetId="demo"
          onAttach={vi.fn()}
          hideStateChip
        />
      </ThemeProvider>,
    )
    expect(screen.getByRole('button', { name: /^pause$/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^cancel$/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^output$/i })).toBeInTheDocument()
    fireEvent.click(screen.getByRole('button', { name: /^pause$/i }))
    expect(hook.mutate.pause).toHaveBeenCalledTimes(1)
  })
})

// =====================================================================
// Group 7 — Inline Alert (R20–R24, PA-4, EC-A1..3)
// =====================================================================

describe('Group 7 — inline Alert', () => {
  function err(overrides: Partial<ControlError>): ControlError {
    return {
      slug: 'http',
      status: 500,
      message: 'oh no',
      ...overrides,
    }
  }

  it('T-7.1: error renders Alert with primary message text', () => {
    setMockState({
      state: 'running',
      error: err({ slug: 'already_running', status: 409, message: 'Session is already running' }),
    })
    renderControls()
    expect(screen.getByRole('alert')).toHaveTextContent(/Session is already running/)
  })

  it('T-7.2: never renders a Snackbar surface', () => {
    setMockState({
      state: 'running',
      error: err({ slug: 'already_running', status: 409, message: 'x' }),
    })
    const { baseElement } = renderControls()
    expect(baseElement.querySelector('.MuiSnackbar-root')).toBeNull()
  })

  it('T-7.3: error.hint renders a secondary caption line', () => {
    setMockState({
      state: 'running',
      error: err({
        slug: 'stream_unavailable',
        status: 422,
        message: 'Resume stream unavailable',
        hint: 'fall back to terminal --from <phase>',
      }),
    })
    renderControls()
    const alert = screen.getByRole('alert')
    expect(alert).toHaveTextContent(/fall back to terminal --from <phase>/)
  })

  it('T-7.4: retryAfterSeconds=30 → primary text contains "retry in 30s"', () => {
    setMockState({
      state: 'running',
      error: err({
        slug: 'concurrent_cap_reached',
        status: 429,
        message: 'Concurrent autopilot cap reached',
        retryAfterSeconds: 30,
      }),
    })
    renderControls()
    expect(screen.getByRole('alert')).toHaveTextContent(/retry in 30s/)
  })

  it('T-7.5: no retryAfterSeconds → no "retry in" suffix', () => {
    setMockState({
      state: 'running',
      error: err({ slug: 'http', status: 500, message: 'Boom' }),
    })
    renderControls()
    expect(screen.getByRole('alert')).not.toHaveTextContent(/retry in/)
  })

  it('T-7.6: csrf slug with hint → SessionControls passes the hint through (controls-07 #3)', () => {
    setMockState({
      state: 'running',
      error: err({
        slug: 'csrf',
        status: 0,
        message: 'CSRF token unavailable',
        hint: 'Open browser DevTools → Console for csrfToken: diagnostics.',
      }),
    })
    renderControls()
    const alert = screen.getByRole('alert')
    /* controls-07 #3 — the hook now attaches a diagnostic hint on
       the client-side csrf-null path; this assertion enforces that
       SessionControls passes it through verbatim instead of
       overriding with the old "Reload the page" misdirection
       (which was misleading because the body-token fallback runs
       fresh on every click). */
    expect(alert).toHaveTextContent(/Open browser DevTools/)
    expect(alert).not.toHaveTextContent(/refresh your session token/)
  })

  it('T-7.6b: csrf slug WITHOUT hint → falls back to default secondary copy (controls-07 #3)', () => {
    setMockState({
      state: 'running',
      error: err({
        slug: 'csrf',
        status: 403,
        message: 'CSRF token unavailable',
      }),
    })
    renderControls()
    expect(screen.getByRole('alert')).toHaveTextContent(
      /The session token did not match\. Reload the page to issue a fresh pair\./,
    )
  })

  it('T-7.7: error=null → no Alert in DOM', () => {
    setMockState({ state: 'running', error: null })
    renderControls()
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('T-7.8: when hook clears error after a mutation, Alert unmounts', () => {
    const hook = setMockState({
      state: 'running',
      error: err({ slug: 'http', status: 500, message: 'oops' }),
    })
    const { rerender } = renderControls()
    expect(screen.getByRole('alert')).toBeInTheDocument()

    setMockState({ state: 'running', error: null, mutate: hook.mutate })
    rerender(
      <ThemeProvider theme={theme}>
        <SessionControls targetKind="autopilot" targetId="demo" onAttach={vi.fn()} />
      </ThemeProvider>,
    )
    expect(screen.queryByRole('alert')).not.toBeInTheDocument()
  })

  it('T-7.9: MUI Alert with severity="error" exposes role="alert" implicitly', () => {
    setMockState({
      state: 'running',
      error: err({ slug: 'http', status: 500, message: 'err' }),
    })
    renderControls()
    expect(screen.getByRole('alert')).toBeInTheDocument()
  })
})

// =====================================================================
// Group 8 — SessionStateChip (R25–R30, PA-5, EC-C1..3)
// =====================================================================

describe('Group 8 — SessionStateChip', () => {
  it('T-8.1: outer container has aria-live=polite and aria-atomic=true', () => {
    renderChip('running', false)
    const chip = screen.getByTestId('session-state-chip')
    expect(chip.getAttribute('aria-live')).toBe('polite')
    expect(chip.getAttribute('aria-atomic')).toBe('true')
  })

  it('T-8.2: running, isPausing=false → label is "Running"', () => {
    renderChip('running', false)
    expect(screen.getByText('Running')).toBeInTheDocument()
  })

  it.each([
    ['idle', 'Idle'],
    ['starting', 'Starting'],
    ['running', 'Running'],
    ['paused', 'Paused'],
    ['resuming', 'Resuming'],
    ['cancelled', 'Cancelled'],
    ['completed', 'Completed'],
    ['failed', 'Failed'],
  ] as Array<[SessionUIState, string]>)(
    'T-8.3: state=%s → label "%s"',
    (state, label) => {
      renderChip(state, false)
      expect(screen.getByText(label)).toBeInTheDocument()
    },
  )

  it('T-8.4: running + isPausing=true → label is "Pausing…"', () => {
    renderChip('running', true)
    expect(screen.getByText('Pausing…')).toBeInTheDocument()
    expect(screen.queryByText('Running')).not.toBeInTheDocument()
  })

  it('T-8.5: cancelled + isPausing=true → label remains "Cancelled"', () => {
    renderChip('cancelled', true)
    expect(screen.getByText('Cancelled')).toBeInTheDocument()
    expect(screen.queryByText('Pausing…')).not.toBeInTheDocument()
  })

  it('T-8.6: rerender across states preserves chip outer DOM node identity', () => {
    const { rerender } = renderChip('running', false)
    const node = screen.getByTestId('session-state-chip')
    for (const s of ['paused', 'running', 'cancelled', 'completed', 'failed'] as const) {
      rerender(
        <ThemeProvider theme={theme}>
          <SessionStateChip state={s} isPausing={false} />
        </ThemeProvider>,
      )
      expect(screen.getByTestId('session-state-chip')).toBe(node)
    }
  })

  it('T-8.7: aria-live + aria-atomic persist across rerenders', () => {
    const { rerender } = renderChip('running', false)
    for (const s of ['paused', 'running', 'cancelled'] as const) {
      rerender(
        <ThemeProvider theme={theme}>
          <SessionStateChip state={s} isPausing={false} />
        </ThemeProvider>,
      )
      const chip = screen.getByTestId('session-state-chip')
      expect(chip.getAttribute('aria-live')).toBe('polite')
      expect(chip.getAttribute('aria-atomic')).toBe('true')
    }
  })

  it('T-8.8: SessionStateChip.tsx imports StatusPill from ./wf/StatusPill', () => {
    expect(sessionStateChipSrc).toMatch(
      /^\s*import\s+StatusPill\s+from\s+['"]\.\/wf\/StatusPill['"]/m,
    )
  })

  it('T-8.9: chip outer Box has inline style "min-width: 88px"', () => {
    renderChip('running', false)
    const chip = screen.getByTestId('session-state-chip')
    const styleAttr = chip.getAttribute('style') ?? ''
    expect(styleAttr).toMatch(/min-width:\s*88px/)
  })

  it('T-8.10: StatusPill data-status maps 8 SessionUIStates to 5 WfStatus + muted', () => {
    const expected: Record<SessionUIState, string> = {
      idle: 'muted',
      starting: 'queued',
      running: 'running',
      paused: 'queued',
      resuming: 'queued',
      cancelled: 'fault',
      completed: 'completed',
      failed: 'fault',
    }
    for (const [state, status] of Object.entries(expected) as Array<[SessionUIState, string]>) {
      const { unmount } = renderChip(state, false)
      const pill = screen.getByTestId('wf-status-pill')
      expect(pill.getAttribute('data-status')).toBe(status)
      unmount()
    }
  })

  it('T-8.11: SessionStateChip.tsx contains zero useEffect / useState calls', () => {
    expect(sessionStateChipSrc).not.toMatch(/^\s*useEffect\s*\(/m)
    expect(sessionStateChipSrc).not.toMatch(/^\s*useState\s*[(<]/m)
  })

  it('T-8.12: SessionStateChip.tsx does NOT runtime-import useSessionControls', () => {
    expect(sessionStateChipSrc).not.toMatch(
      /^\s*import\s+(?!type\b)[^;\n]*\buseSessionControls\b/m,
    )
  })
})

// =====================================================================
// Group 9 — Cross-cutting purity guards (R-EXT-1..4)
// =====================================================================

describe('Group 9 — cross-cutting guards', () => {
  it('T-9.3: no hex color literals in any of the three .tsx files', () => {
    for (const src of [sessionControlsSrc, cancelDialogSrc, sessionStateChipSrc]) {
      expect(src).not.toMatch(/#[0-9A-Fa-f]{3,8}\b/)
    }
  })

  it('T-9.4: CancelConfirmDialog and SessionStateChip do NOT runtime-import useSessionControls', () => {
    expect(cancelDialogSrc).not.toMatch(
      /^\s*import\s+(?!type\b)[^;\n]*\buseSessionControls\b/m,
    )
    expect(sessionStateChipSrc).not.toMatch(
      /^\s*import\s+(?!type\b)[^;\n]*\buseSessionControls\b/m,
    )
  })

  it('T-9.5: react-hooks/exhaustive-deps is NOT silenced anywhere', () => {
    for (const src of [sessionControlsSrc, cancelDialogSrc, sessionStateChipSrc]) {
      expect(src).not.toMatch(/eslint-disable[^\n]*\bexhaustive-deps\b/)
    }
  })
})

// =====================================================================
// Group 10 — density='header' compact rendering (controls-04 #3)
// =====================================================================
//
// Convergent industry pattern (Vercel project header, Render service
// header, GitHub Actions workflow header, AWS CodePipeline, Linear
// project header): ONE visible primary CTA + a `⋯` overflow icon-button
// that opens a Menu for every secondary verb. The `density` prop is the
// switch — default 'panel' preserves the existing inline rendering for
// detail-surface mounts; 'header' is the compact treatment for plan
// rows, feature cards, and other dense list/header surfaces.
//
// The state-machine (button visibility table, cancel-confirm flow,
// optimistic pause/resume) is identical — only the rendering layer
// changes. Cancel still routes through CancelConfirmDialog.

describe("Group 10 — density='header' compact rendering (controls-06 #3)", () => {
  /* Cycle-6 #3 rewired density='header' from a kebab-overflow Menu
     into inline Pause / Cancel / Attach `sm` wf/Button rendering.
     Industry survey (Vercel / GitHub Actions / Render / Linear /
     Stripe / Heroku / AWS CodePipeline — 7/7) places state-machine
     verbs inline on row-level controls; kebabs hold low-frequency
     navigation. Cycle-4 #3 / cycle-5 inverted that pattern; this
     cycle restores convergent practice.
     Most T-10.* tests below are rewritten in place — same number,
     same intent, new expectation (inline, no menu). T-10.2 and
     T-10.16 are deleted because the menu and the overflow Tooltip
     they pinned no longer exist. */

  /* T-10.1: running state surfaces Pause + Cancel + Attach as
     inline `sm` buttons; no overflow IconButton mounted. */
  it("T-10.1: density='header' + running → inline Pause / Cancel / Attach buttons", () => {
    setMockState({ state: 'running', tmuxSession: 'autopilot-demo' })
    renderControls({ density: 'header' })
    expect(screen.getByRole('button', { name: /^Pause$/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^Cancel$/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^Output$/i })).toBeInTheDocument()
    expect(screen.queryByTestId('session-controls-overflow')).not.toBeInTheDocument()
  })

  /* T-10.3: paused state surfaces Resume primary + Cancel + Attach. */
  it("T-10.3: density='header' + paused → inline Resume / Cancel / Attach", () => {
    setMockState({ state: 'paused', tmuxSession: 'autopilot-demo' })
    renderControls({ density: 'header' })
    expect(screen.getByRole('button', { name: /^Resume$/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^Cancel$/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^Output$/i })).toBeInTheDocument()
    expect(screen.queryByTestId('session-controls-overflow')).not.toBeInTheDocument()
  })

  /* T-10.4: idle — only Start. */
  it("T-10.4: density='header' + idle → Start visible, no overflow icon", () => {
    setMockState({ state: 'idle' })
    renderControls({ density: 'header' })
    expect(screen.getByRole('button', { name: /^Start autopilot$/i })).toBeInTheDocument()
    expect(screen.queryByTestId('session-controls-overflow')).not.toBeInTheDocument()
  })

  /* T-10.5: terminal → Restart. */
  it("T-10.5: density='header' + completed → Restart visible, no overflow icon", () => {
    setMockState({ state: 'completed' })
    renderControls({ density: 'header' })
    expect(screen.getByRole('button', { name: /^Restart autopilot$/i })).toBeInTheDocument()
    expect(screen.queryByTestId('session-controls-overflow')).not.toBeInTheDocument()
  })

  /* T-10.6: inline Cancel button opens the CancelConfirmDialog;
     mutate.cancel stays uncalled until the operator confirms. */
  it("T-10.6: density='header' Cancel button opens CancelConfirmDialog", () => {
    const state = setMockState({ state: 'running', tmuxSession: 'autopilot-demo' })
    renderControls({ density: 'header' })
    fireEvent.click(screen.getByRole('button', { name: /^Cancel$/i }))
    expect(screen.getByRole('dialog')).toBeInTheDocument()
    expect(state.mutate.cancel).not.toHaveBeenCalled()
  })

  /* T-10.7: inline Pause button invokes mutate.pause once. */
  it("T-10.7: density='header' Pause button invokes mutate.pause once", () => {
    const state = setMockState({ state: 'running', tmuxSession: 'autopilot-demo' })
    renderControls({ density: 'header' })
    fireEvent.click(screen.getByRole('button', { name: /^Pause$/i }))
    expect(state.mutate.pause).toHaveBeenCalledTimes(1)
  })

  /* T-10.8: inline Attach invokes onAttach; relabels to Detach
     when attached=true. */
  it("T-10.8: density='header' Attach button invokes onAttach; attached=true relabels to Detach", () => {
    setMockState({ state: 'running', tmuxSession: 'autopilot-demo' })
    const onAttach = vi.fn()
    const { rerender } = renderControls({ density: 'header', onAttach })
    fireEvent.click(screen.getByRole('button', { name: /^Output$/i }))
    expect(onAttach).toHaveBeenCalledTimes(1)

    rerender(
      <ThemeProvider theme={theme}>
        <SessionControls
          targetKind="autopilot"
          targetId="demo"
          onAttach={onAttach}
          density="header"
          attached
        />
      </ThemeProvider>,
    )
    expect(screen.getByRole('button', { name: /^Hide$/i })).toBeInTheDocument()
  })

  /* T-10.9: inline Pause is disabled with elapsed label when
     isPausing. */
  it("T-10.9: density='header' + isPausing → inline Pause button disabled with elapsed label", () => {
    setMockState({
      state: 'running',
      tmuxSession: 'autopilot-demo',
      isPausing: true,
      pauseElapsedSeconds: 42,
    })
    renderControls({ density: 'header' })
    const pause = screen.getByRole('button', { name: /Pausing…\s*0:42/ })
    expect(pause).toBeDisabled()
  })

  /* T-10.10: no controls-divider nodes. */
  it("T-10.10: density='header' renders no controls-divider nodes", () => {
    setMockState({ state: 'running', tmuxSession: 'autopilot-demo' })
    renderControls({ density: 'header' })
    expect(screen.queryAllByTestId('controls-divider')).toHaveLength(0)
  })

  /* T-10.11: density default is 'panel'. */
  it("T-10.11: density default is 'panel' (existing inline MUI Button rendering)", () => {
    setMockState({ state: 'running', tmuxSession: 'autopilot-demo' })
    renderControls()
    expect(screen.getByTestId('pause-button')).toBeInTheDocument()
    expect(screen.queryByTestId('session-controls-overflow')).not.toBeInTheDocument()
  })

  /* T-10.12 (controls-06 #4): stale lifecycle → single inline
     "Restart {target}" primary CTA with PlayArrowRounded icon.
     No Pause/Cancel/Attach (session is dead — nothing to act on
     except recover). Cycle 6 #4 renames the cycle-5 #4 verb
     ("Clear stale state") to match the operator's mental model
     — the chain stopped, start it again. The atomic handler
     calls mutate.cancel then mutate.start so the operator
     experiences a single "restart" rather than the cycle-4
     two-step (Clear stale state → Start). */
  it("T-10.12: density='header' + running + tmuxSession=null → single inline Restart button", () => {
    setMockState({ state: 'running', tmuxSession: null, isStale: true })
    renderControls({ density: 'header', targetKind: 'chain' })
    expect(screen.getByRole('button', { name: /^Restart chain$/i })).toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^Pause$/i })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^Cancel$/i })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^Output$/i })).not.toBeInTheDocument()
    expect(screen.queryByRole('button', { name: /^Clear stale state$/i })).not.toBeInTheDocument()
  })

  /* T-10.13: healthy running (tmuxSession populated) renders the
     full inline trio. */
  it("T-10.13: density='header' + running + tmuxSession populated → inline Pause / Cancel / Attach", () => {
    setMockState({ state: 'running', tmuxSession: 'autopilot-demo' })
    renderControls({ density: 'header' })
    expect(screen.getByRole('button', { name: /^Pause$/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^Cancel$/i })).toBeInTheDocument()
    expect(screen.getByRole('button', { name: /^Output$/i })).toBeInTheDocument()
  })

  /* T-10.14 (controls-06 #4, controls-07 #4): inline Restart click
     invokes mutate.restart() — the operator perceives a single
     "restart" action, the hook bundles cancel-then-start so the
     server emits the missing terminal lifecycle event before the
     new chain spawns, and the start leg bypasses the _isAllowed
     guard that otherwise races against SWR revalidation. No
     destructive-confirm dialog (no active work to lose). */
  it("T-10.14: density='header' Restart button calls mutate.restart (controls-07 #4)", async () => {
    const state = setMockState({ state: 'running', tmuxSession: null, isStale: true })
    renderControls({ density: 'header', targetKind: 'chain' })
    fireEvent.click(screen.getByRole('button', { name: /^Restart chain$/i }))
    await waitFor(() => {
      expect(state.mutate.restart).toHaveBeenCalledTimes(1)
    })
    /* The old chain (`mutate.cancel` then `mutate.start`) is gone;
       the hook owns the atomicity now. Asserting the component does
       NOT call either of them directly catches a regression where a
       future edit reintroduces the racy pattern. */
    expect(state.mutate.cancel).not.toHaveBeenCalled()
    expect(state.mutate.start).not.toHaveBeenCalled()
    expect(screen.queryByRole('dialog')).not.toBeInTheDocument()
  })

  /* T-10.15 (controls-05 #3 — preserved): the inline stale caption
     stays out of SessionControls; the parent ProjectPanel owns
     stale chrome until cycle-6 #5 removes it. */
  it("T-10.15: density='header' stale state renders NO inline caption inside SessionControls", () => {
    setMockState({ state: 'running', tmuxSession: null, isStale: true })
    renderControls({ density: 'header' })
    expect(screen.queryByTestId('stale-lifecycle-caption')).not.toBeInTheDocument()
  })
})
