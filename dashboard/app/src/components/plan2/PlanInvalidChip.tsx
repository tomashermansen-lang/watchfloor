import { useState } from 'react'
import Box from '@mui/material/Box'
import Chip from '@mui/material/Chip'
import Popover from '@mui/material/Popover'
import Tooltip from '@mui/material/Tooltip'
import Typography from '@mui/material/Typography'
import WarningAmberIcon from '@mui/icons-material/WarningAmber'
import { pv, pva } from '../../utils/cssVars'
import type { PlanValidity } from '../../utils/planValidity'

interface PlanInvalidChipProps {
  validity: PlanValidity
}

export default function PlanInvalidChip({ validity }: Readonly<PlanInvalidChipProps>) {
  const [anchor, setAnchor] = useState<HTMLElement | null>(null)
  if (validity.valid) return null

  const count = validity.totalCount
  const tooltipSummary = `${count} validity error${count === 1 ? '' : 's'} — click for details`

  return (
    <>
      <Tooltip title={tooltipSummary}>
        <Chip
          icon={<WarningAmberIcon />}
          label="Plan invalid"
          color="warning"
          variant="outlined"
          size="small"
          aria-label={`Plan invalid: ${count} errors`}
          onClick={(e) => setAnchor(e.currentTarget)}
          onKeyDown={(e) => {
            if (e.key === 'Enter' || e.key === ' ') {
              e.preventDefault()
              setAnchor(e.currentTarget as HTMLElement)
            }
          }}
          sx={{
            bgcolor: pva('warning-main', 0.14),
            color: pv('warning-main'),
            cursor: 'pointer',
          }}
        />
      </Tooltip>
      <Popover
        open={Boolean(anchor)}
        anchorEl={anchor}
        onClose={() => setAnchor(null)}
        anchorOrigin={{ vertical: 'bottom', horizontal: 'left' }}
      >
        <Box sx={{ p: 2, maxWidth: 360 }}>
          <Typography variant="titleSmall" component="h4" sx={{ mb: 1 }}>
            {count} validity error{count === 1 ? '' : 's'}
          </Typography>
          <Box component="ul" role="list" sx={{ m: 0, pl: 2.5 }}>
            {validity.errors.map((err) => (
              <Typography component="li" key={err} variant="body2" sx={{ mb: 0.25 }}>
                {err}
              </Typography>
            ))}
          </Box>
        </Box>
      </Popover>
    </>
  )
}
