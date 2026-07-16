import { useState, useMemo, useEffect, useRef } from 'react'
import Box from '@mui/material/Box'
import Select from '@mui/material/Select'
import MenuItem from '@mui/material/MenuItem'
import ToggleButton from '@mui/material/ToggleButton'
import ToggleButtonGroup from '@mui/material/ToggleButtonGroup'
import Tabs from '@mui/material/Tabs'
import Tab from '@mui/material/Tab'
import Typography from '@mui/material/Typography'
import Grid from '@mui/material/Grid'
import Button from '@mui/material/Button'
import FileDownloadOutlinedIcon from '@mui/icons-material/FileDownloadOutlined'
import { useMetrics } from '../../hooks/useMetrics'
import { useSessions } from '../../hooks/useSessions'
import KpiStrip from './KpiStrip'
import ActivityTimeline from './ActivityTimeline'
import ToolUsage from './ToolUsage'
import ErrorTracking from './ErrorTracking'
import SessionLifecycle from './SessionLifecycle'
import PermissionFriction from './PermissionFriction'
import SubagentUtil from './SubagentUtil'
import TaskCompletion from './TaskCompletion'
import FileActivity from './FileActivity'
import RunEconomy from './RunEconomy'

type TimeRange = '15m' | '1h' | '6h' | '24h' | '7d' | 'all'
type SubTab = 'activity' | 'run-economy'

function computeSince(range: TimeRange): string | undefined {
  if (range === 'all') return undefined
  const minsByRange: Record<Exclude<TimeRange, 'all'>, number> = {
    '15m': 15,
    '1h': 60,
    '6h': 360,
    '24h': 1440,
    '7d': 1440 * 7,
  }
  return new Date(Date.now() - minsByRange[range] * 60_000).toISOString()
}

function formatRelativeAgo(ts: number): string {
  const seconds = Math.max(0, Math.floor((Date.now() - ts) / 1000))
  if (seconds < 60) return `${seconds}s ago`
  if (seconds < 3600) return `${Math.floor(seconds / 60)}m ago`
  return `${Math.floor(seconds / 3600)}h ago`
}

export default function MetricsView() {
  const [subTab, setSubTab] = useState<SubTab>('activity')
  const [selectedSid, setSelectedSid] = useState<string | 'all'>('all')
  const [timeRange, setTimeRange] = useState<TimeRange>('1h')

  // Refresh since every 30s to keep time window accurate
  const [sinceKey, setSinceKey] = useState(0)
  useEffect(() => {
    if (timeRange === 'all') return
    const id = setInterval(() => setSinceKey(k => k + 1), 30_000)
    return () => clearInterval(id)
  }, [timeRange])

  const since = useMemo(() => computeSince(timeRange), [timeRange, sinceKey])
  const { data: metrics } = useMetrics(
    selectedSid !== 'all' ? selectedSid : undefined,
    since,
  )
  const { data: sessions } = useSessions()

  // Track last-fetch timestamp for the LIVE indicator. Updates whenever
  // the metrics object reference changes (SWR returns a new object on
  // each successful fetch).
  const lastFetchRef = useRef<number>(Date.now())
  useEffect(() => {
    if (metrics) lastFetchRef.current = Date.now()
  }, [metrics])
  const [liveTick, setLiveTick] = useState(0)
  useEffect(() => {
    const id = setInterval(() => setLiveTick((t) => t + 1), 5_000)
    return () => clearInterval(id)
  }, [])
  const liveLabel = useMemo(() => formatRelativeAgo(lastFetchRef.current), [liveTick])

  // Build session list for the selector
  const sessionOptions = useMemo(() => {
    if (!sessions) return []
    return sessions.map(s => ({
      sid: s.sid,
      label: `${s.branch} — ${s.sid.slice(0, 7)}`,
    }))
  }, [sessions])

  return (
    <Box sx={{ px: { xs: 1.5, sm: 2, md: 3 }, py: { xs: 1.5, md: 2 }, overflowY: 'auto', height: '100%' }}>
      {/* Sub-tab navigation. Activity = the existing 8-card hook-driven
          observability grid. Run Economy = autopilot run aggregates per
          feature. Brand chrome: borderless tabs with wf.signal underline
          for the selected tab; the same JBM mono UPPERCASE label voice
          as the time-range segmented control above to keep the metric
          surface visually unified. */}
      <Tabs
        value={subTab}
        onChange={(_, v: SubTab) => setSubTab(v)}
        data-testid="metrics-subtabs"
        aria-label="Metrics sub-views"
        sx={{
          mb: 2,
          minHeight: 32,
          borderBottom: '1px solid',
          borderColor: 'wf.steel',
          '& .MuiTabs-indicator': { backgroundColor: 'wf.signal', height: 2 },
          '& .MuiTab-root': {
            minHeight: 32,
            py: 0.5,
            px: 1.5,
            fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
            fontSize: '11px',
            fontWeight: 500,
            letterSpacing: '0.08em',
            textTransform: 'uppercase',
            color: 'wf.fog',
            '&.Mui-selected': { color: 'wf.bone' },
          },
        }}
      >
        <Tab value="activity" label="Activity" />
        <Tab value="run-economy" label="Run Economy" />
      </Tabs>

      {subTab === 'run-economy' && <RunEconomy />}
      {subTab === 'activity' && <ActivityContent
        selectedSid={selectedSid}
        setSelectedSid={setSelectedSid}
        timeRange={timeRange}
        setTimeRange={setTimeRange}
        sessionOptions={sessionOptions}
        metrics={metrics}
        liveLabel={liveLabel}
      />}
    </Box>
  )
}

