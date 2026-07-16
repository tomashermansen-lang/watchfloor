import type { GridColDef } from '@mui/x-data-grid'
import type { DeferredEntry } from '../../types'

export const STATE_FILTER_VALUES = ['WontFix', 'FalsePositive', 'Deferred', 'Accepted'] as const

export const openTaskColumn: GridColDef = {
  field: 'openTask',
  headerName: 'Task',
  sortable: false,
  filterable: false,
  width: 80,
}

const codeFindingColumns: GridColDef[] = [
  { field: 'id', headerName: 'ID', width: 110 },
  { field: 'kind', headerName: 'Kind', width: 110 },
  { field: 'finding_id', headerName: 'Finding', width: 150 },
  { field: 'rule', headerName: 'Rule', width: 130 },
  { field: 'file', headerName: 'File', flex: 1, minWidth: 180 },
  { field: 'line', headerName: 'Line', width: 70 },
  { field: 'state', headerName: 'State', width: 110 },
  { field: 'owner', headerName: 'Owner', width: 110 },
  { field: 'reviewed_at', headerName: 'Reviewed', width: 130 },
  { field: 'review_trigger', headerName: 'Trigger', width: 150 },
  openTaskColumn,
]

const reviewSuggestionColumns: GridColDef[] = [
  { field: 'id', headerName: 'ID', width: 110 },
  { field: 'kind', headerName: 'Kind', width: 130 },
  { field: 'date', headerName: 'Date', width: 110 },
  { field: 'feature_or_task_id', headerName: 'Feature/Task', width: 160 },
  { field: 'phase_id', headerName: 'Phase', width: 110 },
  { field: 'reviewer', headerName: 'Reviewer', width: 110 },
  { field: 'category', headerName: 'Category', width: 130 },
  { field: 'description', headerName: 'Description', flex: 1, minWidth: 200 },
  { field: 'reason_deferred', headerName: 'Reason', flex: 1, minWidth: 180 },
  openTaskColumn,
]

const scopeDecisionColumns: GridColDef[] = [
  { field: 'id', headerName: 'ID', width: 110 },
  { field: 'kind', headerName: 'Kind', width: 130 },
  { field: 'date', headerName: 'Date', width: 110 },
  { field: 'decided_at_task_id', headerName: 'Decided at task', width: 170 },
  { field: 'decision', headerName: 'Decision', width: 150 },
  { field: 'rationale', headerName: 'Rationale', flex: 1, minWidth: 220 },
  openTaskColumn,
]

const futureEnhancementColumns: GridColDef[] = [
  { field: 'id', headerName: 'ID', width: 110 },
  { field: 'kind', headerName: 'Kind', width: 150 },
  { field: 'date', headerName: 'Date', width: 110 },
  { field: 'description', headerName: 'Description', flex: 1, minWidth: 220 },
  { field: 'target_release', headerName: 'Target release', width: 150 },
  { field: 'effort_estimate', headerName: 'Effort', width: 110 },
  openTaskColumn,
]

export const DEFERRED_KIND_COLUMNS: Readonly<Record<DeferredEntry['kind'], GridColDef[]>> = {
  code_finding: codeFindingColumns,
  review_suggestion: reviewSuggestionColumns,
  scope_decision: scopeDecisionColumns,
  future_enhancement: futureEnhancementColumns,
}

export const DEFERRED_KIND_LABELS: Readonly<Record<DeferredEntry['kind'], string>> = {
  code_finding: 'Code findings',
  review_suggestion: 'Review suggestions',
  scope_decision: 'Scope decisions',
  future_enhancement: 'Future enhancements',
}
