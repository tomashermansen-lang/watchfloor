import { useMemo } from 'react'
import Box from '@mui/material/Box'
import Skeleton from '@mui/material/Skeleton'
import Stack from '@mui/material/Stack'
import Typography from '@mui/material/Typography'
import type { Feature, FeatureStatus } from '../../types'
import {
  useFeatureFilters,
  type LifecycleFilterChip,
  type SortMode,
} from '../../hooks/useFeatureFilters'
import FeatureCard, { type OnNavigateToPlan } from './FeatureCard'
import ToggleChip from '../wf/ToggleChip'
import EmptyScope from '../wf/EmptyScope'

/* ═══ helpers ═══ */

/** REQ-2, REQ-18, REQ-36, EC-15 — numeric rank lookup for the
   `urgency-then-completion` sort mode. Replaces the legacy ranking
   constant; the predecessor identifier is intentionally absent
   from this file (host plan Phase 4 RSK-E grep-negation gate). */
const STATUS_RANK: Record<FeatureStatus, number> = {
  stuck: 0,
  waiting: 1,
  active: 2,
  paused: 3,
  done: 4,
}

/** REQ-22, REQ-23 — deterministic render order for the lifecycle chip group. */
const LIFECYCLE_CHIP_ORDER: readonly LifecycleFilterChip[] = [
  'active',
  'paused',
  'pending',
  'done',
]

/** REQ-23, REQ-15 — chip label text shown to operators (and used by
   the empty-state subtitle builder). */
const LIFECYCLE_CHIP_LABEL: Record<LifecycleFilterChip, string> = {
  active: 'Active',
  paused: 'Paused',
  pending: 'Pending',
  done: 'Done',
}

/** REQ-25 — render order for the sort chip group. */
const SORT_CHIP_ORDER: readonly SortMode[] = [
  'urgency-then-completion',
  'name-asc',
  'last-activity-desc',
]

/** REQ-25 — visible label per sort mode. */
const SORT_CHIP_LABEL: Record<SortMode, string> = {
  'urgency-then-completion': 'Urgency',
  'name-asc': 'Name A→Z',
  'last-activity-desc': 'Recent',
}

/* audit-list-filters #3 (Features-tab parity) — native-tooltip explanation
   for each sort chip. URGENCY especially needs the rank ordering surfaced
   since the label alone can't communicate it. */
const SORT_CHIP_TITLE: Record<SortMode, string> = {
  'urgency-then-completion':
    'Sort by status urgency (stuck → waiting → active → paused)',
  'name-asc': 'Sort alphabetically by feature name',
  'last-activity-desc':
    'Sort by most recent feature activity (newest first)',
}

/* Search-input styling tokens copied inline from ToggleChip per REQ-39
   (no new wf primitive). Values are intentionally kept verbatim so the
   search input visually coheres with the chip rail without introducing
   a shared constants module. */
const WF_STEEL = '#2A3340'
const WF_FOG = '#5A6472'
const WF_BONE = '#E6EBF2'

/** REQ-4, REQ-5, REQ-6, REQ-8, EC-14 — decide whether a feature
   passes the lifecycle filter for the inprogress layer. Treats
   `lifecycle === undefined` as `'inprogress'` (back-compat for
   pre-Phase-1 cached responses). */
function lifecycleMatches(
  feature: Feature,
  lifecycleSet: ReadonlySet<LifecycleFilterChip>,
): boolean {
  const lifecycle = feature.lifecycle ?? 'inprogress'
  if (lifecycle === 'pending') {
    return lifecycleSet.has('pending')
  }
  if (lifecycle !== 'inprogress') {
    return false
  }
  const status = feature.status
  if (status === 'paused') {
    return lifecycleSet.has('paused')
  }
  if (status === 'done') {
    /* EC-14 — `lifecycle:'inprogress' + status:'done'` is a logical
       inconsistency. Hide rather than promote to either layer. */
    return false
  }
  /* EC-15 — `{stuck, waiting, active}` AND any forward-compat unknown
     status fall under the Active branch so the comparator's
     `Number.MAX_SAFE_INTEGER` fallback is reachable. */
  return lifecycleSet.has('active')
}

