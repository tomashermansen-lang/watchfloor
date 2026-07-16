import { useState, useCallback, useMemo, useRef, useEffect, useLayoutEffect, Fragment } from 'react'
import type { KeyboardEvent as ReactKeyboardEvent, MouseEvent as ReactMouseEvent } from 'react'
import Box from '@mui/material/Box'
import IconButton from '@mui/material/IconButton'
import Paper from '@mui/material/Paper'
import ContentCopyIcon from '@mui/icons-material/ContentCopy'
import Collapse from '@mui/material/Collapse'
import Dialog from '@mui/material/Dialog'
import Popover from '@mui/material/Popover'
import Tooltip from '@mui/material/Tooltip'
import Typography from '@mui/material/Typography'
import CancelIcon from '@mui/icons-material/Cancel'
import CheckCircleIcon from '@mui/icons-material/CheckCircle'
import ErrorIcon from '@mui/icons-material/Error'
import FiberManualRecordIcon from '@mui/icons-material/FiberManualRecord'
import HourglassEmptyIcon from '@mui/icons-material/HourglassEmpty'
import LockOpenIcon from '@mui/icons-material/LockOpen'
import LockIcon from '@mui/icons-material/Lock'
import RadioButtonUncheckedIcon from '@mui/icons-material/RadioButtonUnchecked'
import RemoveCircleOutlineIcon from '@mui/icons-material/RemoveCircleOutline'
import RadarMark from './wf/RadarMark'
import StatusPill from './wf/StatusPill'
import CornerReticles from './wf/CornerReticles'
import type { WfStatus } from './wf/StatusDot'
import { taskStatusToWfStatus } from '../utils/featureStatusMapping'
import type { Plan, Phase, Task, TaskStatus, Session, AutopilotSession, ChecklistItem, EnrichedChecklistItem } from '../types'
import SessionPanel from './SessionPanel'
import { useHoverLink } from '../contexts/HoverLinkContext'
import { useAutopilots } from '../hooks/useAutopilots'
import { buildTreeLayout, NODE_W, NODE_H, GAP_X, GAP_Y } from '../utils/dagLayout'
import type { TreeNode } from '../utils/dagLayout'
import { routePath, type NodeRect } from '../utils/connectorRouting'
import { phaseStatus, phaseStatusWithOverlay, phaseProgressWithOverlay } from '../utils/phaseHelpers'
import { effectivePhaseProgress, autopilotPhaseFraction } from '../utils/effectivePhaseProgress'
import { pv, pva } from '../utils/cssVars'
import { taskTypeLabel } from '../utils/taskTypeIcons'
import PhaseIcon from './wf/PhaseIcon'
import { taskTypeToWfPhase } from '../utils/taskTypeToWfPhase'
import { taskExecutionMode } from '../utils/taskExecutionMode'
import { isPlan2 } from '../utils/planVersion'

/* ═══ Helpers ═══ */

function checklistItemText(item: ChecklistItem): string {
  return typeof item === 'string' ? item : item.item
}

function gateItemIcon(item: EnrichedChecklistItem, gatePassed: boolean) {
  const iconSx = { fontSize: 16, mt: 0.25, flexShrink: 0 }

  if (gatePassed) {
    return <CheckCircleIcon data-testid="gate-item-icon-passed" sx={{ ...iconSx, color: pv('status-done') }} />
  }

  if (item.kind === 'human') {
    return <RadioButtonUncheckedIcon data-testid="gate-item-icon-human" sx={{ ...iconSx, color: 'text.secondary' }} />
  }

  // kind === 'shell'
  if (item.lastResult === 'passed') {
    return <CheckCircleIcon data-testid="gate-item-icon-passed" sx={{ ...iconSx, color: pv('status-done') }} />
  }
  if (item.lastResult === 'failed' || item.lastResult === 'timeout') {
    return <CancelIcon data-testid="gate-item-icon-failed" sx={{ ...iconSx, color: pv('status-failed') }} />
  }
  // needs_review or null → pending
  return <HourglassEmptyIcon data-testid="gate-item-icon-pending" sx={{ ...iconSx, color: pv('warning-main') }} />
}

function shouldShowGatePrompt(gate: { enrichedChecklist?: EnrichedChecklistItem[]; checklist: ChecklistItem[] }): boolean {
  if (!gate.enrichedChecklist) return true
  if (gate.enrichedChecklist.length === 0) return false
  return !gate.enrichedChecklist.every((i) => i.kind === 'shell' && i.lastResult === 'passed')
}

function gateNodeSummary(gate: { enrichedChecklist?: EnrichedChecklistItem[]; checklist: ChecklistItem[]; passed: boolean }): string {
  const total = gate.enrichedChecklist?.length ?? gate.checklist.length
  if (gate.passed) return `${total}/${total} checks`
  if (!gate.enrichedChecklist) return `0/${total} checks`
  const passed = gate.enrichedChecklist.filter((i) => i.lastResult === 'passed').length
  const hasHumanRemaining = gate.enrichedChecklist.some((i) => i.kind === 'human' && i.lastResult !== 'passed')
  if (passed > 0 && hasHumanRemaining) return `${passed}/${total} auto-passed`
  return `${passed}/${total} checks`
}

const ACTIVE_SESSION_STATUSES = new Set(['working', 'needs_input', 'idle'])

function findSessionForTask(taskId: string, sessions: Session[], taskStatus?: TaskStatus): Session | undefined {
  return sessions.find((s) => {
    const feature = s.branch.split('/').pop() ?? ''
    if (feature !== taskId) return false
    // For pending tasks, only show active sessions — ended sessions are stale
    // (task was reset/rolled back but JSONL still has the old session)
    if (taskStatus === 'pending' && !ACTIVE_SESSION_STATUSES.has(s.status)) return false
    return true
  })
}

/* ═══ StatusDot ═══ */

const reducedMotionQuery = '@media (prefers-reduced-motion: reduce)'

