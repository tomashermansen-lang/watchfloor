import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import Chip from '@mui/material/Chip'
import LinearProgress from '@mui/material/LinearProgress'
import { useFeatures } from '../hooks/useFeatures'
import type { Feature } from '../types'

interface FeatureTabViewProps {
  featureKey: string  // 'project/name' encoding
}

/**
 * FeatureTabView — per-feature tab content.
 *
 * Commit 5 MVP: shows a feature header (name + project + status +
 * progress) and a sessions list scoped to this feature. Future
 * expansion (commit 6+) wires per-feature pipeline DAG, plan view,
 * and artifact links.
 */
export default function FeatureTabView({ featureKey }: Readonly<FeatureTabViewProps>) {
  const { data: features } = useFeatures()
  const feature = (features ?? []).find((f) => `${f.project}/${f.name}` === featureKey)

  if (!feature) {
    return (
      <Box sx={{ p: 3, color: 'text.secondary' }} data-testid="feature-tab-header">
        Feature not found: <strong>{featureKey}</strong>
      </Box>
    )
  }

  const progress = feature.total_phases > 0
    ? Math.round((feature.phase_index / feature.total_phases) * 100)
    : 0

  return (
    <Box sx={{ p: 3, display: 'flex', flexDirection: 'column', gap: 3 }}>
      {/* Header */}
      <Box
        data-testid="feature-tab-header"
        sx={{
          p: 2,
          border: '1px solid',
          borderColor: 'divider',
          borderLeft: '3px solid',
          borderLeftColor: statusBorderColor(feature.status),
          borderRadius: 1,
          bgcolor: 'surface1',
        }}
      >
        <Box sx={{ display: 'flex', alignItems: 'baseline', gap: 1.5 }}>
          <Typography variant="wfH2" sx={{ fontWeight: 600 }}>
            {feature.name}
          </Typography>
          <Chip
            label={feature.status}
            size="small"
            sx={{ height: 20, fontSize: '0.6875rem', bgcolor: statusBg(feature.status) }}
          />
          <Typography variant="caption" color="text.secondary">
            project · <Box component="span" sx={{ color: 'text.primary' }}>{feature.project}</Box>
          </Typography>
          <Typography variant="caption" color="text.secondary">
            pipeline · {feature.pipeline_type}
          </Typography>
        </Box>
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mt: 1.5 }}>
          <Typography variant="caption" color="text.secondary" sx={{ minWidth: 50 }}>
            phase
          </Typography>
          <LinearProgress variant="determinate" value={progress} sx={{ flex: 1, height: 5, borderRadius: 1 }} />
          <Typography variant="caption" color="text.secondary" sx={{ minWidth: 50, textAlign: 'right', fontVariantNumeric: 'tabular-nums' }}>
            {feature.phase_index}/{feature.total_phases}
          </Typography>
        </Box>
      </Box>

      {/* Sessions list */}
      <Box sx={{ border: '1px solid', borderColor: 'divider', borderRadius: 1, overflow: 'hidden' }}>
        <Typography
          variant="wfLabel"
          sx={{
            px: 2, py: 1, bgcolor: 'surface1', display: 'block',
            textTransform: 'uppercase', letterSpacing: 0.5,
          }}
        >
          Sessions ({feature.sessions.length})
        </Typography>
        {feature.sessions.length === 0 ? (
          <Box sx={{ p: 3, color: 'text.secondary', textAlign: 'center' }}>
            No active sessions on this feature.
          </Box>
        ) : (
          <Box>
            {feature.sessions.map((s) => (
              <Box
                key={s.sid}
                sx={{
                  display: 'flex', alignItems: 'center', gap: 1.5,
                  px: 2, py: 1,
                  borderTop: '1px solid', borderColor: 'divider',
                  fontSize: '0.8125rem',
                }}
              >
                <Box sx={{ width: 8, height: 8, borderRadius: '50%', bgcolor: 'info.main' }} />
                <Typography variant="wfBody" sx={{ fontFamily: 'monospace', color: 'text.secondary' }}>
                  {s.sid.slice(0, 8)}
                </Typography>
                <Box sx={{ flex: 1 }}>{s.status}</Box>
                <Typography variant="caption" color="text.secondary">
                  {s.last_ts}
                </Typography>
              </Box>
            ))}
          </Box>
        )}
      </Box>
    </Box>
  )
}

function statusBorderColor(status: Feature['status']): string {
  switch (status) {
    case 'active': return 'info.main'
    case 'waiting': return 'warning.main'
    case 'stuck': return 'error.main'
    case 'paused': return 'text.disabled'
    case 'done': return 'success.main'
    default: return 'divider'
  }
}

function statusBg(status: Feature['status']): string {
  switch (status) {
    case 'active': return 'rgba(33, 150, 243, 0.15)'
    case 'waiting': return 'rgba(255, 167, 38, 0.15)'
    case 'stuck': return 'rgba(244, 67, 54, 0.15)'
    case 'paused': return 'rgba(158, 158, 158, 0.15)'
    case 'done': return 'rgba(76, 175, 80, 0.15)'
    default: return 'transparent'
  }
}
