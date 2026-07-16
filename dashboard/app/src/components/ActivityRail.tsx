import { useState } from 'react'
import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import Collapse from '@mui/material/Collapse'
import ChevronRightIcon from '@mui/icons-material/ChevronRight'
import { useSessions } from '../hooks/useSessions'
import { useFeatures } from '../hooks/useFeatures'
import { usePlans } from '../hooks/usePlans'
import { useAutopilots } from '../hooks/useAutopilots'
import { useGrinderList } from '../hooks/useGrinder'
import StatusDot from './wf/StatusDot'
import { toneToWfStatus, isAutopilotActive, autopilotToTone } from '../utils/featureStatusMapping'

/**
 * ActivitySections — runtime artifact summary, embedded inside the
 * left sidebar (operator preference: keep all navigation on the left
 * with a single column rather than a separate right rail).
 *
 * Four collapsible sections:
 *   - Active Sessions: live Claude Code sessions (from /api/sessions)
 *   - Active Plans: chains under run (autopilot sessions)
 *   - Active Features: in-progress features (status !== done)
 *   - Active Grinders: grinder projects with status === 'in_progress'
 *
 * Renders as a Fragment with no outer wrapper so the parent sidebar
 * controls width, padding, and borders.
 *
 * User-request 2026-05-08: Active Features and Active Plans rows are
 * clickable. The shell passes onSelectFeature / onSelectPlan to switch
 * the main view; rows are read-only when the props are absent.
 */
interface ActivityRailProps {
  onSelectFeature?: () => void
  /* User-request 2026-05-08 (revision): click an Active Plan row to
     open that specific plan's Pipeline tab (project:<name>/pipeline),
     not the generic Plans view. The autopilot session carries the
     project name; the shell maps it to the appropriate per-project
     tab id. Receives null when the autopilot session has no project
     attached (treated as fallback to the generic Plans view). */
  onSelectPlan?: (project: string | null) => void
}

export default function ActivityRail({
  onSelectFeature,
  onSelectPlan,
}: Readonly<ActivityRailProps> = {}) {
  const { data: sessions } = useSessions()
  const { data: features } = useFeatures()
  const { data: plans } = usePlans()
  const { data: autopilots } = useAutopilots()
  const { data: grinders } = useGrinderList()

  const activeSessions = (sessions ?? []).filter((s) => s.status === 'working' || s.status === 'needs_input')
  const activeFeatures = (features ?? []).filter((f) => f.status === 'active' || f.status === 'waiting')
  const activePlans = (autopilots ?? []).filter((a) => isAutopilotActive(a.status))
  const activeGrinders = (grinders ?? []).filter((g) => g.status === 'in_progress')

  return (
    <>
      <RailSection title="Active Sessions" count={activeSessions.length}>
        {activeSessions.map((s) => (
          <RailRow
            key={s.sid}
            title={s.branch.split('/').pop() ?? s.branch}
            subtitle={s.status}
            secondaryLine={s.worktree}
            tone={statusToneSession(s.status)}
          />
        ))}
      </RailSection>

      <RailSection title="Active Plans" count={activePlans.length}>
        {activePlans.map((a) => (
          <RailRow
            key={a.task}
            title={a.task}
            subtitle={a.phases.find((p) => p.status === 'running')?.name ?? a.status}
            tone={autopilotToTone(a.status)}
            onClick={onSelectPlan ? () => onSelectPlan(a.project) : undefined}
            testId="rail-plan-row"
          />
        ))}
      </RailSection>

      <RailSection title="Active Features" count={activeFeatures.length}>
        {activeFeatures.map((f) => (
          <RailRow
            key={`${f.project}/${f.name}`}
            title={f.name}
            subtitle={`${f.phase_index}/${f.total_phases} · ${f.project}`}
            tone={statusToneFeature(f.status)}
            onClick={onSelectFeature}
            testId="rail-feature-row"
          />
        ))}
      </RailSection>

      <RailSection title="Active Grinders" count={activeGrinders.length}>
        {activeGrinders.map((g) => (
          <RailRow
            key={g.project}
            title={g.project}
            subtitle={`${g.current_pass ?? g.status}${g.paused ? ' · paused' : ''}`}
            tone="info"
          />
        ))}
      </RailSection>

      <Box sx={{
        pl: 2, pt: 1.5, pb: 0.5, mt: 1,
        borderTop: '1px solid',
        borderColor: 'wf.steel',
      }}>
        <Typography
          sx={{
            fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
            fontSize: '10.5px',
            color: 'wf.fog',
          }}
        >
          {(plans?.length ?? 0)} project{(plans?.length ?? 0) === 1 ? '' : 's'} discovered
        </Typography>
      </Box>
    </>
  )
}