function StatusDot({ status, size = 10 }: Readonly<{ status: TaskStatus; size?: number }>) {
  const color = pv(`status-${status}`)
  const s = size + 4

  if (status === 'done') return <CheckCircleIcon sx={{ color, fontSize: s }} />
  if (status === 'failed') return <ErrorIcon sx={{ color, fontSize: s }} />
  if (status === 'skipped') return <RemoveCircleOutlineIcon sx={{ color, fontSize: s }} />
  if (status === 'wip')
    return (
      <Box sx={{ width: s, height: s, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <FiberManualRecordIcon
          sx={{
            color,
            fontSize: s - 2,
            animation: 'pipelinePulse 2s ease-in-out infinite',
            '@keyframes pipelinePulse': {
              '0%, 100%': { opacity: 1, transform: 'scale(1)' },
              '50%': { opacity: 0.4, transform: 'scale(0.8)' },
            },
            [reducedMotionQuery]: { animation: 'none' },
          }}
        />
      </Box>
    )
  return <RadioButtonUncheckedIcon sx={{ color, fontSize: s }} />
}

const FLOW_LABELS: Record<string, string> = {
  started: 'Started', ba: 'BA', design: 'Design', plan: 'Plan',
  'team-review': 'T-Rev', review: 'Review', implement: 'Impl',
  'static-analysis': 'SA', manualtest: 'Test', 'team-qa': 'T-QA',
  commit: 'Commit', done: 'Done',
}

/* ═══ Task node card (M3 styling) ═══ */

function taskNodeBorderColor(isLinkedHighlight: boolean, status: TaskStatus, statusPath: string) {
  if (isLinkedHighlight) return pv('primary-main')
  if (status === 'wip') return pva(statusPath, 0.5)
  return pv('outlineVariant')
}

function taskNodeBoxShadow(isLinkedHighlight: boolean, status: TaskStatus, statusPath: string) {
  if (isLinkedHighlight) return `0 0 0 2px ${pva('primary-main', 0.3)}, 0 4px 12px ${pva('primary-main', 0.15)}`
  if (status === 'wip') return `0 0 0 1px ${pva(statusPath, 0.15)}, 0 2px 8px ${pva(statusPath, 0.12)}`
  return `0 1px 2px ${pva('text-primary', 0.04)}`
}

function autopilotIconOpacity(taskStatus: TaskStatus, autopilotSession?: AutopilotSession) {
  return taskStatus === 'done' && !autopilotSession ? 0.5 : 0.85
}

function autopilotTooltipTitle(autopilotSession?: AutopilotSession) {
  return autopilotSession ? `Autopilot ${autopilotSession.status}` : 'Autopilot eligible'
}

/* Per-task completion gauge (handoff §"Task node completion gauge").
   Sits at the bottom edge of every task card and fills in the wf
   status color. Width:
     done   → 100% (full bar = task complete)
     failed → 100% (full bar in fault-red so the failure punctuates
              the card as a finished-but-broken state)
     wip    → session.flow phase progress when a session is live,
              otherwise a neutral 50% so the brand color reads
   pending/skipped → no bar; non-states should not borrow attention. */
function TaskProgressBar({ task, session, autopilotSession }: Readonly<{ task: Task; session?: Session; autopilotSession?: AutopilotSession }>) {
  /* Audit-12 — effective progress.
     Plan-level task.status often lags behind reality: when autopilot
     is actively running on a task, the plan still reads 'pending'.
     The `effectivePhaseProgress` helper resolves: autopilot phases
     (live) > session.flow (file-scan) > nothing. When isActive=true
     we render the bar even if task.status='pending'. */
  const live = effectivePhaseProgress({ task, session, autopilotSession })
  const wfStatus = taskStatusToWfStatus(task.status)
  const renderActive = live?.isActive ?? false
  /* Audit-15 #4 — needs_input session means autopilot paused waiting
     for permission. The autopilot wrapper may have exited (status=
     'completed') so isActive is false, but the live position is still
     in `live.completed/total`. Render the bar in fault color so the
     stuck state reads at a glance. Terminal task.status (done/failed)
     wins over isStuck — those are end-states, stuck is transient. */
  const isStuck = session?.status === 'needs_input'
    && task.status !== 'done'
    && task.status !== 'failed'
  if (!renderActive && !isStuck && wfStatus === null) return null

  /* Visual status: prefer 'running' when autopilot is live, even if
     the plan says pending. Done/failed only when the task itself is
     terminal — never derived from autopilot. Stuck inherits the fault
     palette (matches the needs-input → fault chip mapping in
     buildTaskChips). */
  const visualStatus: WfStatus = task.status === 'done' ? 'completed'
    : task.status === 'failed' ? 'fault'
    : isStuck ? 'fault'
    : renderActive ? 'running'
    : (wfStatus ?? 'queued')

  let pct: number
  if (visualStatus === 'running' || isStuck) {
    /* Midpoint heuristic per audit-11 — (phase_index + 0.5) / total.
       Strict completed/total shows 0% at phase 0 (no visual feedback
       that work started). +0.5 reads as "halfway through current
       phase". Sub-phase progress isn't tracked. Stuck reuses the
       same math: position of the stuck phase is what users care
       about ("where did it stall"), not 100%. */
    pct = live
      ? Math.round(((live.completed + 0.5) / live.total) * 100)
      : 50
  } else {
    pct = 100
  }

  /* Color tokens key off `visualStatus` so an autopilot-active
     pending-in-plan task fills with signal-blue, not the inert
     pending grey. */
  const wfColor = pv(`status-${visualStatus === 'completed' ? 'done' : visualStatus === 'fault' ? 'failed' : 'wip'}`)
  const isRunning = visualStatus === 'running'
  /* Audit-10 #2 — wip uses neutral wf.steel track so two-tone
     "blue progress · grey remaining" reads. done/failed fill 100%
     so their track is hidden. Stuck (audit-15 #4) also uses steel
     track so the partial fill reads against neutral grey. */
  const trackBg = isRunning || isStuck
    ? 'wf.steel'
    : pva(`status-${visualStatus === 'completed' ? 'done' : 'failed'}`, 0.12)
  return (
    <Box
      data-testid="task-progress-bar"
      data-task-id={task.id}
      data-status={visualStatus}
      data-track={isRunning || isStuck ? 'wf.steel' : 'status-tinted'}
      role="progressbar"
      aria-valuenow={pct}
      aria-valuemin={0}
      aria-valuemax={100}
      style={{
        position: 'absolute',
        left: 0,
        right: 0,
        bottom: -1,
        height: 2,
        zIndex: 1,
      }}
      sx={{
        bgcolor: trackBg,
        overflow: 'hidden',
      }}
    >
      <Box sx={{ height: '100%', width: `${pct}%`, bgcolor: wfColor }} />
    </Box>
  )
}

/* Phase aggregate completion gauge — bottom-edge sibling of
   TaskProgressBar / GateProgressBar. Consumes the phase status
   color and fills to the phase progress percentage so the top
   strip + side markers share the same instrument vocabulary as
   the task and gate nodes. Renders absolutely-positioned at the
   container's bottom edge — wrap in a position:relative parent. */
function PhaseGauge({
  status, pct,
}: Readonly<{ status: TaskStatus; pct: number }>) {
  const fillToken = `status-${status}`
  return (
    <Box
      data-testid="wf-phase-gauge"
      data-status={status}
      role="progressbar"
      aria-valuenow={pct}
      aria-valuemin={0}
      aria-valuemax={100}
      style={{
        position: 'absolute',
        left: 0,
        right: 0,
        bottom: -1,
        height: 2,
        zIndex: 1,
      }}
      sx={{
        bgcolor: pva(fillToken, 0.12),
        overflow: 'hidden',
      }}
    >
      <Box sx={{ height: '100%', width: `${pct}%`, bgcolor: pv(fillToken) }} />
    </Box>
  )
}

/* Gate completion gauge — same shape as TaskProgressBar but
   keyed off gate state. gate.passed → 100% completed-green;
   otherwise the bar fills to the percentage of shell items
   already passed (so the gauge advances incrementally as
   verification work lands), or 0 when no progress yet. */
function GateProgressBar({
  gate,
}: Readonly<{
  gate: { enrichedChecklist?: EnrichedChecklistItem[]; checklist: ChecklistItem[]; passed: boolean }
}>) {
  let pct: number
  let wfStatus: WfStatus
  if (gate.passed) {
    pct = 100
    wfStatus = 'completed'
  } else {
    const total = gate.enrichedChecklist?.length ?? gate.checklist.length
    const done = gate.enrichedChecklist?.filter((i) => i.lastResult === 'passed').length ?? 0
    pct = total > 0 ? Math.round((done / total) * 100) : 0
    wfStatus = 'running'
  }
  const fillToken = gate.passed ? 'status-done' : 'status-wip'
  return (
    <Box
      data-testid="task-progress-bar"
      data-task-id="__gate"
      data-status={wfStatus}
      role="progressbar"
      aria-valuenow={pct}
      aria-valuemin={0}
      aria-valuemax={100}
      style={{
        position: 'absolute',
        left: 0,
        right: 0,
        bottom: -1,
        height: 2,
        zIndex: 1,
      }}
      sx={{
        bgcolor: pva(fillToken, 0.12),
        overflow: 'hidden',
      }}
    >
      <Box sx={{ height: '100%', width: `${pct}%`, bgcolor: pv(fillToken) }} />
    </Box>
  )
}

/* Task-node status chips are wf StatusPills (handoff §UI Primitives).
   wfStatus drives the colour band; pulse adds the needs_input
   attention animation on the wrapper.

   Skarmaudit-15a/b contract: pills are EXCEPTION-ONLY. Default flow
   is pill-free — the StatusDot in Row 1 + TaskProgressBar fill
   already carry done/wip/pending status, so a CLOSED/COMPLETED/
   WORKING pill would just triple the visual weight for no information
   gain. The blocked-pending state is conveyed by the dashed inbound
   SVG connector + hollow dot (audit-15b #1). Pills stay only when
   they flag a state the connector + dot cannot: 'fix' (failed — call
   to action), 'needs input' (human attention — pulsing), 'paused'
   (intentional stop / stale agent — muted variant per StatusPill
   spec). */
interface TaskChip { label: string; wfStatus: WfStatus | null; pulse?: boolean }

function buildTaskChips(args: {
  task: Task
  session?: Session
  autopilotSession?: AutopilotSession
}): TaskChip[] {
  const { task, session, autopilotSession } = args
  const chips: TaskChip[] = []
  if (task.status === 'failed') {
    chips.push({ label: 'fix', wfStatus: 'fault' })
  }
  /* Session-derived chips only fire on wip tasks (sessions on
     pending/done tasks are noise — the task status leads). Autopilot
     auto-handles checkpoints so its sessions never need a chip. */
  const suppressSessionChip = autopilotSession?.status === 'running'
  if (session && task.status === 'wip' && !suppressSessionChip) {
    if (session.status === 'needs_input') {
      chips.push({ label: 'needs input', wfStatus: 'fault', pulse: true })
    } else if (session.status === 'stopped' || session.status === 'stale') {
      chips.push({ label: 'paused', wfStatus: null })
    }
  }
  return chips
}

export function TaskNodeCard({
  node, session, autopilotSession, onClick, isV2 = false,
}: Readonly<{
  node: TreeNode; session?: Session; autopilotSession?: AutopilotSession; onClick: () => void; isV2?: boolean
}>) {
  const { hoveredSessionBranch, setHoveredTask } = useHoverLink()
  const { task } = node

  const statusPath = `status-${task.status}`

  // Cross-panel: highlight when a session with matching branch feature is hovered
  const sessionFeature = hoveredSessionBranch?.split('/').pop() ?? ''
  const isLinkedHighlight = sessionFeature !== '' && sessionFeature === task.id

  const chips = buildTaskChips({ task, session, autopilotSession })

  const handleClickEvent = (e: ReactMouseEvent) => { e.stopPropagation(); onClick() }
  const handleKeyDown = (e: ReactKeyboardEvent) => {
    if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); onClick() }
  }
  const wipAnimationSx = task.status === 'wip' ? {
    animation: 'nodeGlow 3s ease-in-out infinite',
    '@keyframes nodeGlow': {
      '0%, 100%': { boxShadow: `0 0 0 1px ${pva(statusPath, 0.15)}, 0 2px 8px ${pva(statusPath, 0.12)}` },
      '50%': { boxShadow: `0 0 0 1.5px ${pva(statusPath, 0.25)}, 0 2px 12px ${pva(statusPath, 0.2)}` },
    },
    [reducedMotionQuery]: { animation: 'none' },
  } : {}
  return (
    <Box
      data-node-id={task.id}
      onClick={handleClickEvent}
      onMouseEnter={() => setHoveredTask(task.id)}
      onMouseLeave={() => setHoveredTask(null)}
      tabIndex={0}
      onKeyDown={handleKeyDown}
      sx={{
        position: 'absolute',
        width: NODE_W,
        height: NODE_H,
        display: 'flex',
        flexDirection: 'column',
        /* flex-start pushes the existing two rows to the top edge so
           the slack collapses to the bottom — reserved for the future
           progress bar (handoff §Task node "completion gauge"). */
        justifyContent: 'flex-start',
        gap: 0.25,
        pt: 0.75,
        pb: 0.5,
        px: 1,
        borderRadius: 0,
        border: isLinkedHighlight ? '1.5px solid' : '1px solid',
        borderColor: taskNodeBorderColor(isLinkedHighlight, task.status, statusPath),
        /* Audit-20 #3 — TaskNodeCard inherits the wf.ink panel bg one
           tier below the phase rail's surface1 cards, so tasks recess
           visually instead of duplicating the phase chrome. */
        cursor: 'pointer',
        transition: `all var(--motion-short4, 200ms) var(--motion-emphasized, cubic-bezier(0.2, 0, 0, 1))`,
        boxShadow: taskNodeBoxShadow(isLinkedHighlight, task.status, statusPath),
        '&:hover': {
          /* Audit-15c #6 - hover affordance is wf.signal blue,
             matching the selected/active treatment on phase cards.
             Status colour stays reserved for the dot + bottom bar. */
          borderColor: pva('wf-signal', 0.5),
          boxShadow: `0 4px 12px ${pva('wf-signal', 0.16)}`,
          transform: 'translateY(-1px)',
          [reducedMotionQuery]: { transform: 'none' },
        },
        '&:active': {
          transform: 'translateY(0)',
          [reducedMotionQuery]: { transform: 'none' },
        },
        '&:focus-visible': {
          outline: `2px solid ${pv('primary-main')}`,
          outlineOffset: 2,
        },
        ...wipAnimationSx,
      }}
    >
      {/* Row 1: status dot + task id. The visible title is task.id
          (kebab-case, matches the chip vocabulary in DEPENDS ON /
          REQUIRED BY / AFTER GATE sidebars). The longer task.name
          surfaces on hover via the native title attribute. Operators
          asked for this 2026-05-08 — the long names truncated noisily
          and disagreed with the chip identity used elsewhere. */}
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.4 }}>
        <StatusDot status={task.status} size={6} />
        <Typography
          variant="wfBody"
          noWrap
          title={task.name}
          sx={{ flex: 1, fontSize: '12px', fontWeight: task.status === 'wip' ? 600 : 500, color: task.status === 'done' ? 'text.secondary' : 'text.primary', lineHeight: 1.3 }}
        >
          {task.id}
        </Typography>
        {/* Execution-mode glyph rides Row 1 next to the title
            (skarmaudit-15a #2). Status semantics belong on the
            same baseline as the name — like a phase status icon
            in PhaseStepper. Autopilot wins over manual when both
            signals are present; they never co-occur. */}
        {(() => {
          const mode = taskExecutionMode(task)
          if (mode === 'autopilot') {
            const isFullPipeline = task.pipeline === 'full'
            return (
              <Tooltip
                title={`${autopilotTooltipTitle(autopilotSession)} · ${isFullPipeline ? 'full' : 'light'} pipeline`}
                enterDelay={300}
              >
                <Box sx={{
                  display: 'inline-flex',
                  flexShrink: 0,
                  opacity: autopilotIconOpacity(task.status, autopilotSession),
                }}>
                  <RadarMark
                    size={14}
                    sweep={autopilotSession?.status === 'running'}
                    sweepDuration="2.2s"
                    variant={isFullPipeline ? 'full' : 'light'}
                  />
                </Box>
              </Tooltip>
            )
          }
          return (
            <Tooltip title="Manual task" enterDelay={300}>
              <Box sx={{ display: 'inline-flex', flexShrink: 0, color: 'wf.fog' }}>
                <PhaseIcon type="manual" size={14} />
              </Box>
            </Tooltip>
          )
        })()}
      </Box>

      {/* Row 2: chips + work-kind label. Exception-only chips per
          skarmaudit-15a #1 (fix / blocked / needs input / paused)
          — most rows are chip-free in steady state, leaving only
          the kind label. Reserved minHeight keeps card geometry
          stable across states. */}
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.4, pl: 1.5, minHeight: 20 }}>
        {chips.map((c) => (
          <Box
            key={c.label}
            component="span"
            sx={c.pulse ? {
              display: 'inline-flex',
              animation: 'badgePulse 2.5s ease-in-out infinite',
              '@keyframes badgePulse': { '0%,100%': { opacity: 1 }, '50%': { opacity: 0.5 } },
              [reducedMotionQuery]: { animation: 'none' },
            } : { display: 'inline-flex' }}
          >
            <StatusPill status={c.wfStatus} label={c.label} />
          </Box>
        ))}
        {isV2 && <TaskNodeExtrasV2 task={task} />}
      </Box>
      {/* Row 3 — phase label (audit-10 #1 + audit-12 + audit-15 #5).
          Moved off Row 2 (which was overcrowded). Sources from the
          effective phase progress so autopilot's live phase wins over
          file-scanned session.flow data. Label persists whenever
          `live.phase` is set (audit-15 #5) — previously gated on
          isActive, which made the name disappear during phase
          transitions and when the autopilot exited mid-pipeline.
          Hidden for terminal task states (done/failed) to keep the
          end-state visually clean. */}
      {(() => {
        const live = effectivePhaseProgress({ task, session, autopilotSession })
        const isTerminal = task.status === 'done' || task.status === 'failed'
        if (!live?.phase || isTerminal) return null
        return (
          <Box sx={{ display: 'flex', alignItems: 'center', pl: 1.5, mt: 0.25 }}>
            <Typography
              data-testid="task-phase-label"
              variant="wfLabel"
              sx={{ fontSize: '9px', color: 'wf.fog', letterSpacing: '0.08em' }}
            >
              {FLOW_LABELS[live.phase] ?? live.phase}
            </Typography>
          </Box>
        )
      })()}
      <TaskProgressBar task={task} session={session} autopilotSession={autopilotSession} />
    </Box>
  )
}

