import React, { useState, useMemo, lazy, Suspense } from 'react'
import { flushSync } from 'react-dom'
import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import Alert from '@mui/material/Alert'
import Skeleton from '@mui/material/Skeleton'
import IconButton from '@mui/material/IconButton'
import Tooltip from '@mui/material/Tooltip'
import Select from '@mui/material/Select'
import MenuItem from '@mui/material/MenuItem'
import DarkModeIcon from '@mui/icons-material/DarkMode'
import LightModeIcon from '@mui/icons-material/LightMode'
import CloseIcon from '@mui/icons-material/Close'
import ChevronRightIcon from '@mui/icons-material/ChevronRight'
import BuildOutlinedIcon from '@mui/icons-material/BuildOutlined'
import AppIcon from './wf/AppIcon'
import type { AppIconType } from './wf/AppIcon'
import Collapse from '@mui/material/Collapse'
import { useColorScheme, useTheme } from '@mui/material/styles'
import useMediaQuery from '@mui/material/useMediaQuery'
import { usePlans } from '../hooks/usePlans'
import { usePlan } from '../hooks/usePlan'
import type { ProjectSummary, Session } from '../types'
import { useSessions } from '../hooks/useSessions'
import { useFeatures } from '../hooks/useFeatures'
import { useDataFreshness } from '../hooks/useDataFreshness'
import Pipeline from './Pipeline'
import DataFreshnessChip from './DataFreshnessChip'
import RadarMark from './wf/RadarMark'
import LiveBadge from './wf/LiveBadge'
import StatusPill from './wf/StatusPill'
import EmptyScope from './wf/EmptyScope'
import PlanCompletionBand from './wf/PlanCompletionBand'
import { flattenTasks, computeProgressPct } from '../utils/planMetrics'
import { classifyPlan, statusPillProps } from '../utils/planLifecycle'
import PlansFilterBar from './PlansFilterBar'
import { usePlanFilters, type LifecycleChip, type SortMode } from '../hooks/usePlanFilters'
import { HoverLinkProvider } from '../contexts/HoverLinkContext'
import { SessionControls } from './SessionControls'
import { planDirToChainId } from '../utils/chainId'

const MetricsView = lazy(() => import('./metrics/MetricsView'))
const GrinderView = lazy(() => import('./grinder/GrinderView'))
const FeaturesView = lazy(() => import('./features/FeaturesView'))
// OverviewView is the default landing tab — kept eager so first paint
// has no Suspense fallback flicker and the test surface stays simple.
import OverviewView from './OverviewView'
import FeatureTabView from './FeatureTabView'
import ProjectSubviewTab from './ProjectSubviewTab'
import ActivityRail from './ActivityRail'

const SUPPORTED_SCHEMA_MAJORS = ['1', '2']

type DashboardView = 'overview' | 'plan' | 'metrics' | 'features' | 'grinder'

// TabId: any built-in DashboardView OR a per-feature tab encoded as
// 'feature:<project>/<name>' OR a project sub-view tab encoded as
// 'project:<project>/<subview>' where subview ∈ {vision, pipeline,
// deferred, deviations}. Generalising openTabs/activeTab to string
// lets the tab system carry these alongside built-in views without
// a parallel type union per kind.
type TabId = DashboardView | `feature:${string}` | `project:${string}`
const FEATURE_TAB_PREFIX = 'feature:'
const PROJECT_TAB_PREFIX = 'project:'
const isFeatureTab = (id: string): id is `feature:${string}` => id.startsWith(FEATURE_TAB_PREFIX)
const featureKeyFromTab = (id: string): string => id.slice(FEATURE_TAB_PREFIX.length)
const isProjectSubviewTab = (id: string): id is `project:${string}` => id.startsWith(PROJECT_TAB_PREFIX)

type ProjectSubview = 'vision' | 'pipeline' | 'deferred' | 'deviations'
const PROJECT_SUBVIEW_KEYS: Record<string, ProjectSubview> = {
  Vision: 'vision',
  Pipeline: 'pipeline',
  'Deferred Audit': 'deferred',
  Deviations: 'deviations',
}
function parseProjectSubviewTab(id: string): { projectId: string; subview: ProjectSubview } | null {
  if (!isProjectSubviewTab(id)) return null
  const rest = id.slice(PROJECT_TAB_PREFIX.length)
  const slash = rest.lastIndexOf('/')
  if (slash < 0) return null
  const projectId = rest.slice(0, slash)
  const sub = rest.slice(slash + 1) as ProjectSubview
  if (!['vision', 'pipeline', 'deferred', 'deviations'].includes(sub)) return null
  return { projectId, subview: sub }
}

// Overview is first as default landing. 'plan' value retained for
// localStorage compatibility with commits 1+2; the operator-facing
// label is 'Plans' (plural) and renders as an expandable group whose
// children list per-project plans (project tree expansion lands in
// commit 4).
const VIEW_OPTIONS: { value: DashboardView; label: string }[] = [
  { value: 'overview', label: 'Overview' },
  { value: 'plan', label: 'Plans' },
  { value: 'metrics', label: 'Metrics' },
  { value: 'features', label: 'Features' },
  { value: 'grinder', label: 'Grinder' },
]

/* Sidebar icons per view — wf brand AppIcon set (handoff §App icons set).
   overview→vision (the fleet is what we're aiming at), plan→plan,
   metrics→metrics, features→features. grinder is outside the 8-icon
   set — Build keeps the wrench affordance until a brand grinder icon
   is defined. The global "Deferred Audit" view was retired in favour
   of per-project deferred sub-tabs (document icon now lives there). */
