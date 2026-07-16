// Watchfloor session-state visual chip — pure rendering, props-driven
// (R25). Wraps wf/StatusPill in an aria-live=polite Box (R26, R27)
// so screen readers re-announce the full chip on every state change
// without StatusPill itself growing an aria surface (ISP).
//
// 8 SessionUIState → 5 WfStatus + null mapping per R27. The label
// flips to "Pausing…" only when state === 'running' AND isPausing
// (R29 / EC-C1) so a future bug surface that forgets to clear
// isPausing on terminal states cannot lie about the chip text.

import type { JSX } from 'react'
import Box from '@mui/material/Box'
import StatusPill from './wf/StatusPill'
import type { WfStatus } from './wf/StatusDot'
import type { SessionUIState } from '../hooks/useSessionControls'

export interface SessionStateChipProps {
  state: SessionUIState
  isPausing: boolean
}

const _STATE_LABELS: Record<SessionUIState, string> = {
  idle: 'Idle',
  starting: 'Starting',
  running: 'Running',
  paused: 'Paused',
  resuming: 'Resuming',
  cancelled: 'Cancelled',
  completed: 'Completed',
  failed: 'Failed',
}

// R27 — 8→5 mapping. `idle → null` renders the muted StatusPill
// variant. paused/starting/resuming all roll up to the queued color
// because they are intentionally pre-/post-active stops on the
// transition surface; only running carries the live signal.
const _STATUS_BY_STATE: Record<SessionUIState, WfStatus | null> = {
  idle: null,
  starting: 'queued',
  running: 'running',
  paused: 'queued',
  resuming: 'queued',
  cancelled: 'fault',
  completed: 'completed',
  failed: 'fault',
}

const _PAUSING_LABEL = 'Pausing…'
const _CHIP_MIN_WIDTH = 88

export function SessionStateChip({
  state,
  isPausing,
}: Readonly<SessionStateChipProps>): JSX.Element {
  const label =
    state === 'running' && isPausing
      ? _PAUSING_LABEL
      : _STATE_LABELS[state]
  return (
    <Box
      data-testid="session-state-chip"
      aria-live="polite"
      aria-atomic="true"
      style={{ display: 'inline-flex', minWidth: _CHIP_MIN_WIDTH }}
    >
      <StatusPill status={_STATUS_BY_STATE[state]} label={label} />
    </Box>
  )
}