function TaskNodeExtrasV2({ task }: Readonly<{ task: Task }>) {
  if (!task.task_type) return null
  /* "What kind of work is this" — rendered inline on Row 2 next to
     the status pill and autopilot icon. No leading padding because
     the parent already pl-indents the whole row. */
  const wfPhase = taskTypeToWfPhase(task.task_type)
  const isActive = task.status === 'wip'
  return (
    <Box sx={{ display: 'inline-flex', alignItems: 'center', gap: 0.5 }}>
      {wfPhase && (
        <PhaseIcon type={wfPhase} size={12} active={isActive} color="var(--mui-palette-wf-fog, #5A6472)" />
      )}
      <Typography
        variant="wfLabel"
        sx={{ color: 'wf.fog' }}
        /* Inline style override is intentional: keeps wfLabel's 10px
           size + JetBrains Mono + letter-spacing but resets the
           variant's textTransform: uppercase so labels read as
           'Development' / 'Refactor' (mixed case) per user-request
           2026-05-08. */
        style={{ textTransform: 'none' }}
      >
        {taskTypeLabel(task.task_type)}
      </Typography>
    </Box>
  )
}

/* ═══ Orthogonal path — handoff "sharp 90° elbow" connectors ═══

   Hard right angles, no rounded corners. The pipeline graph
   follows the radar geometry the rest of the brand uses
   (concentric rings + crosshair lines), so connector elbows
   render as honest H/V joins instead of softened Q curves.

   The optional `r` parameter is preserved as a fallback for
   callers that explicitly want a rounded elbow, but the default
   is 0 — sharp.  */

function orthogonalPath(x1: number, y1: number, x2: number, y2: number, r: number = 0, viaX?: number): string {
  const dy = y2 - y1
  if (Math.abs(dy) < 1) return `M ${x1} ${y1} H ${x2}`
  const mx = viaX ?? (x1 + x2) / 2
  const cr = Math.min(r, Math.abs(dy) / 2, Math.abs(mx - x1), Math.abs(x2 - mx))
  if (cr < 0.5) return `M ${x1} ${y1} H ${mx} V ${y2} H ${x2}`
  const sign = dy > 0 ? 1 : -1
  return `M ${x1} ${y1} H ${mx - cr} Q ${mx} ${y1}, ${mx} ${y1 + sign * cr} V ${y2 - sign * cr} Q ${mx} ${y2}, ${mx + cr} ${y2} H ${x2}`
}

/* ═══ SVG connectors: orthogonal lines ═══ */

