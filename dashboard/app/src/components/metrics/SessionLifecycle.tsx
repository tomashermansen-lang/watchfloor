import { Box, Chip, Stack, Typography } from '@mui/material'
import { memo, useMemo } from 'react'
import type { SessionLifecycleMetrics } from '../../types'
import { formatDuration } from '../../utils/time'
import MetricCard from './MetricCard'

interface SessionLifecycleProps {
  data: SessionLifecycleMetrics
}

/**
 * SessionLifecycle — polished version (commit 7 footer panels).
 *
 * Drops the model-distribution pie chart and end-reason chips that
 * crowded the previous layout. Reference shows a tighter panel:
 *   - Large avg-duration headline + session-count caption
 *   - Peak concurrent number, isolated and prominent
 *   - Concurrency bar mini-visualization across time
 *   - Source distribution as small outlined chips
 */
function SessionLifecycleInner({ data }: SessionLifecycleProps) {
  const sessions = data.sessions
  const avgDuration = sessions.length > 0
    ? sessions.reduce((sum, s) => sum + s.duration_s, 0) / sessions.length
    : 0

  const peakConcurrent = data.concurrency_timeline.length > 0
    ? Math.max(...data.concurrency_timeline.map((c) => c.concurrent))
    : sessions.length

  const concurrencyBars = useMemo(() => {
    if (data.concurrency_timeline.length === 0) return []
    return data.concurrency_timeline.slice(-12).map((c) => c.concurrent)
  }, [data.concurrency_timeline])
  const max = Math.max(1, ...concurrencyBars)

  const sourceData = Object.entries(data.source_distribution)

  return (
    <MetricCard title="Session Lifecycle" isEmpty={sessions.length === 0} emptyMessage="No session data">
      <Box sx={{ display: 'flex', alignItems: 'baseline', gap: 1.5 }}>
        <Typography
          variant="headlineSmall"
          data-testid="lifecycle-avg-duration"
          sx={{ fontWeight: 600 }}
        >
          {formatDuration(avgDuration)}
        </Typography>
        <Typography variant="caption" color="text.secondary">
          Avg duration ({sessions.length} sessions)
        </Typography>
      </Box>

      {sessions.length > 0 && (
        <Box sx={{ display: 'flex', alignItems: 'baseline', gap: 1, mt: 1.5 }}>
          <Typography variant="caption" color="text.secondary">
            Peak concurrent:
          </Typography>
          <Typography
            variant="titleMedium"
            data-testid="lifecycle-peak-concurrent"
            sx={{ fontWeight: 600 }}
          >
            {peakConcurrent}
          </Typography>
        </Box>
      )}

      {concurrencyBars.length > 0 && (
        <Box
          data-testid="lifecycle-concurrency-bars"
          sx={{ display: 'flex', alignItems: 'flex-end', gap: 0.5, height: 36, mt: 1 }}
        >
          {concurrencyBars.map((c, i) => (
            <Box
              key={i}
              sx={{
                flex: 1,
                bgcolor: c > 0 ? 'info.main' : 'action.disabledBackground',
                opacity: c > 0 ? 0.85 : 0.3,
                borderRadius: 0.5,
                height: `${(c / max) * 100}%`,
                minHeight: 2,
              }}
            />
          ))}
        </Box>
      )}

      {sourceData.length > 0 && (
        <Stack direction="row" spacing={0.75} flexWrap="wrap" mt={1.5}>
          {sourceData.map(([src, count]) => (
            <Chip
              key={src}
              size="small"
              label={`${src}: ${count}`}
              variant="outlined"
              sx={{ height: 20, fontSize: '0.6875rem' }}
            />
          ))}
        </Stack>
      )}
    </MetricCard>
  )
}

const SessionLifecycle = memo(SessionLifecycleInner)
export default SessionLifecycle
