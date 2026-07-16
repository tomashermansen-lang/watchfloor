import Box from '@mui/material/Box'
import LinearProgress from '@mui/material/LinearProgress'
import Stack from '@mui/material/Stack'
import Typography from '@mui/material/Typography'
import Tooltip from '@mui/material/Tooltip'
import StatusPill from './wf/StatusPill'
import { useSessions } from '../hooks/useSessions'
import { useHoverLink } from '../contexts/HoverLinkContext'
import { buildFocusUri } from '../utils/focusUri'
import { relativeTime } from '../utils/time'
import { pva } from '../utils/cssVars'
import { sessionStatusToWfStatus } from '../utils/featureStatusMapping'
import type { Session, SessionStatus, FlowInfo } from '../types'

const reducedMotionQuery = '@media (prefers-reduced-motion: reduce)'

/* Urgency-first sort order */
const STATUS_SORT_ORDER: Record<SessionStatus, number> = {
  needs_input: 0,
  working: 1,
  idle: 2,
  completed: 3,
  stopped: 4,
  closed: 5,
  stale: 6,
}


const PHASE_LABELS: Record<string, string> = {
  started: 'Started',
  ba: 'BA',
  design: 'Design',
  plan: 'Plan',
  'team-review': 'T-Rev',
  review: 'Review',
  implement: 'Impl',
  'static-analysis': 'SA',
  manualtest: 'Test',
  'team-qa': 'T-QA',
  commit: 'Commit',
  done: 'Done',
  unknown: '?',
}

function FlowProgress({ flow }: { flow: FlowInfo }) {
  const progress = ((flow.phase_index + 1) / flow.total_phases) * 100
  const label = PHASE_LABELS[flow.phase] ?? flow.phase
  return (
    <Tooltip title={`${flow.feature}: ${label} (${flow.phase_index + 1}/${flow.total_phases})`}>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}>
        <Typography variant="caption" sx={{ fontWeight: 600, fontSize: '0.6rem', minWidth: 28 }}>
          {label}
        </Typography>
        <LinearProgress
          variant="determinate"
          value={progress}
          sx={{ flex: 1, height: 3, borderRadius: 2, minWidth: 40 }}
        />
      </Box>
    </Tooltip>
  )
}

function shortenPath(path: string): string {
  const home = '/Users/'
  const idx = path.indexOf(home)
  if (idx >= 0) {
    const parts = path.substring(idx + home.length).split('/')
    return parts.length > 1 ? `~/${parts.slice(1).join('/')}` : path
  }
  return path
}

/* Session summary strip */
function SummaryStrip({ sessions }: { sessions: Session[] }) {
  const counts: Partial<Record<SessionStatus, number>> = {}
  for (const s of sessions) {
    counts[s.status] = (counts[s.status] ?? 0) + 1
  }

  const chips: { status: SessionStatus; count: number; label: string }[] = []
  for (const [status, count] of Object.entries(counts)) {
    if (count > 0) {
      chips.push({
        status: status as SessionStatus,
        count,
        label: `${count} ${status.replace('_', ' ')}`,
      })
    }
  }

  // Sort by urgency
  chips.sort((a, b) => STATUS_SORT_ORDER[a.status] - STATUS_SORT_ORDER[b.status])

  if (chips.length === 0) return null

  return (
    <Stack direction="row" spacing={0.75} sx={{ mb: 1, flexWrap: 'wrap' }}>
      {chips.map((c) => (
        <StatusPill key={c.status} status={sessionStatusToWfStatus(c.status)} label={c.label} />
      ))}
    </Stack>
  )
}