function TreeConnectors({
  nodes, containerRef,
}: Readonly<{
  nodes: Map<string, TreeNode>; containerRef: React.RefObject<HTMLDivElement | null>
}>) {
  /* User-request 2026-05-08: store the routed path string per line so
     the routing decision (simple H, 3-segment, or U-detour) is taken
     once at measure-time with knowledge of all node rectangles, and
     the render below stays a dumb mapper. See utils/connectorRouting.
     Same-row through-box (qa-rapport case) and multi-row elbow-into-
     box (transitive-redundancy case) both detour through the row gap. */
  const [lines, setLines] = useState<
    { id: string; path: string; status: TaskStatus }[]
  >([])

  const measure = useCallback(() => {
    if (!containerRef.current) return
    const container = containerRef.current
    const rect = container.getBoundingClientRect()

    /* Collect every node's rectangle once so routePath can detect
       through-box collisions for any (source, target) pair. */
    const allRects: NodeRect[] = []
    for (const [, node] of nodes) {
      const el = container.querySelector(`[data-node-id="${node.task.id}"]`)
      if (!el) continue
      const r = el.getBoundingClientRect()
      allRects.push({
        id: node.task.id,
        left: r.left - rect.left,
        right: r.right - rect.left,
        top: r.top - rect.top,
        bottom: r.bottom - rect.top,
      })
    }

    type RawLine = {
      id: string; x1: number; y1: number; x2: number; y2: number
      status: TaskStatus; srcId: string; tgtId: string; viaX?: number
    }
    const linesByChild = new Map<string, RawLine[]>()
    for (const [, node] of nodes) {
      for (const childId of node.children) {
        const pEl = container.querySelector(`[data-node-id="${node.task.id}"]`)
        const cEl = container.querySelector(`[data-node-id="${childId}"]`)
        if (!pEl || !cEl) continue
        const pR = pEl.getBoundingClientRect()
        const cR = cEl.getBoundingClientRect()
        const raw: RawLine = {
          id: `${node.task.id}->${childId}`,
          x1: pR.right - rect.left,
          y1: pR.top + pR.height / 2 - rect.top,
          x2: cR.left - rect.left,
          y2: cR.top + cR.height / 2 - rect.top,
          status: node.task.status,
          srcId: node.task.id,
          tgtId: childId,
        }
        const group = linesByChild.get(childId) ?? []
        group.push(raw)
        linesByChild.set(childId, group)
      }
    }
    for (const [, group] of linesByChild) {
      if (group.length > 1) {
        const convX = group[0].x2 - GAP_X / 2
        for (const l of group) l.viaX = convX
      }
    }

    const newLines: { id: string; path: string; status: TaskStatus }[] = []
    for (const [, group] of linesByChild) {
      for (const raw of group) {
        const path = routePath({
          x1: raw.x1, y1: raw.y1, x2: raw.x2, y2: raw.y2,
          viaX: raw.viaX,
          rects: allRects,
          excludeIds: new Set([raw.srcId, raw.tgtId]),
          nodeH: NODE_H,
          gapY: GAP_Y,
        })
        newLines.push({ id: raw.id, path, status: raw.status })
      }
    }
    setLines(newLines)
  }, [nodes, containerRef])

  // Measure on mount and when nodes change
  useLayoutEffect(measure, [measure])

  // Re-measure when container layout shifts (handles late paint / resize)
  useEffect(() => {
    const el = containerRef.current
    if (!el) return
    const ro = new ResizeObserver(measure)
    ro.observe(el)
    return () => ro.disconnect()
  }, [measure, containerRef])

  const colorPending = pva('text-primary', 0.35)

  return (
    <svg
      style={{ position: 'absolute', top: 0, left: 0, width: '100%', height: '100%', pointerEvents: 'none', overflow: 'visible' }}
      aria-hidden="true"
    >
      {lines.map((l) => {
        /* Skarmaudit-15c — solid lines only, status colour
           differentiates: blue for done/wip parents (the unlocked
           or actively flowing path), grey for pending. Animation
           and dash patterns dropped per operator. */
        const c = phaseEntryColor(l.status, colorPending)
        return (
          <path
            key={l.id}
            d={l.path}
            fill="none"
            strokeWidth={2}
            strokeLinecap="round"
            strokeLinejoin="round"
            strokeDasharray="none"
            style={{ stroke: c }}
          />
        )
      })}
    </svg>
  )
}

/* ═══ Phase tree: left-to-right DAG ═══ */

function phaseEntryColor(status: TaskStatus | undefined, fallback: string): string {
  /* Skarmaudit-15c — every "active flow" line uses wf.signal blue
     regardless of whether the predecessor is done or wip. Pending
     and undefined predecessors fall back to grey so the line reads
     as future-flow not yet unlocked. The dash differentiation that
     this function used to drive in conjunction with phaseEntryDash
     was removed (operator: dashes are noise; status colour alone
     should differentiate). */
  if (status === 'done' || status === 'wip') return pv('wf-signal')
  return fallback
}

function phaseStatusColor(status: TaskStatus): string {
  return phaseEntryColor(status, pva('text-secondary', 0.3))
}

interface PhaseMarkerCardProps {
  phase: PhaseMarkerInfo
  markerWidth: number
  onNavigate?: (phaseId: string) => void
}

function PhaseMarkerCard({ phase, markerWidth, onNavigate }: Readonly<PhaseMarkerCardProps>) {
  return (
    <Box
      onClick={() => onNavigate?.(phase.id)}
      sx={{
        position: 'relative',
        width: markerWidth,
        /* Match TaskNodeCard / CompactPhaseCard height + padding
           so all three card surfaces read as one card vocabulary. */
        height: NODE_H,
        display: 'flex', flexDirection: 'column', justifyContent: 'flex-start',
        gap: 0.25,
        pt: 0.75, pb: 0.5, px: 1,
        borderRadius: 0, border: '1px solid',
        borderColor: pv('outlineVariant'), bgcolor: pv('surface1'),
        cursor: 'pointer',
        transition: 'all var(--motion-short4, 200ms) var(--motion-emphasized, cubic-bezier(0.2, 0, 0, 1))',
        /* Audit-15c #6 - hover uses wf.signal regardless of phase
           status, matching the selected/active border on
           CompactPhaseCard and the hover treatment on TaskNodeCard. */
        '&:hover': { borderColor: pva('wf-signal', 0.5), bgcolor: pva('wf-signal', 0.04) },
      }}
    >
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.4 }}>
        <StatusDot status={phase.status} size={6} />
        <Typography variant="wfBody" noWrap sx={{ flex: 1, fontSize: '12px', fontWeight: 500, lineHeight: 1.2 }}>
          {phase.name}
        </Typography>
      </Box>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.4, pl: 1.5, minHeight: 18 }}>
        <Typography variant="wfLabel" sx={{ color: pv(`status-${phase.status}`), flexShrink: 0 }}>
          {phase.progress.done}/{phase.progress.total}
        </Typography>
      </Box>
      <PhaseGauge status={phase.status} pct={phase.progress.pct} />
    </Box>
  )
}

function PhaseMarkerFallback({ label }: Readonly<{ label: string }>) {
  return (
    <Typography variant="wfLabel" sx={{ color: 'text.secondary' }}>
      {label}
    </Typography>
  )
}

interface IsolatedPathArgs {
  isoId: string
  nodes: Map<string, TreeNode>
  ENTRY_W: number; entryY: number; exitY: number; NODE_W: number; NODE_H: number
  GAP_X: number; GAP_Y: number; treeW: number
  hasGate: boolean; gateX: number; gateCenterY: number
  entryDash: string; entryColor: string
}

function renderIsolatedTaskPaths(args: IsolatedPathArgs) {
  const { isoId, nodes, ENTRY_W, entryY, exitY, NODE_W, NODE_H, GAP_X, GAP_Y, treeW, hasGate, gateX, gateCenterY, entryDash, entryColor } = args
  const isoNode = nodes.get(isoId)
  if (!isoNode) return null
  const ny = isoNode.row * (NODE_H + GAP_Y) + NODE_H / 2
  const taskLeft = ENTRY_W + isoNode.col * (NODE_W + GAP_X)
  const taskRight = taskLeft + NODE_W
  const exitX = hasGate ? gateX : (ENTRY_W + treeW + GAP_X)
  /* Skarmaudit-15c — both halves of an isolated task path follow the
     unified flow rule: status colour drives blue-vs-grey, always
     solid. */
  const exitColor = phaseStatusColor(isoNode.task.status)
  const exitDash = 'none'
  return (
    <g key={`iso-${isoId}`}>
      <path d={orthogonalPath(MARKER_W_CONST, entryY, taskLeft, ny)} fill="none" strokeWidth={2} strokeLinecap="round" strokeDasharray={entryDash} style={{ stroke: entryColor }} />
      <path d={orthogonalPath(taskRight, ny, exitX, hasGate ? gateCenterY : exitY, 0, exitX - GAP_X / 2)} fill="none" strokeWidth={2} strokeLinecap="round" strokeDasharray={exitDash} style={{ stroke: exitColor }} />
    </g>
  )
}

interface LeafPathArgs {
  leafId: string
  nodes: Map<string, TreeNode>
  ENTRY_W: number; NODE_W: number; NODE_H: number; GAP_X: number; GAP_Y: number
}

function renderLeafToGatePath(args: LeafPathArgs & { gateX: number; gateCenterY: number; exitConvergenceX: number }) {
  const { leafId, nodes, ENTRY_W, NODE_W, NODE_H, GAP_X, GAP_Y, gateX, gateCenterY, exitConvergenceX } = args
  const leafNode = nodes.get(leafId)
  if (!leafNode) return null
  const nx = ENTRY_W + leafNode.col * (NODE_W + GAP_X) + NODE_W
  const ny = leafNode.row * (NODE_H + GAP_Y) + NODE_H / 2
  const c = phaseStatusColor(leafNode.task.status)
  return <path key={`gate-${leafId}`} d={orthogonalPath(nx, ny, gateX, gateCenterY, 0, exitConvergenceX)} fill="none" strokeWidth={2} strokeLinecap="round" strokeDasharray="none" style={{ stroke: c }} />
}

