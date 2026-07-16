import { Box, Typography } from '@mui/material'
import { memo, useMemo } from 'react'
import { Area, AreaChart } from 'recharts'
import type { ToolUsageMetrics } from '../../types'
import MetricCard from './MetricCard'

interface ToolUsageProps {
  data: ToolUsageMetrics
  selectedSid: string | 'all'
}

/**
 * ToolUsage — horizontal bar list with inline sparkline per tool.
 *
 * Polished version (commit 7c). Drops the previous Recharts BarChart in
 * favor of a manual list so each row can carry tool name + filled bar +
 * count + mini sparkline together. Matches the reference screenshot's
 * dense-but-glanceable look.
 *
 * Sparklines per tool are fabricated from the count via a sensible ramp
 * until commit 7d wires real per-tool time-series from
 * metrics_helpers.py. Visual is correct; numbers behind the sparklines
 * are placeholders — operator can already see relative volume.
 */
function ToolUsageInner({ data, selectedSid }: ToolUsageProps) {
  const rows = useMemo(() => {
    return Object.entries(data.by_tool)
      .sort(([, a], [, b]) => b - a)
      .map(([tool, count]) => ({ tool, count }))
  }, [data.by_tool])

  const max = rows[0]?.count ?? 1
  const rate = selectedSid !== 'all' ? data.by_session[selectedSid]?.rate : undefined

  return (
    <MetricCard
      title="Tool Usage"
      isEmpty={data.total === 0}
      emptyMessage="No tool usage data available"
    >
      <Box data-testid="tool-usage-list" sx={{ display: 'flex', flexDirection: 'column', gap: 0.75 }}>
        {rows.map(({ tool, count }) => (
          <ToolRow key={tool} tool={tool} count={count} maxCount={max} />
        ))}
      </Box>
      <Box sx={{ display: 'flex', justifyContent: 'space-between', mt: 1.5, color: 'text.secondary' }}>
        <Typography variant="wfLabel">Most used: {data.most_used || '—'}</Typography>
        {rate !== undefined && <Typography variant="wfLabel">{rate} calls/min</Typography>}
      </Box>
    </MetricCard>
  )
}

function ToolRow({ tool, count, maxCount }: Readonly<{ tool: string; count: number; maxCount: number }>) {
  const pct = maxCount > 0 ? (count / maxCount) * 100 : 0
  // Fabricated 8-point ramp; commit 7d replaces with real series.
  const sparkData = useMemo(() => {
    const len = 8
    const arr: { i: number; v: number }[] = []
    for (let i = 0; i < len; i += 1) arr.push({ i, v: count * ((i + 1) / len) })
    return arr
  }, [count])

  return (
    <Box
      data-testid="tool-usage-row"
      data-count={count}
      sx={{ display: 'flex', alignItems: 'center', gap: 1.5, fontSize: '0.8125rem' }}
    >
      <Typography variant="wfCode" sx={{ minWidth: 80, color: 'text.primary' }}>
        {tool}
      </Typography>
      <Box sx={{ flex: 1, position: 'relative', height: 14, bgcolor: 'wf.steel' }}>
        <Box
          sx={{
            position: 'absolute', left: 0, top: 0, bottom: 0,
            width: `${pct}%`,
            bgcolor: 'wf.signal',
            boxShadow: '0 0 6px rgba(59, 158, 255, 0.6)',
          }}
        />
      </Box>
      <Typography variant="wfCode" sx={{ minWidth: 40, textAlign: 'right', color: 'text.secondary', fontVariantNumeric: 'tabular-nums' }}>
        {count}
      </Typography>
      <Box sx={{ width: 56, height: 18, color: 'wf.signal' }}>
        <AreaChart width={56} height={18} data={sparkData} margin={{ top: 1, right: 0, bottom: 0, left: 0 }}>
          <defs>
            <linearGradient id={`spark-tool-${tool}`} x1="0" y1="0" x2="0" y2="1">
              <stop offset="0%" stopColor="currentColor" stopOpacity={0.4} />
              <stop offset="100%" stopColor="currentColor" stopOpacity={0} />
            </linearGradient>
          </defs>
          <Area
            type="monotone"
            dataKey="v"
            stroke="currentColor"
            strokeWidth={1.25}
            fill={`url(#spark-tool-${tool})`}
            isAnimationActive={false}
          />
        </AreaChart>
      </Box>
    </Box>
  )
}

const ToolUsage = memo(ToolUsageInner)
export default ToolUsage
