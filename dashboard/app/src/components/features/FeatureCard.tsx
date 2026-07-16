import Box from '@mui/material/Box'
import Paper from '@mui/material/Paper'
import Typography from '@mui/material/Typography'
import type { Feature } from '../../types'
import StatusPill from '../wf/StatusPill'
import ExecutionModeIcon from '../wf/ExecutionModeIcon'
import ProgressBar from '../wf/ProgressBar'
import { featureToWfStatus } from '../../utils/featureStatusMapping'
import { relativeTime } from '../../utils/time'
import { usePlans } from '../../hooks/usePlans'

const PHASE_LABELS: Record<string, string> = {
  started: 'Started',
  ba: 'BA',
  design: 'Design',
  plan: 'Plan',
  'team-review': 'T-Rev',
  review: 'Review',
  implement: 'Impl',
  'static-analysis': 'SA',
  manualtest: 'Test',
  'team-qa': 'T-QA',
  qa: 'QA',
  commit: 'Commit',
  done: 'Done',
  unknown: '?',
}

/* feature-plan-link-and-nav (REQ-11) — single shared signature for the
   plan-navigation callback. Threaded through FeatureCard → FeatureList
   → FeaturesView → DashboardShell; only DashboardShell provides a real
   implementation. Exported here because FeatureCard is the deepest
   consumer (no circular imports). */
export type OnNavigateToPlan = (planDir: string) => void

const NAV_NOOP: OnNavigateToPlan = () => {}

interface FeatureCardProps {
  feature: Feature
  selected: boolean
  onSelect: () => void
  /* feature-plan-link-and-nav (REQ-6) — optional with a no-op default
     so existing call sites (FE-3..FE-7 and the predecessor sidebar
     usages) keep compiling and passing without modification. */
  onNavigateToPlan?: OnNavigateToPlan
}

