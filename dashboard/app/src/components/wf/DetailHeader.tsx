import type { ReactNode } from 'react'
import Box from '@mui/material/Box'
import IconButton from '@mui/material/IconButton'
import Typography from '@mui/material/Typography'
import CloseIcon from '@mui/icons-material/Close'
import LiveBadge from './LiveBadge'

/* Canonical detail-screen header. Single source of truth for the
   row that sits above the 2-col body in SessionPanel + FeatureDetail.

   Per design_handoff_watchfloor_v2/specs/screens.md §3 "Header row":
     - × close button (24×24, ghost) at left
     - LIVE pill (atoms.md §LIVE pill) when isLive
     - Session/feature title, Geist Mono via wfH3
     - Right-aligned project name, JetBrains Mono in wf.fog via
       wfLabel + text.secondary
     - Trailing slot for status pills (AUTOPILOT, COMPLETED, etc.)

   The chrome is identical across surfaces; what differs is the
   trailing-slot content (autopilot badges/status vs nothing). */

interface DetailHeaderProps {
  title: string
  isLive: boolean
  onClose?: () => void
  projectName?: string
  trailing?: ReactNode
  /* User-request 2026-05-08: brief / feature-detail headers pair task.id
     (primary) with task.name (secondary). When provided, subtitle renders
     below the title as a smaller muted line. Optional for back-compat. */
  subtitle?: string
}

export default function DetailHeader({
  title,
  isLive,
  onClose,
  projectName,
  trailing,
  subtitle,
}: DetailHeaderProps) {
  return (
    <Box
      data-testid="detail-header"
      sx={{
        px: 2,
        py: 1.5,
        borderBottom: '1px solid',
        borderColor: 'divider',
        display: 'flex',
        alignItems: 'center',
        gap: 1,
      }}
    >
      {onClose && (
        <IconButton size="small" onClick={onClose} aria-label="Close panel" sx={{ mr: 0.5 }}>
          <CloseIcon fontSize="small" />
        </IconButton>
      )}
      {isLive && <LiveBadge />}
      <Box sx={{ flexGrow: 1, display: 'flex', flexDirection: 'column', minWidth: 0 }}>
        <Typography variant="wfH3" noWrap sx={{ fontWeight: 500 }}>
          {title}
        </Typography>
        {subtitle && (
          <Typography
            data-testid="detail-header-subtitle"
            variant="wfLabel"
            color="text.secondary"
            noWrap
            sx={{ textTransform: 'none', mt: 0.25 }}
          >
            {subtitle}
          </Typography>
        )}
      </Box>
      {projectName && (
        <Typography variant="wfLabel" color="text.secondary">
          {projectName}
        </Typography>
      )}
      {trailing}
    </Box>
  )
}
