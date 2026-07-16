import { Box, Card, Typography } from '@mui/material'
import { memo, useId } from 'react'

interface MetricCardProps {
  title: string
  isEmpty: boolean
  emptyMessage: string
  children: React.ReactNode
}

/**
 * Watchfloor instrument-panel chrome for the eight metrics surfaces
 * (handoff §1 Overview "Feature portfolio"): wf.carbon body, wf.steel
 * border (sharp corners come from the global Card theme override), top
 * header strip carrying the panel title in wfLabel typography (JBM
 * uppercase 0.16em / wf.fog) separated from the body by a wf.steel
 * hairline. Replacing the legacy MUI CardHeader keeps every metrics
 * card consistent with the OverviewView portfolio bar and the
 * DeferredAuditView panel header.
 */
function MetricCardInner({ title, isEmpty, emptyMessage, children }: MetricCardProps) {
  const titleId = useId()
  return (
    <Card
      role="region"
      aria-labelledby={titleId}
      sx={{ bgcolor: 'wf.carbon', borderColor: 'wf.steel' }}
    >
      <Box
        sx={{
          px: 2,
          py: 1,
          borderBottom: '1px solid',
          borderColor: 'wf.steel',
        }}
      >
        <Typography
          id={titleId}
          variant="wfLabel"
          color="text.secondary"
          sx={{ display: 'block' }}
        >
          {title}
        </Typography>
      </Box>
      <Box sx={{ p: 2 }}>
        {isEmpty ? (
          <Typography variant="wfBody" color="text.secondary" sx={{ textAlign: 'center', py: 2 }}>
            {emptyMessage}
          </Typography>
        ) : (
          children
        )}
      </Box>
    </Card>
  )
}

const MetricCard = memo(MetricCardInner)
export default MetricCard
