import { createVersionedFilterState } from './createVersionedFilterState'

export type LifecycleFilterChip = 'active' | 'paused' | 'pending' | 'done'

export type SortMode =
  | 'urgency-then-completion'
  | 'name-asc'
  | 'last-activity-desc'

const LIFECYCLE_VALUES = [
  'active',
  'paused',
  'pending',
  'done',
] as const satisfies readonly LifecycleFilterChip[]

const SORT_VALUES = [
  'urgency-then-completion',
  'name-asc',
  'last-activity-desc',
] as const satisfies readonly SortMode[]

export const useFeatureFilters = createVersionedFilterState<
  LifecycleFilterChip,
  SortMode
>({
  storageKey: 'wf.featureFilters.v1',
  lifecycleValues: LIFECYCLE_VALUES,
  sortValues: SORT_VALUES,
  defaults: {
    lifecycle: new Set<LifecycleFilterChip>(['active', 'paused']),
    project: new Set<string>(),
    search: '',
    sort: 'urgency-then-completion',
  },
})

export type FeatureFiltersState = ReturnType<typeof useFeatureFilters>
