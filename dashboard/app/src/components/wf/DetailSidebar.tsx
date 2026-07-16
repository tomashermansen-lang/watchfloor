import type { ReactNode } from 'react'
import Box from '@mui/material/Box'
import Stack from '@mui/material/Stack'
import Typography from '@mui/material/Typography'
import AppIcon from './AppIcon'
import ToggleChip from './ToggleChip'
import PhaseStepper from '../autopilot/PhaseStepper'
import type { AutopilotPhase, TaskEstimate } from '../../types'

/* Canonical 240px detail-screen sidebar — pairs with DetailHeader
   to form the shared chrome shell that SessionPanel + FeatureDetail
   both consume. Per design_handoff_watchfloor_v2/specs/screens.md §3
   "Phase rail" body column:

     - PhaseStepper full mode renders ✓ checkmark / running pulse /
       pending hollow ring per phase + name + duration/cost meta line
       + TOTAL footer
     - DOCUMENTS list renders each artifact as a ToggleChip with the
       brand 'document' AppIcon glyph (the converged pattern from
       commit b4fc013 — replaces the legacy StatusPill-as-button)
     - Optional `extras` slot below for surface-specific widgets
       (Session History toggle, gates, dependency lists). */

interface ArtifactEntry {
  name: string
  file: string
}

interface DetailSidebarProps {
  phases: AutopilotPhase[]
  artifacts?: ArtifactEntry[]
  onArtifactClick?: (file: string) => void
  /* Audit-18 #1 - mode-switcher slot rendered between PhaseStepper
     and Documents. Reserved for the TASK BRIEF toggle so the brief-
     vs-stream mode chip lives directly above where the user is told
     "Documents" (matches operator request to put the toggle "over
     documents"). */
  topActions?: ReactNode
  extras?: ReactNode
  /* Audit-23 #8 - forwarded straight to PhaseStepper so the TOTAL
     footer can render `est. Nh · X% under/over` when the surrounding
     screen has a plan-2.0 task with duration_hours set. */
  estimate?: TaskEstimate
}

export default function DetailSidebar({
  phases,
  artifacts,
  onArtifactClick,
  topActions,
  extras,
  estimate,
}: DetailSidebarProps) {
  const hasPhases = phases.length > 0
  const hasArtifacts = artifacts && artifacts.length > 0

  return (
    <Box
      data-testid="detail-sidebar"
      sx={{
        display: { xs: 'none', md: 'flex' },
        flexDirection: 'column',
        width: 240,
        flexShrink: 0,
        overflowY: 'auto',
        borderRight: '1px solid',
        borderColor: 'divider',
        py: 2,
        px: 1.5,
      }}
    >
      {hasPhases && <PhaseStepper phases={phases} mode="full" estimate={estimate} />}

      {topActions && (
        <Box
          sx={{
            mt: hasPhases ? 2 : 0,
            pt: hasPhases ? 2 : 0,
            borderTop: hasPhases ? '1px solid' : 'none',
            borderColor: 'divider',
          }}
        >
          {topActions}
        </Box>
      )}

      {hasArtifacts && (
        <Box
          sx={{
            mt: (hasPhases || topActions) ? 2 : 0,
            pt: (hasPhases || topActions) ? 2 : 0,
            borderTop: (hasPhases || topActions) ? '1px solid' : 'none',
            borderColor: 'divider',
          }}
        >
          <Typography variant="wfLabel" color="text.secondary" sx={{ mb: 0.5 }}>
            Documents
          </Typography>
          <Stack spacing={0.5} alignItems="flex-start">
            {artifacts.map((a) => (
              <Box
                key={a.file}
                data-testid="wf-doc-pill"
                sx={{ display: 'inline-flex' }}
              >
                <ToggleChip
                  label={a.name.replace('.md', '')}
                  active={false}
                  onClick={() => onArtifactClick?.(a.file)}
                  icon={<AppIcon type="document" size={12} />}
                />
              </Box>
            ))}
          </Stack>
        </Box>
      )}

      {extras}
    </Box>
  )
}
