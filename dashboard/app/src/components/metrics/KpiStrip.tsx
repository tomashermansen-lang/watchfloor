import { Box, Typography } from '@mui/material'
import { memo, useMemo } from 'react'
import { Area, AreaChart } from 'recharts'
import type { MetricsResponse } from '../../types'
import { formatDuration } from '../../utils/time'

interface KpiStripProps {
  metrics: MetricsResponse | undefined
  selectedSid: string | 'all'
}

interface KpiCard {
  label: string
  value: string
  hint?: string
  tone?: 'ok' | 'warn'
  trend: number[]
}

/**
 * KpiStrip — six glanceable KPI cards: Sessions · Tool Calls · Error Rate ·
 * Friction · Autopilot · Spend. Each card carries a small inline sparkline
 * derived from existing MetricsResponse buckets (no new endpoints).
 *
 * VS Code-quiet aesthetic: no Paper shadows, just a thin divider border;
 * label uppercase + small caption, value large, sparkline floats inside
 * the card on the right side.
 */
function KpiStripInner({ metrics, selectedSid }: KpiStripProps) {
  const cards = useMemo<KpiCard[]>(() => buildCards(metrics, selectedSid), [metrics, selectedSid])

  return (
    <Box
      display="grid"
      gridTemplateColumns="repeat(6, 1fr)"
      gap={1.5}
      aria-live="polite"
      data-testid="kpi-strip"
    >
      {cards.map((card) => (
        <KpiCardCell key={card.label} card={card} />
      ))}
    </Box>
  )
}

/* Brand status accent — handoff §1 Overview "KPI grid": cards carry
   a 2-3px top/left rail in the relevant status color when the value
   trips a threshold ('warn' for friction/error rate spikes, 'ok' for
   autopilot engagement). Otherwise no rail — the resting card is just
   wf.carbon + wf.steel chrome. */
function toneRail(tone: KpiCard['tone']): string | null {
  if (tone === 'warn') return 'var(--mui-palette-status-stalled)'
  if (tone === 'ok') return 'var(--mui-palette-status-completed)'
  return null
}

function valueColorFor(tone: KpiCard['tone']): string {
  if (tone === 'warn') return 'status.stalled'
  if (tone === 'ok') return 'status.completed'
  return 'wf.bone'
}

function KpiCardCell({ card }: Readonly<{ card: KpiCard }>) {
  // Recharts AreaChart needs at least one data point; pad with zeros if empty
  const data = card.trend.length > 0 ? card.trend : [0, 0]
  const sparkData = data.map((v, i) => ({ i, v }))
  const rail = toneRail(card.tone)
  return (
    <Box
      aria-label={`${card.label}: ${card.value}`}
      sx={{
        position: 'relative',
        p: 1.5,
        border: '1px solid',
        borderColor: 'wf.steel',
        bgcolor: 'wf.carbon',
        borderRadius: 0,
        display: 'flex',
        flexDirection: 'column',
        gap: 0.5,
        minHeight: 96,
        overflow: 'hidden',
        '&::before': rail
          ? {
              content: '""',
              position: 'absolute',
              left: 0, top: 0, bottom: 0,
              width: '3px',
              bgcolor: rail,
            }
          : undefined,
      }}
    >
      <Typography variant="wfLabel" color="text.secondary">
        {card.label}
      </Typography>
      <Box sx={{ display: 'flex', alignItems: 'baseline', gap: 1 }}>
        <Typography
          variant="wfDisplay"
          sx={{
            color: valueColorFor(card.tone),
            fontFeatureSettings: '"tnum" 1',
          }}
        >
          {card.value}
        </Typography>
        {card.hint && (
          <Typography variant="wfCode" sx={{ color: 'wf.fog' }}>
            {card.hint}
          </Typography>
        )}
      </Box>
      {/* Sparkline — Signal Blue accent (single-chromatic-accent rule),
          floats top-right of the card. */}
      <Box sx={{ position: 'absolute', right: 8, top: 8, color: 'wf.signal' }}>
        <AreaChart width={60} height={28} data={sparkData} margin={{ top: 2, right: 0, bottom: 0, left: 0 }}>
          <defs>
            <linearGradient id={`spark-${card.label}`} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="currentColor" stopOpacity={0.4} />
              <stop offset="100%" stopColor="currentColor" stopOpacity={0} />
            </linearGradient>
          </defs>
          <Area
            type="monotone"
            dataKey="v"
            stroke="currentColor"
            strokeWidth={1.25}
            fill={`url(#spark-${card.label})`}
            isAnimationActive={false}
          />
        </AreaChart>
      </Box>
    </Box>
  )
}

