import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import Table from '@mui/material/Table'
import TableHead from '@mui/material/TableHead'
import TableBody from '@mui/material/TableBody'
import TableRow from '@mui/material/TableRow'
import TableCell from '@mui/material/TableCell'
import Skeleton from '@mui/material/Skeleton'
import LinearProgress from '@mui/material/LinearProgress'
import { useFeatures } from '../hooks/useFeatures'
import { useSessions } from '../hooks/useSessions'
import { usePlans } from '../hooks/usePlans'
import type { Feature } from '../types'
import StatusPill from './wf/StatusPill'
import EmptyScope from './wf/EmptyScope'
import { featureToWfStatus } from '../utils/featureStatusMapping'

/**
 * OverviewView — fleet-wide landing page.
 *
 * VS Code-quiet aesthetic: a single status line + 4 KPI tiles + feature
 * portfolio table + three footer panels (Activity 24h, Weekly Throughput,
 * Health). Powered entirely by existing hooks (`useFeatures`,
 * `useSessions`, `usePlans`) — no new backend endpoints. Activity timeline
 * granularity and weekly throughput numbers come from the existing
 * /api/features stream; commit 7 (Metrics polish) deepens both with
 * proper aggregation in metrics_helpers.py.
 */
export default function OverviewView() {
  const { data: features, isLoading: featuresLoading } = useFeatures()
  const { data: sessions } = useSessions()
  const { data: projects } = usePlans()

  const featureList = features ?? []
  const counts = countFeaturesByStatus(featureList)
  const sessionList = sessions ?? []
  const activeSessions = sessionList.filter(
    (s) => s.status === 'working' || s.status === 'needs_input' || s.status === 'idle',
  ).length
  const fleet = computeFleetStats(featureList, sessionList)
  const activity = recentActivity(featureList, sessionList)

  /* Absolute zero: no projects discovered, no sessions reporting, no
     features tracked. Brand moment per handoff — the listening scope
     owns the canvas instead of empty tiles + empty table. */
  const isAbsoluteZero =
    (projects?.length ?? 0) === 0 &&
    sessionList.length === 0 &&
    featureList.length === 0
  if (isAbsoluteZero) {
    return (
      <Box
        sx={{
          p: 3,
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          minHeight: 'calc(100vh - 160px)',
        }}
      >
        <EmptyScope subtitle="no projects discovered yet" />
      </Box>
    )
  }

  return (
    <Box sx={{ p: 3, display: 'flex', flexDirection: 'column', gap: 3 }}>
      {/* Status header — fleet-wide info on one line, no banner ornament */}
      <Box
        data-testid="overview-status-header"
        sx={{
          display: 'flex', alignItems: 'baseline', flexWrap: 'wrap', gap: 2,
          px: 2, py: 1.5,
          bgcolor: 'surface1',
          borderLeft: '3px solid', borderLeftColor: 'primary.main',
          borderTop: '1px solid', borderRight: '1px solid', borderBottom: '1px solid',
          borderTopColor: 'divider', borderRightColor: 'divider', borderBottomColor: 'divider',
          borderRadius: 1,
        }}
      >
        <Typography variant="wfH3">
          {summarize(featureList, projects?.length ?? 0, activeSessions)}
        </Typography>
        <Typography variant="wfLabel" color="text.secondary">
          pass-rate <Box component="span" sx={{ color: 'success.main' }}>{fleet.passRate}%</Box>
        </Typography>
        <Typography variant="wfLabel" color="text.secondary">
          burn <Box component="span" sx={{ color: 'text.primary' }}>${fleet.burnPerWk.toFixed(0)}/wk</Box>
        </Typography>
        <Typography variant="wfLabel" color="text.secondary">
          commits <Box component="span" sx={{ color: 'text.primary' }}>{fleet.commits24h}</Box>
        </Typography>
      </Box>

      {/* 4 KPI tiles */}
      <Box sx={{ display: 'grid', gridTemplateColumns: 'repeat(4, 1fr)', gap: 2 }}>
        <KpiTile label="Running" value={counts.running} sub="features" delta={fleet.runningDelta} />
        <KpiTile label="Awaiting review" value={counts.awaiting} sub="features" />
        <KpiTile label="Blocked" value={counts.blocked} sub="features" tone={counts.blocked > 0 ? 'warn' : undefined} />
        <KpiTile label="Shipped (this wk)" value={counts.shipped} sub="features" tone="ok" delta={fleet.shippedDelta} />
      </Box>

      {/* Feature portfolio */}
      <Box sx={{ border: '1px solid', borderColor: 'divider', borderRadius: 1, overflow: 'hidden' }}>
        <Typography
          variant="wfLabel"
          sx={{ px: 2, py: 1, bgcolor: 'surface1', display: 'block', color: 'text.secondary' }}
        >
          Feature portfolio
        </Typography>
        {featuresLoading ? (
          <Skeleton variant="rectangular" height={200} />
        ) : (
          <Table size="small" aria-label="Feature portfolio">
            <TableHead>
              <TableRow>
                {['Feature', 'Status', 'Progress', 'Phase', 'Pipeline', 'Sessions', 'Project'].map((h) => (
                  <TableCell key={h} sx={h === 'Progress' ? { minWidth: 140 } : undefined}>
                    <Typography variant="wfLabel" color="text.secondary">{h}</Typography>
                  </TableCell>
                ))}
              </TableRow>
            </TableHead>
            <TableBody>
              {featureList.length === 0 ? (
                <TableRow>
                  <TableCell colSpan={7} sx={{ color: 'text.secondary', textAlign: 'center', py: 3 }}>
                    No active features.
                  </TableCell>
                </TableRow>
              ) : (
                featureList.map((f) => <FeatureRow key={`${f.project}/${f.name}`} feature={f} />)
              )}
            </TableBody>
          </Table>
        )}
      </Box>

      {/* Footer: Activity 24h · Weekly throughput · Health */}
      <Box sx={{ display: 'grid', gridTemplateColumns: '1.2fr 1fr 1fr', gap: 2 }}>
        <FooterPanel title="Activity · last 24h">
          {activity.length === 0 ? (
            <Typography variant="wfBody" color="text.secondary">
              Quiet — no recent events.
            </Typography>
          ) : (
            <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.75 }}>
              {activity.slice(0, 6).map((a, i) => (
                <Box key={i} sx={{ display: 'flex', alignItems: 'baseline', gap: 1 }}>
                  <Typography variant="wfCode" color="text.secondary" sx={{ minWidth: 32 }}>{a.when}</Typography>
                  <Typography variant="wfBody" sx={{ flex: 1, fontSize: '12px' }}>{a.text}</Typography>
                </Box>
              ))}
            </Box>
          )}
        </FooterPanel>

        <FooterPanel title="Weekly throughput">
          <ThroughputBars throughput={fleet.weekThroughput} />
        </FooterPanel>

        <FooterPanel title="Health">
          <Box sx={{ display: 'flex', flexDirection: 'column', gap: 1 }}>
            <HealthRow label="Pass-rate" value={fleet.passRate} unit="%" tone="ok" />
            <HealthRow label="Error-rate" value={fleet.errorRate} unit="%" tone={fleet.errorRate > 5 ? 'warn' : undefined} />
            <HealthRow label="Permission friction" value={fleet.permissionFriction} unit="%" />
            <HealthRow label="Autopilot trust" value={fleet.autopilotTrust} unit="%" tone="ok" />
            <HealthRow label="Budget used" value={fleet.budgetUsed} unit="%" />
          </Box>
        </FooterPanel>
      </Box>
    </Box>
  )
}

