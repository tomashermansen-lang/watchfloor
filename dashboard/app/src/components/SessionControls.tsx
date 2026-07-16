// Watchfloor session controls panel — the operator's only entry
// point for starting / pausing / resuming / cancelling / attaching to
// a dashboard-launched autopilot or chain session. Calls
// useSessionControls exactly once (R2, plan constraint #5); the
// sibling components (CancelConfirmDialog, SessionStateChip) are
// pure presentation and receive props.
//
// State the component owns: cancel-dialog open + cancel-in-flight
// flags. Everything else (state, isPausing, error, mutations) flows
// from the hook. No useEffect — the hook owns transitions and timers
// (see DN-13 in the plan and useSessionControls.ts:444-end).

import type { JSX } from 'react'
import { useState } from 'react'
import Alert from '@mui/material/Alert'
import Box from '@mui/material/Box'
import Button from '@mui/material/Button'
import Divider from '@mui/material/Divider'
import Stack from '@mui/material/Stack'
import Typography from '@mui/material/Typography'
import PlayArrowRoundedIcon from '@mui/icons-material/PlayArrowRounded'
import PauseRoundedIcon from '@mui/icons-material/PauseRounded'
import StopRoundedIcon from '@mui/icons-material/StopRounded'
import OpenInNewRoundedIcon from '@mui/icons-material/OpenInNewRounded'
import CloseRoundedIcon from '@mui/icons-material/CloseRounded'
import WfButton from './wf/Button'
import { useSessionControls } from '../hooks/useSessionControls'
import type {
  SessionUIState,
  ControlError,
} from '../hooks/useSessionControls'
import { CancelConfirmDialog } from './CancelConfirmDialog'
import { SessionStateChip } from './SessionStateChip'

export interface SessionControlsProps {
  targetKind: 'autopilot' | 'chain'
  targetId: string | null
  onAttach: () => void
  // R20 anti-duplicate opt-out: suppress the SessionStateChip rendered
  // inside the action stack when the host already renders its own
  // chip (e.g. SessionPanel DetailHeader trailing slot).
  hideStateChip?: boolean
  // controls-01 #6 — contextual suffix for the primary action label.
  // 'light' / 'full' render "Start autopilot · light/full"; 'manual'
  // or omitted collapse to bare "Start autopilot" so the operator at
  // least knows what subsystem the click drives.
  autopilotMode?: 'light' | 'full' | 'manual'
  // controls-03 #9 — toggle the Attach button into a Detach button
  // when the parent already shows the terminal panel. The parent
  // interprets onAttach as "toggle" — the primitive stays SRP-pure
  // (one callback, one button, two presentations driven by one prop).
  // SessionPanel does not pass this (autopilot path unchanged);
  // ProjectPanel passes the local isTerminalOpen state.
  attached?: boolean
  // controls-04 #3 / controls-06 #3 — rendering density. 'panel'
  // (default) is the verbose inline row of MUI Buttons + hairline
  // dividers used by dedicated detail surfaces (SessionPanel).
  // 'header' is the compact treatment for plan rows, feature cards,
  // and any list/header surface where the action surface shares
  // chrome with a plan name, StatusPill, and progress band. Compact
  // density surfaces Pause / Cancel / Attach as inline `sm` wf/Button
  // affordances per the industry-convergent pattern (Vercel / GitHub
  // Actions / Render / Linear / Stripe / Heroku / AWS CodePipeline,
  // 7/7 surveyed) — state-machine verbs are visible, not hidden
  // behind a kebab. Cycle 4/5's `⋯` overflow Menu was inverted by
  // cycle 6 #3 to restore convergent practice. The state machine
  // (button-visibility table, cancel-confirm flow, optimistic
  // pause/resume) is identical across both densities — only the
  // rendering layer changes.
  density?: 'panel' | 'header'
  // controls-06 #14 — suppress the Output (formerly Attach) button.
  // Used by the per-project Pipeline subview, which IS the
  // destination of the navigate-on-Output click; offering an Output
  // button there would be a no-op self-link. Defaults to false so
  // the Plans-tab row + autopilot detail surfaces keep their
  // affordance.
  hideOutputButton?: boolean
}

// === Module-private constants (R-EXT-4) =============================

