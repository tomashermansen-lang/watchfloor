import { useMemo, useState } from 'react'
import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import Skeleton from '@mui/material/Skeleton'
import StatusPill from './wf/StatusPill'
import PlanCompletionBand from './wf/PlanCompletionBand'
import Pipeline from './Pipeline'
import { SessionControls } from './SessionControls'
import { TerminalPanel } from './TerminalPanel'
import DeferredAuditView from './plan2/DeferredAuditView'
import { usePlan } from '../hooks/usePlan'
import { usePlans } from '../hooks/usePlans'
import { useSessions } from '../hooks/useSessions'
import { useFeatures } from '../hooks/useFeatures'
import { classifyPlan, statusPillProps } from '../utils/planLifecycle'
import { flattenTasks, computeProgressPct } from '../utils/planMetrics'
import { planDirToChainId } from '../utils/chainId'
import type { Plan, ProjectSummary } from '../types'

interface ProjectSubviewTabProps {
  projectId: string
  subview: 'vision' | 'pipeline' | 'deferred' | 'deviations'
}

/**
 * ProjectSubviewTab — renders the right content for a project sub-view
 * tab. The four sub-views surface different slices of the same plan
 * YAML — Vision (strategic metadata), Pipeline (DAG), Deferred Audit
 * (project.deferred[]), Deviations (phase_results, post backlog #30).
 */
export default function ProjectSubviewTab({ projectId, subview }: Readonly<ProjectSubviewTabProps>) {
  const { data: projects, isLoading: projectsLoading } = usePlans()
  const project = (projects ?? []).find((p) => p.project === projectId)
  const planDir = project?.plan_dir ?? project?.path ?? null
  const { data: plan, isLoading: planLoading } = usePlan(planDir)
  const { data: sessions } = useSessions()

  if (projectsLoading || planLoading) {
    return (
      <Box sx={{ p: 3 }}>
        <Skeleton variant="rectangular" height={120} sx={{ mb: 2 }} />
        <Skeleton variant="rectangular" height={300} />
      </Box>
    )
  }

  if (!project || !plan) {
    return (
      <Box sx={{ p: 3, color: 'text.secondary' }}>
        Project plan not found: <strong>{projectId}</strong>
      </Box>
    )
  }

  const projectName = project.project ?? projectId
  const projectSessions = (sessions ?? []).filter((s) => {
    return typeof s.cwd === 'string' && project.path && s.cwd.startsWith(project.path)
  })

  switch (subview) {
    case 'vision':
      return <VisionPane projectId={projectId} projectName={projectName} plan={plan} />
    case 'pipeline':
      return (
        <Box data-testid="project-subview-pipeline" sx={{ height: '100%', display: 'flex', flexDirection: 'column' }}>
          <ProjectHeader projectName={projectName} subviewLabel="Pipeline" plan={plan} project={project} />
          <Box sx={{ flex: 1, minHeight: 0, overflow: 'auto' }}>
            <Pipeline plan={plan} sessions={projectSessions} />
          </Box>
        </Box>
      )
    case 'deferred':
      return <DeferredPane projectId={projectId} projectName={projectName} plan={plan} project={project} />
    case 'deviations':
      return <DeviationsPane projectId={projectId} projectName={projectName} plan={plan} project={project} />
  }
}

/* controls-06 #8 — per-project subview header. Mirrors the
   Plans-tab ProjectPanel layout: 6-track CSS grid with the plan
   title + StatusPill clustered in the leftmost 1fr track,
   SessionControls in their own column ahead of the progress band,
   and the row-counts / TASKS / percent cells aligned on the right.
   Same watchfloor precedent (screens.md:35 Feature portfolio
   grid). The `project` prop is optional only because some
   subviews historically rendered without it; when present, the
   header gains the StatusPill + SessionControls. */