function renderLeafToExitPath(args: LeafPathArgs & { treeW: number; exitY: number }) {
  const { leafId, nodes, ENTRY_W, NODE_W, NODE_H, GAP_X, GAP_Y, treeW, exitY } = args
  const leafNode = nodes.get(leafId)
  if (!leafNode) return null
  const nx = ENTRY_W + leafNode.col * (NODE_W + GAP_X) + NODE_W
  const ny = leafNode.row * (NODE_H + GAP_Y) + NODE_H / 2
  /* Skarmaudit-15c — leaf-to-exit (no gate) follows the unified
     flow rule: blue when leaf is done/wip, grey when pending. Aimed
     at exitY (single-leaf-row Y when collapsed, midY otherwise). */
  const c = phaseStatusColor(leafNode.task.status)
  return (
    <path
      key={`exit-${leafId}`}
      d={orthogonalPath(nx, ny, ENTRY_W + treeW + GAP_X, exitY, 0)}
      fill="none"
      strokeWidth={2}
      strokeLinecap="round"
      strokeDasharray="none"
      style={{ stroke: c }}
    />
  )
}

const MARKER_W_CONST = 140

interface PhaseMarkerInfo {
  id: string; name: string; status: TaskStatus
  progress: { done: number; total: number; pct: number }
}

function PhaseSideMarker({
  phaseInfo, fallbackLabel, markerWidth, anchorY, side, onNavigate,
}: Readonly<{
  phaseInfo: PhaseMarkerInfo | null | undefined
  fallbackLabel: string
  markerWidth: number
  anchorY: number
  side: 'start' | 'end'
  onNavigate?: (phaseId: string) => void
}>) {
  const isStart = side === 'start'
  /* Skarmaudit-15c #2 - fallback markers inset on the inner side so
     the label clears the line endpoint.

     Audit-15c #7 - vertical anchor centred on the connector line
     endpoint (entryY / exitY) instead of treeH/2, so the marker
     label and the entry/exit chrome line stay co-linear when all
     roots/leaves share a single row even if the tree itself spans
     more rows for branching children. Inline style for top so jsdom
     can introspect for tests. */
  const isFallback = !phaseInfo
  const fallbackInset: React.CSSProperties = isFallback
    ? (isStart ? { paddingRight: 8 } : { paddingLeft: 8 })
    : {}
  return (
    <Box
      data-testid={isStart ? 'start-marker' : 'end-marker'}
      data-fallback={isFallback ? 'true' : 'false'}
      data-anchor-y={anchorY}
      style={{
        position: 'absolute',
        ...(isStart ? { left: 0 } : { right: 0 }),
        top: anchorY - NODE_H / 2,
        width: markerWidth,
        height: NODE_H,
        display: 'flex',
        alignItems: 'center',
        justifyContent: isStart ? 'flex-end' : 'flex-start',
        ...fallbackInset,
      }}
    >
      {phaseInfo
        ? <PhaseMarkerCard phase={phaseInfo} markerWidth={markerWidth} onNavigate={onNavigate} />
        : <PhaseMarkerFallback label={fallbackLabel} />}
    </Box>
  )
}

interface PhasePathsLayerProps {
  phase: Phase
  nodes: Map<string, TreeNode>
  rootIds: string[]
  leafIds: string[]
  isolatedIds: Set<string>
  ENTRY_W: number; NODE_W_VAL: number; NODE_H_VAL: number
  GAP_X_VAL: number; GAP_Y_VAL: number
  treeW: number; entryY: number; exitY: number
  hasGate: boolean
  gateX: number; gateCenterY: number; exitConvergenceX: number
  entryDash: string; entryColor: string
  markerWidth: number
  lineColor: string
}

function PhasePathsLayer(props: Readonly<PhasePathsLayerProps>) {
  const {
    phase, nodes, rootIds, leafIds, isolatedIds,
    ENTRY_W, NODE_W_VAL, NODE_H_VAL, GAP_X_VAL, GAP_Y_VAL,
    treeW, entryY, exitY, hasGate, gateX, gateCenterY, exitConvergenceX,
    entryDash, entryColor, markerWidth,
  } = props
  const nonIsolatedRootIds = rootIds.filter((id) => !isolatedIds.has(id))
  const nonIsolatedLeafIds = leafIds.filter((id) => !isolatedIds.has(id))
  return (
    <svg style={{ position: 'absolute', top: 0, left: 0, width: '100%', height: '100%', pointerEvents: 'none', overflow: 'visible' }} aria-hidden="true">
      {nonIsolatedRootIds.map((rootId) => {
        const rootNode = nodes.get(rootId)
        if (!rootNode) return null
        const nx = ENTRY_W + rootNode.col * (NODE_W_VAL + GAP_X_VAL)
        const ny = rootNode.row * (NODE_H_VAL + GAP_Y_VAL) + NODE_H_VAL / 2
        return <path key={`entry-${rootId}`} d={orthogonalPath(markerWidth, entryY, nx, ny)} fill="none" strokeWidth={2} strokeLinecap="round" strokeDasharray={entryDash} style={{ stroke: entryColor }} />
      })}

      {Array.from(isolatedIds).map((isoId) => renderIsolatedTaskPaths({
        isoId, nodes, ENTRY_W, entryY, exitY, NODE_W: NODE_W_VAL, NODE_H: NODE_H_VAL,
        GAP_X: GAP_X_VAL, GAP_Y: GAP_Y_VAL, treeW, hasGate, gateX, gateCenterY, entryDash, entryColor,
      }))}

      {hasGate && phase.gate ? (
        <>
          {nonIsolatedLeafIds.map((leafId) => renderLeafToGatePath({
            leafId, nodes, ENTRY_W, NODE_W: NODE_W_VAL, NODE_H: NODE_H_VAL,
            GAP_X: GAP_X_VAL, GAP_Y: GAP_Y_VAL, gateX, gateCenterY, exitConvergenceX,
          }))}
          <path
            d={orthogonalPath(gateX + NODE_W_VAL, gateCenterY, ENTRY_W + treeW + GAP_X_VAL, exitY)}
            fill="none"
            strokeWidth={2}
            strokeLinecap="round"
            /* Skarmaudit-15c - gate-to-next-phase exit line follows
               the unified flow rule: solid wf.signal blue when the
               gate has passed (the path is unlocked forward), solid
               grey when still gated. The bottom completion gauge
               stays the dedicated passed signal on the gate card
               itself; this line carries the cross-phase flow signal
               so done-phase rails read as a continuous blue path. */
            strokeDasharray="none"
            style={{ stroke: phase.gate.passed ? pv('wf-signal') : pva('text-secondary', 0.3) }}
          />
        </>
      ) : (
        nonIsolatedLeafIds.map((leafId) => renderLeafToExitPath({
          leafId, nodes, ENTRY_W, NODE_W: NODE_W_VAL, NODE_H: NODE_H_VAL,
          GAP_X: GAP_X_VAL, GAP_Y: GAP_Y_VAL, treeW, exitY,
        }))
      )}
    </svg>
  )
}

function GatePopoverChecklistItem({ icon, text }: Readonly<{ icon: React.ReactNode; text: string }>) {
  return (
    <Box sx={{ display: 'flex', alignItems: 'flex-start', gap: 1, py: 0.5 }}>
      {icon}
      <Typography variant="body2" sx={{ fontSize: '0.82rem', userSelect: 'text', cursor: 'text' }}>{text}</Typography>
    </Box>
  )
}

function GatePopoverChecklist({ gate }: Readonly<{ gate: NonNullable<Phase['gate']> }>) {
  if (gate.enrichedChecklist) {
    return (
      <>
        {gate.enrichedChecklist.map((item) => (
          <GatePopoverChecklistItem
            key={item.item}
            icon={gateItemIcon(item, gate.passed)}
            text={item.item}
          />
        ))}
      </>
    )
  }
  const fallbackIcon = gate.passed
    ? <CheckCircleIcon data-testid="gate-item-icon-passed" sx={{ fontSize: 16, color: pv('status-done'), mt: 0.25, flexShrink: 0 }} />
    : <RadioButtonUncheckedIcon data-testid="gate-item-icon-unchecked" sx={{ fontSize: 16, color: 'text.secondary', mt: 0.25, flexShrink: 0 }} />
  return (
    <>
      {gate.checklist.map((item) => (
        <GatePopoverChecklistItem
          key={checklistItemText(item)}
          icon={fallbackIcon}
          text={checklistItemText(item)}
        />
      ))}
    </>
  )
}

function buildGatePrompt(phase: Phase, planName: string | undefined): string {
  const gate = phase.gate
  if (!gate) return ''
  const checklist = gate.checklist.map((item, i) => `${i + 1}. ${checklistItemText(item)}`).join('\n')
  const cmdLine = gate.command ? `\nVerification command: ${gate.command}` : ''
  return [
    `We are closing phase "${phase.name}" from execution plan "${planName ?? 'unknown'}".`,
    `Verify the "${gate.name}" gate checks:`,
    '',
    checklist,
    cmdLine,
    '',
    `Run the verification${gate.command ? ' command' : ''}, confirm all checks pass, then update the execution plan YAML to set this gate's passed: true.`,
  ].filter((l) => l !== '').join('\n')
}

