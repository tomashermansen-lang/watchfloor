// Watchfloor destructive-action confirmation dialog (R13–R18). Pure
// presentation: owns no fetch / SWR / hook calls. The parent
// (SessionControls) drives the open/isCancelling lifecycle and
// invokes mutate.cancel inside its own onConfirm handler.
//
// Focus lands on the SAFE button ("Keep running") via autoFocus —
// WCAG / GOV.UK destructive-confirmation guidance — so a stray Enter
// keypress cannot kill the session. Both action buttons are disabled
// while isCancelling=true and ESC + backdrop close are short-circuited
// so an in-flight request is not orphaned mid-await (R17, EC-D3).

import type { JSX } from 'react'
import { useId } from 'react'
import Alert from '@mui/material/Alert'
import Button from '@mui/material/Button'
import Dialog from '@mui/material/Dialog'
import DialogActions from '@mui/material/DialogActions'
import DialogContent from '@mui/material/DialogContent'
import DialogTitle from '@mui/material/DialogTitle'
import Typography from '@mui/material/Typography'
import type { SessionUIState } from '../hooks/useSessionControls'

export interface CancelConfirmDialogProps {
  open: boolean
  /** Drives the title — "Cancel running session?" vs "Cancel paused
   *  session?" etc. The dialog only opens for cancellable states; the
   *  fallback covers the never-reached path defensively (EC-D4).
   *  NOTE: keep `_TITLE_BY_STATE` (below) in sync with
   *  `_BUTTON_VISIBILITY` in `SessionControls.tsx` — adding a new
   *  cancellable state requires an entry in BOTH maps (PLAN
   *  § Component 2 documents the Partial<Record> rationale). */
  state: SessionUIState
  /** Promise-in-flight flag owned by the parent. Disables both
   *  buttons and the ESC / backdrop close paths (R16, R17). */
  isCancelling: boolean
  /** Inline error surface — R16 step 4. When non-null, an Alert is
   *  rendered above the action row so the operator sees the error
   *  without dismissing the dialog. The parent (SessionControls)
   *  computes these strings via its `_primaryText`/`_secondaryText`
   *  helpers; the dialog stays presentation-only and does not own
   *  the slug-to-copy lookup. */
  errorPrimary: string | null
  errorSecondary: string | null
  /** Parent invokes mutate.cancel inside this handler. */
  onConfirm: () => void
  /** Parent ignores while isCancelling (defense in depth alongside
   *  disableEscapeKeyDown). */
  onClose: () => void
}

const _CANCEL_WARNING_TEXT =
  'This will kill the tmux session immediately. Any in-flight phase ' +
  'work will be lost — there is no undo path once the session is ' +
  'cancelled.'

const _LABEL_KEEP_RUNNING = 'Keep running'
const _LABEL_CANCEL_ANYWAY = 'Cancel anyway'
const _LABEL_CANCELLING = 'Cancelling…'

// Intentionally Partial<Record<...>>. The dialog only opens for the
// four cancellable states (starting / running / resuming / paused);
// rows outside that set are unreachable. _TITLE_FALLBACK is defense
// in depth — adding rows for unreachable states would imply they are
// legitimate code paths and confuse future maintainers. If a new
// cancellable state is added, add it here AND in SessionControls'
// _BUTTON_VISIBILITY in the same edit (TypeScript will not flag the
// gap because of Partial — it is convention).
const _TITLE_BY_STATE: Partial<Record<SessionUIState, string>> = {
  running: 'Cancel running session?',
  paused: 'Cancel paused session?',
  starting: 'Cancel starting session?',
  resuming: 'Cancel resuming session?',
}
const _TITLE_FALLBACK = 'Cancel session?'

export function CancelConfirmDialog({
  open,
  state,
  isCancelling,
  errorPrimary,
  errorSecondary,
  onConfirm,
  onClose,
}: Readonly<CancelConfirmDialogProps>): JSX.Element {
  const titleId = useId()
  const warningId = useId()

  return (
    <Dialog
      open={open}
      onClose={() => {
        if (isCancelling) return
        onClose()
      }}
      disableEscapeKeyDown={isCancelling}
      aria-labelledby={titleId}
      maxWidth="xs"
      fullWidth
    >
      <DialogTitle id={titleId}>
        {_TITLE_BY_STATE[state] ?? _TITLE_FALLBACK}
      </DialogTitle>
      <DialogContent>
        <Typography id={warningId} variant="body2">
          {_CANCEL_WARNING_TEXT}
        </Typography>
        {errorPrimary !== null && (
          <Alert
            role="alert"
            severity="error"
            sx={{ mt: 2, borderRadius: 1 }}
          >
            <strong>{errorPrimary}</strong>
            {errorSecondary !== null && (
              <Typography variant="caption" component="div">
                {errorSecondary}
              </Typography>
            )}
          </Alert>
        )}
      </DialogContent>
      <DialogActions>
        <Button
          autoFocus
          variant="outlined"
          size="large"
          disabled={isCancelling}
          onClick={onClose}
        >
          {_LABEL_KEEP_RUNNING}
        </Button>
        <Button
          variant="contained"
          color="error"
          size="large"
          disabled={isCancelling}
          aria-describedby={warningId}
          onClick={onConfirm}
        >
          {isCancelling ? _LABEL_CANCELLING : _LABEL_CANCEL_ANYWAY}
        </Button>
      </DialogActions>
    </Dialog>
  )
}