function ProjectHeader({
  projectName,
  subviewLabel,
  plan,
  project,
}: Readonly<{
  projectName: string
  subviewLabel: string
  plan?: Plan
  project?: ProjectSummary
}>) {
  const { data: allFeatures } = useFeatures()
  const projectFeatures = useMemo(
    () => (allFeatures ?? []).filter((f) => f.project === projectName),
    [allFeatures, projectName],
  )
  /* controls-06 #14 — terminal opens by default on the Pipeline
     subview because this view IS the chain's "live output" destination
     (drill-down landing page). The operator arrived here by clicking
     Output on the Plans row OR navigated here directly — either way
     the live output is what they came to see. The detach affordance
     on TerminalPanel itself closes the panel and the operator can
     re-open via the row Output click (which navigates back here AND
     re-renders this component fresh, defaulting `isTerminalOpen=true`
     again). */
  const [isTerminalOpen, setIsTerminalOpen] = useState(true)

  const chainId = useMemo(
    () => planDirToChainId(project?.plan_dir ?? ''),
    [project?.plan_dir],
  )
  const showChainControls = project ? classifyPlan(project) !== 'done' : false

  const rowTasks = plan ? flattenTasks(plan) : []
  const rowTasksTotal = rowTasks.length
  const rowTasksDone = rowTasks.filter((t) => t.status === 'done').length
  const rowTasksPct = plan ? computeProgressPct(plan) : 0

  return (
    <>
      <Box
        data-testid="plan-header-row"
        sx={{
          px: 3, py: 1.5,
          borderBottom: '1px solid', borderColor: 'divider',
          alignItems: 'center', gap: 1.5,
        }}
        style={{
          display: 'grid',
          gridTemplateColumns:
            'minmax(0, 1fr) auto 240px 72px auto 56px',
        }}
      >
        <Box
          data-testid="plan-title-cluster"
          sx={{ display: 'flex', alignItems: 'center', gap: 1.5, minWidth: 0 }}
        >
          <Typography
            variant="wfH3"
            sx={{
              minWidth: 0,
              whiteSpace: 'nowrap',
              overflow: 'hidden',
              textOverflow: 'ellipsis',
            }}
          >
            {plan?.name ?? projectName}
          </Typography>
          <Typography variant="wfLabel" color="text.secondary">
            {subviewLabel}
          </Typography>
          {project && <StatusPill {...statusPillProps(project)} />}
        </Box>
        {project && showChainControls ? (
          <SessionControls
            targetKind="chain"
            targetId={chainId || null}
            attached={isTerminalOpen}
            onAttach={() => setIsTerminalOpen((prev) => !prev)}
            density="header"
            hideStateChip
            /* controls-06 #14 — terminal owns this subview; offering
               an Output button here would be a no-op self-link. The
               Output affordance lives on the Plans row (drill-down
               entry point) only. */
            hideOutputButton
          />
        ) : (
          <Box aria-hidden />
        )}
        {plan ? (
          <PlanCompletionBand plan={plan} features={projectFeatures} barOnly />
        ) : (
          <Box aria-hidden />
        )}
        <Typography
          data-testid="plan-row-counts"
          variant="wfLabel"
          color="text.secondary"
          sx={{ textAlign: 'right' }}
        >
          {rowTasksDone}/{rowTasksTotal}
        </Typography>
        <Typography
          data-testid="plan-row-label"
          variant="wfLabel"
          color="text.secondary"
        >
          TASKS
        </Typography>
        <Typography
          data-testid="plan-row-percent"
          variant="wfLabel"
          sx={{ color: 'wf.signal', textAlign: 'right' }}
        >
          {rowTasksPct}%
        </Typography>
      </Box>
      {project && showChainControls && isTerminalOpen && (
        /* controls-06 #14 — "Autochain live output" destination
           landing. A small heading bar identifies the view, then the
           TerminalPanel fills the remaining height. The cycle-13
           explicit height stays so TerminalPanel's
           `flex: 1, minHeight: 0` resolves to a real pixel value.
           560px ≈ 28 rows × 20px line-height — taller than the
           Plans-row mount (which is gone) since this view is
           dedicated to the live output. */
        <Box
          data-testid="terminal-panel-wrapper"
          sx={{ px: 3, py: 1.5, borderBottom: '1px solid', borderColor: 'divider' }}
          style={{
            display: 'flex',
            flexDirection: 'column',
            height: '560px',
          }}
        >
          <Box
            sx={{
              pb: 0.75, mb: 0.75,
              borderBottom: '1px solid', borderColor: 'wf.steel',
              display: 'flex', alignItems: 'center', gap: 1,
            }}
          >
            <Typography
              data-testid="autochain-live-output-heading"
              variant="wfLabel"
              sx={{ color: 'wf.signal' }}
            >
              Autochain live output
            </Typography>
            <Typography variant="wfLabel" color="text.secondary">
              · {projectName}
            </Typography>
          </Box>
          <TerminalPanel
            targetKind="chain"
            targetId={chainId || null}
            onDetach={() => setIsTerminalOpen(false)}
          />
        </Box>
      )}
    </>
  )
}

interface SubviewPaneProps {
  projectId: string
  projectName: string
  plan: import('../types').Plan
  project?: ProjectSummary
}