interface ActivityContentProps {
  selectedSid: string | 'all'
  setSelectedSid: (s: string | 'all') => void
  timeRange: TimeRange
  setTimeRange: (r: TimeRange) => void
  sessionOptions: { sid: string; label: string }[]
  metrics: ReturnType<typeof useMetrics>['data']
  liveLabel: string
}

function ActivityContent({ selectedSid, setSelectedSid, timeRange, setTimeRange, sessionOptions, metrics, liveLabel }: ActivityContentProps) {
  return (
    <Box>
      {/* Filter Bar */}
      <Box
        sx={{
          display: 'flex',
          gap: 2,
          mb: 2,
          alignItems: 'center',
          flexWrap: 'wrap',
        }}
      >
        {/* Session selector — brand input chrome: sharp 0px corners,
            JBM mono, wf.steel border, signal-blue focus border per
            handoff §UI Primitives "Inputs" + "Dropdown". MenuProps
            cascades the same chrome to the open popover (which is
            portaled outside the Select's sx tree, so trigger styles
            don't reach the items by default). */}
        <Select
          size="small"
          value={selectedSid}
          onChange={(e) => setSelectedSid(e.target.value)}
          displayEmpty
          aria-label="Filter by session"
          sx={{
            minWidth: 200,
            borderRadius: 0,
            fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
            fontSize: '11px',
            color: 'wf.bone',
            bgcolor: 'wf.ink',
            '& .MuiOutlinedInput-notchedOutline': { borderColor: 'wf.steel' },
            '&:hover .MuiOutlinedInput-notchedOutline': { borderColor: 'wf.signal' },
            '&.Mui-focused .MuiOutlinedInput-notchedOutline': {
              borderColor: 'wf.signal',
              borderWidth: 1,
            },
            '& .MuiSelect-icon': { color: 'wf.fog' },
          }}
          MenuProps={{
            PaperProps: {
              sx: {
                bgcolor: 'wf.carbon',
                border: '1px solid',
                borderColor: 'wf.steel',
                borderRadius: 0,
                mt: 0.5,
                '& .MuiMenuItem-root': {
                  fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
                  fontSize: '11px',
                  color: 'wf.bone',
                  '&:hover': { bgcolor: 'rgba(59, 158, 255, 0.08)' },
                  '&.Mui-selected': {
                    bgcolor: 'rgba(59, 158, 255, 0.14)',
                    color: 'wf.signal',
                    '&:hover': { bgcolor: 'rgba(59, 158, 255, 0.18)' },
                  },
                },
              },
            },
          }}
        >
          <MenuItem value="all">All Sessions</MenuItem>
          {sessionOptions.map(opt => (
            <MenuItem key={opt.sid} value={opt.sid}>{opt.label}</MenuItem>
          ))}
        </Select>
        {/* Time-range segmented control — handoff §UI Primitives
            "Segmented control": inline-flex group, 1px wf.steel
            border, sharp corners. Selected = wf.signal bg / wf.ink
            text. Unselected = transparent / wf.fog. */}
        <ToggleButtonGroup
          size="small"
          exclusive
          value={timeRange}
          onChange={(_, v) => { if (v) setTimeRange(v) }}
          aria-label="Time range"
          sx={{
            border: '1px solid',
            borderColor: 'wf.steel',
            borderRadius: 0,
            '& .MuiToggleButton-root': {
              fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
              fontSize: '10px',
              fontWeight: 500,
              letterSpacing: '0.08em',
              textTransform: 'uppercase',
              px: 1.25,
              py: 0.5,
              color: 'wf.fog',
              border: 'none',
              borderRadius: 0,
              '&.Mui-selected': {
                bgcolor: 'wf.signal',
                color: 'wf.ink',
                '&:hover': { bgcolor: 'wf.signal' },
              },
              '&:hover': { bgcolor: 'rgba(59, 158, 255, 0.08)' },
            },
          }}
        >
          <ToggleButton value="15m">15m</ToggleButton>
          <ToggleButton value="1h">1h</ToggleButton>
          <ToggleButton value="6h">6h</ToggleButton>
          <ToggleButton value="24h">24h</ToggleButton>
          <ToggleButton value="7d">7d</ToggleButton>
          <ToggleButton value="all">All</ToggleButton>
        </ToggleButtonGroup>
        <Box sx={{ flex: 1 }} />
        {/* Data-freshness label — plain JBM mono timestamp, no LIVE
            pill ornament. The LiveBadge lives once in the global
            title-bar chrome (handoff §App Chrome "appears on every
            authenticated screen"); duplicating it inside a single
            view doubled the brand surface and read as noise rather
            than signal. */}
        <Typography
          data-testid="metrics-live-indicator"
          variant="wfCode"
          sx={{ color: 'wf.fog', fontSize: '10px' }}
        >
          Updated {liveLabel}
        </Typography>
        <Button
          size="small"
          variant="outlined"
          startIcon={<FileDownloadOutlinedIcon sx={{ fontSize: 14 }} />}
          onClick={() => exportMetricsCsv(metrics, selectedSid, timeRange)}
        >
          Export CSV
        </Button>
      </Box>

      {/* KPI Strip */}
      <Box sx={{ mb: 2 }}>
        <KpiStrip metrics={metrics} selectedSid={selectedSid} />
      </Box>

      {!metrics ? (
        <Box sx={{ textAlign: 'center', mt: 4 }}>
          <Typography variant="body2" color="text.secondary">
            Loading metrics...
          </Typography>
        </Box>
      ) : (
        <Grid container spacing={2}>
          {/* M8 Activity Timeline — full width */}
          <Grid size={12}>
            <ActivityTimeline data={metrics.activity_timeline} selectedSid={selectedSid} />
          </Grid>

          {/* M1 + M2 side by side */}
          <Grid size={{ xs: 12, md: 6 }}>
            <ToolUsage data={metrics.tool_usage} selectedSid={selectedSid} />
          </Grid>
          <Grid size={{ xs: 12, md: 6 }}>
            <ErrorTracking data={metrics.error_tracking} selectedSid={selectedSid} />
          </Grid>

          {/* M3 + M4 side by side */}
          <Grid size={{ xs: 12, md: 6 }}>
            <SessionLifecycle data={metrics.session_lifecycle} />
          </Grid>
          <Grid size={{ xs: 12, md: 6 }}>
            <PermissionFriction data={metrics.permission_friction} selectedSid={selectedSid} />
          </Grid>

          {/* M5 + M7 side by side */}
          <Grid size={{ xs: 12, md: 6 }}>
            <SubagentUtil data={metrics.subagent_utilization} />
          </Grid>
          <Grid size={{ xs: 12, md: 6 }}>
            <TaskCompletion data={metrics.task_completion} selectedSid={selectedSid} />
          </Grid>

          {/* M6 File Activity — full width */}
          <Grid size={12}>
            <FileActivity data={metrics.file_activity} />
          </Grid>
        </Grid>
      )}
    </Box>
  )
}