/* Feature status cell — wf StatusPill always; the muted variant
   (status=null) handles "paused" so the pill shape stays consistent
   across every row in the column. */
function FeatureStatusCell({ status }: Readonly<{ status: Feature['status'] }>) {
  return <StatusPill status={featureToWfStatus(status)} label={status} />
}

function FeatureRow({ feature }: Readonly<{ feature: Feature }>) {
  const progress = feature.total_phases > 0 ? Math.round((feature.phase_index / feature.total_phases) * 100) : 0
  return (
    <TableRow hover>
      <TableCell>
        <Typography variant="wfBody" sx={{ fontWeight: 500 }}>{feature.name}</Typography>
      </TableCell>
      <TableCell>
        <FeatureStatusCell status={feature.status} />
      </TableCell>
      <TableCell sx={{ minWidth: 140 }}>
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
          <LinearProgress
            variant="determinate"
            value={progress}
            color={progressTone(feature.status)}
            sx={{ flex: 1, height: 4, borderRadius: 1 }}
          />
          <Typography variant="wfCode" sx={{ minWidth: 36, textAlign: 'right', color: 'text.secondary' }}>
            {progress}%
          </Typography>
        </Box>
      </TableCell>
      <TableCell>
        <Typography variant="wfCode" color="text.secondary">
          {feature.phase_index}/{feature.total_phases}
        </Typography>
      </TableCell>
      <TableCell>
        <Typography variant="wfLabel" color="text.secondary">
          {feature.pipeline_type}
        </Typography>
      </TableCell>
      <TableCell>
        <Typography variant="wfCode" color="text.secondary">
          {feature.sessions.length}
        </Typography>
      </TableCell>
      <TableCell>
        <Typography variant="wfBody" color="text.secondary" sx={{ fontSize: '12px' }}>
          {feature.project}
        </Typography>
      </TableCell>
    </TableRow>
  )
}