/* Session row with hover linking and opacity for completed */
function SessionRow({ session }: { session: Session }) {
  const { hoveredTaskId, setHoveredSession } = useHoverLink()
  const isCompleted = session.status === 'completed' || session.status === 'stopped' || session.status === 'stale' || session.status === 'closed'
  const wfStatus = sessionStatusToWfStatus(session.status)

  // Cross-panel: highlight when pipeline task matching this branch feature is hovered
  const feature = session.branch.split('/').pop() ?? ''
  const isLinkedHighlight = hoveredTaskId !== null && hoveredTaskId === feature

  const handleClick = () => {
    const uri = buildFocusUri(session.worktree)
    if (uri) window.location.href = uri
  }

  return (
    <Box
      data-testid="session-row"
      data-session-id={session.sid}
      onClick={handleClick}
      onMouseEnter={() => setHoveredSession(session.branch)}
      onMouseLeave={() => setHoveredSession(null)}
      sx={{
        display: 'flex',
        flexDirection: 'column',
        gap: 0.25,
        px: 1.5,
        py: 0.75,
        cursor: isCompleted ? 'default' : 'pointer',
        borderRadius: 1,
        transition: `all var(--motion-short4, 200ms) var(--motion-emphasized, cubic-bezier(0.2, 0, 0, 1))`,
        ...(!isCompleted ? { '&:hover': { bgcolor: pva('primary-main', 0.04) } } : {}),
        borderBottom: '1px solid',
        borderColor: 'divider',
        '&:last-child': { borderBottom: 'none' },
        opacity: isCompleted ? 0.6 : 1,
        ...(isLinkedHighlight ? {
          bgcolor: pva('primary-main', 0.06),
        } : {}),
      }}
    >
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.75 }}>
        <Box
          sx={
            session.status === 'needs_input'
              ? {
                  display: 'inline-flex',
                  animation: 'softPulse 3s ease-in-out infinite',
                  '@keyframes softPulse': { '0%,100%': { opacity: 1 }, '50%': { opacity: 0.6 } },
                  [reducedMotionQuery]: { animation: 'none' },
                }
              : { display: 'inline-flex' }
          }
        >
          <StatusPill status={wfStatus} label={session.status.replace('_', ' ')} />
        </Box>
        <Typography
          variant="caption"
          noWrap
          sx={{ flex: 1, fontSize: '0.7rem', fontWeight: 500 }}
        >
          {shortenPath(session.worktree)}
        </Typography>
        <Typography variant="caption" sx={{ color: 'text.secondary', fontSize: '0.6rem', flexShrink: 0 }}>
          {relativeTime(session.ts)}
        </Typography>
      </Box>
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, pl: 0.25 }}>
        <Typography variant="caption" noWrap sx={{ fontSize: '0.6rem', fontWeight: 600, color: 'text.secondary', flex: 1 }}>
          {session.branch}
        </Typography>
        {session.flow && (
          <Box sx={{ flex: 1, maxWidth: 120 }}>
            <FlowProgress flow={session.flow} />
          </Box>
        )}
      </Box>
    </Box>
  )
}

/* Fix 5: Deduplicate sessions by worktree+branch (keep most recent) */
function deduplicateSessions(sessions: Session[]): Session[] {
  const seen = new Map<string, Session>()
  for (const s of sessions) {
    const key = `${s.worktree}::${s.branch}`
    const existing = seen.get(key)
    if (!existing || new Date(s.ts).getTime() > new Date(existing.ts).getTime()) {
      seen.set(key, s)
    }
  }
  return Array.from(seen.values())
}

export default function SessionMonitor() {
  const { data: sessions } = useSessions()
  const rows = sessions ?? []

  /* Deduplicate before processing */
  const deduped = deduplicateSessions(rows)

  /* Sort by urgency */
  const sorted = [...deduped].sort(
    (a, b) => STATUS_SORT_ORDER[a.status] - STATUS_SORT_ORDER[b.status],
  )

  return (
    <Box>
      <Typography variant="subtitle2" sx={{ mb: 1, fontWeight: 600, fontSize: '0.75rem', textTransform: 'uppercase', letterSpacing: '0.05em', color: 'text.secondary' }}>
        Sessions
      </Typography>

      {/* Summary strip */}
      {deduped.length > 0 && <SummaryStrip sessions={deduped} />}

      {deduped.length === 0 ? (
        <Box sx={{ textAlign: 'center', py: 4 }}>
          <Typography variant="caption" color="text.secondary">
            No active sessions
          </Typography>
        </Box>
      ) : (
        <Box
          sx={{
            border: '1px solid',
            borderColor: 'outlineVariant',
            borderRadius: 1,
            bgcolor: 'background.paper',
            overflow: 'hidden',
          }}
        >
          {sorted.map((s) => (
            <SessionRow key={s.sid} session={s} />
          ))}
        </Box>
      )}
    </Box>
  )
}
