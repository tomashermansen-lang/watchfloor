import { useState, useCallback, useEffect, useMemo, useRef, lazy, Suspense, type ReactElement } from 'react'
import Box from '@mui/material/Box'
import IconButton from '@mui/material/IconButton'
import List from '@mui/material/List'
import ListItem from '@mui/material/ListItem'
import ListItemIcon from '@mui/material/ListItemIcon'
import ListItemText from '@mui/material/ListItemText'
import Paper from '@mui/material/Paper'
import Skeleton from '@mui/material/Skeleton'
import Stack from '@mui/material/Stack'
import Typography from '@mui/material/Typography'
import ContentCopyIcon from '@mui/icons-material/ContentCopy'
import DescriptionIcon from '@mui/icons-material/Description'
import StatusPill from './wf/StatusPill'
import AutopilotBadge from './wf/AutopilotBadge'
import ToggleChip from './wf/ToggleChip'
import WfCheckbox from './wf/Checkbox'
import DetailHeader from './wf/DetailHeader'
import DetailSidebar from './wf/DetailSidebar'
import { taskStatusToWfStatus } from '../utils/featureStatusMapping'
import { useAutopilotArtifacts } from '../hooks/useAutopilotArtifacts'
import { usePlanArtifacts } from '../hooks/usePlanArtifacts'
import { useTaskBriefFilters, type BriefSection } from '../hooks/useTaskBriefFilters'
import PhaseStepper from './autopilot/PhaseStepper'
import { resolveArtifactRef } from '../utils/artifactRefs'
import { isPlan2 } from '../utils/planVersion'
import { taskTypeLabel } from '../utils/taskTypeIcons'
import { relativeTime } from '../utils/time'
import { useSessionControls } from '../hooks/useSessionControls'
import { SessionStateChip } from './SessionStateChip'
import { SessionControls } from './SessionControls'
import { TerminalPanel } from './TerminalPanel'
import type { Task, AutopilotSession, Plan } from '../types'

const BRIEF_SECTION_ORDER: readonly BriefSection[] = [
  'task_type',
  'what',
  'why',
  'where',
  'constraints',
  'acceptance',
  'manualtest_scenarios',
  'manual_test',
  'estimate',
  'description',
  'scope_change',
  'delivered_beyond_plan',
  'remaining_gaps',
] as const

const BRIEF_SECTION_LABELS: Record<BriefSection, string> = {
  task_type: 'Type',
  what: 'What',
  why: 'Why',
  where: 'Where',
  constraints: 'Constraints',
  acceptance: 'Acceptance',
  manualtest_scenarios: 'Test Scenarios',
  manual_test: 'Manual Test',
  estimate: 'Estimate',
  description: 'Description',
  scope_change: 'Scope Change',
  delivered_beyond_plan: 'Delivered Beyond Plan',
  remaining_gaps: 'Remaining Gaps',
}

/* Audit-19 #3 - sub-filter row shows only chips whose section
   actually has data. An empty Description chip confused the operator
   on screen 19 ("er description mening skal vaere fyldt ud - der er
   ingen ting") so we extend the rule to every plan-2.0 field too:
   if a section would render nothing, its chip is hidden. */
function availableBriefSections(task: Task, plan: Plan | null | undefined): Set<BriefSection> {
  const result = new Set<BriefSection>()
  const isPlan2Schema = plan ? isPlan2(plan) : false
  if (isPlan2Schema && task.task_type) result.add('task_type')
  if (isPlan2Schema && task.what) result.add('what')
  if (isPlan2Schema && task.why) result.add('why')
  if (isPlan2Schema && task.where && (task.where.modify?.length || task.where.create?.length || task.where.delete?.length)) {
    result.add('where')
  }
  if (isPlan2Schema && task.constraints && task.constraints.length > 0) result.add('constraints')
  if (task.acceptance && task.acceptance.length > 0) result.add('acceptance')
  if (isPlan2Schema && task.manualtest_scenarios && task.manualtest_scenarios.length > 0) {
    result.add('manualtest_scenarios')
  }
  if (isPlan2Schema && task.manual_test) result.add('manual_test')
  if (isPlan2Schema && task.estimate && (task.estimate.lines_estimate || task.estimate.duration_hours)) {
    result.add('estimate')
  }
  if (task.description) result.add('description')
  if (isPlan2Schema && task.scope_change) result.add('scope_change')
  if (isPlan2Schema && task.delivered_beyond_plan && task.delivered_beyond_plan.length > 0) {
    result.add('delivered_beyond_plan')
  }
  if (isPlan2Schema && task.remaining_gaps && task.remaining_gaps.length > 0) {
    result.add('remaining_gaps')
  }
  return result
}

const ARTIFACT_ORDER: Record<string, number> = {
  'REQUIREMENTS.md': 1,
  'DESIGN.md': 2,
  'PLAN.md': 3,
  'REVIEW.md': 4,
  'TEAM_REVIEW.md': 4,
  'TESTPLAN.md': 5,
  'STATIC_ANALYSIS.md': 6,
  'MANUAL_TEST_LOG.md': 7,
  'TEAM_QA.md': 8,
  'QA_REPORT.md': 9,
}