function VisionPane({ projectName, plan }: Readonly<SubviewPaneProps>) {
  const successCriteria = (plan as { success_criteria?: Array<{ id: string; description: string; verified_at_phase?: string; measurable_via?: string }> }).success_criteria ?? []
  const techStack = (plan as { tech_stack?: string[] }).tech_stack ?? []
  const scopeIn = (plan as { scope?: { in_scope?: string[] } }).scope?.in_scope ?? []
  const scopeOut = (plan as { scope?: { out_of_scope?: string[] } }).scope?.out_of_scope ?? []
  const visionText = (plan as { vision?: string }).vision

  return (
    <Box data-testid="project-subview-vision" sx={{ p: 3, display: 'flex', flexDirection: 'column', gap: 2.5 }}>
      <Box sx={{ display: 'flex', alignItems: 'baseline', gap: 1.5 }}>
        <Typography variant="wfH1">{projectName}</Typography>
        <Typography variant="wfLabel" color="text.secondary">
          Vision
        </Typography>
      </Box>

      {plan.description && (
        <Typography variant="wfBody" color="text.secondary">{plan.description}</Typography>
      )}

      {visionText && (
        <Box sx={{ borderLeft: '3px solid', borderLeftColor: 'wf.signal', pl: 2, py: 0.5 }}>
          <Typography variant="wfBody">{visionText}</Typography>
        </Box>
      )}

      {techStack.length > 0 && (
        <Section label="Tech stack">
          <Box sx={{ display: 'flex', flexWrap: 'wrap', gap: 0.75 }}>
            {techStack.map((t) => (
              <StatusPill key={t} status={null} label={t} />
            ))}
          </Box>
        </Section>
      )}

      {successCriteria.length > 0 && (
        <Section label={`Success criteria (${successCriteria.length})`}>
          <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.75 }}>
            {successCriteria.map((sc) => (
              <Box key={sc.id} sx={{ display: 'flex', gap: 1, alignItems: 'baseline' }}>
                <Typography variant="wfLabel" sx={{ color: 'text.disabled', minWidth: 36 }}>{sc.id}</Typography>
                <Typography variant="wfBody" sx={{ flex: 1 }}>{sc.description}</Typography>
                {sc.measurable_via && <StatusPill status={null} label={sc.measurable_via} />}
              </Box>
            ))}
          </Box>
        </Section>
      )}

      {(scopeIn.length > 0 || scopeOut.length > 0) && (
        <Section label="Scope">
          <Box sx={{ display: 'grid', gridTemplateColumns: '1fr 1fr', gap: 2 }}>
            <Box>
              <Typography variant="wfLabel" sx={{ color: 'text.disabled' }}>
                In scope
              </Typography>
              <Box component="ul" sx={{ pl: 2, my: 0.5 }}>
                {scopeIn.map((s, i) => <Box component="li" key={i}><Typography variant="wfBody">{s}</Typography></Box>)}
              </Box>
            </Box>
            <Box>
              <Typography variant="wfLabel" sx={{ color: 'text.disabled' }}>
                Out of scope
              </Typography>
              <Box component="ul" sx={{ pl: 2, my: 0.5 }}>
                {scopeOut.map((s, i) => <Box component="li" key={i}><Typography variant="wfBody">{s}</Typography></Box>)}
              </Box>
            </Box>
          </Box>
        </Section>
      )}
    </Box>
  )
}

function DeferredPane({ projectName, plan, project }: Readonly<SubviewPaneProps>) {
  /* Per-project Deferred Audit sub-tab — renders the same rich
     DeferredAuditView (kind tabs + state/owner toggle chips +
     DataGrid) the global Deferred view used to host. The global
     view was removed; the rich rendering now lives where it's
     actually scoped — under the project that owns the entries. */
  return (
    <Box data-testid="project-subview-deferred" sx={{ display: 'flex', flexDirection: 'column' }}>
      <ProjectHeader projectName={projectName} subviewLabel="Deferred Audit" plan={plan} project={project} />
      <DeferredAuditView plan={plan} />
    </Box>
  )
}

interface DeviationDetail {
  type?: string
  description?: string
  reason?: string
  impact?: string
  confidence?: number
  evidence?: string
  criteria_affected?: string[]
}

interface PhaseResult {
  phase: string
  timestamp?: string
  conformance: string
  acceptance_status?: string
  deviations?: DeviationDetail[]
}

