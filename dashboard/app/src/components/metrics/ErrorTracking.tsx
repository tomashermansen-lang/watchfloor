import { Box, Stack, Typography } from '@mui/material'
import CheckCircleIcon from '@mui/icons-material/CheckCircle'
import { memo, useMemo } from 'react'
import {
  ResponsiveContainer, ScatterChart, Scatter, XAxis, YAxis, Tooltip,
} from 'recharts'
import type { ErrorTrackingMetrics } from '../../types'
import MetricCard from './MetricCard'
import StatusPill from '../wf/StatusPill'

interface ErrorTrackingProps {
  data: ErrorTrackingMetrics
  selectedSid: string | 'all'
}

/**
 * ErrorTracking — failures + interrupts at a glance, with a time-series
 * scatter and a one-line annotation calling out the dominant origin.
 *
 * Polished version (commit 7d). Drops the previous stacked bar chart in
 * favor of:
 *   - a prominent error count headline + Failures/Interrupts chips
 *   - a wide scatter showing when errors happened (X = time, dots
 *     coloured by interrupt vs failure)
 *   - a single annotation line ('Most errors originate in Bash (6 of
 *     8) — timeouts in long test runs') so the operator sees the
 *     pattern without scanning the chart
 */
function ErrorTrackingInner({ data, selectedSid }: ErrorTrackingProps) {
  const isEmpty = data.total_errors === 0

  const timelineData = useMemo(() => {
    return data.timeline.map((e) => ({
      ts: new Date(e.ts).getTime(),
      y: e.is_interrupt ? 0 : 1,
      tool: e.tool,
      type: e.is_interrupt ? 'Interrupt' : 'Failure',
    }))
  }, [data.timeline])

  const dominant = useMemo(() => {
    const entries = Object.entries(data.by_tool)
    if (entries.length === 0) return null
    entries.sort(([, a], [, b]) => b - a)
    const [tool, count] = entries[0]
    return { tool, count }
  }, [data.by_tool])

  const rate = selectedSid !== 'all' ? data.by_session[selectedSid]?.rate : undefined
  const overallRate = rate !== undefined ? `${rate}%` : undefined

  return (
    <MetricCard title="Error Tracking" isEmpty={false} emptyMessage="">
      {isEmpty ? (
        <Stack direction="row" alignItems="center" spacing={1} justifyContent="center" py={2}>
          <CheckCircleIcon color="success" fontSize="small" />
          <Typography variant="body2" color="text.secondary">
            No errors recorded
          </Typography>
        </Stack>
      ) : (
        <>
          <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5, mb: 1 }}>
            <Typography variant="wfLabel" color="text.secondary">
              Errors {overallRate ? `· rate ${overallRate}` : ''}
            </Typography>
            <Typography
              variant="wfDisplay"
              sx={{ color: 'status.fault', fontFeatureSettings: '"tnum" 1' }}
            >
              {data.total_errors}
            </Typography>
          </Box>
          <Stack direction="row" spacing={1} mb={1.5}>
            <StatusPill status="fault" label={`Failures: ${data.failures}`} />
            <StatusPill status="stalled" label={`Interrupts: ${data.interrupts}`} />
          </Stack>
          {timelineData.length > 0 && (
            <Box sx={{ width: '100%', height: 120 }}>
              <ResponsiveContainer width="100%" height="100%">
                <ScatterChart margin={{ top: 8, right: 8, bottom: 16, left: 8 }}>
                  <XAxis
                    type="number"
                    dataKey="ts"
                    domain={['dataMin', 'dataMax']}
                    tickFormatter={(v) =>
                      new Date(v).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })
                    }
                    tick={{ fontSize: 10 }}
                    axisLine={false}
                    tickLine={false}
                  />
                  <YAxis type="number" dataKey="y" hide domain={[-0.5, 1.5]} />
                  <Tooltip
                    labelFormatter={(v) => new Date(Number(v)).toLocaleTimeString()}
                    formatter={(_value, _name, entry) => {
                      const p = entry.payload as Record<string, string>
                      return [p.tool, p.type]
                    }}
                  />
                  <Scatter
                    data={timelineData.filter((d) => d.y === 1)}
                    fill="var(--mui-palette-error-main)"
                    name="Failures"
                  />
                  <Scatter
                    data={timelineData.filter((d) => d.y === 0)}
                    fill="var(--mui-palette-warning-main)"
                    name="Interrupts"
                  />
                </ScatterChart>
              </ResponsiveContainer>
            </Box>
          )}
          {dominant && (
            <Typography
              data-testid="error-annotation"
              variant="wfBody"
              color="text.secondary"
              sx={{ mt: 1, display: 'block' }}
            >
              Most errors originate in{' '}
              <Box component="span" sx={{ color: 'text.primary', fontWeight: 600 }}>
                {dominant.tool}
              </Box>{' '}
              ({dominant.count} of {data.total_errors})
            </Typography>
          )}
        </>
      )}
    </MetricCard>
  )
}

const ErrorTracking = memo(ErrorTrackingInner)
export default ErrorTracking