function mergeArtifacts(
  autopilotArtifacts: { name: string; file: string }[],
  planArtifacts: { name: string; file: string }[],
): { name: string; file: string; source: 'autopilot' | 'plan' }[] {
  const seen = new Set<string>()
  const result: { name: string; file: string; source: 'autopilot' | 'plan' }[] = []
  for (const a of autopilotArtifacts) {
    if (!seen.has(a.file)) {
      seen.add(a.file)
      result.push({ ...a, source: 'autopilot' })
    }
  }
  for (const a of planArtifacts) {
    if (!seen.has(a.file)) {
      seen.add(a.file)
      result.push({ ...a, source: 'plan' })
    }
  }
  result.sort((a, b) => (ARTIFACT_ORDER[a.file] ?? 99) - (ARTIFACT_ORDER[b.file] ?? 99))
  return result
}

function deriveSessionFlags(autopilotSession: AutopilotSession | null, task: Task | null) {
  return {
    isRunning: autopilotSession?.status === 'running',
    isCompleted: autopilotSession?.status === 'completed' || autopilotSession?.status === 'failed',
    isNotStarted: task?.status === 'pending' || task?.status === 'wip',
    hasStream: !!autopilotSession?.stream_path,
    hasPhases: !!autopilotSession,
  }
}

function TaskChipList({ label, taskIds, allTasks, onSelectTask }: Readonly<{
  label: string
  taskIds: string[]
  allTasks: Map<string, Task> | undefined
  onSelectTask: ((taskId: string) => void) | undefined
}>) {
  if (taskIds.length === 0) return null
  return (
    <Box sx={{ mt: 2, pt: 2, borderTop: '1px solid', borderColor: 'divider' }}>
      <Typography variant="wfLabel" color="text.secondary" sx={{ mb: 0.5 }}>
        {label}
      </Typography>
      <Stack spacing={0.5}>
        {taskIds.map((dep) => {
          const depTask = allTasks?.get(dep)
          const status = depTask?.status ?? 'pending'
          const wfStatus = taskStatusToWfStatus(status)
          const clickable = Boolean(onSelectTask)
          return (
            <Box
              key={dep}
              component={clickable ? 'button' : 'div'}
              type={clickable ? 'button' : undefined}
              data-testid="wf-task-dep-pill"
              onClick={clickable ? () => onSelectTask?.(dep) : undefined}
              sx={{
                display: 'flex',
                minWidth: 0,
                background: 'none',
                border: 'none',
                p: 0,
                cursor: clickable ? 'pointer' : 'default',
              }}
            >
              <StatusPill status={wfStatus} label={dep} truncate />
            </Box>
          )
        })}
      </Stack>
    </Box>
  )
}

interface SidebarExtrasProps {
  previousGate: { name: string; passed: boolean } | null
  task: Task | null
  allTasks: Map<string, Task> | undefined
  dependents: string[]
  onSelectTask: ((taskId: string) => void) | undefined
}

/* Extras-slot content for the canonical sidebar — prior-gate pill
   and task dependency lists. The chrome itself (phase rail +
   Documents + TASK BRIEF toggle) is owned by DetailSidebar; only
   these task-specific widgets live here. */
function SidebarExtras({
  previousGate,
  task,
  allTasks,
  dependents,
  onSelectTask,
}: Readonly<SidebarExtrasProps>) {
  return (
    <>
      {previousGate && (
        <Box sx={{ mt: 2, pt: 2, borderTop: '1px solid', borderColor: 'divider' }}>
          <Typography variant="wfLabel" color="text.secondary" sx={{ mb: 0.5 }}>
            After gate
          </Typography>
          <Stack spacing={0.5}>
            <Box
              component="span"
              data-testid="wf-gate-pill"
              data-status={previousGate.passed ? 'completed' : 'fault'}
              sx={{ display: 'flex', minWidth: 0 }}
            >
              <StatusPill
                status={previousGate.passed ? 'completed' : 'fault'}
                label={previousGate.name}
                truncate
              />
            </Box>
          </Stack>
        </Box>
      )}

      <TaskChipList label="Depends on" taskIds={task?.depends ?? []} allTasks={allTasks} onSelectTask={onSelectTask} />
      <TaskChipList label="Required by" taskIds={dependents} allTasks={allTasks} onSelectTask={onSelectTask} />

      {/* Audit-19 #7 - parallel_group sits next to predecessor /
          follower chips per operator request. The id has no
          navigation target (a group is not a task) so the pill is a
          plain non-clickable StatusPill. */}
      {task?.parallel_group && (
        <Box sx={{ mt: 2, pt: 2, borderTop: '1px solid', borderColor: 'divider' }}>
          <Typography variant="wfLabel" color="text.secondary" sx={{ mb: 0.5 }}>
            Parallel group
          </Typography>
          <Stack spacing={0.5}>
            <Box
              data-testid="wf-parallel-group-pill"
              sx={{ display: 'flex', minWidth: 0 }}
            >
              <StatusPill status={null} label={task.parallel_group} truncate />
            </Box>
          </Stack>
        </Box>
      )}
    </>
  )
}

const StreamViewer = lazy(() => import('./autopilot/StreamViewer'))
const LogViewer = lazy(() => import('./autopilot/LogViewer'))
const ArtifactDialog = lazy(() => import('./autopilot/ArtifactDialog'))

