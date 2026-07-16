import { useMemo, useState } from 'react'
import Alert from '@mui/material/Alert'
import Box from '@mui/material/Box'
import Card from '@mui/material/Card'
import CardContent from '@mui/material/CardContent'
import ToggleChip from '../wf/ToggleChip'
import Stack from '@mui/material/Stack'
import Typography from '@mui/material/Typography'
import useMediaQuery from '@mui/material/useMediaQuery'
import { useTheme } from '@mui/material/styles'
import { DataGrid } from '@mui/x-data-grid'
import type { GridColDef, GridRenderCellParams } from '@mui/x-data-grid'
import IconButton from '@mui/material/IconButton'
import LaunchIcon from '@mui/icons-material/Launch'
import { isPlan2 } from '../../utils/planVersion'
import {
  DEFERRED_KIND_COLUMNS,
  DEFERRED_KIND_LABELS,
  STATE_FILTER_VALUES,
} from './deferredColumns'
import type {
  DeferredEntry,
  Plan,
  Task,
} from '../../types'

interface DeferredAuditViewProps {
  plan: Plan | null | undefined
  onSelectTask?: (task: Task) => void
}

const KINDS: DeferredEntry['kind'][] = [
  'code_finding',
  'review_suggestion',
  'scope_decision',
  'future_enhancement',
]

function defaultSortValue(entry: DeferredEntry): string {
  if (entry.kind === 'code_finding') return entry.reviewed_at ?? ''
  return (entry as { date?: string }).date ?? ''
}

function deferredSortComparator(a: DeferredEntry, b: DeferredEntry): number {
  const av = defaultSortValue(a)
  const bv = defaultSortValue(b)
  const cmp = bv.localeCompare(av)
  if (cmp !== 0) return cmp
  return a.id.localeCompare(b.id)
}

function buildDependentTaskMap(plan: Plan): Map<string, Task> {
  const m = new Map<string, Task>()
  for (const phase of plan.phases) {
    for (const task of phase.tasks) {
      for (const ref of task.deferred_refs ?? []) {
        m.set(ref, task)
      }
    }
  }
  return m
}

interface OpenTaskButtonProps {
  dependentTaskMap: Map<string, Task>
  deferredId: string
  onSelectTask?: (task: Task) => void
}

function OpenTaskButton({ dependentTaskMap, deferredId, onSelectTask }: Readonly<OpenTaskButtonProps>) {
  const task = dependentTaskMap.get(deferredId)
  if (!task) return null
  const handleClick = () => onSelectTask?.(task)
  return (
    <IconButton
      size="small"
      aria-label={`Open task ${task.id}`}
      onClick={handleClick}
    >
      <LaunchIcon fontSize="small" />
    </IconButton>
  )
}

/** Top-3 fields per kind for mobile card view */
const KIND_CARD_FIELDS: Record<DeferredEntry['kind'], string[]> = {
  code_finding: ['id', 'file', 'state'],
  review_suggestion: ['id', 'description', 'category'],
  scope_decision: ['id', 'decision', 'rationale'],
  future_enhancement: ['id', 'description', 'target_release'],
}

function MobileCardList({
  entries,
  activeKind,
  dependentTaskMap,
  onSelectTask,
}: Readonly<{
  entries: DeferredEntry[]
  activeKind: DeferredEntry['kind']
  dependentTaskMap: Map<string, Task>
  onSelectTask?: (task: Task) => void
}>) {
  const fields = KIND_CARD_FIELDS[activeKind]
  return (
    <Stack spacing={1}>
      {entries.map((entry) => (
        <Card key={entry.id} variant="outlined">
          <CardContent sx={{ p: 1.5, '&:last-child': { pb: 1.5 } }}>
            {fields.map((f) => {
              const val = (entry as unknown as Record<string, unknown>)[f]
              if (val === undefined || val === null) return null
              return (
                <Box key={String(f)} sx={{ display: 'flex', gap: 0.5, mb: 0.25 }}>
                  <Typography variant="caption" color="text.secondary" sx={{ flexShrink: 0, fontWeight: 600 }}>
                    {String(f)}:
                  </Typography>
                  <Typography variant="caption" noWrap>{String(val)}</Typography>
                </Box>
              )
            })}
            <OpenTaskButton
              dependentTaskMap={dependentTaskMap}
              deferredId={entry.id}
              onSelectTask={onSelectTask}
            />
          </CardContent>
        </Card>
      ))}
    </Stack>
  )
}