const _PAUSE_SECONDARY_LABEL = 'Waiting for current phase to finish'
/* controls-07 #3 — fallback secondary text when the csrf error
   reaches this component without a hint attached. The hook attaches
   a diagnostic hint on the client-side null-token path; this
   fallback covers server-403 cases where the cookie/header pair
   mismatched (rare — typically a true tab-stale state where the
   browser's cookie diverged from what the hook just resolved). */
const _CSRF_DEFAULT_HINT =
  'The session token did not match. Reload the page to issue a fresh pair.'

const _LABEL_PAUSE = 'Pause'
const _LABEL_RESUME = 'Resume'
const _LABEL_CANCEL = 'Cancel'
// controls-06 #14 — renamed from cycle-3 "Attach" / "Detach".
// Research (GitHub Actions, Vercel, Render, Heroku, Buildkite,
// Datadog, Linear, K8s dashboards) converges on "Output" / "Logs"
// for the affordance that surfaces a process's live stdout —
// "Attach" is tmux jargon operators don't carry into a web UI.
// "Hide" is the inverse for the toggle path; navigation-style
// mounts (Plans-tab row) never reach the Hide branch because the
// click navigates away.
const _LABEL_ATTACH = 'Output'
const _LABEL_DETACH = 'Hide'
// controls-06 #3 / #4 — stale-lifecycle recovery is an inline
// "Restart {target}" wf/Button. The action is atomic from the
// operator's POV (one click) but routes through mutate.cancel
// then mutate.start under the hood so the server records the
// missing terminal lifecycle event before the new chain spawns.
// Labelled via _buildPrimaryLabel so it matches the convention
// used for terminal-state Restart CTAs (cancelled/completed/
// failed branches of _PRIMARY_VERB).

// controls-01 #2 / controls-03 #4 — Side-effect hint surfaced via the
// OS tooltip on hover. The bare verb "Start" tells operators nothing
// about what the click costs (a real tmux session + Claude API budget
// burn until the pipeline finishes or hits a checkpoint). Chain runs
// fan out across every autopilot-eligible task in the plan, so its
// copy must describe a plan-level fan-out rather than a single feature.
const _START_TITLE_AUTOPILOT =
  'Spawns an autopilot tmux session and runs this feature end-to-end through the pipeline.'
const _START_TITLE_CHAIN =
  'Spawns an autopilot-chain tmux session and runs every autopilot-eligible task in this plan.'

function _buildStartTitle(targetKind: 'autopilot' | 'chain'): string {
  return targetKind === 'chain' ? _START_TITLE_CHAIN : _START_TITLE_AUTOPILOT
}

// R4 — single source of truth for per-state button visibility. The
// closed Record<SessionUIState, ...> shape forces TypeScript to
// reject any future SessionUIState literal that does not extend the
// table, so the contract cannot drift silently.
const _BUTTON_VISIBILITY: Record<
  SessionUIState,
  {
    start: boolean
    pause: boolean
    resume: boolean
    cancel: boolean
    attach: boolean
  }
> = {
  idle:      { start: true,  pause: false, resume: false, cancel: false, attach: false },
  starting:  { start: false, pause: false, resume: false, cancel: true,  attach: false },
  running:   { start: false, pause: true,  resume: false, cancel: true,  attach: true  },
  paused:    { start: false, pause: false, resume: true,  cancel: true,  attach: true  },
  resuming:  { start: false, pause: false, resume: false, cancel: true,  attach: true  },
  cancelled: { start: true,  pause: false, resume: false, cancel: false, attach: false },
  completed: { start: true,  pause: false, resume: false, cancel: false, attach: false },
  failed:    { start: true,  pause: false, resume: false, cancel: false, attach: false },
}

// R5 — terminal states relabel Start → "Restart". Closed Record so
// adding a SessionUIState literal trips a compile error.
const _PRIMARY_VERB: Record<SessionUIState, 'Start' | 'Restart'> = {
  idle: 'Start',
  starting: 'Start',
  running: 'Start',
  paused: 'Start',
  resuming: 'Start',
  cancelled: 'Restart',
  completed: 'Restart',
  failed: 'Restart',
}

