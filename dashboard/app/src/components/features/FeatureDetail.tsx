import { useState, lazy, Suspense } from 'react'
import Alert from '@mui/material/Alert'
import Box from '@mui/material/Box'
import Divider from '@mui/material/Divider'
import Skeleton from '@mui/material/Skeleton'
import Stack from '@mui/material/Stack'
import Typography from '@mui/material/Typography'
import StatusPill from '../wf/StatusPill'
import DetailHeader from '../wf/DetailHeader'
import DetailSidebar from '../wf/DetailSidebar'
import { SessionControls } from '../SessionControls'
import { sessionStatusToWfStatus } from '../../utils/featureStatusMapping'
import { featureToPhases } from '../../utils/featureToPhases'
import type { AutopilotSession, Feature, SessionStatus } from '../../types'
import { relativeTime } from '../../utils/time'
import { useFeatureArtifacts } from '../../hooks/useFeatureArtifacts'
import { useFeaturePlanTask } from '../../hooks/useFeaturePlanTask'
import { useSessionActivity } from '../../hooks/useSessionActivity'
import SessionPanel from '../SessionPanel'

const ArtifactDialog = lazy(() => import('../autopilot/ArtifactDialog'))

interface FeatureDetailProps {
  feature: Feature
  autopilotSession: AutopilotSession | null
  onClose: () => void
}

/* FeatureDetail renders the canonical detail-screen chrome
   (DetailHeader + DetailSidebar) shared with SessionPanel so the
   active-feature and paused-feature surfaces are visually identical
   per design_handoff_watchfloor_v2/specs/screens.md §3. The chrome
   is the same; only the main content varies — autopilot features
   delegate to SessionPanel for stream/log narrative, while
   non-autopilot features show stuck-alert + recent activity +
   sessions in their main column. */