function GatePromptPanel({ prompt }: Readonly<{ prompt: string }>) {
  return (
    <Paper
      sx={{
        mt: 1.5,
        p: 1,
        display: 'flex',
        alignItems: 'flex-start',
        bgcolor: 'surfaceVariant',
        border: 'none',
      }}
    >
      <Typography
        component="pre"
        sx={{
          fontFamily: 'var(--font-mono)',
          fontSize: '0.75rem',
          flex: 1,
          wordBreak: 'break-word',
          whiteSpace: 'pre-wrap',
          m: 0,
          userSelect: 'text',
          cursor: 'text',
          lineHeight: 1.6,
        }}
      >
        {prompt}
      </Typography>
      <IconButton
        size="small"
        onClick={() => navigator.clipboard.writeText(prompt)}
        aria-label="Copy gate prompt"
      >
        <ContentCopyIcon fontSize="small" />
      </IconButton>
    </Paper>
  )
}

interface GateColumnProps {
  phase: Phase
  gateX: number
  gateY: number
  planName?: string
}

function GateColumn({ phase, gateX, gateY, planName }: Readonly<GateColumnProps>) {
  const [gateAnchor, setGateAnchor] = useState<HTMLElement | null>(null)
  if (!phase.gate) return null
  const gate = phase.gate
  const showPrompt = shouldShowGatePrompt(gate)
  const prompt = showPrompt ? buildGatePrompt(phase, planName) : ''

  return (
    <>
      <Box
        data-testid="gate-node"
        data-node-id="__gate"
        onClick={(e) => setGateAnchor(e.currentTarget)}
        sx={{
          position: 'absolute',
          left: gateX,
          top: gateY,
          width: NODE_W,
          height: NODE_H,
          /* Mirror the TaskNodeCard layout: column with flex-start
             so meta sits beneath the title row and the bottom slot
             is reserved for the gate completion gauge. Padding,
             border-radius, and border treatment all match. */
          display: 'flex',
          flexDirection: 'column',
          justifyContent: 'flex-start',
          gap: 0.25,
          pt: 0.75,
          pb: 0.5,
          px: 1,
          borderRadius: 0,
          /* Skarmaudit-15b #2 - gate inline node aligns with task
             card chrome: steel hairline border + surface1 bg
             regardless of passed state. The bottom GateProgressBar
             carries the passed signal (fills 100% green when passed),
             same vocabulary as task cards' bottom bar. Dashed
             border kept for the not-yet-passed state to flag the
             "still gated" semantic. */
          border: gate.passed ? '1px solid' : '1px dashed',
          borderColor: pv('outlineVariant'),
          bgcolor: pv('surface1'),
          cursor: 'pointer',
          transition: 'border-color 0.15s ease',
          '&:hover': { borderColor: pv('primary-main') },
        }}
      >
        {/* Row 1: lock icon + gate name (mirrors task title row). */}
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.4 }}>
          {gate.passed
            ? <LockOpenIcon sx={{ fontSize: 12, color: pv('status-done'), flexShrink: 0 }} />
            : <LockIcon sx={{ fontSize: 12, color: 'text.secondary', flexShrink: 0 }} />}
          <Typography variant="wfBody" noWrap sx={{ flex: 1, fontSize: '12px', fontWeight: 500, color: gate.passed ? 'text.secondary' : 'text.primary', lineHeight: 1.3 }}>
            {gate.name}
          </Typography>
        </Box>
        {/* Row 2: checks summary only — PASSED pill removed
            (audit-15b #2; the 100% green completion gauge at the
            bottom edge is the passed signal, not a redundant pill). */}
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.4, pl: 1.5, minHeight: 20 }}>
          <Typography variant="wfLabel" sx={{ color: 'text.secondary' }}>
            {gateNodeSummary(gate)}
          </Typography>
        </Box>
        <GateProgressBar gate={gate} />
      </Box>
      <Popover
        open={!!gateAnchor}
        anchorEl={gateAnchor}
        onClose={() => setGateAnchor(null)}
        anchorOrigin={{ vertical: 'bottom', horizontal: 'left' }}
        transformOrigin={{ vertical: 'top', horizontal: 'left' }}
        slotProps={{ paper: { sx: { maxWidth: 420, p: 2, border: '1px solid', borderColor: 'divider', bgcolor: 'background.paper' } } }}
      >
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 1 }}>
          <Typography variant="wfH3" sx={{ flex: 1 }}>
            {gate.name}
          </Typography>
          {gate.passed && <StatusPill status="completed" label="PASSED" />}
        </Box>
        <GatePopoverChecklist gate={gate} />
        {showPrompt && <GatePromptPanel prompt={prompt} />}
      </Popover>
    </>
  )
}

export function PhaseTree({
  phase, sessions, autopilotSessions, onTaskClick, prevPhase, nextPhase, onNavigatePhase, projectPath: _projectPath, planName, isV2 = false,
}: Readonly<{
  phase: Phase; allTasks: Map<string, Task>; sessions: Session[]; autopilotSessions: AutopilotSession[]
  onTaskClick: (task: Task) => void
  prevPhase?: PhaseMarkerInfo | null; nextPhase?: PhaseMarkerInfo | null
  onNavigatePhase?: (phaseId: string) => void
  projectPath?: string
  planName?: string
  isV2?: boolean
}>) {
  const containerRef = useRef<HTMLDivElement>(null)
  const { nodes, maxCol, maxRow } = useMemo(() => buildTreeLayout(phase.tasks), [phase.tasks])

  // Layout with entry/exit markers and gate column
  const MARKER_W = MARKER_W_CONST
  const ENTRY_W = MARKER_W + GAP_X
  const EXIT_W = GAP_X + MARKER_W
  const hasGate = !!phase.gate
  const lastCol = hasGate ? maxCol + 1 : maxCol
  const treeW = (lastCol + 1) * (NODE_W + GAP_X) - GAP_X
  const treeH = (maxRow + 1) * (NODE_H + GAP_Y) - GAP_Y
  const totalW = ENTRY_W + treeW + EXIT_W
  const midY = treeH / 2
  /* Fallback connector color (used when neither prev nor next
     phase is done/wip) — signal-blue brand accent at 0.4 so the
     chrome reads as brand even when no status story is driving
     the line. Bumped from 0.22 per operator feedback that the
     graph should carry more visible brand-blue presence. */
  const lineColor = pva('wf-signal', 0.4)

  // Find root and leaf nodes for entry/exit connector lines
  const childSet = useMemo(() => {
    const s = new Set<string>()
    for (const [, node] of nodes) for (const cid of node.children) s.add(cid)
    return s
  }, [nodes])
  const rootIds = useMemo(() => Array.from(nodes.keys()).filter((id) => !childSet.has(id)), [nodes, childSet])
  const leafIds = useMemo(() => Array.from(nodes.entries()).filter(([, n]) => n.children.length === 0).map(([id]) => id), [nodes])
  // Isolated tasks: both root AND leaf (no deps, nothing depends on them)
  const isolatedIds = useMemo(() => new Set(rootIds.filter((id) => leafIds.includes(id))), [rootIds, leafIds])

  /* Skarmaudit-15c — entry line from prev-phase marker (or "Start")
     to the first task carries the unified flow rule: blue when prev
     phase is done/wip, grey when prev is pending or undefined. Always
     solid - dashes removed globally per operator.

     Audit-15c #8 - when there is no prev phase ("Start" placeholder),
     the line still goes blue once any root task has started (wip or
     done). The first phase otherwise had no flow signal at all. */
  const someRootActive = rootIds.some((id) => {
    const status = nodes.get(id)?.task.status
    return status === 'done' || status === 'wip'
  })
  const entryColor = prevPhase
    ? phaseEntryColor(prevPhase.status, pva('text-secondary', 0.3))
    : (someRootActive ? pv('wf-signal') : pva('text-secondary', 0.3))
  const entryDash = 'none'

  /* Audit-15c #7 - entry/exit chrome lines should be straight when
     all roots (resp. leaves) share a single row, even if the tree
     itself spans more rows for branching. Anchor Y collapses to the
     row's vertical centre when single-row; falls back to the tree's
     mid-line when the line needs to branch up/down to multiple
     roots/leaves. */
  const rowYOf = (row: number) => row * (NODE_H + GAP_Y) + NODE_H / 2
  const rootRowSet = new Set(rootIds.map((id) => nodes.get(id)?.row ?? 0))
  const leafRowSet = new Set(leafIds.map((id) => nodes.get(id)?.row ?? 0))
  const entryY = rootRowSet.size === 1
    ? rowYOf([...rootRowSet][0])
    : midY
  const exitY = leafRowSet.size === 1
    ? rowYOf([...leafRowSet][0])
    : midY

  // Gate node positioning - aligns with leaves so leaf-to-gate is straight
  const gateX = hasGate ? ENTRY_W + (maxCol + 1) * (NODE_W + GAP_X) : 0
  const gateCenterY = exitY
  const gateY = gateCenterY - NODE_H / 2

  // Exit convergence: all exit lines turn vertical at the same X (just before gate/exit)
  const exitTargetX = hasGate ? gateX : (ENTRY_W + treeW + GAP_X)
  const exitConvergenceX = exitTargetX - GAP_X / 2

  return (
    <Box
      ref={containerRef}
      data-testid="phase-tree"
      style={{ width: totalW, height: treeH }}
      sx={{
        position: 'relative',
        mx: 'auto',
        my: 1.5,
      }}
    >

      <PhaseSideMarker
        phaseInfo={prevPhase}
        fallbackLabel="Start"
        markerWidth={MARKER_W}
        anchorY={entryY}
        side="start"
        onNavigate={onNavigatePhase}
      />

      <PhasePathsLayer
        phase={phase}
        nodes={nodes}
        rootIds={rootIds}
        leafIds={leafIds}
        isolatedIds={isolatedIds}
        ENTRY_W={ENTRY_W}
        NODE_W_VAL={NODE_W}
        NODE_H_VAL={NODE_H}
        GAP_X_VAL={GAP_X}
        GAP_Y_VAL={GAP_Y}
        treeW={treeW}
        entryY={entryY}
        exitY={exitY}
        hasGate={hasGate}
        gateX={gateX}
        gateCenterY={gateCenterY}
        exitConvergenceX={exitConvergenceX}
        entryDash={entryDash}
        entryColor={entryColor}
        markerWidth={MARKER_W}
        lineColor={lineColor}
      />

      <TreeConnectors nodes={nodes} containerRef={containerRef} />

      {Array.from(nodes.values()).map((node) => {
        const session = findSessionForTask(node.task.id, sessions, node.task.status)
        const autopilot = autopilotSessions.find((a) => a.task === node.task.id)

        return (
          <Box
            key={node.task.id}
            sx={{
              position: 'absolute',
              left: ENTRY_W + node.col * (NODE_W + GAP_X),
              top: node.row * (NODE_H + GAP_Y),
            }}
          >
            <TaskNodeCard
              node={node}
              session={session}
              autopilotSession={autopilot}
              onClick={() => onTaskClick(node.task)}
              isV2={isV2}
            />
          </Box>
        )
      })}

      {hasGate && (
        <GateColumn phase={phase} gateX={gateX} gateY={gateY} planName={planName} />
      )}

      <PhaseSideMarker
        phaseInfo={nextPhase}
        fallbackLabel="Finished"
        markerWidth={MARKER_W}
        anchorY={exitY}
        side="end"
        onNavigate={onNavigatePhase}
      />
    </Box>
  )
}