function DeviationsPane({ projectName, plan, project }: Readonly<SubviewPaneProps>) {
  const tasks = plan.phases.flatMap((ph) => ph.tasks)
  const rows: Array<{ taskId: string; result: PhaseResult }> = []
  for (const t of tasks) {
    const results = (t as { phase_results?: PhaseResult[] }).phase_results
    if (results) {
      for (const r of results) rows.push({ taskId: t.id, result: r })
    }
  }
  return (
    <Box data-testid="project-subview-deviations" sx={{ p: 3, display: 'flex', flexDirection: 'column', gap: 2 }}>
      <ProjectHeader projectName={projectName} subviewLabel="Deviations" plan={plan} project={project} />
      {rows.length === 0 ? (
        <Typography variant="wfBody" color="text.secondary">
          No phase_results recorded yet. Once backlog #30 (deviation-tracker autopilot wrapper)
          lands, every phase will produce an audit entry visible here.
        </Typography>
      ) : (
        <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.75 }}>
          {rows.map((row, i) => (
            <DeviationRow key={i} taskId={row.taskId} result={row.result} />
          ))}
        </Box>
      )}
    </Box>
  )
}

function DeviationRow({ taskId, result }: Readonly<{ taskId: string; result: PhaseResult }>) {
  const devs = result.deviations ?? []
  return (
    <Box sx={{ border: '1px solid', borderColor: 'divider', display: 'flex', flexDirection: 'column' }}>
      {/* Summary row */}
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1.5, px: 1.5, py: 0.75 }}>
        <Typography variant="wfLabel" sx={{ minWidth: 120, color: 'text.secondary' }}>{taskId}</Typography>
        <StatusPill status={null} label={result.phase} />
        <Box sx={{ flex: 1 }} />
        <Typography
          variant="wfLabel"
          sx={{ color: result.conformance === 'aligned' ? 'wf.signal' : 'status.stalled' }}
        >
          {result.conformance}
        </Typography>
        {result.acceptance_status && (
          <Typography variant="wfLabel" color="text.secondary">{result.acceptance_status}</Typography>
        )}
      </Box>
      {/* Detail blocks — one per entry in deviations[]. Aligned rows skip this. */}
      {devs.length > 0 && (
        <Box sx={{ display: 'flex', flexDirection: 'column', gap: 0.5, px: 1.5, pb: 1, pt: 0.25 }}>
          {devs.map((d, j) => (
            <DeviationDetailBlock key={j} d={d} />
          ))}
        </Box>
      )}
    </Box>
  )
}

function DeviationDetailBlock({ d }: Readonly<{ d: DeviationDetail }>) {
  const conf = typeof d.confidence === 'number'
    ? `${Math.round(d.confidence * 100)}%`
    : null
  return (
    <Box
      data-testid="deviation-detail"
      sx={{
        display: 'flex', flexDirection: 'column', gap: 0.25,
        px: 1, py: 0.5,
        borderLeft: '2px solid', borderLeftColor: 'status.stalled',
        backgroundColor: 'background.default',
      }}
    >
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
        {d.type && <Typography variant="wfLabel" sx={{ color: 'wf.signal' }}>{d.type}</Typography>}
        {d.impact && <Typography variant="wfLabel" sx={{ color: 'text.secondary' }}>impact: {d.impact}</Typography>}
        <Box sx={{ flex: 1 }} />
        {conf && <Typography variant="wfLabel" sx={{ color: 'text.secondary' }}>{conf}</Typography>}
      </Box>
      {d.description && (
        <Typography variant="wfBody" sx={{ color: 'text.primary' }}>{d.description}</Typography>
      )}
      {d.reason && (
        <Typography variant="wfBody" sx={{ color: 'text.secondary' }}>
          <Box component="span" sx={{ color: 'text.disabled', mr: 0.5 }}>reason:</Box>
          {d.reason}
        </Typography>
      )}
      {d.evidence && (
        <Typography variant="wfBody" sx={{ color: 'text.secondary', fontFamily: 'monospace', fontSize: '0.8em' }}>
          <Box component="span" sx={{ color: 'text.disabled', mr: 0.5, fontFamily: 'inherit' }}>evidence:</Box>
          {d.evidence}
        </Typography>
      )}
      {d.criteria_affected && d.criteria_affected.length > 0 && (
        <Typography variant="wfLabel" sx={{ color: 'text.secondary' }}>
          affects: {d.criteria_affected.join(', ')}
        </Typography>
      )}
    </Box>
  )
}

function Section({ label, children }: Readonly<{ label: string; children: React.ReactNode }>) {
  return (
    <Box>
      <Typography
        variant="wfLabel"
        sx={{ color: 'text.disabled', display: 'block', mb: 0.75 }}
      >
        {label}
      </Typography>
      {children}
    </Box>
  )
}
