import Box from '@mui/material/Box'
import Stack from '@mui/material/Stack'
import ToggleChip from './wf/ToggleChip'
import type { LifecycleChip, SortMode } from '../hooks/usePlanFilters'

/* PlansFilterBar — presentational filter rail above the Plans tab.
   Receives all state and setters via props (REQ-2, REQ-24). Holds no
   internal state. Multi-select toggles construct a fresh `Set` so
   React's `Object.is` change detection fires (REQ-31). */

const LIFECYCLE_CHIP_ORDER: readonly LifecycleChip[] = [
  'active',
  'open',
  'done',
  'pending',
]

const LIFECYCLE_CHIP_LABEL: Record<LifecycleChip, string> = {
  active: 'Active',
  open: 'Open',
  done: 'Done',
  pending: 'Pending',
}

const SORT_CHIP_ORDER: readonly SortMode[] = [
  'group-then-progress-desc',
  'name-asc',
  'last-activity-desc',
]

const SORT_CHIP_LABEL: Record<SortMode, string> = {
  'group-then-progress-desc': 'Status',
  'name-asc': 'Name A→Z',
  'last-activity-desc': 'Recent',
}

/* audit-list-filters #3 — native-tooltip explanation for each sort chip.
   Labels alone don't answer 'A→Z by what?' or 'Group of what?'; titles
   surface on hover after the OS-default delay. */
const SORT_CHIP_TITLE: Record<SortMode, string> = {
  'group-then-progress-desc':
    'Group by lifecycle (active → open → done → pending), then by progress descending',
  'name-asc': 'Sort alphabetically by plan name',
  'last-activity-desc':
    'Sort by most recent task activity (newest first)',
}

/* Brand tokens copied inline from FeatureList.tsx's SearchInput per
   REQ-29 / REQ-42 (no new wf primitive, no new shared util). */
const WF_STEEL = '#2A3340'
const WF_FOG = '#5A6472'
const WF_BONE = '#E6EBF2'

export interface PlansFilterBarProps {
  lifecycle: ReadonlySet<LifecycleChip>
  project: ReadonlySet<string>
  search: string
  sort: SortMode
  chipNames: readonly string[]
  setLifecycle: (next: ReadonlySet<LifecycleChip>) => void
  setProject: (next: ReadonlySet<string>) => void
  setSearch: (next: string) => void
  setSort: (next: SortMode) => void
  /* audit-list-filters #4 — hide the sort row when the post-filter set
     has nothing to reorder (n ≤ 1). Optional for back-compat with call
     sites that pre-date the trivial-set guard. */
  visibleCount?: number
}

interface LifecycleChipsProps {
  lifecycle: ReadonlySet<LifecycleChip>
  setLifecycle: (next: ReadonlySet<LifecycleChip>) => void
}

function LifecycleChips({ lifecycle, setLifecycle }: Readonly<LifecycleChipsProps>) {
  return (
    <Box sx={{ display: 'flex', gap: '8px', flexWrap: 'wrap' }}>
      {LIFECYCLE_CHIP_ORDER.map((value) => {
        const active = lifecycle.has(value)
        return (
          <span key={value} data-filter="lifecycle" data-value={value}>
            <ToggleChip
              label={LIFECYCLE_CHIP_LABEL[value]}
              active={active}
              onClick={() => {
                const next = new Set(lifecycle)
                if (active) next.delete(value)
                else next.add(value)
                setLifecycle(next)
              }}
            />
          </span>
        )
      })}
    </Box>
  )
}

interface ProjectChipsProps {
  chipNames: readonly string[]
  project: ReadonlySet<string>
  setProject: (next: ReadonlySet<string>) => void
}

function ProjectChips({ chipNames, project, setProject }: Readonly<ProjectChipsProps>) {
  if (chipNames.length === 0) return null
  return (
    <Box sx={{ display: 'flex', gap: '8px', flexWrap: 'wrap' }}>
      {chipNames.map((name) => {
        const active = project.has(name)
        return (
          <span key={name} data-filter="project" data-value={name}>
            <ToggleChip
              label={name}
              active={active}
              onClick={() => {
                const next = new Set(project)
                if (active) next.delete(name)
                else next.add(name)
                setProject(next)
              }}
            />
          </span>
        )
      })}
    </Box>
  )
}

interface SortChipsProps {
  sort: SortMode
  setSort: (next: SortMode) => void
}

function SortChips({ sort, setSort }: Readonly<SortChipsProps>) {
  return (
    <Box sx={{ display: 'flex', gap: '8px', flexWrap: 'wrap' }}>
      {SORT_CHIP_ORDER.map((value) => {
        const active = sort === value
        return (
          <span key={value} data-filter="sort" data-value={value}>
            <ToggleChip
              label={SORT_CHIP_LABEL[value]}
              title={SORT_CHIP_TITLE[value]}
              active={active}
              onClick={() => {
                if (active) return
                setSort(value)
              }}
            />
          </span>
        )
      })}
    </Box>
  )
}

interface SearchInputProps {
  search: string
  setSearch: (next: string) => void
}

function SearchInput({ search, setSearch }: Readonly<SearchInputProps>) {
  return (
    <input
      type="text"
      aria-label="Search plans"
      placeholder="Search name or project"
      data-testid="plan-filter-search"
      value={search}
      onChange={(e) => setSearch(e.target.value)}
      style={{
        height: 24,
        padding: '0 10px',
        backgroundColor: 'transparent',
        border: `1px solid ${WF_STEEL}`,
        borderRadius: 0,
        color: WF_BONE,
        fontFamily:
          '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
        fontSize: '11px',
        letterSpacing: '0.04em',
        outline: 'none',
        minWidth: 200,
      }}
      onFocus={(e) => {
        e.currentTarget.style.borderColor = WF_FOG
      }}
      onBlur={(e) => {
        e.currentTarget.style.borderColor = WF_STEEL
      }}
    />
  )
}

export default function PlansFilterBar({
  lifecycle,
  project,
  search,
  sort,
  chipNames,
  setLifecycle,
  setProject,
  setSearch,
  setSort,
  visibleCount,
}: Readonly<PlansFilterBarProps>) {
  /* Show sort chips unless the caller explicitly says n ≤ 1 (no
     reorder possible). Omitted prop preserves legacy always-on behavior. */
  const showSort = visibleCount === undefined || visibleCount >= 2
  return (
    <Stack spacing={1.5} sx={{ p: 1.5, pb: 1 }}>
      <LifecycleChips lifecycle={lifecycle} setLifecycle={setLifecycle} />
      <ProjectChips
        chipNames={chipNames}
        project={project}
        setProject={setProject}
      />
      <Box
        sx={{
          display: 'flex',
          gap: '8px',
          flexWrap: 'wrap',
          justifyContent: 'space-between',
          alignItems: 'center',
        }}
      >
        <SearchInput search={search} setSearch={setSearch} />
        {showSort && <SortChips sort={sort} setSort={setSort} />}
      </Box>
    </Stack>
  )
}