export default function FeatureCard({
  feature,
  selected,
  onSelect,
  onNavigateToPlan = NAV_NOOP,
}: Readonly<FeatureCardProps>) {
  /* Midpoint heuristic per audit-11 — (phase_index + 0.5) / total.
     Strict completed/total leaves the bar at 0% during phase 0
     (no visual feedback that work has started). The +0.5 offset
     reads as "halfway through the current phase", giving a visible
     sliver at phase 0 (~5%) that grows monotonically. Last-phase
     active still reads < 100% (e.g. 7/8 → 94%) so the bar
     distinguishes "in progress on final phase" from "done". */
  const completedRatio =
    feature.status === 'done' || feature.phase_index >= feature.total_phases
      ? 1
      : (feature.phase_index + 0.5) / feature.total_phases
  const phaseLabel = PHASE_LABELS[feature.phase] ?? feature.phase
  /* Audit-21 #1 — phase-chip and status-chip both render "DONE" on
     archived features (phase='done', status='done'); the DONE section
     header + the canonical green status-chip already convey lifecycle.
     Drop the muted phase-chip when its label collides with the status
     so the row stops shouting DONE twice. The orthogonal case
     (phase='done', status='paused') keeps both chips. */
  const phaseChipRedundant = phaseLabel.toLowerCase() === feature.status.toLowerCase()

  /* feature-plan-link-and-nav (REQ-1, REQ-2, REQ-3) — chip renders only
     when both fields are non-empty strings. Label resolves against
     `usePlans()` on `plan_dir` equality with a `plan_task_id` fallback
     covering loading (`data === undefined`), empty (`[]`), and
     unmatched-lookup states (REQ-2 / EC-1 / EC-2). */
  const { data: plans } = usePlans()
  const showPlanLink = Boolean(feature.plan_dir && feature.plan_task_id)
  const planEntry = showPlanLink
    ? plans?.find((p) => p.plan_dir === feature.plan_dir)
    : undefined
  const planLinkLabel = planEntry?.project ?? feature.plan_task_id

  return (
    <Paper
      role="option"
      aria-selected={selected}
      aria-label={`${feature.name} — ${feature.project} — ${feature.status}`}
      tabIndex={selected ? 0 : -1}
      onClick={onSelect}
      onKeyDown={(e) => {
        if (e.key === 'Enter' || e.key === ' ') {
          e.preventDefault()
          onSelect()
        }
      }}
      elevation={0}
      data-testid="feature-card"
      sx={{
        p: 1.5,
        cursor: 'pointer',
        border: '1px solid',
        borderColor: selected ? 'primary.main' : 'divider',
        bgcolor: selected ? 'surface1' : 'transparent',
        '&:hover': {
          borderColor: 'primary.light',
          transition: 'var(--motion-short4) var(--motion-emphasized)',
        },
      }}
    >
      <Box sx={{ display: 'flex', justifyContent: 'space-between', alignItems: 'flex-start', mb: 0.5 }}>
        <Box sx={{ display: 'flex', flexDirection: 'column', minWidth: 0 }}>
          <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.5 }}>
            <Typography variant="wfH3" noWrap sx={{ fontWeight: 500 }}>
              {feature.name}
            </Typography>
            {/* Execution mode — full / light / manual icons match
                SessionPanel + Pipeline so operators read the same
                signifier in every surface. */}
            <ExecutionModeIcon
              mode={feature.is_autopilot ? feature.pipeline_type : 'manual'}
            />
          </Box>
          {/* User-request 2026-05-08: long human-readable task name
              renders as a muted subtitle when the linked plan task's
              name differs from feature.name (server already filters
              the equal-string case in _apply_plan_link, but the
              defensive guard below keeps stale cached payloads from
              shouting the same string twice). */}
          {feature.plan_task_name && feature.plan_task_name !== feature.name && (
            <Typography
              data-testid="feature-card-subtitle"
              variant="wfLabel"
              color="text.secondary"
              noWrap
              sx={{ textTransform: 'none', mt: 0.25 }}
            >
              {feature.plan_task_name}
            </Typography>
          )}
        </Box>
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
          {/* feature-plan-link-and-nav (REQ-1, REQ-4, REQ-5, REQ-13) —
              plan-link chip is leftmost in the cluster (visually closest
              to the feature name). Native <button> via
              `Box component="button"` so screen readers announce it.
              Both onClick and onKeyDown call stopPropagation so the
              parent Paper's selection handlers stay silent (EC-5/EC-6).
              The keyboard handler also calls preventDefault on Space
              (page scroll suppression) and on both keys (suppresses the
              native button's default activation so the callback fires
              exactly once per activation, EC-14). */}
          {showPlanLink && (
            <Box
              component="button"
              type="button"
              data-testid="plan-link-chip"
              onClick={(e) => {
                e.stopPropagation()
                onNavigateToPlan(feature.plan_dir as string)
              }}
              onKeyDown={(e) => {
                if (e.key === 'Enter' || e.key === ' ') {
                  e.preventDefault()
                  e.stopPropagation()
                  onNavigateToPlan(feature.plan_dir as string)
                }
              }}
              sx={{
                cursor: 'pointer',
                border: 'none',
                background: 'transparent',
                p: 0,
                color: 'wf.fog',
                display: 'inline-flex',
                alignItems: 'center',
                '&:hover': { color: 'wf.bone' },
                '&:focus-visible': {
                  outline: '1px solid',
                  outlineColor: 'wf.bone',
                },
              }}
            >
              <Typography variant="wfLabel">{planLinkLabel}</Typography>
            </Box>
          )}
          {!phaseChipRedundant && (
            <Box component="span" data-testid="phase-chip" sx={{ display: 'inline-flex' }}>
              <StatusPill status={null} label={phaseLabel} />
            </Box>
          )}
          <Box component="span" data-testid="status-chip" sx={{ display: 'inline-flex' }}>
            <StatusPill status={featureToWfStatus(feature.status)} label={feature.status} />
          </Box>
        </Box>
      </Box>

      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1, mb: 0.5 }}>
        <Typography variant="wfLabel" color="text.secondary" sx={{ flexShrink: 0 }}>
          {feature.project}
        </Typography>
        <Box sx={{ flex: 1 }}>
          <ProgressBar value={completedRatio} />
        </Box>
      </Box>

      <Box sx={{ display: 'flex', justifyContent: 'space-between' }}>
        <Typography variant="wfLabel" color="text.secondary">
          {feature.last_activity ? relativeTime(feature.last_activity) : 'no activity'}
        </Typography>
        {feature.sessions.length > 1 && (
          <Typography variant="wfLabel" color="text.secondary">
            {feature.sessions.length} sessions
          </Typography>
        )}
      </Box>
    </Paper>
  )
}
