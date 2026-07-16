import { useCallback, useMemo } from 'react'
import Box from '@mui/material/Box'
import Chip from '@mui/material/Chip'
import Paper from '@mui/material/Paper'
import Stack from '@mui/material/Stack'
import Tooltip from '@mui/material/Tooltip'
import Typography from '@mui/material/Typography'
import { pv, pva } from '../../utils/cssVars'
import { isPlan2 } from '../../utils/planVersion'
import { PREFERS_REDUCED_MOTION } from '../../utils/motion'
import type { Plan, SuccessCriterion } from '../../types'

interface ProjectHeaderProps {
  plan: Plan
}

const CRITERION_LABEL_MAX = 60

function truncate(text: string, max: number): string {
  if (text.length <= max) return text
  return `${text.slice(0, max - 1)}…`
}

function CriterionChip({ criterion }: Readonly<{ criterion: SuccessCriterion }>) {
  const label = truncate(criterion.description, CRITERION_LABEL_MAX)
  const tooltipText = label === criterion.description ? '' : criterion.description
  const isInteractive = Boolean(criterion.verified_at_phase)

  const handleActivate = useCallback(() => {
    if (!criterion.verified_at_phase) return
    const target = document.getElementById(`phase-${criterion.verified_at_phase}`)
    if (!target) return
    const reducedMotion = globalThis.matchMedia?.(PREFERS_REDUCED_MOTION).matches ?? false
    target.scrollIntoView({ behavior: reducedMotion ? 'auto' : 'smooth' })
    if (typeof target.focus === 'function') {
      target.focus({ preventScroll: true })
    }
  }, [criterion.verified_at_phase])

  const chipProps = isInteractive
    ? {
        clickable: true,
        onClick: handleActivate,
        onKeyDown: (e: React.KeyboardEvent) => {
          if (e.key === 'Enter' || e.key === ' ') {
            e.preventDefault()
            handleActivate()
          }
        },
      }
    : {}

  const chip = (
    <Chip
      data-criterion-id={criterion.id}
      label={label}
      size="small"
      variant="outlined"
      sx={{
        bgcolor: pva('primary-main', 0.14),
        color: pv('primary-main'),
        fontWeight: 500,
      }}
      {...chipProps}
    />
  )

  return (
    <Stack direction="row" spacing={0.5} alignItems="center">
      {tooltipText ? <Tooltip title={tooltipText}>{chip}</Tooltip> : chip}
      {criterion.measurable_via && (
        <Chip
          label={criterion.measurable_via}
          size="small"
          variant="outlined"
          sx={{
            fontSize: '0.65rem',
            height: 20,
            bgcolor: pva('secondary-main', 0.1),
            color: pv('secondary-main'),
          }}
        />
      )}
    </Stack>
  )
}

export default function ProjectHeader({ plan }: Readonly<ProjectHeaderProps>) {
  const isV2 = useMemo(() => isPlan2(plan), [plan])
  if (!isV2) return null

  const showVision = plan.vision && plan.vision.length > 0
  const successCriteria = plan.success_criteria ?? []
  const techStack = plan.tech_stack ?? []

  if (!showVision && successCriteria.length === 0 && techStack.length === 0) {
    return null
  }

  return (
    <Paper
      elevation={0}
      data-testid="project-header"
      sx={{
        border: '1px solid',
        borderColor: pv('outlineVariant'),
        borderRadius: 1,
        p: { xs: 2, md: 3 },
        bgcolor: pv('surface1'),
      }}
    >
      {showVision && (
        <Box sx={{ mb: 2 }}>
          <Typography variant="labelMedium" color="text.secondary" component="h3" sx={{ mb: 0.5 }}>
            Vision
          </Typography>
          <Typography variant="body1" component="p">
            {plan.vision}
          </Typography>
        </Box>
      )}

      {successCriteria.length > 0 && (
        <Box sx={{ mb: 2 }}>
          <Typography variant="labelMedium" color="text.secondary" component="h3" sx={{ mb: 0.75 }}>
            Success criteria
          </Typography>
          <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap data-testid="success-criteria-row">
            {successCriteria.map((c) => (
              <CriterionChip key={c.id} criterion={c} />
            ))}
          </Stack>
        </Box>
      )}

      {techStack.length > 0 && (
        <Box>
          <Typography variant="labelMedium" color="text.secondary" component="h3" sx={{ mb: 0.75 }}>
            Tech stack
          </Typography>
          <Stack direction="row" spacing={0.5} flexWrap="wrap" useFlexGap data-testid="tech-stack-row">
            {techStack.map((t) => (
              <Chip key={t} label={t} size="small" variant="outlined" />
            ))}
          </Stack>
        </Box>
      )}
    </Paper>
  )
}