/* ═══ Compact Phase Card (horizontal rail) ═══ */

export function CompactPhaseCard({
  phase, isActive, onClick, cardRef, runningTaskProgress,
}: Readonly<{
  phase: Phase; isActive: boolean; onClick: () => void; cardRef?: React.RefObject<HTMLDivElement | null>
  /* Audit-12+13 — Map<taskId, fraction> of tasks with live autopilot
     sessions. Pending+autopilot-active tasks count toward wip status
     and contribute their actual sub-phase fraction to phase progress.
     Optional — falls back to plain phaseStatus/phaseProgress. */
  runningTaskProgress?: ReadonlyMap<string, number>
}>) {
  const overlay = runningTaskProgress ?? new Map<string, number>()
  const status = phaseStatusWithOverlay(phase, overlay)
  const progress = phaseProgressWithOverlay(phase, overlay)
  const statusPath = `status-${status}`
  const color = pv(statusPath)

  /* Skarmaudit-15c #3 — selected/expanded phase card reads as the
     wf.signal blue selection regardless of phase status. The done
     state continues to communicate via the bottom PhaseGauge fill
     (100% green when status==='done'); a green-tinted border + bg
     on a "done + selected" card was redundant (and visually noisy).
     Inline style for the active state so jsdom can introspect the
     border colour for tests; sx applies via emotion class. */
  /* Audit-15c #5 - active border at half saturation reads as
     "selected" without dominating the card chrome. Operator: too
     prominent at full saturation. */
  const activeBorder = isActive
    ? `1px solid ${pva('wf-signal', 0.5)}`
    : undefined
  const activeBg = isActive
    ? pva('wf-signal', 0.06)
    : undefined
  const activeStyle: React.CSSProperties = isActive
    ? { border: activeBorder, backgroundColor: activeBg }
    : {}
  return (
    <Box
      ref={cardRef}
      data-testid="phase-card"
      data-active={isActive ? 'true' : 'false'}
      onClick={onClick}
      role="button"
      aria-expanded={isActive}
      aria-label={`${phase.name}, ${progress.pct}% complete, ${progress.done} of ${progress.total} tasks done`}
      style={activeStyle}
      sx={{
        position: 'relative',
        scrollSnapAlign: 'center',
        flexShrink: 0,
        minWidth: 140,
        maxWidth: 200,
        /* Match TaskNodeCard height + padding so the rail reads
           as one consistent rhythm of cards. The bottom-edge
           PhaseGauge anchors against this card. */
        height: NODE_H,
        display: 'flex',
        flexDirection: 'column',
        justifyContent: 'flex-start',
        gap: 0.25,
        pt: 0.75,
        pb: 0.5,
        px: 1,
        borderRadius: 0,
        border: '1px solid',
        borderColor: pv('outlineVariant'),
        bgcolor: pv('surface1'),
        cursor: 'pointer',
        userSelect: 'none',
        transition: `all var(--motion-short4, 200ms) var(--motion-emphasized, cubic-bezier(0.2, 0, 0, 1))`,
        '&:hover': {
          borderColor: pva('wf-signal', 0.5),
          bgcolor: pva('wf-signal', 0.04),
        },
      }}
    >
      {/* Row 1: status dot + phase name (mirrors task title row). */}
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.4 }}>
        <StatusDot status={status} size={6} />
        <Typography variant="wfBody" noWrap sx={{ flex: 1, fontSize: '12px', fontWeight: 500, lineHeight: 1.2 }}>
          {phase.name}
        </Typography>
      </Box>
      {/* Row 2: done/total fraction. The progress bar moves to the
         bottom edge as PhaseGauge so the card matches task chrome. */}
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.4, pl: 1.5, minHeight: 18 }}>
        <Typography variant="wfLabel" sx={{ color, flexShrink: 0 }}>
          {progress.done}/{progress.total}
        </Typography>
      </Box>
      <PhaseGauge status={status} pct={progress.pct} />
    </Box>
  )
}

/* ═══ Phase card connector (SVG line between cards) ═══ */

