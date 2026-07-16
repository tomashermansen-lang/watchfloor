import { createVersionedFilterState } from './createVersionedFilterState'

const LIFECYCLE_CHIPS = ['active', 'open', 'done', 'pending'] as const
const SORT_MODES = [
  'group-then-progress-desc',
  'name-asc',
  'last-activity-desc',
] as const

export type LifecycleChip = (typeof LIFECYCLE_CHIPS)[number]
export type SortMode = (typeof SORT_MODES)[number]

// PlanFiltersState and UsePlanFiltersReturn are declared as explicit
// interfaces (not type aliases re-derived from the factory output) so
// editor tooling continues to render the predecessor names in IDE
// tooltips. They are structurally identical to VersionedFilterState
// from the factory; tsc enforces compatibility at the export-assignment
// site below.
export interface PlanFiltersState {
  lifecycle: ReadonlySet<LifecycleChip>
  project: ReadonlySet<string>
  search: string
  sort: SortMode
}

export interface UsePlanFiltersReturn extends PlanFiltersState {
  setLifecycle: (next: ReadonlySet<LifecycleChip>) => void
  setProject: (next: ReadonlySet<string>) => void
  setSearch: (next: string) => void
  setSort: (next: SortMode) => void
}

export const usePlanFilters: () => UsePlanFiltersReturn =
  createVersionedFilterState<LifecycleChip, SortMode>({
    storageKey: 'wf.planFilters.v1',
    lifecycleValues: LIFECYCLE_CHIPS,
    sortValues: SORT_MODES,
    defaults: {
      lifecycle: new Set<LifecycleChip>(['active', 'open']),
      project: new Set<string>(),
      search: '',
      sort: 'group-then-progress-desc',
    },
  })