const APP_ICON_FOR_VIEW: Partial<Record<DashboardView, AppIconType>> = {
  overview: 'vision',
  plan: 'plan',
  metrics: 'metrics',
  features: 'features',
}

/* Sub-views shown when a project under Plans is expanded. Each carries
   a wf AppIcon — Vision/Pipeline/Deviations map 1:1; Deferred Audit
   uses the document icon (matches the global Deferred view). */
const PROJECT_SUBVIEWS: ReadonlyArray<{ label: string; iconType: AppIconType }> = [
  { label: 'Vision', iconType: 'vision' },
  { label: 'Pipeline', iconType: 'pipeline' },
  { label: 'Deferred Audit', iconType: 'document' },
  { label: 'Deviations', iconType: 'deviations' },
]

// Sidebar section headers — handoff §Three-Tier Left Rail. Tier
// labels use JetBrains Mono in Signal Blue, prefixed by an 8×1px
// signal-blue rule and followed by an optional right-aligned count.
function SidebarSectionHeader({ label, badge }: Readonly<{ label: string; badge?: number }>) {
  return (
    <Box
      sx={{
        display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 1,
        px: 1, pt: 1.5, pb: 0.5,
        userSelect: 'none',
      }}
    >
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.75, minWidth: 0 }}>
        {/* 8×1px signal-blue rule per handoff "tier label" treatment */}
        <Box sx={{ width: 8, height: '1px', bgcolor: 'wf.signal', flexShrink: 0 }} />
        <Typography
          sx={{
            fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
            color: 'wf.signal',
            fontSize: '10px',
            letterSpacing: '0.22em',
            textTransform: 'uppercase',
            fontWeight: 500,
            lineHeight: 1,
          }}
        >
          {label}
        </Typography>
      </Box>
      {badge !== undefined && (
        <Typography
          sx={{
            fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
            fontSize: '10.5px',
            color: 'wf.fog',
            fontVariantNumeric: 'tabular-nums',
          }}
        >
          {badge}
        </Typography>
      )}
    </Box>
  )
}


// Tab strip label resolver. Built-in views look up VIEW_OPTIONS for
// their human label; per-feature tabs surface the feature name parsed
// from the encoded tab id (`feature:<project>/<name>`); project sub-
// view tabs read 'project · subview' from the encoded id (e.g.
// 'OIH · Vision').
function labelForTab(tabId: string, viewOptions: typeof VIEW_OPTIONS): string {
  if (isFeatureTab(tabId)) {
    const key = featureKeyFromTab(tabId)
    return key.includes('/') ? key.slice(key.indexOf('/') + 1) : key
  }
  if (isProjectSubviewTab(tabId)) {
    const parsed = parseProjectSubviewTab(tabId)
    if (parsed) {
      const subviewLabel = parsed.subview === 'vision' ? 'Vision'
        : parsed.subview === 'pipeline' ? 'Pipeline'
        : parsed.subview === 'deferred' ? 'Deferred'
        : 'Deviations'
      // Prefer last path-segment of project id so a long path like
      // /Users/foo/Projekter/OIH renders as 'OIH · Vision'.
      const tail = parsed.projectId.split('/').filter(Boolean).pop() ?? parsed.projectId
      return `${tail} · ${subviewLabel}`
    }
  }
  const opt = viewOptions.find((o) => o.value === tabId)
  return opt?.label ?? tabId
}

/* ═══ plans-filter-ui helpers (module-scope, file-local — REQ-40) ═══ */

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

const PLAN_GROUP_RANK: Record<LifecycleChip, number> = {
  active: 0,
  open: 1,
  done: 2,
  pending: 3,
}

/** REQ-12, EC-6, EC-14 — alphabetised (case-insensitive), de-duplicated,
   empty-string-filtered project chip vocabulary derived from
   `path.split('/').filter(Boolean).pop()`. */
function derivedProjectChips(
  projects: readonly ProjectSummary[] | undefined,
): string[] {
  if (!projects || projects.length === 0) return []
  const set = new Set<string>()
  for (const p of projects) {
    const segments = (p.path ?? '').split('/').filter(Boolean)
    const basename = segments.at(-1)
    if (basename && basename.length > 0) set.add(basename)
  }
  return Array.from(set).sort((a, b) =>
    a.toLowerCase().localeCompare(b.toLowerCase()),
  )
}

function projectBasename(p: ProjectSummary): string {
  const segments = (p.path ?? '').split('/').filter(Boolean)
  return segments.at(-1) ?? ''
}

function lifecycleMatches(
  p: ProjectSummary,
  lifecycleSet: ReadonlySet<LifecycleChip>,
): boolean {
  return lifecycleSet.has(classifyPlan(p))
}

function projectMatches(
  p: ProjectSummary,
  projectSet: ReadonlySet<string>,
): boolean {
  if (projectSet.size === 0) return true
  return projectSet.has(projectBasename(p))
}

function searchMatches(p: ProjectSummary, search: string): boolean {
  if (search === '') return true
  const q = search.toLowerCase()
  const name = (p.project ?? '').toLowerCase()
  const base = projectBasename(p).toLowerCase()
  return name.includes(q) || base.includes(q)
}

