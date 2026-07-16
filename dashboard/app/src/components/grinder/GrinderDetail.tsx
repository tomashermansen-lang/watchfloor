import { useEffect, useState } from 'react'
import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import IconButton from '@mui/material/IconButton'
import Button from '@mui/material/Button'
import Skeleton from '@mui/material/Skeleton'
import Link from '@mui/material/Link'
import ArrowBackIcon from '@mui/icons-material/ArrowBack'
import RefreshIcon from '@mui/icons-material/Refresh'
import { useGrinderDetail, usePauseGrinder } from '../../hooks/useGrinder'
import { useGrinderStream } from '../../hooks/useGrinderStream'
import GrinderPassStepper from './GrinderPassStepper'
import GrinderBatchCard from './GrinderBatchCard'
import GrinderEventsList from './GrinderEventsList'
import GrinderDeferralsTable from './GrinderDeferralsTable'
import GrinderBatchView from './GrinderBatchView'

interface GrinderDetailProps {
  project: string
  paused: boolean
  onBack: () => void
}

export default function GrinderDetail({ project, paused, onBack }: GrinderDetailProps) {
  const { data, isLoading, mutate } = useGrinderDetail(project)
  const { pause, resume, isLoading: pauseLoading } = usePauseGrinder()
  const [streamBatchId, setStreamBatchId] = useState<string | null>(null)

  /* Auto-open the stream pane when the current batch changes (mount
     with a running batch, or a new batch starts mid-poll), and
     auto-close when the running batch ends. Dep is the id, so the
     effect only re-fires on a real transition — a user who clicked
     the breadcrumb to close the pane is not re-opened on the next
     poll while the same batch is still running.

     react-hooks/set-state-in-effect is suppressed: the alternative
     ("mirror external state via render-time setState + prev-state
     tracking") is explicitly forbidden by REQ-7 (no render-time
     setStreamBatchId). The dep array contract (REQ-6 / REQ-8) also
     requires this effect to fire only on a real id transition, which
     the key-reset pattern would not satisfy without losing
     user-initiated close behaviour. */
  useEffect(() => {
    const currentId = data?.current_batch?.id ?? null
    // eslint-disable-next-line react-hooks/set-state-in-effect
    setStreamBatchId(currentId)
  }, [data?.current_batch?.id])

  const { events: streamEvents, hasStream } = useGrinderStream(
    streamBatchId ? project : null,
    streamBatchId ?? undefined,
  )

  const hasActiveBatch = data?.current_batch != null
  const isPauseDisabled = !hasActiveBatch && !paused

  if (isLoading || !data) {
    return (
      <Box sx={{ p: 2 }}>
        <Skeleton variant="rectangular" height={40} sx={{ mb: 1.5, borderRadius: 1 }} />
        <Skeleton variant="rectangular" height={120} sx={{ borderRadius: 1 }} />
      </Box>
    )
  }

  // Stream view — two-pane with breadcrumb
  if (streamBatchId) {
    const batch = data.current_batch?.id === streamBatchId ? data.current_batch : null

    return (
      <Box sx={{ p: 2, display: 'flex', flexDirection: 'column', gap: 2, flex: 1, minHeight: 0 }}>
        {/* Breadcrumb */}
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
          <Link
            component="button"
            variant="body2"
            underline="hover"
            onClick={() => setStreamBatchId(null)}
            sx={{ cursor: 'pointer' }}
          >
            ← Grinder / {project}
          </Link>
          <Typography variant="body2" color="text.secondary">
            / batch {streamBatchId}
          </Typography>
        </Box>

        <GrinderBatchView
          batchId={streamBatchId}
          batch={batch}
          events={streamEvents}
          hasStream={hasStream}
        />
      </Box>
    )
  }

  // Normal detail view
  return (
    <Box sx={{ p: 2, display: 'flex', flexDirection: 'column', gap: 2 }}>
      {/* Header */}
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 1 }}>
        <IconButton onClick={onBack} aria-label="Back" size="small">
          <ArrowBackIcon fontSize="small" />
        </IconButton>
        <Typography variant="titleMedium">
          Grinder / {project}
        </Typography>
        <Box sx={{ flexGrow: 1 }} />
        <IconButton onClick={() => mutate()} aria-label="Refresh" size="small">
          <RefreshIcon fontSize="small" />
        </IconButton>
        <Button
          variant="outlined"
          size="small"
          disabled={isPauseDisabled || pauseLoading}
          onClick={() => paused ? resume(project) : pause(project)}
          aria-label={paused ? 'Resume grinder' : 'Pause grinder'}
        >
          {paused ? 'Resume grinder' : 'Pause grinder'}
        </Button>
      </Box>

      {/* Passes */}
      <GrinderPassStepper passes={data.passes} />

      {/* Current batch */}
      <GrinderBatchCard batch={data.current_batch} onOpenStream={setStreamBatchId} />

      {/* Events */}
      <GrinderEventsList events={data.recent_events} onOpenStream={setStreamBatchId} />

      {/* Deferrals */}
      <GrinderDeferralsTable deferrals={data.top_deferrals} />
    </Box>
  )
}