// controls-01 #6 / controls-03 #3 — build the contextual primary-action
// label. Chain has no light/full pipeline (autopilot-chain.sh ignores
// the pipeline arg), so the · light/full suffix is autopilot-only.
// Examples:
//   _buildPrimaryLabel('idle',      'autopilot', 'light')  → "Start autopilot · light"
//   _buildPrimaryLabel('completed', 'autopilot', 'full')   → "Restart autopilot · full"
//   _buildPrimaryLabel('idle',      'autopilot', 'manual') → "Start autopilot"
//   _buildPrimaryLabel('idle',      'autopilot', undefined)→ "Start autopilot"
//   _buildPrimaryLabel('idle',      'chain',     'full')   → "Start chain"
//   _buildPrimaryLabel('completed', 'chain',     undefined)→ "Restart chain"
function _buildPrimaryLabel(
  state: SessionUIState,
  targetKind: 'autopilot' | 'chain',
  mode: 'light' | 'full' | 'manual' | undefined,
): string {
  const verb = _PRIMARY_VERB[state]
  const suffix =
    targetKind === 'autopilot' && (mode === 'light' || mode === 'full')
      ? ` · ${mode}`
      : ''
  return `${verb} ${targetKind}${suffix}`
}

// === File-private pure helpers ======================================

function _formatPauseElapsed(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds))
  const ss = String(s % 60).padStart(2, '0')
  if (s < 3600) {
    const m = Math.floor(s / 60)
    return `Pausing… ${m}:${ss}`
  }
  const h = Math.floor(s / 3600)
  const m = Math.floor((s % 3600) / 60)
  return `Pausing… ${h}:${String(m).padStart(2, '0')}:${ss}`
}

function _primaryText(error: ControlError): string {
  if (
    typeof error.retryAfterSeconds === 'number' &&
    error.retryAfterSeconds > 0
  ) {
    return `${error.message} — retry in ${error.retryAfterSeconds}s`
  }
  return error.message
}

function _secondaryText(error: ControlError): string | null {
  /* controls-07 #3 — hint wins. The hook now attaches a diagnostic
     hint on the client-side csrf-null path; without this swap, the
     hard-coded "Reload the page" misdirection would still appear
     and the operator would never see the actionable copy that points
     at csrfToken: console warnings. The csrf-slug fallback below
     only kicks in when no hint was attached (server-403 path). */
  if (error.hint && error.hint.length > 0) return error.hint
  if (error.slug === 'csrf') return _CSRF_DEFAULT_HINT
  return null
}

// === Component ======================================================

