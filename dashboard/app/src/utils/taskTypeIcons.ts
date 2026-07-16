import type { ComponentType } from 'react'
import type { SvgIconProps } from '@mui/material'
import BuildIcon from '@mui/icons-material/Build'
import DescriptionOutlinedIcon from '@mui/icons-material/DescriptionOutlined'
import SearchIcon from '@mui/icons-material/Search'
import SettingsIcon from '@mui/icons-material/Settings'
import RateReviewIcon from '@mui/icons-material/RateReview'
import AutoFixHighIcon from '@mui/icons-material/AutoFixHigh'
import ScienceIcon from '@mui/icons-material/Science'
import MoreHorizIcon from '@mui/icons-material/MoreHoriz'

import type { TaskType } from '../types'

export const TASK_TYPE_ICONS: Readonly<Record<TaskType, ComponentType<SvgIconProps>>> = {
  development: BuildIcon,
  documentation: DescriptionOutlinedIcon,
  research: SearchIcon,
  setup: SettingsIcon,
  review: RateReviewIcon,
  refactor: AutoFixHighIcon,
  testing: ScienceIcon,
  other: MoreHorizIcon,
}

export const TASK_TYPE_LABEL: Readonly<Record<TaskType, string>> = {
  development: 'Development',
  documentation: 'Documentation',
  research: 'Research',
  setup: 'Setup',
  review: 'Review',
  refactor: 'Refactor',
  testing: 'Testing',
  other: 'Other',
}

export function taskTypeIcon(taskType: string | undefined): ComponentType<SvgIconProps> {
  if (!taskType) return BuildIcon
  return (TASK_TYPE_ICONS as Record<string, ComponentType<SvgIconProps>>)[taskType] ?? BuildIcon
}

export function taskTypeLabel(taskType: string | undefined): string {
  if (!taskType) return 'Development'
  return (TASK_TYPE_LABEL as Record<string, string>)[taskType] ?? taskType
}