/**
 * Export the current metrics snapshot as a CSV. The download triggers
 * client-side via a Blob+anchor, so no server endpoint is needed. CSV
 * shape is intentionally narrow (one row per metric category) — full
 * timeline export will follow once the backend exposes a streaming
 * endpoint.
 */
function exportMetricsCsv(
  metrics: ReturnType<typeof useMetrics>['data'],
  selectedSid: string,
  range: TimeRange,
): void {
  if (!metrics) return
  const rows: string[][] = [
    ['metric', 'value', 'session_filter', 'time_range'],
    ['sessions', String(metrics.session_lifecycle.sessions.length), selectedSid, range],
    ['tool_calls', String(metrics.tool_usage.total), selectedSid, range],
    ['errors_total', String(metrics.error_tracking.total_errors), selectedSid, range],
    ['permission_prompts', String(metrics.permission_friction.total_prompts), selectedSid, range],
    ['tasks_total', String(metrics.task_completion.total), selectedSid, range],
  ]
  const csv = rows.map((r) => r.map(csvEscape).join(',')).join('\n')
  const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' })
  const url = URL.createObjectURL(blob)
  const a = document.createElement('a')
  a.href = url
  a.download = `metrics-${range}-${new Date().toISOString().slice(0, 19).replace(/[:T]/g, '-')}.csv`
  document.body.appendChild(a)
  a.click()
  document.body.removeChild(a)
  URL.revokeObjectURL(url)
}

function csvEscape(v: string): string {
  if (/[",\n]/.test(v)) return `"${v.replace(/"/g, '""')}"`
  return v
}