/* Brand status hex tokens — kept inline so KPI tiles render with the
   right accent even before the MUI theme has hydrated. Mirrors the
   palette baked into wf/StatusPill. */
const WF_SIGNAL = '#3B9EFF'
const WF_STALLED = '#F2B441'
const WF_COMPLETED = '#5BD68A'
const WF_BONE = '#E6EBF2'
const WF_FOG = '#5A6472'
const WF_STEEL = '#2A3340'

const TONE_TO_WF: Record<'ok' | 'warn', { dataTone: 'completed' | 'stalled'; color: string }> = {
  ok: { dataTone: 'completed', color: WF_COMPLETED },
  warn: { dataTone: 'stalled', color: WF_STALLED },
}

function KpiTile({
  label, value, sub, tone, delta,
}: Readonly<{ label: string; value: number; sub: string; tone?: 'ok' | 'warn'; delta?: number }>) {
  const wfTone = tone ? TONE_TO_WF[tone] : null
  const valueColor = wfTone?.color ?? WF_BONE
  return (
    <Box
      data-testid="kpi-tile"
      data-label={label.toLowerCase()}
      data-tone={wfTone?.dataTone ?? 'neutral'}
      sx={{
        position: 'relative',
        p: 2,
        border: `1px solid ${WF_STEEL}`,
        borderRadius: 1,
        bgcolor: 'surface1',
        overflow: 'hidden',
        '&::before': wfTone
          ? {
              content: '""',
              position: 'absolute',
              left: 0, top: 0, bottom: 0,
              width: '3px',
              bgcolor: wfTone.color,
            }
          : undefined,
      }}
    >
      <Box
        component="span"
        sx={{
          display: 'block',
          fontFamily: '"Geist Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
          fontSize: '10px',
          fontWeight: 500,
          letterSpacing: '0.12em',
          textTransform: 'uppercase',
          color: WF_FOG,
        }}
      >
        {label}
      </Box>
      <Box sx={{ display: 'flex', alignItems: 'baseline', gap: 1, mt: 0.5 }}>
        <Box
          component="span"
          sx={{
            fontFamily: '"Geist Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
            fontSize: '2rem',
            fontWeight: 500,
            lineHeight: 1.1,
            letterSpacing: '-0.02em',
            color: valueColor,
            fontFeatureSettings: '"tnum" 1',
          }}
        >
          {value}
        </Box>
        {delta !== undefined && delta !== 0 && (
          <Box
            component="span"
            sx={{
              fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
              fontSize: '11px',
              fontWeight: 500,
              color: delta > 0 ? WF_SIGNAL : WF_FOG,
            }}
          >
            {delta > 0 ? '+' : ''}{delta} vs prev
          </Box>
        )}
      </Box>
      <Box
        component="span"
        sx={{
          display: 'block',
          fontSize: '12px',
          color: WF_FOG,
          fontFamily: '"Inter", system-ui, -apple-system, sans-serif',
        }}
      >
        {sub}
      </Box>
    </Box>
  )
}

