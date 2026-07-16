import type { Theme } from '@mui/material/styles'
import type { TaskStatus } from '../types'

export interface StatusColorSet {
  status: string
  container: string
  onContainer: string
}

export function getStatusColors(status: TaskStatus, theme: Theme): StatusColorSet {
  return {
    status: theme.palette.status[status],
    container: theme.palette.statusContainer[status],
    onContainer: theme.palette.onStatusContainer[status],
  }
}
