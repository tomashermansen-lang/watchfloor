import { Box, Stack, Typography } from '@mui/material'
import { memo, useMemo } from 'react'
import type { SubagentUtilizationMetrics } from '../../types'
import MetricCard from './MetricCard'
import SubagentRadar from '../wf/SubagentRadar'

interface SubagentUtilProps {
  data: SubagentUtilizationMetrics
}

/* Decreasing opacity ramp must mirror SubagentRadar's WEDGE_OPACITIES
   so the legend swatch reads exactly like the wedge it labels. Kept
   inline (not exported from SubagentRadar) because the radar is the
   data source for the visual treatment — duplicating six numbers is
   cheaper than a public API for an implementation detail. */
const LEGEND_OPACITIES = [0.85, 0.65, 0.5, 0.38, 0.28, 0.2] as const

function SubagentUtilInner({ data }: SubagentUtilProps) {
  const typeData = useMemo(
    () =>
      Object.entries(data.by_type)
        .sort(([, a], [, b]) => b - a)
        .map(([name, value]) => ({ name, value })),
    [data.by_type],
  )

  const avgDuration = useMemo(
    () =>
      data.durations.length > 0
        ? data.durations.reduce((sum, d) => sum + d.duration_s, 0) / data.durations.length
        : 0,
    [data.durations],
  )

  const isRunning = data.running.length > 0

  return (
    <MetricCard
      title="Subagent Utilization"
      isEmpty={data.total_spawned === 0}
      emptyMessage="No subagent activity"
    >
      <Box sx={{ display: 'flex', gap: 3, alignItems: 'flex-start' }}>
        {/* Left column: KPI stats stack */}
        <Box sx={{ display: 'flex', flexDirection: 'column', gap: 2, minWidth: 140 }}>
          <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5 }}>
            <Typography variant="wfLabel" color="text.secondary">
              Spawned
            </Typography>
            <Typography variant="wfDisplay" sx={{ color: 'wf.bone', fontFeatureSettings: '"tnum" 1' }}>
              {data.total_spawned}
            </Typography>
          </Box>
          <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5 }}>
            <Typography variant="wfLabel" color="text.secondary">
              Peak concurrent
            </Typography>
            <Typography variant="wfH2" sx={{ color: 'wf.bone', fontFeatureSettings: '"tnum" 1' }}>
              {data.peak_concurrent}
            </Typography>
          </Box>
          {avgDuration > 0 && (
            <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5 }}>
              <Typography variant="wfLabel" color="text.secondary">
                Avg duration
              </Typography>
              <Typography variant="wfH2" sx={{ color: 'wf.bone', fontFeatureSettings: '"tnum" 1' }}>
                {Math.round(avgDuration)}s
              </Typography>
            </Box>
          )}
        </Box>

        {/* Right column: brand radar with wedges per agent type */}
        {typeData.length > 0 && (
          <Box sx={{ flex: 1, display: 'flex', justifyContent: 'center' }}>
            <SubagentRadar size={200} data={typeData} sweep={isRunning} />
          </Box>
        )}
      </Box>

      {/* Legend — single row of name + value pairs, JBM mono, swatch
          opacity matches the wedge fill so they read as the same
          datum from two angles. */}
      {typeData.length > 0 && (
        <Stack
          direction="row"
          spacing={2}
          flexWrap="wrap"
          useFlexGap
          sx={{
            mt: 2,
            pt: 1.5,
            borderTop: '1px solid',
            borderColor: 'wf.steel',
          }}
        >
          {typeData.map((d, i) => {
            const opacity = LEGEND_OPACITIES[i % LEGEND_OPACITIES.length]
            return (
              <Box
                key={d.name}
                sx={{ display: 'flex', alignItems: 'center', gap: 0.75 }}
              >
                <Box
                  sx={{
                    width: 10,
                    height: 10,
                    bgcolor: 'wf.signal',
                    opacity,
                  }}
                />
                <Typography variant="wfCode" sx={{ color: 'wf.bone' }}>
                  {d.name}
                </Typography>
                <Typography variant="wfCode" sx={{ color: 'wf.fog' }}>
                  {d.value}
                </Typography>
              </Box>
            )
          })}
        </Stack>
      )}

      {isRunning && (
        <Typography variant="wfBody" sx={{ color: 'status.stalled', mt: 1.5 }}>
          {data.running.length} subagent(s) still running
        </Typography>
      )}
    </MetricCard>
  )
}

const SubagentUtil = memo(SubagentUtilInner)
export default SubagentUtil