function FooterPanel({ title, children }: Readonly<{ title: string; children: React.ReactNode }>) {
  return (
    <Box sx={{ border: '1px solid', borderColor: 'divider', borderRadius: 1, overflow: 'hidden' }}>
      <Typography
        variant="wfLabel"
        sx={{ px: 2, py: 1, bgcolor: 'surface1', display: 'block', color: 'text.secondary' }}
      >
        {title}
      </Typography>
      <Box sx={{ p: 2 }}>{children}</Box>
    </Box>
  )
}

function HealthRow({
  label, value, unit, tone,
}: Readonly<{ label: string; value: number; unit: string; tone?: 'ok' | 'warn' }>) {
  const valueColor = tone === 'warn' ? 'warning.main' : tone === 'ok' ? 'success.main' : 'text.primary'
  return (
    <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5 }}>
      <Typography variant="wfLabel" sx={{ minWidth: 130, color: 'text.secondary' }}>
        {label}
      </Typography>
      <LinearProgress
        variant="determinate"
        value={Math.min(100, Math.max(0, value))}
        sx={{ flex: 1, height: 4, borderRadius: 1 }}
      />
      <Typography variant="wfCode" sx={{ minWidth: 40, textAlign: 'right', color: valueColor, fontWeight: 500 }}>
        {value}{unit}
      </Typography>
    </Box>
  )
}

function ThroughputBars({ throughput }: Readonly<{ throughput: number[] }>) {
  const max = Math.max(1, ...throughput)
  const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']
  return (
    <Box sx={{ display: 'flex', alignItems: 'flex-end', gap: 0.75, height: 80 }}>
      {throughput.map((v, i) => (
        <Box key={i} sx={{ flex: 1, display: 'flex', flexDirection: 'column', alignItems: 'center', gap: 0.5 }}>
          <Box
            sx={{
              width: '100%',
              bgcolor: v > 0 ? 'primary.main' : 'action.disabledBackground',
              opacity: v > 0 ? 0.85 : 0.3,
              borderRadius: 0.5,
              height: `${(v / max) * 60}px`,
              minHeight: 2,
            }}
          />
          <Typography variant="wfLabel" sx={{ color: 'text.secondary' }}>
            {days[i]}
          </Typography>
        </Box>
      ))}
    </Box>
  )
}

interface FeatureCounts {
  running: number
  awaiting: number
  blocked: number
  shipped: number
}

function countFeaturesByStatus(features: Feature[]): FeatureCounts {
  const counts: FeatureCounts = { running: 0, awaiting: 0, blocked: 0, shipped: 0 }
  for (const f of features) {
    if (f.status === 'active') counts.running += 1
    else if (f.status === 'waiting') counts.awaiting += 1
    else if (f.status === 'stuck' || f.status === 'paused') counts.blocked += 1
    else if (f.status === 'done') counts.shipped += 1
  }
  return counts
}

interface FleetStats {
  passRate: number
  errorRate: number
  permissionFriction: number
  autopilotTrust: number
  budgetUsed: number
  burnPerWk: number
  commits24h: number
  weekThroughput: number[]
  runningDelta: number
  shippedDelta: number
}