export function SessionControls({
  targetKind,
  targetId,
  onAttach,
  hideStateChip = false,
  autopilotMode,
  attached = false,
  density = 'panel',
  hideOutputButton = false,
}: Readonly<SessionControlsProps>): JSX.Element {
  const { state, isPausing, pauseElapsedSeconds, error, isStale, mutate } =
    useSessionControls(targetKind, targetId)

  // controls-04 #2 / controls-05 #3 / controls-06 #3 — stale-
  // lifecycle defence. Server reports `running` but no tmux
  // session is live → pause / attach against the dead session
  // would either no-op or 404. In compact density we collapse to
  // a single inline "Clear stale state" button (cycle-6 #3
  // replaces the cycle-4/5 overflow menu — 7/7 industry products
  // surveyed surface state-machine verbs inline, not via kebab).
  // The button calls mutate.cancel directly to emit the missing
  // terminal lifecycle event; no destructive-confirm dialog (no
  // active work to lose).
  const _isStaleRunning = isStale

  const [cancelDialogOpen, setCancelDialogOpen] = useState(false)
  const [isCancelling, setIsCancelling] = useState(false)

  const visible = _BUTTON_VISIBILITY[state]
  const errorPrimary = error ? _primaryText(error) : null
  const errorSecondary = error ? _secondaryText(error) : null

  // controls-01 #4 — group boundaries. Cancel is destructive and
  // sits in its own visual group separated by a hairline; Attach is
  // a utility action separated again. Dividers only render when both
  // sides of the boundary have something to show, so single-button
  // states (idle, starting, terminal) stay flush.
  const _hasMainlineAction =
    visible.start || visible.pause || visible.resume
  const _showCancelDivider = visible.cancel && _hasMainlineAction
  const _showAttachDivider = visible.attach && visible.cancel

  const handleConfirmCancel = async (): Promise<void> => {
    setIsCancelling(true)
    try {
      await mutate.cancel()
      setIsCancelling(false)
      setCancelDialogOpen(false)
    } catch {
      // Hook surfaces the error via its `error` field; keep the
      // dialog open so the operator sees the inline Alert and can
      // dismiss explicitly via "Keep running" (R16 step 4).
      setIsCancelling(false)
    }
  }

  const handleCloseDialog = (): void => {
    if (isCancelling) return
    setCancelDialogOpen(false)
  }

  return (
    <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
      <Stack direction="row" spacing={1} alignItems="center">
        {visible.start && (
          /* controls-01 #1, #5 — route the primary action through the
             wf/Button primitive so it gets solid signal-blue fill +
             wf.ink text (no longer colliding with active ToggleChip
             at rgba(59,158,255,0.12)) and the proper size-ramp typography
             (large = 40px tall / 13px font, not the theme-pinned 11px). */
          <WfButton
            variant="primary"
            /* controls-05 #2 — `md` (23px) matches the watchfloor
               spec exactly and sits flush against the 22px StatusPill
               baseline. The legacy `default` (32px) overshot the spec
               by 39% and made the START CHAIN button dominate the
               plan-header row. */
            size="md"
            title={_buildStartTitle(targetKind)}
            label={_buildPrimaryLabel(state, targetKind, autopilotMode)}
            icon={<PlayArrowRoundedIcon fontSize="small" />}
            onClick={() => {
              void mutate.start()
            }}
          />
        )}
        {visible.pause && density === 'panel' && (
          <Button
            data-testid="pause-button"
            size="large"
            variant="outlined"
            disabled={isPausing}
            startIcon={<PauseRoundedIcon fontSize="small" />}
            onClick={() => {
              void mutate.pause()
            }}
          >
            {isPausing
              ? _formatPauseElapsed(pauseElapsedSeconds)
              : _LABEL_PAUSE}
          </Button>
        )}
        {visible.resume && density === 'panel' && (
          <Button
            size="large"
            variant="contained"
            startIcon={<PlayArrowRoundedIcon fontSize="small" />}
            onClick={() => {
              void mutate.resume()
            }}
          >
            {_LABEL_RESUME}
          </Button>
        )}
        {visible.resume && density === 'header' && (
          /* controls-04 #3 — Resume promoted to wf/Button primary in
             compact density to match the Start CTA visual weight. The
             two are mutually exclusive (visibility table), so the
             header row never shows both at once. */
          <WfButton
            variant="primary"
            size="md"
            label={_LABEL_RESUME}
            icon={<PlayArrowRoundedIcon fontSize="small" />}
            onClick={() => {
              void mutate.resume()
            }}
          />
        )}
        {_showCancelDivider && density === 'panel' && (
          <Divider
            data-testid="controls-divider"
            orientation="vertical"
            flexItem
            sx={{ mx: 0.5, borderColor: 'wf.steel' }}
          />
        )}
        {visible.cancel && density === 'panel' && (
          <Button
            size="large"
            variant="outlined"
            color="error"
            startIcon={<StopRoundedIcon fontSize="small" />}
            onClick={() => setCancelDialogOpen(true)}
          >
            {_LABEL_CANCEL}
          </Button>
        )}
        {_showAttachDivider && density === 'panel' && (
          <Divider
            data-testid="controls-divider"
            orientation="vertical"
            flexItem
            sx={{ mx: 0.5, borderColor: 'wf.steel' }}
          />
        )}
        {visible.attach && density === 'panel' && !hideOutputButton && (
          <Button
            size="large"
            variant="text"
            startIcon={
              attached ? (
                <CloseRoundedIcon fontSize="small" />
              ) : (
                <OpenInNewRoundedIcon fontSize="small" />
              )
            }
            onClick={() => onAttach()}
          >
            {attached ? _LABEL_DETACH : _LABEL_ATTACH}
          </Button>
        )}
        {/* controls-06 #3 — inline header-density rendering of
            Pause / Cancel / Attach. Replaces the cycle-4/5 kebab +
            overflow Menu. Industry convergence (7/7 — Vercel /
            GitHub Actions / Render / Linear / Stripe / Heroku /
            AWS CodePipeline) surfaces state-machine verbs inline
            on row-level controls; the kebab is reserved for
            low-frequency navigation / export. Each affordance is
            a wf/Button at `sm` size (18px height, JetBrains Mono
            10px) so the trio fits inside the plan-header grid's
            action column without overshooting the spec. The
            secondary / destructive / ghost variants of wf/Button
            now carry styling (was gap #15 through cycle 5). */}
        {density === 'header' && !_isStaleRunning && visible.pause && (
          <WfButton
            variant="secondary"
            size="sm"
            label={isPausing
              ? _formatPauseElapsed(pauseElapsedSeconds)
              : _LABEL_PAUSE}
            icon={<PauseRoundedIcon fontSize="small" />}
            disabled={isPausing}
            onClick={() => {
              void mutate.pause()
            }}
          />
        )}
        {density === 'header' && !_isStaleRunning && visible.cancel && (
          <WfButton
            variant="destructive"
            size="sm"
            label={_LABEL_CANCEL}
            icon={<StopRoundedIcon fontSize="small" />}
            onClick={() => setCancelDialogOpen(true)}
          />
        )}
        {density === 'header' && !_isStaleRunning && visible.attach && !hideOutputButton && (
          <WfButton
            variant="ghost"
            size="sm"
            label={attached ? _LABEL_DETACH : _LABEL_ATTACH}
            icon={
              attached
                ? <CloseRoundedIcon fontSize="small" />
                : <OpenInNewRoundedIcon fontSize="small" />
            }
            onClick={() => onAttach()}
          />
        )}
        {density === 'header' && _isStaleRunning && (
          /* Stale-lifecycle recovery — single inline Restart
             button. Reads as a "go again" verb to the operator,
             but routes through mutate.cancel → mutate.start so the
             server records the missing terminal lifecycle event
             before the new chain claims the target_id slot. No
             destructive-confirm dialog — there's no active work
             to lose. Primary variant + md size match the
             terminal-state Restart CTA at the top of the file. */
          <WfButton
            variant="primary"
            size="md"
            title={_buildStartTitle(targetKind)}
            label={`Restart ${targetKind}`}
            icon={<PlayArrowRoundedIcon fontSize="small" />}
            onClick={() => {
              /* controls-07 #4 — atomic restart owned by the hook.
                 The cycle-6 `await cancel(); await start()` chain
                 silently dropped the start leg in ~half the React
                 render cadences because stateRef.current still read
                 'running' when start()'s _isAllowed guard ran (SWR
                 cache updated, useEffect→stateRef copy had not).
                 mutate.restart() bundles both POSTs and skips that
                 guard with first-hand knowledge that cancel just
                 succeeded; failures still surface via error.hint. */
              void mutate.restart()
            }}
          />
        )}
        {!hideStateChip && <SessionStateChip state={state} isPausing={isPausing} />}
      </Stack>

      {isPausing && (
        <Typography
          data-testid="pause-secondary-label"
          variant="caption"
          color="text.secondary"
        >
          {_PAUSE_SECONDARY_LABEL}
        </Typography>
      )}

      {errorPrimary !== null && (
        <Alert
          role="alert"
          severity="error"
          sx={{ mb: 2, borderRadius: 1 }}
        >
          <strong>{errorPrimary}</strong>
          {errorSecondary !== null && (
            <Typography variant="caption" component="div">
              {errorSecondary}
            </Typography>
          )}
        </Alert>
      )}

      <CancelConfirmDialog
        open={cancelDialogOpen}
        state={state}
        isCancelling={isCancelling}
        errorPrimary={errorPrimary}
        errorSecondary={errorSecondary}
        onConfirm={() => {
          void handleConfirmCancel()
        }}
        onClose={handleCloseDialog}
      />
    </Box>
  )
}

// === Test-only internals ============================================
// Exposed for vitest unit coverage of the pure helper. Mirrors the
// predecessor hook's __test__ namespace at useSessionControls.ts:535.
// react-refresh/only-export-components fires because this file mixes
// a component export with a non-component constant export. Splitting
// the helper into a separate module would require a 5th file
// (R-EXT-1 caps this task at 4); inlining the helper into the test
// file would defeat Group-4 unit coverage. The disable is targeted
// to one line and the constant is test-only — the file's runtime
// surface is still a single React component.
// eslint-disable-next-line react-refresh/only-export-components
export const __test__ = { _formatPauseElapsed } as const