/** REQ-7 — partition predicate for the Done layer. */
function isDoneFeature(feature: Feature): boolean {
  return feature.lifecycle === 'done'
}

/** REQ-11, REQ-12, EC-3 — pass-through when the project Set is empty,
   otherwise OR-membership against `feature.project`. */
function projectMatches(
  feature: Feature,
  projectSet: ReadonlySet<string>,
): boolean {
  if (projectSet.size === 0) return true
  return projectSet.has(feature.project)
}

/** REQ-13, REQ-14, EC-5..EC-7 — case-insensitive substring match on
   `feature.name` OR `feature.project`. Empty `search` is pass-through. */
function searchMatches(feature: Feature, search: string): boolean {
  if (search === '') return true
  const q = search.toLowerCase()
  return (
    feature.name.toLowerCase().includes(q) ||
    feature.project.toLowerCase().includes(q)
  )
}

/** REQ-18, REQ-19, REQ-20, REQ-21, EC-8, EC-9, EC-15 — comparator
   factory for the inprogress layer. Returns 0 for equal-rank pairs
   and relies on V8 stable sort for insertion-order preservation. */
function compareInprogress(
  sortMode: SortMode,
): (a: Feature, b: Feature) => number {
  if (sortMode === 'name-asc') {
    return (a, b) =>
      a.name.localeCompare(b.name, undefined, { sensitivity: 'base' })
  }
  if (sortMode === 'last-activity-desc') {
    return (a, b) => {
      const aHas = a.last_activity != null
      const bHas = b.last_activity != null
      if (!aHas && !bHas) return 0
      if (!aHas) return 1
      if (!bHas) return -1
      const av = a.last_activity as string
      const bv = b.last_activity as string
      if (av > bv) return -1
      if (av < bv) return 1
      return 0
    }
  }
  // 'urgency-then-completion' (default).
  return (a, b) => {
    const ra = STATUS_RANK[a.status] ?? Number.MAX_SAFE_INTEGER
    const rb = STATUS_RANK[b.status] ?? Number.MAX_SAFE_INTEGER
    return ra - rb
  }
}

/** REQ-7, REQ-21, EC-10, AS-3, AS-4 — Done-layer comparator:
   `done_at` desc with null/empty sentinel sorted last. */
function compareDoneByDoneAt(a: Feature, b: Feature): number {
  const aHas = a.done_at != null && a.done_at !== ''
  const bHas = b.done_at != null && b.done_at !== ''
  if (!aHas && !bHas) return 0
  if (!aHas) return 1
  if (!bHas) return -1
  const av = a.done_at as string
  const bv = b.done_at as string
  if (av > bv) return -1
  if (av < bv) return 1
  return 0
}

/** REQ-10, REQ-24, EC-3, EC-4, EC-13 — alphabetised (case-insensitive),
   de-duplicated, empty-string-filtered project chip vocabulary. */
function derivedProjectChips(features: readonly Feature[]): string[] {
  const set = new Set<string>()
  for (const f of features) {
    if (f.project && f.project.length > 0) set.add(f.project)
  }
  return Array.from(set).sort((a, b) =>
    a.toLowerCase().localeCompare(b.toLowerCase()),
  )
}

/** REQ-15, EC-1, EC-2 — produce the filter-aware empty-state subtitle.
   Empty Set ⇒ `''`; all four chips selected ⇒ `'… — try clearing the
   search'`; otherwise ⇒ `'<labels> — try adding <missing>'`. */