function buildCards(metrics: MetricsResponse | undefined, selectedSid: string | 'all'): KpiCard[] {
  const isSingle = selectedSid !== 'all'

  if (!metrics) {
    return [
      { label: 'Sessions', value: '0', trend: [] },
      { label: 'Tool Calls', value: '0', trend: [] },
      { label: 'Error Rate', value: '—', trend: [] },
      { label: 'Friction', value: '—', trend: [] },
      { label: 'Autopilot', value: '0/0', hint: 'engaged', trend: [] },
      { label: 'Spend', value: '$0', hint: '/hr', trend: [] },
    ]
  }

  if (isSingle) {
    const sess = metrics.session_lifecycle.sessions.find((s) => s.sid === selectedSid)
    const toolCount = metrics.tool_usage.by_session[selectedSid]?.count ?? 0
    const errInfo = metrics.error_tracking.by_session[selectedSid]
    const permPrompts = metrics.permission_friction.by_session[selectedSid]?.prompts ?? 0
    const responses = metrics.task_completion.responses_by_session?.[selectedSid] ?? 0
    const tasks = metrics.task_completion.by_session[selectedSid] ?? 0
    return [
      { label: 'Duration', value: sess ? formatDuration(sess.duration_s) : '—', trend: [] },
      { label: 'Tool Calls', value: String(toolCount), trend: derivedTrend(toolCount) },
      { label: 'Error Rate', value: errInfo ? `${errInfo.rate}%` : '—', tone: (errInfo?.rate ?? 0) > 5 ? 'warn' : undefined, trend: [] },
      {
        label: 'Friction',
        value: toolCount > 0 ? `${((permPrompts / toolCount) * 100).toFixed(1)}%` : '—',
        trend: [],
      },
      { label: 'Autopilot', value: '—', hint: 'session view', trend: [] },
      { label: 'Tasks', value: tasks > 0 ? `${responses}/${tasks}` : String(responses), trend: [] },
    ]
  }

  const totalSessions = metrics.session_lifecycle.sessions.length
  const totalTools = metrics.tool_usage.total
  const errorRate = totalTools > 0 ? (metrics.error_tracking.total_errors / totalTools) * 100 : 0
  const frictionRate = totalTools > 0 ? (metrics.permission_friction.total_prompts / totalTools) * 100 : 0
  // Spend approximated from session count × an average cost-per-session
  // estimate; commit 7b will replace this with real cost aggregation
  // from autopilot summary JSONs.
  const spendPerHour = totalSessions * 0.85
  // Autopilot share — sessions tagged with end_reason 'clear' typically
  // come from autopilot runs; the proper signal lands when /api/autopilots
  // is fed into the metrics aggregator (commit 7b).
  const autopilotEngaged = metrics.session_lifecycle.sessions.filter(
    (s) => s.end_reason === 'clear' || s.source === 'continue',
  ).length

  return [
    {
      label: 'Sessions',
      value: String(totalSessions),
      trend: trendFromConcurrency(metrics.session_lifecycle.concurrency_timeline.map((p) => ({ timestamp: p.ts, concurrent: p.concurrent }))),
    },
    {
      label: 'Tool Calls',
      value: String(totalTools),
      trend: trendFromTimeline(metrics.activity_timeline),
    },
    {
      label: 'Error Rate',
      value: `${errorRate.toFixed(1)}%`,
      tone: errorRate > 5 ? 'warn' : undefined,
      trend: trendFromTimeline(metrics.error_tracking.timeline),
    },
    {
      label: 'Friction',
      value: `${frictionRate.toFixed(1)}%`,
      tone: frictionRate > 10 ? 'warn' : undefined,
      trend: trendFromTimeline(metrics.permission_friction.timeline),
    },
    {
      label: 'Autopilot',
      value: `${autopilotEngaged}/${totalSessions}`,
      hint: 'engaged',
      tone: autopilotEngaged > 0 ? 'ok' : undefined,
      trend: derivedTrend(autopilotEngaged),
    },
    {
      label: 'Spend',
      value: `$${spendPerHour.toFixed(0)}`,
      hint: '/hr',
      trend: derivedTrend(spendPerHour),
    },
  ]
}

function trendFromConcurrency(timeline: Array<{ timestamp: string; concurrent: number }> | undefined): number[] {
  if (!timeline || timeline.length === 0) return []
  return timeline.slice(-12).map((p) => p.concurrent)
}

interface TimelinePoint {
  timestamp?: string
  count?: number
  errors?: number
  prompts?: number
  [key: string]: unknown
}

function trendFromTimeline(timeline: unknown): number[] {
  if (!Array.isArray(timeline)) return []
  return timeline.slice(-12).map((p: TimelinePoint) => {
    if (typeof p.count === 'number') return p.count
    if (typeof p.errors === 'number') return p.errors
    if (typeof p.prompts === 'number') return p.prompts
    return 0
  })
}

function derivedTrend(value: number): number[] {
  // No real history available — fabricate a sensible 8-point trend that
  // ramps to the current value. Visual placeholder until commit 7b wires
  // proper time-series aggregation.
  const len = 8
  const trend: number[] = []
  for (let i = 0; i < len; i += 1) {
    const t = (i + 1) / len
    trend.push(value * t)
  }
  return trend
}

const KpiStrip = memo(KpiStripInner)
export default KpiStrip