function comparatorFor(
  mode: SortMode,
): (a: ProjectSummary, b: ProjectSummary) => number {
  if (mode === 'name-asc') {
    return (a, b) =>
      a.project.localeCompare(b.project, undefined, { sensitivity: 'base' })
  }
  if (mode === 'last-activity-desc') {
    /* Honest recency: ISO timestamp desc, null/missing last (V8-stable
       insertion order among nulls). Mirrors FeatureList.tsx's compareInprogress
       so Plans-tab RECENT and Features-tab Recent agree on shape. */
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
  /* 'group-then-progress-desc' (default) */
  return (a, b) => {
    const ra = PLAN_GROUP_RANK[classifyPlan(a)]
    const rb = PLAN_GROUP_RANK[classifyPlan(b)]
    if (ra !== rb) return ra - rb
    return (b.progress ?? 0) - (a.progress ?? 0)
  }
}

function filterAndSort(
  projects: readonly ProjectSummary[],
  lifecycle: ReadonlySet<LifecycleChip>,
  project: ReadonlySet<string>,
  search: string,
  sort: SortMode,
): ProjectSummary[] {
  const filtered = projects.filter(
    (p) =>
      lifecycleMatches(p, lifecycle) &&
      projectMatches(p, project) &&
      searchMatches(p, search),
  )
  return [...filtered].sort(comparatorFor(sort))
}

/** REQ-21, EC-1, EC-2, R5 — filter-aware empty-state subtitle. */
function buildEmptyStateSubtitle(
  lifecycleSet: ReadonlySet<LifecycleChip>,
): string {
  if (lifecycleSet.size === 0) {
    return 'No lifecycle chips selected — pick at least one'
  }
  const activeLabels = LIFECYCLE_CHIP_ORDER.filter((v) => lifecycleSet.has(v)).map(
    (v) => LIFECYCLE_CHIP_LABEL[v],
  )
  const missingLabels = LIFECYCLE_CHIP_ORDER.filter((v) => !lifecycleSet.has(v)).map(
    (v) => LIFECYCLE_CHIP_LABEL[v],
  )
  const head = activeLabels.join('+')
  if (missingLabels.length === 0) {
    return `${head} — try clearing the search`
  }
  return `${head} — try adding ${missingLabels.join(' or ')}`
}

/* ═══ Per-project panel (calls usePlan internally) ═══ */

function ProjectPanel({
  project,
  sessions,
  onOpenOutput,
}: {
  project: ProjectSummary
  sessions: Session[] | undefined
  /* controls-06 #14 — Output click on the Plans row navigates to
     the per-project Pipeline subview (drill-down per industry
     pattern: GitHub Actions / Vercel / Render / Heroku / Linear /
     K8s dashboards all converge on this for row-of-running-jobs).
     Receives the project's tab id (`project:<id>/pipeline`). */
  onOpenOutput: () => void
}) {
  const { data: plan, isLoading: planLoading } = usePlan(project.plan_dir ?? project.path ?? null)
  const { data: allFeatures } = useFeatures()
  const projectFeatures = useMemo(
    () => (allFeatures ?? []).filter((f) => f.project === project.project),
    [allFeatures, project.project],
  )

  /* Chain target_id is the dir-basename minus the INPROGRESS_Plan_
     prefix (control.py:213). project.plan_dir is the absolute path on
     the operator's machine; planDirToChainId strips both the path and
     the prefix. */
  const chainId = useMemo(
    () => planDirToChainId(project.plan_dir ?? ''),
    [project.plan_dir],
  )

  /* controls-04 #1 — gate the chain control surface on the project
     lifecycle. A DONE plan's StatusPill says "done"; offering a
     START CHAIN button on the same row would reopen a finished
     pipeline by surprise. The pill IS the truth (REQ-32/33 wires
     `statusPillProps` through the same `classifyPlan`); the action
     surface must defer to it. Suppressing the mount also avoids
     burning a 2 s SWR poll on a chain that will never run again. */
  const showChainControls = classifyPlan(project) !== 'done'

  const schemaMajor = plan?.schema_version?.split('.')[0]
  const schemaWarning =
    schemaMajor != null && !SUPPORTED_SCHEMA_MAJORS.includes(schemaMajor)

  if (planLoading) {
    return (
      <Box>
        <Skeleton variant="rectangular" height={48} sx={{ mb: 1.5, borderRadius: 1 }} />
        <Skeleton variant="rectangular" height={36} sx={{ mb: 1.5, borderRadius: 1 }} />
        <Skeleton variant="rectangular" height={120} sx={{ borderRadius: 1 }} />
      </Box>
    )
  }

  if (!plan) {
    return (
      <Alert severity="info" sx={{ borderRadius: 1 }}>
        No execution plan found for {project.project}.
      </Alert>
    )
  }

  /* controls-06 #1 — plan-row data cells. Pulled out of
     PlanCompletionBand so each cell occupies its own grid column
     for vertical alignment across all rows on the Plans tab. */
  const rowTasks = flattenTasks(plan)
  const rowTasksTotal = rowTasks.length
  const rowTasksDone = rowTasks.filter((t) => t.status === 'done').length
  const rowTasksPct = computeProgressPct(plan)

  return (
    <Box>
      {/* controls-06 #1 + #2 — plan-header row as an explicit CSS
          grid. The seven tracks mirror the watchfloor Feature
          portfolio table pattern (screens.md:35) so plan-name,
          status, actions, progress bar, counts, label, and percent
          align vertically across every row on the Plans tab.
          Action column sits BEFORE the progress band so the
          state-action verb leads the row's visual scan path
          (inverted from cycle-5 #1, whose spec citations were
          left-rail / Session-drawer specs not row layout).
          Inline `style` carries the grid declarations so jsdom
          can introspect them in DSH-61 — MUI sx is opaque to
          getComputedStyle. */}
      <Box
        data-testid="plan-header-row"
        sx={{
          alignItems: 'center',
          gap: 1.5,
          pb: 1, mb: 1.5,
          borderBottom: '1px solid', borderColor: 'wf.steel',
        }}
        style={{
          display: 'grid',
          gridTemplateColumns:
            'minmax(0, 1fr) auto 240px 72px auto 56px',
        }}
      >
        {/* controls-06 #7 — plan name + StatusPill share a single
            flex cluster sitting in the row's 1fr grid track.
            Cycle-6 #1's first cut gave each its own column, but
            because the title column was 1fr the pill got pushed
            toward the action cluster as the row stretched.
            Wrapping them in one flex container anchors the pill
            adjacent to the title regardless of viewport width.
            `minWidth: 0` lets the title ellipsis-truncate when
            the row is narrow (otherwise the cluster would push
            the action column off-row). */}
        <Box
          data-testid="plan-title-cluster"
          sx={{
            display: 'flex',
            alignItems: 'center',
            gap: 1.5,
            minWidth: 0,
          }}
        >
          <Typography
            variant="wfH3"
            sx={{
              minWidth: 0,
              whiteSpace: 'nowrap',
              overflow: 'hidden',
              textOverflow: 'ellipsis',
            }}
          >
            {plan.name}
          </Typography>
          <StatusPill {...statusPillProps(project)} />
        </Box>
        {/* controls-06 #2 — chain control surface lives in its own
            grid column BEFORE the progress band. When the project is
            DONE, the column collapses to an empty placeholder so
            siblings stay aligned with the rows that DO have a
            SessionControls mount. */}
        {showChainControls ? (
          <SessionControls
            targetKind="chain"
            /* controls-04 #4 — `chainId || null` coerces only the
               empty-string case; DSH-56 covers it. */
            targetId={chainId || null}
            /* controls-06 #14 — Output click on the row navigates to
               the per-project Pipeline subview (drill-down per
               GitHub Actions / Vercel / Render / Heroku / Linear).
               `attached` stays false so the button label stays
               "Output" (not "Hide") since this surface has no
               toggle semantic. */
            attached={false}
            onAttach={onOpenOutput}
            density="header"
            hideStateChip
          />
        ) : (
          <Box aria-hidden />
        )}
        <PlanCompletionBand plan={plan} features={projectFeatures} barOnly />
        <Typography
          data-testid="plan-row-counts"
          variant="wfLabel"
          color="text.secondary"
          sx={{ textAlign: 'right' }}
        >
          {rowTasksDone}/{rowTasksTotal}
        </Typography>
        <Typography
          data-testid="plan-row-label"
          variant="wfLabel"
          color="text.secondary"
        >
          TASKS
        </Typography>
        <Typography
          data-testid="plan-row-percent"
          variant="wfLabel"
          sx={{ color: 'wf.signal', textAlign: 'right' }}
        >
          {rowTasksPct}%
        </Typography>
      </Box>
      {/* controls-06 #14 — embedded TerminalPanel mount removed.
          Live output now lives on the per-project Pipeline subview
          (drill-down navigation). The cycle-3 #7 inline mount put
          the terminal in a row context where it competed with
          sibling rows + filter chrome for vertical space —
          industry survey (8/9 products) places live logs on a
          dedicated detail page. */}
      {schemaWarning && (
        <Alert severity="warning" sx={{ mb: 1, borderRadius: 1 }} onClose={() => {}}>
          Plan uses schema v{plan.schema_version} — dashboard supports v{SUPPORTED_SCHEMA_MAJORS.join(', v')}.x
        </Alert>
      )}
      <Pipeline plan={plan} sessions={sessions} projectPath={project.path} planDir={project.plan_dir ?? project.path} />
    </Box>
  )
}

export default function DashboardShell() {
  const { mode, setMode } = useColorScheme()
  const theme = useTheme()
  const isMobile = useMediaQuery(theme.breakpoints.down('sm'))
  const { data: projects, isLoading: projectsLoading } = usePlans()
  const { data: sessions } = useSessions()
  useFeatures()  // hook called for side effects (cache priming)
  /* plans-filter-ui REQ-1 — single hook call per render. */
  const {
    lifecycle: planLifecycle,
    project: planProject,
    search: planSearch,
    sort: planSort,
    setLifecycle: setPlanLifecycle,
    setProject: setPlanProject,
    setSearch: setPlanSearch,
    setSort: setPlanSort,
  } = usePlanFilters()
  const planChipNames = useMemo(
    () => derivedProjectChips(projects),
    [projects],
  )
  const filteredAndSortedProjects = useMemo(
    () =>
      filterAndSort(
        projects ?? [],
        planLifecycle,
        planProject,
        planSearch,
        planSort,
      ),
    [projects, planLifecycle, planProject, planSearch, planSort],
  )
  /* User-request 2026-05-08: sidebar FEATURES/ARCHIVED sections removed
     in favor of a runtime-state-only sidebar. The full feature catalog
     lives in the Features tab; ActivityRail surfaces what's running. */
  // Migrate single legacy 'dashboard-view' value (commit 1 era) into the
  // tab-system localStorage keys used from commit 2 onwards. Operators
  // who upgrade do not lose their last-active view. Default falls
  // through to 'overview' (commit 3 default landing).
  const migrateLegacyView = (saved: string | null): DashboardView => {
    if (saved === 'overview') return 'overview'
    if (saved === 'plan') return 'plan'
    if (saved === 'metrics') return 'metrics'
    if (saved === 'grinder') return 'grinder'
    if (saved === 'features' || saved === 'autopilot') return 'features'
    return 'overview'
  }

  const isValidTabId = (v: unknown): v is TabId =>
    typeof v === 'string' &&
    (VIEW_OPTIONS.some((opt) => opt.value === v) || isFeatureTab(v) || isProjectSubviewTab(v))

  const [openTabs, setOpenTabs] = useState<TabId[]>(() => {
    const stored = localStorage.getItem('dashboard-open-tabs')
    if (stored) {
      try {
        const parsed = JSON.parse(stored)
        if (Array.isArray(parsed) && parsed.length > 0) {
          return parsed.filter(isValidTabId)
        }
      } catch { /* fall through */ }
    }
    // Bootstrap: legacy single-view becomes the only open tab
    return [migrateLegacyView(localStorage.getItem('dashboard-view'))]
  })

  const [activeTab, setActiveTab] = useState<TabId>(() => {
    const stored = localStorage.getItem('dashboard-active-tab')
    if (stored && isValidTabId(stored)) return stored
    return migrateLegacyView(localStorage.getItem('dashboard-view'))
  })

  const view = activeTab // existing render branches stay unchanged

  // Persist open tabs and active tab on every change. Synchronous setItem
  // is fine here — small string, cheap, runs at most once per click.
  React.useEffect(() => {
    localStorage.setItem('dashboard-open-tabs', JSON.stringify(openTabs))
  }, [openTabs])
  React.useEffect(() => {
    localStorage.setItem('dashboard-active-tab', activeTab)
  }, [activeTab])

  const openOrFocusTab = (next: TabId) => {
    setOpenTabs((prev) => (prev.includes(next) ? prev : [...prev, next]))
    setActiveTab(next)
  }

  /* feature-plan-link-and-nav (REQ-7..REQ-10) — single real
     implementation of `onNavigateToPlan`. `flushSync` commits the tab
     switch synchronously so the Plans subtree (with its
     `data-plan-dir` wrappers) is in the DOM before `querySelector`
     runs in the same handler. This satisfies REQ-10 (tab switch
     unconditional, even if scroll lookup fails) and REQ-9 (no throw
     on missing panel — the `if (el)` guard handles it) without the
     useEffect-with-state-reset pattern that React 19 flags as a
     cascading-render anti-pattern. Already-on-Plans re-clicks (EC-7)
     work because the handler runs every click — there's no state
     gating it. */
  const handleNavigateToPlan = (planDir: string): void => {
    flushSync(() => {
      setOpenTabs((prev) => (prev.includes('plan') ? prev : [...prev, 'plan']))
      setActiveTab('plan')
    })
    const el = document.querySelector(
      `[data-plan-dir="${CSS.escape(planDir)}"]`,
    )
    if (el) el.scrollIntoView({ behavior: 'smooth', block: 'center' })
  }

  const closeTab = (target: TabId) => {
    setOpenTabs((prev) => {
      const remaining = prev.filter((t) => t !== target)
      if (remaining.length === 0) {
        setActiveTab('overview')
        return ['overview']
      }
      if (target === activeTab) {
        setActiveTab(remaining[remaining.length - 1])
      }
      return remaining
    })
  }

  // Plans is a collapsible section in the sidebar — clicking it both opens
  // the tab AND toggles expansion. Children list per-project plans.
  const [plansExpanded, setPlansExpanded] = useState(false)
  // Each project under Plans is itself expandable to reveal its
  // sub-views (Vision, Pipeline, Deferred Audit, Deviations). Stored as
  // a Set so toggling stays simple; persistence is deferred to commit 5.
  const [expandedProjects, setExpandedProjects] = useState<Set<string>>(new Set())
  const toggleProject = (key: string) => {
    setExpandedProjects((prev) => {
      const next = new Set(prev)
      if (next.has(key)) next.delete(key); else next.add(key)
      return next
    })
  }

  const handleViewSelectChange = (newView: DashboardView) => {
    openOrFocusTab(newView as TabId)
    if (newView === 'plan') setPlansExpanded((prev) => !prev)
  }

  // Data freshness tracking
  const freshness = useDataFreshness(sessions)

  return (
    <Box sx={{ display: 'flex', flexDirection: 'column', height: '100vh', bgcolor: 'background.default' }}>
      {/* Top bar spans full width above sidebar — VS Code title-bar pattern.
          Commit 3 cleanup: removed the duplicate 'Dashboard' label from the
          sidebar (the title bar already says 'Execution Graph Dashboard'). */}
      <Box
        component="header"
        data-testid="wf-title-bar"
        sx={{
          px: { xs: 1.5, sm: 2, md: 3 },
          height: '36px',
          borderBottom: '1px solid',
          /* Title-bar chrome is brand-locked per handoff §App Chrome
             "Title bar": ink background + steel hairline. Mode-agnostic
             — the brand IS dark even when the rest of the app is in
             light mode, so the wf.* tokens have the same value across
             palettes. */
          borderColor: 'wf.steel',
          display: 'flex',
          alignItems: 'center',
          bgcolor: 'wf.ink',
          color: 'wf.bone',
          gap: 1.5,
          flexShrink: 0,
        }}
      >
        {/* Watchfloor brand lockup — handoff §App Chrome "Title bar":
            18px radar mark + 'watchfloor' wordmark (Geist Mono 14/500),
            10px gap. Stays static (no sweep) in chrome lockups; the
            sweep belongs to the LIVE pill on the right. */}
        <Box sx={{ display: 'flex', alignItems: 'center', gap: '10px', flexShrink: 0 }}>
          <RadarMark size={18} />
          <Typography
            sx={{
              fontFamily: '"Geist Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
              fontSize: '14px',
              fontWeight: 500,
              letterSpacing: '-0.005em',
              lineHeight: 1,
            }}
          >
            watchfloor
          </Typography>
        </Box>
        <Box sx={{ flexGrow: 1 }} />
        <LiveBadge />
        {isMobile && (
          <Select
            size="small"
            value={view}
            onChange={(e) => handleViewSelectChange(e.target.value as DashboardView)}
            aria-label="Dashboard view (mobile)"
            sx={{ fontSize: '0.75rem', minHeight: 28 }}
          >
            {VIEW_OPTIONS.map((opt) => (
              <MenuItem key={opt.value} value={opt.value} sx={{ fontSize: '0.75rem' }}>
                {opt.label}
              </MenuItem>
            ))}
          </Select>
        )}
        <DataFreshnessChip lastFetchTime={freshness.lastFetchTime} isTabVisible={freshness.isTabVisible} />
        <Tooltip title={mode === 'dark' ? 'Light mode' : 'Dark mode'}>
          <IconButton
            size="small"
            onClick={() => setMode(mode === 'dark' ? 'light' : 'dark')}
            aria-label="Toggle dark mode"
            sx={{ color: 'wf.fog', p: 0.5, '&:hover': { color: 'wf.bone' } }}
          >
            {mode === 'dark' ? <LightModeIcon sx={{ fontSize: 18 }} /> : <DarkModeIcon sx={{ fontSize: 18 }} />}
          </IconButton>
        </Tooltip>
      </Box>

      {/* Below header: sidebar + main content row */}
      <Box sx={{ display: 'flex', flexDirection: 'row', flex: 1, minHeight: 0 }}>
      <Box
        component="nav"
        aria-label="Dashboard navigation"
        data-testid="wf-sidebar"
        sx={{
          width: 300,
          flexShrink: 0,
          borderRight: '1px solid',
          /* Sidebar joins the title bar and tab strip in the brand
             chrome layer per handoff §App Chrome. ink bg + steel
             hairline matches the rows above so the whole left edge
             of the app reads as one continuous chrome surface. */
          borderColor: 'wf.steel',
          bgcolor: 'wf.ink',
          color: 'wf.bone',
          display: 'flex',
          flexDirection: 'column',
          gap: 1,
          p: 1.5,
          overflowY: 'auto',
        }}
      >
        <Box
          role="group"
          aria-label="Dashboard view"
          sx={{ display: 'flex', flexDirection: 'column' }}
        >
          <SidebarSectionHeader label="GLOBAL" />
          {VIEW_OPTIONS.map((opt) => {
            const iconType = APP_ICON_FOR_VIEW[opt.value]
            const isActive = view === opt.value
            const isPlans = opt.value === 'plan'
            return (
              <React.Fragment key={opt.value}>
                <Box
                  component="button"
                  type="button"
                  aria-pressed={isPlans ? undefined : isActive}
                  aria-expanded={isPlans ? plansExpanded : undefined}
                  onClick={() => {
                    openOrFocusTab(opt.value)
                    if (isPlans) setPlansExpanded((prev) => !prev)
                  }}
                  sx={{
                    display: 'flex', alignItems: 'center', gap: 1,
                    width: '100%',
                    py: 0.5, pl: 1, pr: 0.75,
                    /* Active item per handoff §Three-Tier Left Rail
                       "Item styling": tinted signal-blue surface + 2px
                       signal-blue left border. Inactive items inherit
                       the sidebar's default fog text. */
                    border: 'none',
                    borderLeft: '2px solid',
                    borderLeftColor: isActive ? 'wf.signal' : 'transparent',
                    bgcolor: isActive ? 'rgba(59,158,255,0.12)' : 'transparent',
                    color: isActive ? 'wf.bone' : 'wf.fog',
                    fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
                    fontSize: '12px',
                    textAlign: 'left',
                    cursor: 'pointer',
                    '&:hover': { bgcolor: isActive ? 'rgba(59,158,255,0.12)' : 'rgba(255,255,255,0.04)', color: 'wf.bone' },
                  }}
                >
                  {iconType ? (
                    <AppIcon type={iconType} size={16} active={isActive} />
                  ) : (
                    /* grinder + workspaces fall back to MUI Build/Workspaces
                       until brand icons exist for them. */
                    <BuildOutlinedIcon sx={{ fontSize: 16, color: 'inherit' }} />
                  )}
                  <Box sx={{ flex: 1 }}>{opt.label}</Box>
                  {isPlans && (
                    <ChevronRightIcon
                      sx={{
                        fontSize: 14,
                        transform: plansExpanded ? 'rotate(90deg)' : 'none',
                        transition: 'transform 0.15s',
                        color: 'inherit',
                      }}
                    />
                  )}
                </Box>
                {isPlans && (
                  <Collapse in={plansExpanded} timeout="auto" unmountOnExit>
                    <Box sx={{ display: 'flex', flexDirection: 'column' }}>
                      {(projects ?? []).map((p) => {
                        // DSH-18 (BACKLOG #55) — multiple plans can share
                        // path (one repo, two plans). Use plan_dir for
                        // per-plan uniqueness; fall back to a composite
                        // when plan_dir is absent so render-stability is
                        // preserved across re-fetches.
                        const projectKey =
                          p.plan_dir ?? `${p.path ?? ''}::${p.project}`
                        const isExpanded = expandedProjects.has(projectKey)
                        return (
                          <React.Fragment key={projectKey}>
                            <Box
                              component="button"
                              type="button"
                              aria-expanded={isExpanded}
                              onClick={() => {
                                // Project row: open this project's
                                // Pipeline tab AND toggle expansion.
                                // Single-project view, distinct from
                                // the 'All plans' aggregate tab above.
                                openOrFocusTab(`project:${p.project}/pipeline` as TabId)
                                toggleProject(projectKey)
                              }}
                              sx={{
                                display: 'flex', alignItems: 'center', gap: 1,
                                width: '100%',
                                py: 0.25, pl: 3.5, pr: 1,
                                border: 'none',
                                bgcolor: 'transparent',
                                color: 'wf.fog',
                                fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
                                fontSize: '12px',
                                textAlign: 'left',
                                cursor: 'pointer',
                                '&:hover': { color: 'wf.bone', bgcolor: 'rgba(255,255,255,0.04)' },
                              }}
                            >
                              <ChevronRightIcon
                                sx={{
                                  fontSize: 12,
                                  transform: isExpanded ? 'rotate(90deg)' : 'none',
                                  transition: 'transform 0.15s',
                                  color: 'inherit',
                                }}
                              />
                              <Box sx={{ flex: 1 }}>{p.project}</Box>
                            </Box>
                            <Collapse in={isExpanded} timeout="auto" unmountOnExit>
                              <Box sx={{ display: 'flex', flexDirection: 'column' }}>
                                {PROJECT_SUBVIEWS.map((sv) => (
                                  <Box
                                    key={sv.label}
                                    component="button"
                                    type="button"
                                    onClick={() => openOrFocusTab(`project:${p.project}/${PROJECT_SUBVIEW_KEYS[sv.label]}` as TabId)}
                                    sx={{
                                      display: 'flex', alignItems: 'center', gap: 1,
                                      width: '100%',
                                      py: 0.25, pl: 6.5, pr: 1,
                                      border: 'none',
                                      bgcolor: 'transparent',
                                      color: 'wf.fog',
                                      fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
                                      fontSize: '12px',
                                      textAlign: 'left',
                                      cursor: 'pointer',
                                      '&:hover': { color: 'wf.bone', bgcolor: 'rgba(255,255,255,0.04)' },
                                    }}
                                  >
                                    <AppIcon type={sv.iconType} size={12} />
                                    {sv.label}
                                  </Box>
                                ))}
                              </Box>
                            </Collapse>
                          </React.Fragment>
                        )
                      })}
                    </Box>
                  </Collapse>
                )}
              </React.Fragment>
            )
          })}

          {/* Activity sections — Active Sessions / Plans / Features /
              Grinders — at the bottom of the left sidebar per
              operator's original sketch. Surfaces live runtime state
              alongside the navigation column rather than competing
              with main content for horizontal space.

              User-request 2026-05-08: clicking an Active Feature row
              switches to the Features tab; clicking an Active Plan
              row switches to the Plans tab. Sessions and Grinders
              rows stay informational. */}
          <ActivityRail
            onSelectFeature={() => openOrFocusTab('features')}
            onSelectPlan={(project) => {
              /* User-request 2026-05-08 (revision): each Active Plan
                 row opens its own Pipeline tab via the project sub-view
                 mechanism (same path as clicking a project row in the
                 Plans tree). Falls back to the generic Plans view when
                 the autopilot session has no project attached. */
              if (project) {
                openOrFocusTab(`project:${project}/pipeline` as TabId)
              } else {
                openOrFocusTab('plan')
              }
            }}
          />
        </Box>
      </Box>

      {/* Right side — tablist + main content stack vertically */}
      <Box sx={{ display: 'flex', flexDirection: 'column', flex: 1, minWidth: 0 }}>
      {/* Tab bar — VS Code lineage per handoff §UI Primitives "Top tabs"
          and §App Chrome "Tab bar". 30-34px row on wf.ink, separators in
          wf.steel. Active tab raises onto wf.carbon (one notch lighter
          than the strip itself) with a 2px wf.signal top border so the
          live view reads at a glance. */}
      <Box
        role="tablist"
        aria-label="Open views"
        data-testid="wf-tab-strip"
        sx={{
          display: 'flex',
          alignItems: 'stretch',
          bgcolor: 'wf.ink',
          borderBottom: '1px solid',
          borderColor: 'wf.steel',
          flexShrink: 0,
          overflowX: 'auto',
          minHeight: 34,
        }}
      >
        {openTabs.map((tabId) => {
          const isActive = tabId === activeTab
          const label = labelForTab(tabId, VIEW_OPTIONS)
          return (
            <Box
              key={tabId}
              role="tab"
              aria-selected={isActive}
              tabIndex={isActive ? 0 : -1}
              onClick={() => setActiveTab(tabId)}
              sx={{
                display: 'flex',
                alignItems: 'center',
                gap: 0.75,
                pl: 1.5,
                pr: 0.5,
                cursor: 'pointer',
                bgcolor: isActive ? 'wf.carbon' : 'transparent',
                borderRight: '1px solid',
                borderColor: 'wf.steel',
                borderTop: '2px solid transparent',
                borderTopColor: isActive ? 'wf.signal' : 'transparent',
                '&:hover': isActive ? {} : { bgcolor: 'rgba(255,255,255,0.04)' },
                userSelect: 'none',
              }}
            >
              <Typography
                variant="caption"
                sx={{
                  fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
                  fontSize: '11px',
                  color: isActive ? 'wf.bone' : 'wf.fog',
                  whiteSpace: 'nowrap',
                }}
              >
                {label}
              </Typography>
              <IconButton
                size="small"
                aria-label={`Close ${label} tab`}
                onClick={(e) => {
                  e.stopPropagation()
                  closeTab(tabId)
                }}
                sx={{ p: 0.25, color: 'wf.fog', opacity: 0.4, '&:hover': { color: 'wf.bone', opacity: 1 } }}
              >
                <CloseIcon sx={{ fontSize: 14 }} />
              </IconButton>
            </Box>
          )
        })}
      </Box>

      {isFeatureTab(view) && (
        <Box component="main" sx={{ flex: 1, minHeight: 0, overflow: 'auto' }}>
          <FeatureTabView featureKey={featureKeyFromTab(view)} />
        </Box>
      )}

      {isProjectSubviewTab(view) && (
        <Box component="main" sx={{ flex: 1, minHeight: 0, overflow: 'auto' }}>
          {(() => {
            const parsed = parseProjectSubviewTab(view)
            if (!parsed) return null
            return <ProjectSubviewTab projectId={parsed.projectId} subview={parsed.subview} />
          })()}
        </Box>
      )}

      {view === 'overview' && (
        <Box component="main" sx={{ flex: 1, minHeight: 0, overflow: 'auto' }}>
          <Suspense fallback={<Skeleton variant="rectangular" height={400} sx={{ m: 3, borderRadius: 1 }} />}>
            <OverviewView />
          </Suspense>
        </Box>
      )}

      {view === 'plan' && (
        /* Plan view: just the projects stack — active sessions live
           in the global ActivityRail on the right of the shell now. */
        <HoverLinkProvider>
        <Box
          component="main"
          sx={{
            flex: 1,
            minHeight: 0,
            overflow: 'hidden',
            display: 'flex',
            flexDirection: 'column',
          }}
        >
          <Box
            data-testid="plans-scroll-container"
            sx={{
              flex: 1,
              minWidth: 0,
              minHeight: 0,
              px: { xs: 1.5, sm: 2, md: 3 },
              py: { xs: 1.5, md: 2 },
              overflowY: 'auto',
            }}
            /* audit-list-filters #2 — disable browser scroll-anchoring so a
               Plans sort-mode change doesn't cause the viewport to jump
               when the list re-orders below. Inline style (sx applies
               emotion classes that jsdom can't introspect, blocking
               regression tests). */
            style={{ overflowAnchor: 'none' }}
          >
            {projectsLoading && (
              <Box>
                <Skeleton variant="rectangular" height={48} sx={{ mb: 1.5, borderRadius: 1 }} />
                <Skeleton variant="rectangular" height={36} sx={{ mb: 1.5, borderRadius: 1 }} />
                <Skeleton variant="rectangular" height={120} sx={{ borderRadius: 1 }} />
              </Box>
            )}
            {!projectsLoading && (!projects || projects.length === 0) && (
              <EmptyScope subtitle="run /plan-project in a project to generate an execution plan" />
            )}
            {!projectsLoading && projects && projects.length > 0 && (
              <>
                <PlansFilterBar
                  lifecycle={planLifecycle}
                  project={planProject}
                  search={planSearch}
                  sort={planSort}
                  chipNames={planChipNames}
                  setLifecycle={setPlanLifecycle}
                  setProject={setPlanProject}
                  setSearch={setPlanSearch}
                  setSort={setPlanSort}
                  visibleCount={filteredAndSortedProjects.length}
                />
                {filteredAndSortedProjects.length === 0 ? (
                  <EmptyScope
                    title="No plans match"
                    subtitle={buildEmptyStateSubtitle(planLifecycle)}
                  />
                ) : (
                  <Box sx={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
                    {filteredAndSortedProjects.map((p) => {
                      /* feature-plan-link-and-nav (REQ-8, EC-11) — wrapper
                         Box carries the `data-plan-dir` anchor used by the
                         handler's `querySelector` lookup. Placed OUTSIDE
                         ProjectPanel so the attribute is present in both
                         the panel's loading-skeleton and ready branches
                         without reaching into the component's internals. */
                      const anchor = p.plan_dir ?? p.path
                      return (
                        <Box key={anchor} data-plan-dir={anchor}>
                          <ProjectPanel
                            project={p}
                            sessions={sessions}
                            onOpenOutput={() =>
                              openOrFocusTab(`project:${p.project}/pipeline` as TabId)
                            }
                          />
                        </Box>
                      )
                    })}
                  </Box>
                )}
              </>
            )}
          </Box>
        </Box>
        </HoverLinkProvider>
      )}

      {view === 'features' && (
        /* Features view (unified features + autopilot) */
        <Suspense fallback={
          <Box sx={{ p: 3 }}>
            <Skeleton variant="rectangular" height={48} sx={{ mb: 1.5, borderRadius: 1 }} />
            <Skeleton variant="rectangular" height={200} sx={{ borderRadius: 1 }} />
          </Box>
        }>
          <FeaturesView onNavigateToPlan={handleNavigateToPlan} />
        </Suspense>
      )}

      {view === 'metrics' && (
        /* Metrics view */
        <Box component="main" sx={{ flex: 1, minHeight: 0, overflow: 'hidden' }}>
          <Suspense fallback={
            <Box sx={{ p: 3 }}>
              <Skeleton variant="rectangular" height={48} sx={{ mb: 1.5, borderRadius: 1 }} />
              <Skeleton variant="rectangular" height={200} sx={{ borderRadius: 1 }} />
            </Box>
          }>
            <MetricsView />
          </Suspense>
        </Box>
      )}

      {view === 'grinder' && (
        /* Grinder view */
        <Box component="main" sx={{ flex: 1, minHeight: 0, overflow: 'hidden', display: 'flex', flexDirection: 'column' }}>
          <Suspense fallback={
            <Box sx={{ p: 3 }}>
              <Skeleton variant="rectangular" height={48} sx={{ mb: 1.5, borderRadius: 1 }} />
              <Skeleton variant="rectangular" height={200} sx={{ borderRadius: 1 }} />
            </Box>
          }>
            <GrinderView />
          </Suspense>
        </Box>
      )}

      </Box>
      </Box>
    </Box>
  )
}