function PhaseCardConnector({ prevStatus }: Readonly<{ prevStatus: TaskStatus }>) {
  /* Skarmaudit-15c — phase-rail connector follows the unified flow
     rule: solid wf.signal blue when the predecessor phase is done
     (or actively wip), solid grey otherwise. Always solid - dashes
     are noise per operator follow-up. Inline style so jsdom can
     introspect the colour for tests (sx applies via emotion classes
     that jsdom does not resolve). */
  const isFlow = prevStatus === 'done' || prevStatus === 'wip'
  const color = isFlow ? pv('wf-signal') : pva('text-secondary', 0.3)
  return (
    <Box
      data-testid="phase-connector"
      data-prev-status={prevStatus}
      sx={{
        flexShrink: 0,
        width: 24,
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <Box
        data-testid="phase-connector-line"
        data-flow={isFlow ? 'true' : 'false'}
        style={{
          width: '100%',
          height: 0,
          borderTop: `2px solid ${color}`,
          borderRadius: 0,
        }}
      />
    </Box>
  )
}

/* ═══ localStorage helpers ═══ */

function getStorageKey(planName: string): string {
  return `pipeline-expanded-${planName}`
}

function loadExpandedPhase(planName: string, phases: Phase[]): string | null {
  try {
    const raw = localStorage.getItem(getStorageKey(planName))
    if (!raw) return null
    const parsed = JSON.parse(raw)
    if (typeof parsed === 'string') {
      // Validate: phase ID must exist
      if (phases.some((p) => p.id === parsed)) return parsed
    }
    return null
  } catch {
    return null
  }
}

function saveExpandedPhase(planName: string, phaseId: string | null): void {
  try {
    localStorage.setItem(getStorageKey(planName), JSON.stringify(phaseId))
  } catch {
    // Silently ignore storage errors
  }
}

/* ═══ Main Pipeline ═══ */

interface Props {
  plan: Plan
  sessions?: Session[]
  projectPath?: string
  /* Audit-18 followup - plan directory (where execution-plan.yaml
     lives). Forwarded to SessionPanel so BriefView's artifact_refs
     resolution and isPlan2 dispatch have the surrounding plan
     context. Falls back to projectPath when omitted. */
  planDir?: string | null
}

export default function Pipeline({ plan, sessions = [], projectPath, planDir }: Props) {
  const { data: autopilotSessions } = useAutopilots()

  const isV2 = isPlan2(plan)

  const allTasks = useMemo(() => {
    const m = new Map<string, Task>()
    for (const phase of plan.phases) for (const task of phase.tasks) m.set(task.id, task)
    return m
  }, [plan])

  /* Audit-12+13+15 — map of {taskId → sub-phase fraction (0..1)}
     for tasks with a live autopilot session. The plan often still
     reads 'pending' while autopilot is running; overlay variants
     of phaseStatus/phaseProgress treat these as wip and weight the
     parent phase's progress by each task's actual sub-phase depth
     (not a flat 0.5). Shares `autopilotPhaseFraction` with
     TaskProgressBar so both apply the same canonical pipeline floor
     when only the first phases have been emitted (audit-15). */
  const runningTaskProgress = useMemo(() => {
    const m = new Map<string, number>()
    for (const ap of autopilotSessions ?? []) {
      if (ap.status !== 'running' || !ap.task) continue
      const ratio = autopilotPhaseFraction(ap)
      if (ratio === null) continue
      m.set(ap.task, ratio)
    }
    return m
  }, [autopilotSessions])

  // Single expansion: expandedPhaseId: string | null
  const [expandedPhaseId, setExpandedPhaseId] = useState<string | null>(() => {
    const stored = loadExpandedPhase(plan.name, plan.phases)
    if (stored) return stored
    // Auto-expand first WIP/failed phase
    for (const phase of plan.phases) {
      const s = phaseStatus(phase)
      if (s === 'wip' || s === 'failed') return phase.id
    }
    return null
  })

  const [selectedTask, setSelectedTask] = useState<Task | null>(null)

  const handleTaskClick = useCallback((task: Task) => {
    setSelectedTask(task)
  }, [])

  // Match selected task to autopilot session
  const selectedAutopilot = selectedTask
    ? autopilotSessions?.find((a) => a.task === selectedTask.id) ?? null
    : null

  // Find previous phase gate for the selected task
  const selectedPreviousGate = useMemo(() => {
    if (!selectedTask) return null
    for (let i = 0; i < plan.phases.length; i++) {
      const phase = plan.phases[i]
      if (phase.tasks.some((t) => t.id === selectedTask.id) && i > 0) {
        const prevGate = plan.phases[i - 1].gate
        return prevGate ? { name: prevGate.name, passed: prevGate.passed } : null
      }
    }
    return null
  }, [selectedTask, plan.phases])

  const togglePhase = useCallback((id: string) => {
    setExpandedPhaseId((prev) => {
      const next = prev === id ? null : id
      saveExpandedPhase(plan.name, next)
      return next
    })
  }, [plan.name])

  const expandedPhase = plan.phases.find((p) => p.id === expandedPhaseId) ?? null
  const expandedPhaseIdx = expandedPhase ? plan.phases.indexOf(expandedPhase) : -1
  const prevPhase = useMemo(() => {
    if (expandedPhaseIdx <= 0) return null
    const p = plan.phases[expandedPhaseIdx - 1]
    return { id: p.id, name: p.name, status: phaseStatusWithOverlay(p, runningTaskProgress), progress: phaseProgressWithOverlay(p, runningTaskProgress) }
  }, [expandedPhaseIdx, plan.phases, runningTaskProgress])
  const nextPhase = useMemo(() => {
    if (expandedPhaseIdx < 0 || expandedPhaseIdx >= plan.phases.length - 1) return null
    const p = plan.phases[expandedPhaseIdx + 1]
    return { id: p.id, name: p.name, status: phaseStatusWithOverlay(p, runningTaskProgress), progress: phaseProgressWithOverlay(p, runningTaskProgress) }
  }, [expandedPhaseIdx, plan.phases, runningTaskProgress])

  // Ref for auto-scroll to active phase card. Audit-list-filters #2:
  // scrollIntoView with block: 'nearest' propagates vertically up the
  // parent chain and scrolls outer ancestors (e.g. the Plans-tab vertical
  // scroller) every time a Pipeline mounts. Plans filter clicks remount
  // Pipelines, which made the viewport jump on every chip click. We now
  // scroll only the horizontal rail directly via scrollLeft so the effect
  // is contained to this component.
  const railRef = useRef<HTMLDivElement>(null)
  const activeCardRef = useRef<HTMLDivElement>(null)
  useEffect(() => {
    const rail = railRef.current
    const card = activeCardRef.current
    if (!rail || !card) return
    const cardCenter = card.offsetLeft + card.offsetWidth / 2
    const target = cardCenter - rail.clientWidth / 2
    rail.scrollLeft = Math.max(0, target)
  }, [])

  return (
    <Box>
      {/* Horizontal card rail — pt 2 + px 2 give the rail visible
         breathing room from the project header divider above and
         the panel viewport edge so the cards don't touch the chrome. */}
      <Box
        ref={railRef}
        sx={{
          display: 'flex',
          overflowX: 'auto',
          scrollSnapType: 'x mandatory',
          gap: 0,
          pt: 2,
          pb: 1,
          px: 2,
          mb: 1,
          /* Audit-16 - hover-reveal: 8px space always reserved (no
             layout shift) but track/thumb transparent until container
             hover. Identical rules on inner task tree below. */
          '&::-webkit-scrollbar': { height: 8 },
          '&::-webkit-scrollbar-track': { bgcolor: 'transparent' },
          '&::-webkit-scrollbar-thumb': {
            bgcolor: 'transparent',
            borderRadius: 4,
            transition: 'background-color 0.2s',
          },
          '&:hover::-webkit-scrollbar-track': { bgcolor: pva('text-secondary', 0.06) },
          '&:hover::-webkit-scrollbar-thumb': { bgcolor: pva('text-secondary', 0.4) },
          '&:hover::-webkit-scrollbar-thumb:hover': { bgcolor: pva('text-secondary', 0.6) },
        }}
      >
        {plan.phases.map((phase, i) => (
          <Fragment key={phase.id}>
            {i > 0 && <PhaseCardConnector prevStatus={phaseStatusWithOverlay(plan.phases[i - 1], runningTaskProgress)} />}
            <CompactPhaseCard
              phase={phase}
              isActive={expandedPhaseId === phase.id}
              onClick={() => togglePhase(phase.id)}
              cardRef={expandedPhaseId === phase.id ? activeCardRef : undefined}
              runningTaskProgress={runningTaskProgress}
            />
          </Fragment>
        ))}
      </Box>

      {/* Single expansion panel — wf.ink darker bg so the surface1
          task/gate cards inside stand out as a brighter surface
          against the deep canvas. */}
      <Collapse in={expandedPhaseId !== null} timeout={{ enter: 300, exit: 200 }} unmountOnExit>
        {expandedPhase && (
          <Box
            sx={{
              position: 'relative',
              borderRadius: 0,
              border: '1px solid',
              borderColor: 'wf.steel',
              bgcolor: 'wf.ink',
              overflow: 'hidden',
              mb: 1,
            }}
          >
            {/* Audit-20 #1 — tier-label header per chrome.md:121-125.
                Marks the expanded panel as one hierarchy tier deeper
                than the phase rail above, scoped to the active phase
                so the user reads "you are zooming into Phase X's
                tasks" rather than perceiving a second peer pipeline. */}
            <Box
              sx={{
                display: 'flex',
                alignItems: 'center',
                gap: '6px',
                pt: 1.5,
                pb: 0.5,
                px: 2,
              }}
            >
              <Box
                data-testid="phase-tasks-tier-rule"
                sx={{
                  width: 8,
                  height: 1,
                  bgcolor: 'wf.signal',
                  flexShrink: 0,
                }}
              />
              <Typography
                data-testid="phase-tasks-tier-label"
                variant="wfLabel"
                sx={{
                  color: 'wf.signal',
                  letterSpacing: '0.22em',
                }}
              >
                {`TASKS · ${expandedPhase.name}`}
              </Typography>
            </Box>
            <Box sx={{ px: 1, py: 1 }}>
              {expandedPhase.tasks.length === 0 ? (
                <Typography variant="wfBody" color="text.secondary" sx={{ px: 1, py: 1, fontStyle: 'italic', display: 'block' }}>No tasks defined yet</Typography>
              ) : (
                <Box sx={{
                  overflowX: 'auto',
                  /* Audit-16 - hover-reveal pattern matching phase rail above. */
                  '&::-webkit-scrollbar': { height: 8 },
                  '&::-webkit-scrollbar-track': { bgcolor: 'transparent' },
                  '&::-webkit-scrollbar-thumb': {
                    bgcolor: 'transparent',
                    borderRadius: 4,
                    transition: 'background-color 0.2s',
                  },
                  '&:hover::-webkit-scrollbar-track': { bgcolor: pva('text-secondary', 0.06) },
                  '&:hover::-webkit-scrollbar-thumb': { bgcolor: pva('text-secondary', 0.4) },
                  '&:hover::-webkit-scrollbar-thumb:hover': { bgcolor: pva('text-secondary', 0.6) },
                }}>
                  <PhaseTree phase={expandedPhase} allTasks={allTasks} sessions={sessions} autopilotSessions={autopilotSessions ?? []} onTaskClick={handleTaskClick} prevPhase={prevPhase} nextPhase={nextPhase} onNavigatePhase={(phaseId) => togglePhase(phaseId)} projectPath={projectPath} planName={plan.name} isV2={isV2} />
                </Box>
              )}
            </Box>
            <CornerReticles size={12} />
          </Box>
        )}
      </Collapse>

      {/* Unified session panel dialog */}
      <Dialog
        open={selectedTask !== null}
        onClose={() => setSelectedTask(null)}
        maxWidth={false}
        PaperProps={{
          sx: {
            width: '90vw',
            maxWidth: 1200,
            height: '94vh',
            maxHeight: 1100,
            display: 'flex',
            flexDirection: 'column',
            overflow: 'hidden',
          },
        }}
      >
        {selectedTask && (
          <SessionPanel
            task={selectedTask}
            autopilotSession={selectedAutopilot}
            projectPath={projectPath}
            allTasks={allTasks}
            previousGate={selectedPreviousGate}
            plan={plan}
            planDir={planDir ?? projectPath ?? null}
            onClose={() => setSelectedTask(null)}
            onSelectTask={(id) => {
              const t = allTasks.get(id)
              if (t) setSelectedTask(t)
            }}
          />
        )}
      </Dialog>
    </Box>
  )
}