export default function FeatureDetail({ feature, autopilotSession, onClose }: FeatureDetailProps) {
  const { data: artifacts } = useFeatureArtifacts(feature.name, feature.project_root)
  const isLive = feature.status === 'active' || feature.status === 'stuck'
  const { events: activityEvents } = useSessionActivity(feature.name, isLive)
  const [artifactFile, setArtifactFile] = useState<string | null>(null)
  const [artifactUrl, setArtifactUrl] = useState<string | null>(null)
  /* Audit-22 #3 - resolve the plan task directly from
     feature.plan_dir + feature.plan_task_id (set server-side by
     feature_helpers.py when discovery maps a feature folder to a
     plan task). Replaces the previous useTaskForAutopilot lookup,
     which scanned /api/plans and could match the wrong plan when
     several plans shared the same repo root. The Feature object
     already knows which plan owns it; the project-name heuristic
     was unnecessary indirection here. AutopilotView still uses
     useTaskForAutopilot because it lacks a Feature object. */
  const { task: matchedTask, plan: matchedPlan, planDir: matchedPlanDir } =
    useFeaturePlanTask(feature)

  if (feature.is_autopilot && autopilotSession) {
    return (
      <SessionPanel
        task={matchedTask}
        autopilotSession={autopilotSession}
        projectPath={feature.project_root}
        plan={matchedPlan}
        planDir={matchedPlanDir}
        onClose={onClose}
      />
    )
  }

  const resolvedArtifacts = artifacts ?? feature.artifacts
  const phases = featureToPhases(feature)

  const handleArtifactClick = (file: string) => {
    const url = `/api/feature/artifact?feature=${encodeURIComponent(feature.name)}&project_root=${encodeURIComponent(feature.project_root)}&file=${encodeURIComponent(file)}`
    setArtifactFile(file)
    setArtifactUrl(url)
  }

  return (
    <Box sx={{ display: 'flex', flexDirection: 'column', height: '100%', overflow: 'hidden' }}>
      <DetailHeader
        title={feature.name}
        subtitle={
          matchedTask?.name && matchedTask.name !== feature.name
            ? matchedTask.name
            : undefined
        }
        isLive={isLive}
        onClose={onClose}
        projectName={feature.project}
      />

      {/* controls-02 #1 — operator action row. Branch B (no live
          autopilotSession) was previously START-less; standalone
          features could only be launched from the Pipeline tab. Mount
          SessionControls here with targetId=feature.name so START is
          reachable from every operator surface that lists a feature.
          autopilotMode is undefined for standalone features → label
          falls back to bare "Start autopilot" per controls-01 #6.
          onAttach is a no-op because Branch B has no inline terminal
          view; once a session is live the parent flips us to Branch A
          where SessionPanel owns the terminal toggle. */}
      <Box
        data-testid="feature-detail-controls-row"
        sx={{
          px: 2,
          py: 1,
          borderBottom: '1px solid',
          borderColor: 'wf.steel',
        }}
      >
        <SessionControls
          targetKind="autopilot"
          targetId={feature.name}
          onAttach={() => {}}
          hideStateChip
          /* controls-04 #3c — compact overflow treatment converges
             with the Plans-tab plan header and SessionPanel detail
             surface. Pause/Cancel live inside the overflow Menu
             (Attach is currently a no-op in Branch B per the comment
             above, but the verb is still rendered for consistency). */
          density="header"
        />
      </Box>

      <Box
        sx={{
          flex: 1,
          display: 'flex',
          flexDirection: { xs: 'column', md: 'row' },
          overflow: 'hidden',
        }}
      >
        <DetailSidebar
          phases={phases}
          artifacts={resolvedArtifacts}
          onArtifactClick={handleArtifactClick}
        />

        <Box
          data-testid="feature-detail-main"
          sx={{ flex: 1, overflowY: 'auto', p: 2, minWidth: 0 }}
        >
          {feature.stuck_info && (
            <Alert severity="error" data-testid="stuck-alert" sx={{ mb: 2, borderRadius: 1 }}>
              {feature.stuck_info.reason === 'attractor_loop' ? (
                <>
                  <strong>Agent is looping:</strong> repeating {feature.stuck_info.tool} on {feature.stuck_info.file}
                  <br />
                  Check the session — it may need manual intervention.
                </>
              ) : (
                <>
                  <strong>Agent is stuck on permission prompts.</strong>
                  <br />
                  Check the session — it may need approval.
                </>
              )}
            </Alert>
          )}

          <Typography variant="wfLabel" color="text.secondary" sx={{ mb: 1 }}>
            Recent Activity
          </Typography>
          {activityEvents.length > 0 ? (
            <Stack spacing={0.25} sx={{ mb: 2, maxHeight: 200, overflowY: 'auto' }}>
              {activityEvents.slice(0, 10).map((evt, idx) => (
                <Box
                  key={`${evt.ts}-${idx}`}
                  data-testid="activity-event"
                  sx={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 1,
                    py: 0.25,
                    px: 0.5,
                    fontSize: '0.7rem',
                  }}
                >
                  <Typography variant="wfLabel" sx={{ fontFamily: 'monospace', fontWeight: 500, flexShrink: 0 }}>
                    {evt.tool}
                  </Typography>
                  <Typography variant="wfLabel" color="text.secondary" sx={{ flex: 1, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                    {evt.summary}
                  </Typography>
                  <Typography variant="wfLabel" color="text.secondary" sx={{ flexShrink: 0 }}>
                    {relativeTime(evt.ts)}
                  </Typography>
                </Box>
              ))}
            </Stack>
          ) : (
            <Typography variant="wfLabel" color="text.secondary" sx={{ mb: 2 }}>
              {isLive ? 'Waiting for activity...' : 'No recent activity'}
            </Typography>
          )}

          <Divider sx={{ my: 1.5 }} />

          <Typography variant="wfLabel" color="text.secondary" sx={{ mb: 1 }}>
            Sessions ({feature.sessions.length})
          </Typography>
          {feature.sessions.length > 0 ? (
            <Stack spacing={0.5} sx={{ maxHeight: 240, overflowY: 'auto' }}>
              {feature.sessions.map((s) => (
                <Box
                  key={s.sid}
                  data-testid="session-entry"
                  sx={{
                    display: 'flex',
                    alignItems: 'center',
                    gap: 1,
                    py: 0.5,
                    px: 1,
                    borderRadius: 0.5,
                    bgcolor: 'surface1',
                  }}
                >
                  <Typography variant="wfLabel" sx={{ fontFamily: 'monospace', fontWeight: 500 }}>
                    {s.sid.slice(0, 7)}
                  </Typography>
                  <StatusPill status={sessionStatusToWfStatus(s.status as SessionStatus)} label={s.status} />
                  <Typography variant="wfLabel" color="text.secondary" sx={{ ml: 'auto' }}>
                    {relativeTime(s.last_ts)}
                  </Typography>
                </Box>
              ))}
            </Stack>
          ) : (
            <Typography variant="wfLabel" color="text.secondary">
              No active sessions
            </Typography>
          )}
        </Box>
      </Box>

      {artifactUrl && (
        <Suspense fallback={<Skeleton variant="rectangular" height={200} />}>
          <ArtifactDialog
            url={artifactUrl}
            title={artifactFile ?? ''}
            onClose={() => {
              setArtifactUrl(null)
              setArtifactFile(null)
            }}
          />
        </Suspense>
      )}
    </Box>
  )
}
