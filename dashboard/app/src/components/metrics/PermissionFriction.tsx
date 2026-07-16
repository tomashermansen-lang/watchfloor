import { Box, Typography } from '@mui/material'
import { memo, useMemo } from 'react'
import type { PermissionFrictionMetrics } from '../../types'
import MetricCard from './MetricCard'

interface PermissionFrictionProps {
  data: PermissionFrictionMetrics
  selectedSid: string | 'all'
}

/**
 * PermissionFriction — polished version (commit 7 footer panels).
 *
 * Drops the stacked bar chart and per-mode legend that crowded the
 * panel before. Reference shows a tight summary:
 *   - 'Prompts this hour' label + big count
 *   - Single annotation line that recommends action when prompts > 0
 *     or congratulates the operator when 0
 */
function PermissionFrictionInner({ data, selectedSid }: PermissionFrictionProps) {
  const total = selectedSid !== 'all'
    ? data.by_session[selectedSid]?.prompts ?? 0
    : data.total_prompts

  const dominant = useMemo(() => {
    const entries = Object.entries(data.by_tool)
    if (entries.length === 0) return null
    entries.sort(([, a], [, b]) => b - a)
    const [tool, count] = entries[0]
    return { tool, count }
  }, [data.by_tool])

  return (
    <MetricCard title="Permission Friction" isEmpty={false} emptyMessage="">
      <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5 }}>
        <Typography variant="wfLabel" color="text.secondary">
          Prompts this hour
        </Typography>
        <Typography
          variant="wfDisplay"
          data-testid="friction-prompts-count"
          sx={{
            color: total === 0 ? 'status.completed' : 'status.stalled',
            fontFeatureSettings: '"tnum" 1',
          }}
        >
          {total}
        </Typography>
      </Box>
      <Box sx={{ mt: 1.5 }}>
        {total === 0 ? (
          <Typography variant="wfBody" color="text.secondary">
            No permission prompts in the last hour. Autopilot has high trust across
            all active sessions.
          </Typography>
        ) : (
          <Typography variant="wfBody" color="text.secondary">
            Most friction in{' '}
            <Box component="span" sx={{ color: 'text.primary', fontWeight: 600 }}>
              {dominant?.tool ?? '—'}
            </Box>{' '}
            ({dominant?.count ?? 0} prompt{dominant?.count === 1 ? '' : 's'}). Consider
            granting it broader allowlist for these sessions.
          </Typography>
        )}
      </Box>
    </MetricCard>
  )
}

const PermissionFriction = memo(PermissionFrictionInner)
export default PermissionFriction