export default function DeferredAuditView({ plan, onSelectTask }: Readonly<DeferredAuditViewProps>) {
  const theme = useTheme()
  const isMobile = useMediaQuery(theme.breakpoints.down('sm'))
  const [activeKind, setActiveKind] = useState<DeferredEntry['kind']>('code_finding')
  const [stateFilters, setStateFilters] = useState<Set<string>>(new Set())
  const [ownerFilter, setOwnerFilter] = useState<string | null>(null)

  const isV2 = plan ? isPlan2(plan) : false
  const allEntries = useMemo(() => (plan?.deferred ?? []), [plan])

  const dependentTaskMap = useMemo(
    () => (plan ? buildDependentTaskMap(plan) : new Map<string, Task>()),
    [plan],
  )

  const owners = useMemo(() => {
    const result = new Set<string>()
    for (const entry of allEntries) {
      if (entry.kind === 'code_finding' && entry.owner) result.add(entry.owner)
      if (entry.kind === 'review_suggestion' && entry.reviewer) result.add(entry.reviewer)
    }
    return Array.from(result).sort((a, b) => a.localeCompare(b))
  }, [allEntries])

  const visibleEntries = useMemo(() => {
    return allEntries
      .filter((e) => e.kind === activeKind)
      .filter((e) => {
        if (stateFilters.size === 0) return true
        if (e.kind !== 'code_finding') return true
        return stateFilters.has(e.state)
      })
      .filter((e) => {
        if (!ownerFilter) return true
        if (e.kind === 'code_finding') return e.owner === ownerFilter
        if (e.kind === 'review_suggestion') return e.reviewer === ownerFilter
        return true
      })
      .slice()
      .sort(deferredSortComparator)
  }, [allEntries, activeKind, stateFilters, ownerFilter])

  const columns = useMemo<GridColDef[]>(() => {
    const renderOpenTask = (params: GridRenderCellParams) => (
      <OpenTaskButton
        dependentTaskMap={dependentTaskMap}
        deferredId={String(params.row.id)}
        onSelectTask={onSelectTask}
      />
    )
    return DEFERRED_KIND_COLUMNS[activeKind].map((col) =>
      col.field === 'openTask' ? { ...col, renderCell: renderOpenTask } : col,
    )
  }, [activeKind, dependentTaskMap, onSelectTask])

  if (!plan || !isV2) {
    return (
      <Box sx={{ p: 3 }}>
        <Alert severity="info">
          Deferred Audit is only available for schema 2.0 plans.
        </Alert>
      </Box>
    )
  }

  if (allEntries.length === 0) {
    return (
      <Box sx={{ p: 3 }}>
        <Alert severity="info">No deferred entries.</Alert>
      </Box>
    )
  }

  const noRowsForFilters = visibleEntries.length === 0

  return (
    <Box sx={{ p: 3 }}>
      {/* Kind filter chips — brand toggle vocabulary (replaces Tabs per R12). */}
      <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap sx={{ mb: 2 }}>
        {KINDS.map((k) => (
          <ToggleChip
            key={k}
            label={DEFERRED_KIND_LABELS[k]}
            active={activeKind === k}
            onClick={() => setActiveKind(k)}
          />
        ))}
      </Stack>

      <Stack direction="row" spacing={1} flexWrap="wrap" useFlexGap sx={{ mb: 2 }}>
        {STATE_FILTER_VALUES.map((s) => {
          const active = stateFilters.has(s)
          const stateChipsDisabled = activeKind !== 'code_finding'
          return (
            <ToggleChip
              key={s}
              label={s}
              active={active}
              disabled={stateChipsDisabled}
              onClick={() => {
                setStateFilters((prev) => {
                  const next = new Set(prev)
                  if (active) next.delete(s)
                  else next.add(s)
                  return next
                })
              }}
            />
          )
        })}
        {owners.map((o) => (
          <ToggleChip
            key={o}
            label={o}
            active={ownerFilter === o}
            onClick={() => setOwnerFilter((prev) => (prev === o ? null : o))}
          />
        ))}
      </Stack>

      {noRowsForFilters ? (
        <Alert severity="info">No entries match the current filters</Alert>
      ) : isMobile ? (
        <MobileCardList
          entries={visibleEntries}
          activeKind={activeKind}
          dependentTaskMap={dependentTaskMap}
          onSelectTask={onSelectTask}
        />
      ) : (
        <Box
          sx={{
            border: '1px solid',
            borderColor: 'wf.steel',
            bgcolor: 'wf.carbon',
          }}
        >
          {/* Brand panel header — handoff §UI Primitives "TABLE" specimen
              (ui-primitives.jsx L562): mono uppercase 0.16em label in wf.fog,
              right-aligned count. Replaces the bottom caption. */}
          <Box
            sx={{
              display: 'flex',
              alignItems: 'center',
              justifyContent: 'space-between',
              px: 2,
              py: 1,
              borderBottom: '1px solid',
              borderColor: 'wf.steel',
            }}
          >
            <Typography variant="wfLabel" color="text.secondary">
              Deferred entries
            </Typography>
            <Typography variant="wfLabel" color="text.secondary">
              {visibleEntries.length} {visibleEntries.length === 1 ? 'entry' : 'entries'}
            </Typography>
          </Box>
          <Box sx={{ height: 480, width: '100%' }}>
            <DataGrid
              rows={visibleEntries}
              columns={columns}
              getRowId={(row) => row.id}
              disableRowSelectionOnClick
              density="compact"
              initialState={{ pagination: { paginationModel: { pageSize: 25 } } }}
              pageSizeOptions={[25, 50, 100]}
              sx={{
                /* Brand-aligned data grid — handoff §UI Primitives "TABLE ROW".
                   Sharp corners, panel border supplied by the wrapper, mono
                   typography throughout. Headers: 9px JBM uppercase 0.16em,
                   wf.fog. Cells: 11px JBM, wf.bone. Hairlines: wf.steel. */
                border: 0,
                borderRadius: 0,
                fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
                fontSize: '11px',
                color: 'wf.bone',
                '--DataGrid-rowBorderColor': 'var(--mui-palette-wf-steel)',
                '--DataGrid-containerBackground': 'transparent',
                '& .MuiDataGrid-columnHeaders': {
                  borderBottom: '1px solid',
                  borderColor: 'wf.steel',
                  bgcolor: 'transparent',
                },
                '& .MuiDataGrid-columnHeader:focus, & .MuiDataGrid-columnHeader:focus-within': {
                  outline: 'none',
                },
                '& .MuiDataGrid-columnHeaderTitle': {
                  fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
                  fontSize: '9px',
                  fontWeight: 500,
                  letterSpacing: '0.16em',
                  textTransform: 'uppercase',
                  color: 'wf.fog',
                },
                '& .MuiDataGrid-cell': {
                  borderBottom: '1px solid',
                  borderColor: 'wf.steel',
                },
                '& .MuiDataGrid-cell:focus, & .MuiDataGrid-cell:focus-within': {
                  outline: 'none',
                },
                '& .MuiDataGrid-row:hover': {
                  bgcolor: 'rgba(255, 255, 255, 0.03)',
                },
                '& .MuiDataGrid-footerContainer': {
                  borderTop: '1px solid',
                  borderColor: 'wf.steel',
                  minHeight: 36,
                },
                '& .MuiTablePagination-root, & .MuiTablePagination-selectLabel, & .MuiTablePagination-displayedRows': {
                  fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
                  fontSize: '10px',
                  color: 'wf.fog',
                },
                '& .MuiDataGrid-overlay': {
                  bgcolor: 'transparent',
                  color: 'wf.fog',
                },
              }}
            />
          </Box>
        </Box>
      )}
    </Box>
  )
}