interface RailSectionProps {
  title: string
  count: number
  children: React.ReactNode
}
function RailSection({ title, count, children }: Readonly<RailSectionProps>) {
  const [expanded, setExpanded] = useState(true)
  /* User-request 2026-05-08: rail headers match GLOBAL chrome —
     blue title + 8x1 wf.signal rule prefix. Inline style on the rule
     so jsdom can introspect (sx applies emotion classes which jsdom
     can't resolve). */
  return (
    <Box>
      <Box
        component="button"
        type="button"
        aria-expanded={expanded}
        onClick={() => setExpanded((prev) => !prev)}
        sx={{
          display: 'flex', alignItems: 'center', gap: 0.5,
          width: '100%',
          px: 1, py: 0.75,
          border: 'none',
          bgcolor: 'transparent',
          fontFamily: 'inherit',
          textAlign: 'left',
          cursor: 'pointer',
        }}
      >
        <ChevronRightIcon
          sx={{
            fontSize: 12,
            transform: expanded ? 'rotate(90deg)' : 'none',
            transition: 'transform 0.15s',
            color: 'wf.signal',
          }}
        />
        <Box
          data-testid="rail-section-rule"
          sx={{ width: 8, height: '1px', bgcolor: 'wf.signal', flexShrink: 0 }}
        />
        <Typography
          sx={{
            flex: 1,
            fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
            fontSize: '10px',
            letterSpacing: '0.22em',
            textTransform: 'uppercase',
            fontWeight: 500,
            lineHeight: 1,
          }}
          style={{ color: 'var(--mui-palette-wf-signal, #3B9EFF)' }}
        >
          {title}
        </Typography>
        <Typography
          sx={{
            fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
            fontSize: '10.5px',
            color: 'wf.fog',
            fontVariantNumeric: 'tabular-nums',
          }}
        >
          {count}
        </Typography>
      </Box>
      <Collapse in={expanded} timeout="auto" unmountOnExit>
        <Box sx={{ display: 'flex', flexDirection: 'column' }}>
          {count === 0 ? (
            <Typography sx={{
              pl: 3, pb: 0.5,
              fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
              color: 'wf.fog',
              opacity: 0.7,
              fontSize: '12px',
              fontStyle: 'italic',
            }}>
              none active
            </Typography>
          ) : children}
        </Box>
      </Collapse>
    </Box>
  )
}

interface RailRowProps {
  title: string
  subtitle?: string
  /* User-request 2026-05-08: optional third line below the subtitle.
     Used by Active Sessions to surface the worktree path so operators
     can disambiguate when several worktrees share the same branch
     name. Rendered in muted wf.fog at slightly smaller size. */
  secondaryLine?: string
  tone?: 'info' | 'warning' | 'error' | 'success' | 'muted'
  /* When set, the row renders as a clickable button that fires
     onClick. Used by Active Features / Plans to switch the main
     view; left undefined for Sessions / Grinders which are
     informational only. */
  onClick?: () => void
  testId?: string
}
function RailRow({ title, subtitle, secondaryLine, tone = 'info', onClick, testId }: Readonly<RailRowProps>) {
  const wfStatus = toneToWfStatus(tone)
  const interactive = Boolean(onClick)
  return (
    <Box
      data-testid={testId}
      component={interactive ? 'button' : 'div'}
      type={interactive ? 'button' : undefined}
      onClick={onClick}
      /* Constrain the button's accessible name to the title only.
         Subtitle/secondaryLine carry path/project context that would
         otherwise pollute role="button" name queries elsewhere in the
         shell (e.g. /test-project/ matching both a Plans project row
         and an Active Features rail row). */
      aria-label={interactive ? title : undefined}
      sx={{
        display: 'flex', alignItems: 'center', gap: 1,
        width: '100%',
        px: 1.5, py: 0.5,
        border: 'none',
        bgcolor: 'transparent',
        fontFamily: 'inherit',
        textAlign: 'left',
        cursor: interactive ? 'pointer' : 'default',
        '&:hover': { bgcolor: interactive ? 'rgba(255,255,255,0.04)' : 'transparent' },
      }}
    >
      {wfStatus ? (
        <StatusDot status={wfStatus} />
      ) : (
        <Box sx={{ width: 6, height: 6, borderRadius: '50%', bgcolor: 'wf.fog', flexShrink: 0 }} />
      )}
      <Box sx={{ flex: 1, minWidth: 0 }}>
        <Typography
          sx={{
            fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
            fontSize: '12px',
            color: 'wf.bone',
            overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap',
          }}
        >
          {title}
        </Typography>
        {subtitle && (
          <Typography
            sx={{
              fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
              fontSize: '10.5px',
              color: 'wf.fog',
              overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', display: 'block',
            }}
          >
            {subtitle}
          </Typography>
        )}
        {secondaryLine && (
          <Typography
            sx={{
              fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
              fontSize: '9.5px',
              color: 'wf.fog',
              opacity: 0.75,
              overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap', display: 'block',
            }}
          >
            {secondaryLine}
          </Typography>
        )}
      </Box>
    </Box>
  )
}

function statusToneSession(status: string): RailRowProps['tone'] {
  if (status === 'needs_input') return 'warning'
  if (status === 'working') return 'info'
  if (status === 'ended') return 'muted'
  return 'info'
}

function statusToneFeature(status: string): RailRowProps['tone'] {
  if (status === 'stuck') return 'error'
  if (status === 'waiting') return 'warning'
  if (status === 'paused') return 'muted'
  if (status === 'done') return 'success'
  return 'info'
}