function buildEmptyStateSubtitle(
  lifecycleSet: ReadonlySet<LifecycleFilterChip>,
): string {
  if (lifecycleSet.size === 0) return ''
  const activeLabels = LIFECYCLE_CHIP_ORDER.filter((v) =>
    lifecycleSet.has(v),
  ).map((v) => LIFECYCLE_CHIP_LABEL[v])
  const missingLabels = LIFECYCLE_CHIP_ORDER.filter(
    (v) => !lifecycleSet.has(v),
  ).map((v) => LIFECYCLE_CHIP_LABEL[v])
  const head = activeLabels.join('+')
  if (missingLabels.length === 0) {
    return `${head} — try clearing the search`
  }
  return `${head} — try adding ${missingLabels.join(' or ')}`
}

/* ═══ sub-components ═══ */

interface LifecycleChipsProps {
  lifecycle: ReadonlySet<LifecycleFilterChip>
  setLifecycle: (next: ReadonlySet<LifecycleFilterChip>) => void
}

/** REQ-22, REQ-23, REQ-28, AS-18 — render the four lifecycle chips
   in deterministic order. Each click constructs a new Set instance. */
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

/** REQ-22, REQ-24, REQ-28, AS-9, AS-10, EC-3, EC-4 — one chip per
   derived project name. Empty `chipNames` renders nothing. */