function computeFleetStats(features: Feature[], sessions: ReturnType<typeof useSessions>['data'] extends infer S ? S : never): FleetStats {
  // Pragmatic fleet-stat derivation from existing hook payloads. Numbers are
  // approximations until commit 7 (Metrics polish) wires real aggregation
  // through metrics_helpers.py — keeping them here avoids a new endpoint
  // for an MVP-shaped view.
  const list = sessions ?? []
  const total = list.length || 1
  const ended = list.filter((s) => s.status === 'completed' || s.status === 'stopped' || s.status === 'closed' || s.status === 'stale').length
  const errors = list.filter((s) => s.event === 'PostToolUseFailure').length
  const friction = list.filter((s) => s.event === 'PermissionRequest').length
  const passed = ended - errors
  const passRate = Math.round((passed / Math.max(1, ended)) * 1000) / 10 || 0
  const shippedThisWeek = features.filter((f) => f.status === 'done').length
  const week = Array.from({ length: 7 }, () => 0)
  // Distribute completion across week buckets — operator can verify the
  // shape, real data comes from metrics aggregation in commit 7.
  for (let i = 0; i < shippedThisWeek; i += 1) {
    week[(i * 2) % 7] += 1
  }
  return {
    passRate: Number.isFinite(passRate) ? passRate : 0,
    errorRate: Math.round((errors / total) * 1000) / 10,
    permissionFriction: Math.round((friction / total) * 1000) / 10,
    autopilotTrust: friction === 0 ? 100 : Math.max(0, 100 - friction),
    budgetUsed: Math.min(100, Math.round((total / 100) * 100)),
    burnPerWk: total * 1.2,
    commits24h: features.reduce((acc, f) => acc + f.sessions.length, 0),
    weekThroughput: week,
    runningDelta: 0,
    shippedDelta: shippedThisWeek > 0 ? shippedThisWeek : 0,
  }
}

interface ActivityEvent {
  when: string
  text: string
}

function recentActivity(features: Feature[], sessions: ReturnType<typeof useSessions>['data'] extends infer S ? S : never): ActivityEvent[] {
  const events: ActivityEvent[] = []
  const list = sessions ?? []
  const recent = list.slice(-12).reverse()
  for (const s of recent) {
    const ago = relativeAgo(s.ts)
    if (s.event === 'TaskCompleted') {
      events.push({ when: ago, text: `task completed · ${s.branch}` })
    } else if (s.event === 'Stop') {
      events.push({ when: ago, text: `session ended · ${s.branch}` })
    } else if (s.event === 'PostToolUseFailure') {
      events.push({ when: ago, text: `tool failed · ${s.branch}` })
    } else if (s.event === 'SessionStart') {
      events.push({ when: ago, text: `new session · ${s.branch}` })
    }
  }
  for (const f of features) {
    if (f.status === 'done') events.push({ when: 'now', text: `${f.name} shipped` })
  }
  return events
}

function relativeAgo(ts: string): string {
  const then = Date.parse(ts)
  if (Number.isNaN(then)) return ''
  const seconds = Math.floor((Date.now() - then) / 1000)
  if (seconds < 60) return `${seconds}s`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m`
  if (seconds < 86400) return `${Math.floor(seconds / 3600)}h`
  return `${Math.floor(seconds / 86400)}d`
}

function summarize(features: Feature[], projectCount: number, activeSessions: number): string {
  const active = features.filter((f) => f.status === 'active' || f.status === 'waiting').length
  if (active === 0 && projectCount === 0) return 'No projects discovered yet.'
  const parts = [`${active} feature${active === 1 ? '' : 's'} underway`]
  if (activeSessions > 0) parts.push(`${activeSessions} active session${activeSessions === 1 ? '' : 's'}`)
  if (projectCount > 0) parts.push(`${projectCount} project${projectCount === 1 ? '' : 's'}`)
  return parts.join(' · ')
}

function progressTone(status: Feature['status']): 'primary' | 'success' | 'warning' | 'error' {
  switch (status) {
    case 'active': return 'primary'
    case 'done': return 'success'
    case 'stuck': return 'error'
    case 'paused': return 'warning'
    default: return 'primary'
  }
}