interface SessionPanelProps {
  task: Task | null
  autopilotSession: AutopilotSession | null
  projectPath?: string | null
  allTasks?: Map<string, Task>
  onClose?: () => void
  onSelectTask?: (taskId: string) => void
  previousGate?: { name: string; passed: boolean } | null
  plan?: Plan | null
  planDir?: string | null
}

export default function SessionPanel({
  task,
  autopilotSession,
  projectPath,
  allTasks,
  onClose,
  onSelectTask,
  previousGate,
  plan,
  planDir,
}: SessionPanelProps) {
  const [artifactFile, setArtifactFile] = useState<string | null>(null)
  const [artifactUrl, setArtifactUrl] = useState<string | null>(null)

  /* Audit-18 #1 + #4 - mode is the source of truth for which content
     pane shows. Default is session-aware: running session → STREAM
     (live data is what the operator opened the session for); any
     other state (pending, completed-collapsed, no session) → BRIEF.
     Visible-sections filter persists via useTaskBriefFilters; the
     mode itself does NOT persist across feature switches because
     different features have different "what should I see first"
     defaults based on their session state. */
  const briefFilters = useTaskBriefFilters()
  const [mode, setMode] = useState<'stream' | 'brief' | 'terminal'>('brief')

  const name = task?.name ?? autopilotSession?.task ?? null
  const taskId = task?.id ?? autopilotSession?.task ?? null
  const { isRunning, isNotStarted, hasStream, hasPhases } = deriveSessionFlags(autopilotSession, task)

  // Two-mount pattern (R19): this panel-level instance feeds the
  // header SessionStateChip; SessionControls mounts its own second
  // instance internally for the button-visibility table. Per
  // useSessionControls.ts:12-16, per-instance optimistic flags do NOT
  // cross-broadcast — the panel-level instance therefore always
  // reports raw server state. R25's auto-fall-back is driven from
  // autopilotSession.status, NOT from sessionUIState below.
  const { state: sessionUIState, isPausing } = useSessionControls('autopilot', taskId)

  // Compute dependents (tasks that depend on this task)
  const dependents = useMemo(() => {
    if (!taskId || !allTasks) return []
    const result: string[] = []
    allTasks.forEach((t) => {
      if (t.depends?.includes(taskId)) result.push(t.id)
    })
    return result
  }, [taskId, allTasks])

  // Artifacts: merge plan + autopilot, deduplicate by filename
  const planArtifacts = usePlanArtifacts(projectPath ?? null, task?.id ?? null)
  const autopilotArtifacts = useAutopilotArtifacts(autopilotSession?.task ?? null)

  // Sort artifacts by pipeline phase order, not alphabetically
  const mergedArtifacts = useMemo(
    () => mergeArtifacts(autopilotArtifacts, planArtifacts),
    [autopilotArtifacts, planArtifacts],
  )

  // Reset view when task selection changes (not on status flicker)
  const prevTaskIdRef = useRef(taskId)
  const hasInitStreamRef = useRef(false)
  const isSessionRunning = autopilotSession?.status === 'running'
  useEffect(() => {
    const taskChanged = taskId !== prevTaskIdRef.current
    if (taskChanged) {
      prevTaskIdRef.current = taskId
      hasInitStreamRef.current = !!isSessionRunning
      setMode(isSessionRunning ? 'stream' : 'brief')
      setArtifactFile(null)
      setArtifactUrl(null)
      return
    }
    // Autopilot session arrived after initial render — switch to stream
    if (!hasInitStreamRef.current && isSessionRunning) {
      hasInitStreamRef.current = true
      setMode('stream')
    }
  }, [taskId, autopilotSession, isSessionRunning])

  /* Audit-18 #4 - on first render, sync mode with session state.
     Without this, fresh-mounted panels with a running session
     would land on the persisted-default 'brief' since the task-
     change branch above only fires when taskId changes. */
  useEffect(() => {
    if (!hasInitStreamRef.current && isSessionRunning) {
      hasInitStreamRef.current = true
      setMode('stream')
    } else if (!hasInitStreamRef.current && !isSessionRunning) {
      hasInitStreamRef.current = true
      setMode('brief')
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  /* R25 — auto-fall-back. Signal source is autopilotSession.status
     (authoritative SWR-shared raw server status). Using the panel-
     level useSessionControls.state would eject the operator the
     instant they click Start: the server briefly returns 'idle' while
     the optimistic 'starting' flag advances inside SessionControls
     only (per useSessionControls.ts:12-16). 'idle' is intentionally
     excluded — the no-target case (EC-16/EC-17) is gated by the
     taskId !== null render predicate below. setState in this effect
     is the project-wide convention for "external signal flipped a
     local mode flag" (mirrors ArtifactDialog.tsx:27 and
     useTaskForAutopilot.ts:24).
     Note on 'cancelled': REQUIREMENTS R25 lists 'cancelled' as a
     terminal state, but AutopilotSessionStatus (types.ts:378) only
     surfaces 3 values — 'running' | 'completed' | 'failed'. A
     cancellation completes server-side as 'failed' on this endpoint,
     so the 'failed' branch already covers it via this signal. */
  useEffect(() => {
    if (mode !== 'terminal') return
    const status = autopilotSession?.status
    if (status === 'completed' || status === 'failed') {
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setMode(isSessionRunning ? 'stream' : 'brief')
    }
  }, [mode, autopilotSession?.status, isSessionRunning])

  /* Escape-to-close: listen at the document level so it fires
     regardless of which inner element holds focus. The previous
     wrapper-Box keydown depended on the title autofocus (removed
     when the chrome moved into DetailHeader); a doc-level listener
     keeps the keyboard close UX intact and stable. */
  useEffect(() => {
    if (!onClose) return
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') onClose()
    }
    document.addEventListener('keydown', onKey)
    return () => document.removeEventListener('keydown', onKey)
  }, [onClose])

  const handleCopyPrompt = () => {
    if (task?.prompt) navigator.clipboard.writeText(task.prompt)
  }

  const buildArtifactUrl = useCallback((file: string, source: 'autopilot' | 'plan'): string | null => {
    if (source === 'autopilot' && autopilotSession) {
      return `/api/autopilot/artifact?task=${encodeURIComponent(autopilotSession.task)}&file=${encodeURIComponent(file)}`
    }
    if (projectPath && task) {
      return `/api/plan/artifact?cwd=${encodeURIComponent(projectPath)}&task=${encodeURIComponent(task.id)}&file=${encodeURIComponent(file)}`
    }
    return null
  }, [autopilotSession, projectPath, task])

  const handleArtifactClick = (file: string, source: 'autopilot' | 'plan') => {
    setArtifactUrl(buildArtifactUrl(file, source))
    setArtifactFile(file)
  }

  // Empty state
  if (!task && !autopilotSession) {
    return (
      <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100%' }}>
        <Typography variant="wfBody" color="text.secondary">
          Select a task to view details
        </Typography>
      </Box>
    )
  }

  /* AutopilotBadge mode resolution — flattened to a single variable
     so the JSX site is readable and Sonar S3358 (no nested ternary)
     stays satisfied. Mirrors the predecessor pattern of computing
     wire-shape props ahead of the render. */
  let autopilotMode: 'light' | 'full' | 'manual' = 'manual'
  if (task?.autopilot) {
    autopilotMode = task.pipeline === 'light' ? 'light' : 'full'
  }

  /* R22 main-body branch — extracted from JSX as a variable so the
     three-way render (terminal / stream / brief) reads linearly and
     Sonar S3358 (no nested ternary) stays satisfied. Order matters:
     terminal takes priority when active AND a target is bound;
     stream follows when an autopilot session is attached; brief is
     the catch-all fallback (EC-16/EC-17 land here). */
  let mainContent: ReactElement
  if (mode === 'terminal' && taskId !== null) {
    mainContent = (
      <TerminalPanel
        targetKind="autopilot"
        targetId={taskId}
        onDetach={() => setMode(isSessionRunning ? 'stream' : 'brief')}
      />
    )
  } else if (mode === 'stream' && autopilotSession) {
    mainContent = (
      <Suspense fallback={<Skeleton variant="rectangular" height={200} sx={{ m: 2, borderRadius: 1 }} />}>
        {hasStream
          ? <StreamViewer task={autopilotSession.task} />
          : <LogViewer task={autopilotSession.task} />
        }
      </Suspense>
    )
  } else {
    mainContent = (
      <Box sx={{ flex: 1, overflowY: 'auto', p: 3 }}>
        {task ? (
          <BriefView
            task={task}
            plan={plan ?? null}
            planDir={planDir ?? null}
            visibleSections={briefFilters.visibleSections}
            onArtifactOpen={(url, label) => { setArtifactUrl(url); setArtifactFile(label) }}
          />
        ) : (
          /* Audit-22 #2 - parallel to BriefView's
             wf-brief-empty-state. Without this, BRIEF mode
             silently renders an empty Box when task lookup
             fails (e.g. multi-plan match miss in
             useTaskForAutopilot, or feature.plan_task_id
             missing). The TASK BRIEF toggle + sub-filter
             chrome are still visible, so the empty content
             reads as hung; an explicit message keeps the
             surface honest. */
          <Box
            data-testid="wf-brief-task-missing"
            sx={{ mb: 3, py: 4, textAlign: 'center' }}
          >
            <Typography variant="wfBody" color="text.secondary">
              Task brief unavailable — could not match this session to a plan task.
            </Typography>
          </Box>
        )}
      </Box>
    )
  }

  return (
    <Box
      sx={{ display: 'flex', flexDirection: 'column', height: '100%', overflow: 'hidden' }}
    >
      {/* ═══ Header (canonical chrome via DetailHeader) ═══ */}
      <DetailHeader
        title={taskId ?? name ?? ''}
        subtitle={task?.name && task.name !== task.id ? task.name : undefined}
        isLive={isRunning}
        onClose={onClose}
        projectName={autopilotSession?.project ?? undefined}
        trailing={
          <>
            {/* R20 — SessionStateChip leads the trailing slot so it
                sits closest to the title. The chip embedded inside
                SessionControls is suppressed via hideStateChip below
                (R20 anti-duplicate contract). */}
            <SessionStateChip state={sessionUIState} isPausing={isPausing} />
            {task && (
              /* Audit-17 #1 - LiveBadge in DetailHeader is the single
                 live indicator; AutopilotBadge stays static (no radar
                 sweep) so the chrome doesnt double-shout LIVE. */
              <AutopilotBadge mode={autopilotMode} />
            )}
            {task && (
              <StatusPill
                status={taskStatusToWfStatus(task.status)}
                label={task.status === 'done' ? 'completed' : task.status}
              />
            )}
          </>
        }
      />


      {/* R21 — SessionControls action row, immediately below the
          DetailHeader and above the prompt-bar/main-body region.
          hideStateChip={true} suppresses the embedded chip so the
          DetailHeader's trailing-slot chip (R20) is the only one in
          the panel subtree. */}
      <Box
        data-testid="session-controls-row"
        sx={{
          px: 2,
          py: 1,
          borderBottom: '1px solid',
          /* controls-01 #4 — lift the row hairline to wf.steel so it
             reads as brand chrome separating the action surface from
             the filter row below. MUI's 'divider' token resolves too
             faint against wf.carbon in dark mode. */
          borderColor: 'wf.steel',
        }}
      >
        {/* controls-01 #3 — targetKind is intentionally fixed to
            'autopilot' here. SessionPanel mounts in three call sites
            (Pipeline.tsx, FeatureDetail.tsx, AutopilotView.tsx) and
            every one of them passes per-task data. Chain runs operate
            on plan dirs and belong on a plan-level surface (future
            audit cycle on Pipeline.tsx / PlansView.tsx) — not here. */}
        <SessionControls
          targetKind="autopilot"
          targetId={taskId}
          onAttach={() => setMode('terminal')}
          hideStateChip
          autopilotMode={autopilotMode}
          /* controls-04 #3c — compact overflow treatment mirrors the
             Plans-tab plan header. The detail surface keeps every
             affordance (Pause/Cancel/Attach are reachable via the
             overflow), but the rendering converges across surfaces
             so operators see one consistent action shape. */
          density="header"
        />
      </Box>

      {/* ═══ Prompt bar (audit-17 #2: only for fully MANUAL pending
              tasks - autopilot tasks fire via autopilot-chain, not
              copy-paste). ═══ */}
      {isNotStarted && task?.prompt && task?.autopilot === false && (
        <Box sx={{ px: 2, py: 1, borderBottom: '1px solid', borderColor: 'divider', display: 'flex', gap: 1, alignItems: 'center' }}>
          <Paper sx={{ p: 1, display: 'flex', alignItems: 'center', bgcolor: 'surfaceVariant', border: 'none', flex: 1 }}>
            <Typography
              variant="wfBody"
              sx={{ fontFamily: 'monospace', flexGrow: 1, wordBreak: 'break-all' }}
            >
              {task.prompt}
            </Typography>
            <IconButton size="small" onClick={handleCopyPrompt} aria-label="Copy prompt">
              <ContentCopyIcon fontSize="small" />
            </IconButton>
          </Paper>
        </Box>
      )}

      {/* ═══ Main body: sidebar (always) + content ═══ */}
      <Box sx={{ flex: 1, display: 'flex', overflow: 'hidden', flexDirection: { xs: 'column', md: 'row' } }}>
        <DetailSidebar
          phases={hasPhases ? autopilotSession!.phases : []}
          estimate={task?.estimate}
          artifacts={mergedArtifacts}
          onArtifactClick={(file) => {
            const a = mergedArtifacts.find((x) => x.file === file)
            if (a) handleArtifactClick(file, a.source)
          }}
          topActions={
            <Box
              data-testid="wf-task-brief-toggle"
              data-mode={mode}
              sx={{ display: 'inline-flex' }}
            >
              {/* R26 — from 'terminal' mode this collapses to 'brief'
                  (not 'stream'); operators detach via SessionControls
                  or Escape. The two-value setter is intentional:
                  terminal mode is never re-entered by toggling Task
                  Brief. */}
              <ToggleChip
                label="Task Brief"
                active={mode === 'brief'}
                onClick={() => setMode((m) => (m === 'brief' ? 'stream' : 'brief'))}
                icon={<DescriptionIcon sx={{ fontSize: 12, color: 'inherit' }} />}
              />
            </Box>
          }
          extras={
            <SidebarExtras
              previousGate={previousGate ?? null}
              task={task}
              allTasks={allTasks}
              dependents={dependents}
              onSelectTask={onSelectTask}
            />
          }
        />

        {/* Content area */}
        <Box sx={{ flex: 1, display: 'flex', flexDirection: 'column', minWidth: 0, minHeight: 0, overflow: 'hidden' }}>
          {/* Mobile compact stepper */}
          {hasPhases && (
            <Box sx={{ display: { xs: 'block', md: 'none' }, px: 2, py: 1, borderBottom: '1px solid', borderColor: 'divider' }}>
              <PhaseStepper phases={autopilotSession!.phases} mode="compact" />
            </Box>
          )}

          {/* Audit-18 #1 + #7 - sub-filter row only renders in BRIEF mode.
              Mirrors StreamViewer's "Show: Phases / Pipeline / Narrative
              / Results / Tool Calls" filter bar but operates on the
              static execution-graph sections instead of stream events. */}
          {mode === 'brief' && (
            <Box
              data-testid="wf-brief-filters"
              sx={{
                px: 3, py: 1,
                borderBottom: '1px solid', borderColor: 'divider',
                flexShrink: 0,
                display: 'flex', alignItems: 'center', gap: 1, flexWrap: 'wrap',
              }}
            >
              <Typography variant="wfLabel" color="text.disabled" sx={{ mr: 0.5 }}>
                Brief
              </Typography>
              {(() => {
                /* Audit-19 followup (b) - on a plan-2.0 task render all
                   14 chips so the operator can see what the schema
                   defines; chips for empty sections are disabled. On a
                   plan-1.x task only the schema-relevant sections
                   (acceptance + description) render at all — the other
                   12 are plan-2.0-only fields the schema does not
                   permit, so their chips would be permanently
                   disabled (not useful). */
                const isPlan2Schema = plan ? isPlan2(plan) : false
                /* Audit-19 #10 (1) - context-N/A chips are hidden
                   instead of permanent-disabled when their producer
                   never runs for this task:
                     - 'description' is the plan-1.x fallback for
                       'what'; hide on plan-2.0 unless data is present
                     - 'manual_test' applies only to MANUAL tasks
                       (task.autopilot === false). An autopilot task
                       runs end-to-end without human verification, so
                       there is no manual_test report to surface */
                const visibleInRow = isPlan2Schema
                  ? BRIEF_SECTION_ORDER.filter((s) => {
                      if (s === 'description' && !task?.description) return false
                      if (s === 'manual_test' && task?.autopilot === true && !task?.manual_test) return false
                      return true
                    })
                  : BRIEF_SECTION_ORDER.filter((s) => s === 'acceptance' || s === 'description')
                const available = task ? availableBriefSections(task, plan ?? null) : new Set<BriefSection>()
                return visibleInRow.map((section) => {
                  const active = briefFilters.visibleSections.has(section)
                  const hasData = available.has(section)
                  return (
                    <Box
                      key={section}
                      data-testid={`wf-brief-section-${section}`}
                      data-active={active}
                      sx={{ display: 'inline-flex' }}
                    >
                      <ToggleChip
                        label={BRIEF_SECTION_LABELS[section]}
                        active={active}
                        disabled={!hasData}
                        onClick={() => {
                          const next = new Set(briefFilters.visibleSections)
                          if (active) next.delete(section)
                          else next.add(section)
                          briefFilters.setVisibleSections(next)
                        }}
                      />
                    </Box>
                  )
                })
              })()}
            </Box>
          )}

          {/* R22 — main-body branch resolved above into a single
              JSX element. Order: terminal (when active AND target
              bound) → stream (when autopilot session attached) →
              brief (catch-all, EC-16/EC-17 land here). */}
          {mainContent}
        </Box>
      </Box>

      {/* Artifact viewer dialog */}
      <Suspense fallback={<Skeleton />}>
        <ArtifactDialog
          url={artifactUrl}
          title={artifactFile ?? undefined}
          onClose={() => { setArtifactFile(null); setArtifactUrl(null) }}
        />
      </Suspense>

    </Box>
  )
}

interface BriefViewProps {
  task: Task
  plan: Plan | null
  planDir: string | null
  visibleSections: ReadonlySet<BriefSection>
  onArtifactOpen: (url: string, label: string) => void
}

/* Audit-18 #2 + #5 - unified brief view. Acceptance criteria and
   description, previously sibling blocks of Plan2TaskBody, now live
   inside this component so a single visibleSections set gates every
   section. Plan-2.0-only sections (what / why / where / constraints
   / artifacts / estimate) still depend on isPlan2(plan); acceptance
   and description render whenever the underlying field is set,
   regardless of schema version. */
function BriefView({ task, plan, planDir, visibleSections, onArtifactOpen }: Readonly<BriefViewProps>) {
  const where = task.where
  const constraints = task.constraints ?? []
  const estimate = task.estimate

  const isPlan2Schema = plan ? isPlan2(plan) : false

  const handleOpen = useCallback((value: string, label: string) => {
    if (!plan) return
    const result = resolveArtifactRef({ value, plan, planDir, taskId: task.id })
    if (result.resolved) {
      onArtifactOpen(result.url, label)
    }
  }, [plan, planDir, task.id, onArtifactOpen])

  /* Audit-18 #6 - empty state when every brief filter is toggled off.
     Parallel to FeatureList's "no features match" pattern; keeps the
     brief surface from collapsing to a silent empty container when the
     operator has hidden every chip. */
  if (visibleSections.size === 0) {
    return (
      <Box
        data-testid="wf-brief-empty-state"
        sx={{
          mb: 3,
          py: 4,
          textAlign: 'center',
        }}
      >
        <Typography variant="wfBody" color="text.secondary">
          All brief sections hidden — toggle a filter above to see content.
        </Typography>
      </Box>
    )
  }

  return (
    <Box sx={{ mb: 3 }}>
      {/* Audit-19 #1 #2 - sections render fully open with no collapsible
          toggle and no truncation. The brief sub-filter row is the
          single point of control for hiding sections. */}
      {visibleSections.has('task_type') && isPlan2Schema && task.task_type && (
        <Box sx={{ mb: 2 }}>
          <Typography variant="wfH3" component="h3">Type</Typography>
          <Typography variant="wfBody" sx={{ mt: 0.5 }}>
            {taskTypeLabel(task.task_type)}
          </Typography>
        </Box>
      )}
      {visibleSections.has('what') && isPlan2Schema && task.what && (
        <Box sx={{ mb: 2 }}>
          <Typography variant="wfH3" component="h3">What</Typography>
          <Typography variant="wfBody" sx={{ mt: 0.5 }}>
            {task.what}
          </Typography>
        </Box>
      )}
      {visibleSections.has('why') && isPlan2Schema && task.why && (
        <Box sx={{ mb: 2 }}>
          <Typography variant="wfH3" component="h3">Why</Typography>
          <Typography variant="wfBody" sx={{ mt: 0.5 }}>{task.why}</Typography>
        </Box>
      )}
      {visibleSections.has('where') && isPlan2Schema && where && (where.modify?.length || where.create?.length || where.delete?.length) ? (
        <Box sx={{ mb: 2 }}>
          <Typography variant="wfH3" component="h3" sx={{ mb: 0.5 }}>Where</Typography>
          {(['modify', 'create', 'delete'] as const).map((kind) => {
            const paths = where[kind]
            if (!paths || paths.length === 0) return null
            const heading = kind.charAt(0).toUpperCase() + kind.slice(1)
            return (
              <Box key={kind} sx={{ mb: 1 }}>
                <Typography variant="wfLabel" color="text.secondary">{heading}</Typography>
                <Stack direction="row" spacing={0.5} flexWrap="wrap" useFlexGap>
                  {paths.map((p) => (
                    <Box
                      key={p}
                      component="button"
                      type="button"
                      aria-label={`Open file ${p}`}
                      onClick={() => handleOpen(p, p)}
                      onKeyDown={(e) => {
                        if (e.key === 'Enter' || e.key === ' ') {
                          e.preventDefault()
                          handleOpen(p, p)
                        }
                      }}
                      sx={{
                        display: 'inline-flex',
                        background: 'none',
                        border: 'none',
                        p: 0,
                        cursor: 'pointer',
                        '&:hover': { opacity: 0.85 },
                      }}
                    >
                      <StatusPill status={null} label={p} truncate />
                    </Box>
                  ))}
                </Stack>
              </Box>
            )
          })}
        </Box>
      ) : null}
      {visibleSections.has('constraints') && isPlan2Schema && constraints.length > 0 && (
        <Box sx={{ mb: 2 }}>
          <Typography variant="wfH3" component="h3" sx={{ mb: 0.5 }}>Constraints</Typography>
          <List dense disablePadding>
            {constraints.map((c) => (
              <ListItem key={c} sx={{ alignItems: 'flex-start', py: 0.25 }}>
                <ListItemText primary={c} slotProps={{ primary: { variant: 'body2' } }} />
              </ListItem>
            ))}
          </List>
        </Box>
      )}
      {visibleSections.has('acceptance') && task.acceptance && task.acceptance.length > 0 && (
        <Box sx={{ mb: 2 }}>
          {/* Audit-19 #5 - heading unified with other body sections
              (h3 + wfH3) for brand consistency. */}
          <Typography variant="wfH3" component="h3" sx={{ mb: 1 }}>
            Acceptance Criteria
          </Typography>
          {/* Audit-19 #4 - wf/Checkbox primitive matches the
              GFM task-list checkbox chrome streams use, replacing
              the MUI Checkbox span wrapper that did not match the
              brand spec. */}
          <List dense disablePadding>
            {task.acceptance.map((item) => (
              <ListItem key={item} disablePadding sx={{ alignItems: 'flex-start', gap: 1, py: 0.25 }}>
                <ListItemIcon sx={{ minWidth: 0, mt: 0.5 }}>
                  <WfCheckbox
                    data-testid="wf-acceptance-checkbox"
                    checked={task.status === 'done'}
                    disabled
                    readOnly
                  />
                </ListItemIcon>
                <ListItemText primary={item} primaryTypographyProps={{ variant: 'body2' }} />
              </ListItem>
            ))}
          </List>
        </Box>
      )}
      {visibleSections.has('manualtest_scenarios') && isPlan2Schema && task.manualtest_scenarios && task.manualtest_scenarios.length > 0 && (
        <Box sx={{ mb: 2 }}>
          <Typography variant="wfH3" component="h3" sx={{ mb: 0.5 }}>Test Scenarios</Typography>
          <List dense disablePadding>
            {task.manualtest_scenarios.map((s) => (
              <ListItem key={s} sx={{ alignItems: 'flex-start', py: 0.25 }}>
                <ListItemText primary={s} slotProps={{ primary: { variant: 'body2' } }} />
              </ListItem>
            ))}
          </List>
        </Box>
      )}
      {visibleSections.has('manual_test') && isPlan2Schema && task.manual_test && (
        <Box sx={{ mb: 2 }}>
          <Typography variant="wfH3" component="h3">Manual Test</Typography>
          <Typography variant="wfBody" sx={{ mt: 0.5 }}>{task.manual_test}</Typography>
        </Box>
      )}
      {/* Audit-19 #11 - artifact_refs section dropped. Sidebar
          DOCUMENTS already lists every artifact (REQUIREMENTS,
          PLAN, REVIEW, TESTPLAN, STATIC_ANALYSIS, QA_REPORT, ...)
          with a click link that opens the file via ArtifactDialog,
          so the brief block was duplicating a more discoverable
          affordance. */}
      {visibleSections.has('estimate') && isPlan2Schema && estimate && (estimate.lines_estimate || estimate.duration_hours) && (
        <Box sx={{ mb: 2 }}>
          <Typography variant="wfLabel" color="text.secondary">
            {estimate.lines_estimate ? `~${estimate.lines_estimate} lines` : ''}
            {estimate.lines_estimate && estimate.duration_hours ? ' · ' : ''}
            {estimate.duration_hours ? `${estimate.duration_hours}h` : ''}
          </Typography>
        </Box>
      )}
      {visibleSections.has('description') && task.description && (
        <Box sx={{ mb: 2 }}>
          {/* Audit-19 #5 - heading unified with other body sections
              (h3 + wfH3) for brand consistency. */}
          <Typography variant="wfH3" component="h3">Description</Typography>
          <Typography variant="wfBody" sx={{ mt: 0.5 }}>{task.description}</Typography>
        </Box>
      )}
      {/* Audit-19 #6 - drift indicators populated post-completion.
          Surfaced inside BriefView so an operator reviewing a finished
          task can see how the delivered work diverged from the plan
          without leaving SessionPanel for the deviation tracker. */}
      {visibleSections.has('scope_change') && isPlan2Schema && task.scope_change && (
        <Box sx={{ mb: 2 }}>
          <Typography variant="wfH3" component="h3">Scope Change</Typography>
          <Typography variant="wfBody" sx={{ mt: 0.5 }}>{task.scope_change}</Typography>
        </Box>
      )}
      {visibleSections.has('delivered_beyond_plan') && isPlan2Schema && task.delivered_beyond_plan && task.delivered_beyond_plan.length > 0 && (
        <Box sx={{ mb: 2 }}>
          <Typography variant="wfH3" component="h3" sx={{ mb: 0.5 }}>Delivered Beyond Plan</Typography>
          <List dense disablePadding>
            {task.delivered_beyond_plan.map((d) => (
              <ListItem key={d} sx={{ alignItems: 'flex-start', py: 0.25 }}>
                <ListItemText primary={d} slotProps={{ primary: { variant: 'body2' } }} />
              </ListItem>
            ))}
          </List>
        </Box>
      )}
      {visibleSections.has('remaining_gaps') && isPlan2Schema && task.remaining_gaps && task.remaining_gaps.length > 0 && (
        <Box sx={{ mb: 2 }}>
          <Typography variant="wfH3" component="h3" sx={{ mb: 0.5 }}>Remaining Gaps</Typography>
          <List dense disablePadding>
            {task.remaining_gaps.map((g) => (
              <ListItem key={g} sx={{ alignItems: 'flex-start', py: 0.25 }}>
                <ListItemText primary={g} slotProps={{ primary: { variant: 'body2' } }} />
              </ListItem>
            ))}
          </List>
        </Box>
      )}
      <BriefMetadataFooter task={task} />
    </Box>
  )
}

/* Audit-19 #8 - operational metadata trio at the bottom of BriefView.
   auto_update + last_updated + extensions are not first-class
   sections (no chip in the sub-filter row); they appear as a small
   muted footer block with a hairline separator above. The block is
   hidden when none of the three fields are set. */
function BriefMetadataFooter({ task }: Readonly<{ task: Task }>) {
  const hasAutoUpdate = !!task.auto_update
  const hasLastUpdated = !!task.last_updated
  const ext = task.extensions
  const hasExtensions = !!ext && Object.keys(ext).length > 0
  if (!hasAutoUpdate && !hasLastUpdated && !hasExtensions) return null

  const autoUpdate = task.auto_update
  const extensionKeys = ext ? Object.keys(ext) : []

  return (
    <Box
      data-testid="wf-brief-meta-footer"
      sx={{
        mt: 3,
        pt: 2,
        borderTop: '1px solid',
        borderColor: 'divider',
        display: 'flex',
        flexDirection: 'column',
        gap: 0.5,
      }}
    >
      {hasAutoUpdate && autoUpdate && (
        <Typography variant="wfLabel" color="text.secondary">
          auto-update: {autoUpdate.enabled ? 'on' : 'off'}
          {typeof autoUpdate.retry_count === 'number' ? ` · ${autoUpdate.retry_count} retries` : ''}
          {autoUpdate.last_attempt_at ? ` · last attempt ${relativeTime(autoUpdate.last_attempt_at)}` : ''}
        </Typography>
      )}
      {hasLastUpdated && task.last_updated && (
        <Typography
          variant="wfLabel"
          color="text.secondary"
          title={task.last_updated}
        >
          last updated: {relativeTime(task.last_updated)}
        </Typography>
      )}
      {hasExtensions && (
        <Typography variant="wfLabel" color="text.secondary">
          extensions: {extensionKeys.join(' · ')}
        </Typography>
      )}
    </Box>
  )
}