function ProjectChips({
  chipNames,
  project,
  setProject,
}: Readonly<ProjectChipsProps>) {
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

/** REQ-22, REQ-25, REQ-27, AS-13..AS-15, AS-17 — single-select sort chips.
   Clicking the active chip is a no-op. */
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

/** REQ-26, AS-5, AS-6, EC-5..EC-7, EC-16 — single styled `<input>`.
   No new wf primitive (REQ-39); brand tokens copied inline. */
function SearchInput({ search, setSearch }: Readonly<SearchInputProps>) {
  return (
    <input
      type="text"
      aria-label="Search features"
      placeholder="Search name or project"
      data-testid="feature-filter-search"
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

interface FilterBarProps {
  lifecycle: ReadonlySet<LifecycleFilterChip>
  project: ReadonlySet<string>
  search: string
  sort: SortMode
  chipNames: readonly string[]
  setLifecycle: (next: ReadonlySet<LifecycleFilterChip>) => void
  setProject: (next: ReadonlySet<string>) => void
  setSearch: (next: string) => void
  setSort: (next: SortMode) => void
}

/** REQ-22 — three-row filter bar layout. */
function FilterBar({
  lifecycle,
  project,
  search,
  sort,
  chipNames,
  setLifecycle,
  setProject,
  setSearch,
  setSort,
}: Readonly<FilterBarProps>) {
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
        <SortChips sort={sort} setSort={setSort} />
      </Box>
    </Stack>
  )
}

interface DoneDividerProps {
  count: number
}

/** REQ-29, AS-2, AS-19 — divider between inprogress and Done layers
   when both are non-empty. Caller decides when to render. */
function DoneDivider({ count }: Readonly<DoneDividerProps>) {
  return (
    <Box
      data-testid="done-divider"
      sx={{
        display: 'flex',
        alignItems: 'center',
        gap: 1,
        my: '12px',
      }}
    >
      <Box sx={{ flex: 1, height: '1px', backgroundColor: 'divider' }} />
      <Typography
        variant="caption"
        sx={{
          fontFamily:
            '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
          letterSpacing: '0.12em',
          textTransform: 'uppercase',
          color: WF_FOG,
        }}
      >
        Done ({count})
      </Typography>
      <Box sx={{ flex: 1, height: '1px', backgroundColor: 'divider' }} />
    </Box>
  )
}

/* ═══ FeatureList ═══ */

interface FeatureListProps {
  features: Feature[] | undefined
  isLoading: boolean
  selectedKey: string | null
  onSelectFeature: (key: string) => void
  /* feature-plan-link-and-nav (REQ-6, REQ-7, REQ-11) — forwarded
     verbatim to every FeatureCard in both inprogress and done map
     calls. Optional with no-op default per REQ-6. */
  onNavigateToPlan?: OnNavigateToPlan
}

export default function FeatureList({
  features,
  isLoading,
  selectedKey,
  onSelectFeature,
  onNavigateToPlan,
}: Readonly<FeatureListProps>) {
  const {
    lifecycle,
    project,
    search,
    sort,
    setLifecycle,
    setProject,
    setSearch,
    setSort,
  } = useFeatureFilters()

  const chipNames = useMemo(
    () => derivedProjectChips(features ?? []),
    [features],
  )

  const { inprogress, done } = useMemo(() => {
    const source = features ?? []
    const filtered = source.filter(
      (f) => searchMatches(f, search) && projectMatches(f, project),
    )
    const inprogressLayer = filtered
      .filter((f) => !isDoneFeature(f) && lifecycleMatches(f, lifecycle))
      .slice()
      .sort(compareInprogress(sort))
    const doneLayer = lifecycle.has('done')
      ? filtered.filter(isDoneFeature).slice().sort(compareDoneByDoneAt)
      : []
    return { inprogress: inprogressLayer, done: doneLayer }
  }, [features, lifecycle, project, search, sort])

  // REQ-16 — loading branch (skeletons, no filter bar).
  if (isLoading && !features) {
    return (
      <Stack spacing={1.5} sx={{ p: 1.5 }}>
        <Skeleton variant="rectangular" height={80} sx={{ borderRadius: 1 }} />
        <Skeleton variant="rectangular" height={80} sx={{ borderRadius: 1 }} />
        <Skeleton variant="rectangular" height={80} sx={{ borderRadius: 1 }} />
      </Stack>
    )
  }

  // REQ-17 — empty payload branch (baseline empty state, no filter bar).
  if (features?.length === 0) {
    return (
      <Box
        sx={{
          display: 'flex',
          flexDirection: 'column',
          alignItems: 'center',
          justifyContent: 'center',
          height: '100%',
          p: 3,
        }}
      >
        <Typography variant="body1" color="text.secondary" sx={{ fontWeight: 500 }}>
          No features in progress
        </Typography>
        <Typography variant="caption" color="text.secondary" sx={{ mt: 1 }}>
          Features appear here when you run /start or autopilot.sh
        </Typography>
      </Box>
    )
  }

  const filterBar = (
    <FilterBar
      lifecycle={lifecycle}
      project={project}
      search={search}
      sort={sort}
      chipNames={chipNames}
      setLifecycle={setLifecycle}
      setProject={setProject}
      setSearch={setSearch}
      setSort={setSort}
    />
  )

  // REQ-9, REQ-15 — filter-aware empty state.
  if (inprogress.length === 0 && done.length === 0) {
    return (
      <Box sx={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0 }}>
        {filterBar}
        <Box sx={{ flex: 1, overflowY: 'auto' }}>
          <EmptyScope
            title="No features match"
            subtitle={buildEmptyStateSubtitle(lifecycle)}
            size={200}
          />
        </Box>
      </Box>
    )
  }

  // Populated branch — REQ-22, REQ-29, REQ-30.
  return (
    <Box sx={{ display: 'flex', flexDirection: 'column', flex: 1, minHeight: 0 }}>
      {filterBar}
      <Box
        role="listbox"
        aria-label="Features"
        sx={{ overflowY: 'auto', flex: 1 }}
      >
        <Stack spacing={1.5} sx={{ p: 1.5, pt: 0 }}>
          {inprogress.map((feature) => {
            const key = `${feature.project_root}:${feature.name}`
            return (
              <FeatureCard
                key={key}
                feature={feature}
                selected={key === selectedKey}
                onSelect={() => onSelectFeature(key)}
                onNavigateToPlan={onNavigateToPlan}
              />
            )
          })}
          {inprogress.length > 0 && done.length > 0 && (
            <DoneDivider count={done.length} />
          )}
          {done.map((feature) => {
            const key = `${feature.project_root}:${feature.name}`
            return (
              <FeatureCard
                key={key}
                feature={feature}
                selected={key === selectedKey}
                onSelect={() => onSelectFeature(key)}
                onNavigateToPlan={onNavigateToPlan}
              />
            )
          })}
        </Stack>
      </Box>
    </Box>
  )
}
