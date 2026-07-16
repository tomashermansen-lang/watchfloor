import { useMemo, useState } from 'react'
import Box from '@mui/material/Box'
import MenuItem from '@mui/material/MenuItem'
import Select from '@mui/material/Select'
import ToggleButton from '@mui/material/ToggleButton'
import ToggleButtonGroup from '@mui/material/ToggleButtonGroup'
import Typography from '@mui/material/Typography'
import { useAutopilots } from '../../hooks/useAutopilots'
import { useFeatures } from '../../hooks/useFeatures'
import type { AutopilotSession } from '../../types'

/* Run Economy view — autopilot run aggregates (tokens, cost, duration,
   turns) across all features. Sub-view of MetricsView, distinct from
   the Activity tab which surfaces hook-driven session observability.

   Slice 1: KPI strip + by-feature ranked list (default sort cost desc).
   Later slices add by-phase aggregates, estimate-vs-actual joining
   (via /api/plans), and filter/group-by UX.

   Aggregation runs client-side from /api/autopilots which already
   carries phase-level token + duration + turn data per session
   (audit-23 #5 backend). For ~50-150 features the computation is
   cheap enough to recompute on each render via useMemo. */

interface FeatureAggregate {
  task: string
  project: string | null
  upstream: number
  output: number
  newTokens: number
  cacheRate: number | null
  cost: number
  duration_s: number
  turns: number
  /* wall_clock_s = max(ended_at) - min(started_at) across phases.
     null when no phase has timestamps yet (older sessions, log-derived). */
  wallClockSec: number | null
  /* idle = wall_clock - sum(duration_s). null when wall_clock is null. */
  idleSec: number | null
  /* Plan task estimate (in hours), joined client-side from the
     /api/features payload's `plan_task_estimate_hours`. null when the
     feature is standalone or its plan task lacks duration_hours. */
  estimateHours: number | null
  /* Absolute path to the parent plan dir (basename used as group key
     for the by-plan view). null for standalone features. */
  planDir: string | null
  /* Human-readable plan name extracted from the plan_dir basename
     (e.g. "INPROGRESS_Plan_watchfloor" -> "watchfloor"). null when
     standalone. */
  planName: string | null
}

/* Strip the lifecycle prefix from a plan dir basename so the group
   header reads as a stable name across lifecycle transitions
   (INPROGRESS_Plan_X -> DONE_Plan_X stays "X"). */
function planNameFromDir(planDir: string | null): string | null {
  if (planDir == null) return null
  const base = planDir.split('/').filter(Boolean).pop() ?? ''
  return base.replace(/^(INPROGRESS|DONE|PENDING)_Plan_/, '') || null
}

interface PhaseAggregate {
  /* Phase name as it appears in the autopilot stream (e.g., "BA",
     "Implement", "Team Review"). Phase names are normalized backend-
     side so the same canonical labels appear across all features. */
  name: string
  /* How many features include this phase. Useful context: a phase that
     appears in 47/50 features is the load-bearing path; one in 2/50 is
     a corner case. */
  featureCount: number
  /* Averages across all instances of this phase (one per feature). Null
     when no instance carried the metric — e.g. avgCacheRate is null
     when no instance had usage data. */
  avgCost: number
  avgDurationSec: number
  avgTurns: number
  avgUpstream: number
  avgOutput: number
  avgNewTokens: number
  avgCacheRate: number | null
}

interface RunEconomyAggregate {
  featureCount: number
  totalUpstream: number
  totalOutput: number
  totalNewTokens: number
  totalCacheRate: number | null
  totalCost: number
  totalDuration: number
  totalTurns: number
  /* Sum of idleSec across features that have it; null if no feature does. */
  totalIdleSec: number | null
  /* Number of features that contributed to totalIdleSec — used for avg. */
  idleFeatureCount: number
  byFeature: FeatureAggregate[]
  byPhase: PhaseAggregate[]
}

interface FeaturePlanLink {
  estimateHours: number | null
  planDir: string | null
}

function aggregateSession(
  session: AutopilotSession,
  planLinkLookup: Map<string, FeaturePlanLink>,
): FeatureAggregate {
  let upstream = 0
  let output = 0
  let cacheRead = 0
  let newTokens = 0
  let cost = 0
  let duration_s = 0
  let turns = 0
  let earliestStart: number | null = null
  let latestEnd: number | null = null
  for (const p of session.phases) {
    const i = p.input_tokens ?? 0
    const c = p.cache_creation_tokens ?? 0
    const r = p.cache_read_tokens ?? 0
    upstream += i + c + r
    cacheRead += r
    newTokens += i + c
    output += p.output_tokens ?? 0
    cost += p.cost ?? 0
    duration_s += p.duration_s ?? 0
    turns += p.num_turns ?? 0
    if (p.started_at) {
      const t = new Date(p.started_at).getTime()
      if (!Number.isNaN(t) && (earliestStart == null || t < earliestStart)) earliestStart = t
    }
    if (p.ended_at) {
      const t = new Date(p.ended_at).getTime()
      if (!Number.isNaN(t) && (latestEnd == null || t > latestEnd)) latestEnd = t
    }
  }
  // Wall-clock + idle only when BOTH endpoints exist. Live sessions
  // (some phase without ended_at) skip wall-clock — would need a ticker
  // to stay accurate.
  const allEnded = session.phases.every((p) => p.ended_at != null)
  const wallClockSec = earliestStart != null && latestEnd != null && allEnded
    ? Math.floor((latestEnd - earliestStart) / 1000)
    : null
  const idleSec = wallClockSec != null && duration_s > 0
    ? Math.max(0, wallClockSec - duration_s)
    : null
  const link = planLinkLookup.get(session.task) ?? { estimateHours: null, planDir: null }
  return {
    task: session.task,
    project: session.project,
    upstream,
    output,
    newTokens,
    cacheRate: upstream > 0 ? cacheRead / upstream : null,
    cost,
    duration_s,
    turns,
    wallClockSec,
    idleSec,
    estimateHours: link.estimateHours,
    planDir: link.planDir,
    planName: planNameFromDir(link.planDir),
  }
}

/* Combine N partial aggregates that all share the same `task` (i.e. multiple
   sessions for the same feature: retries, paused-and-resumed, etc.) into a
   single aggregate. Each numeric field sums; cacheRate is recomputed from
   the summed read-vs-upstream so it stays a true cumulative rate rather
   than an average-of-averages. wallClock + idle are summed across sessions
   when both contribute (per-session wall-clock is intra-session; the cross-
   session sum approximates "total wall time spent on the feature"). */
function combineFeatureAggregates(parts: FeatureAggregate[]): FeatureAggregate {
  if (parts.length === 1) return parts[0]
  const first = parts[0]
  let upstream = 0, output = 0, newTokens = 0, cost = 0, duration_s = 0, turns = 0
  let cacheReadAccum = 0
  let wallSum = 0
  let wallCount = 0
  let idleSum = 0
  let idleCount = 0
  for (const p of parts) {
    upstream += p.upstream
    output += p.output
    newTokens += p.newTokens
    cost += p.cost
    duration_s += p.duration_s
    turns += p.turns
    if (p.cacheRate != null) cacheReadAccum += p.upstream * p.cacheRate
    if (p.wallClockSec != null) {
      wallSum += p.wallClockSec
      wallCount += 1
    }
    if (p.idleSec != null) {
      idleSum += p.idleSec
      idleCount += 1
    }
  }
  return {
    task: first.task,
    project: first.project,
    upstream,
    output,
    newTokens,
    cacheRate: upstream > 0 ? cacheReadAccum / upstream : null,
    cost,
    duration_s,
    turns,
    wallClockSec: wallCount > 0 ? wallSum : null,
    idleSec: idleCount > 0 ? idleSum : null,
    // Estimate is per-task and stable across retries — take the first
    // session's lookup result; combine doesn't need to merge.
    estimateHours: first.estimateHours,
    planDir: first.planDir,
    planName: first.planName,
  }
}

/* Walk every phase across every session and group by phase name so
   averages can be computed cross-feature. Each phase instance contributes
   one data point regardless of which feature it came from; if a phase
   ran multiple times in the same feature (rare) it still counts as
   distinct samples — avg-by-phase is "what does this phase typically
   cost when it runs", not "per-feature aggregate".

   featureCount counts unique feature names that include the phase, so
   "47 features include implement" is meaningful even if a few of those
   have multiple Implement runs. */
function aggregateByPhase(sessions: AutopilotSession[]): PhaseAggregate[] {
  interface Bucket {
    cost: number; costN: number
    duration: number; durationN: number
    turns: number; turnsN: number
    upstream: number; upstreamN: number
    output: number; outputN: number
    newTokens: number; newTokensN: number
    cacheReadAccum: number; cacheUpstreamAccum: number
    features: Set<string>
  }
  const buckets = new Map<string, Bucket>()
  const fresh = (): Bucket => ({
    cost: 0, costN: 0, duration: 0, durationN: 0, turns: 0, turnsN: 0,
    upstream: 0, upstreamN: 0, output: 0, outputN: 0,
    newTokens: 0, newTokensN: 0, cacheReadAccum: 0, cacheUpstreamAccum: 0,
    features: new Set(),
  })
  for (const session of sessions) {
    for (const p of session.phases) {
      const b = buckets.get(p.name) ?? fresh()
      b.features.add(session.task)
      if (p.cost != null) { b.cost += p.cost; b.costN += 1 }
      if (p.duration_s != null) { b.duration += p.duration_s; b.durationN += 1 }
      if (p.num_turns != null) { b.turns += p.num_turns; b.turnsN += 1 }
      const i = p.input_tokens ?? 0
      const c = p.cache_creation_tokens ?? 0
      const r = p.cache_read_tokens ?? 0
      if (p.input_tokens != null || p.cache_creation_tokens != null || p.cache_read_tokens != null) {
        b.upstream += i + c + r
        b.upstreamN += 1
        b.newTokens += i + c
        b.newTokensN += 1
        b.cacheReadAccum += r
        b.cacheUpstreamAccum += i + c + r
      }
      if (p.output_tokens != null) { b.output += p.output_tokens; b.outputN += 1 }
      buckets.set(p.name, b)
    }
  }
  const result: PhaseAggregate[] = []
  for (const [name, b] of buckets) {
    result.push({
      name,
      featureCount: b.features.size,
      avgCost: b.costN > 0 ? b.cost / b.costN : 0,
      avgDurationSec: b.durationN > 0 ? b.duration / b.durationN : 0,
      avgTurns: b.turnsN > 0 ? b.turns / b.turnsN : 0,
      avgUpstream: b.upstreamN > 0 ? b.upstream / b.upstreamN : 0,
      avgOutput: b.outputN > 0 ? b.output / b.outputN : 0,
      avgNewTokens: b.newTokensN > 0 ? b.newTokens / b.newTokensN : 0,
      avgCacheRate: b.cacheUpstreamAccum > 0 ? b.cacheReadAccum / b.cacheUpstreamAccum : null,
    })
  }
  // No internal sort — consumer applies user-controlled sort (slice 4a).
  return result
}

function aggregate(
  sessions: AutopilotSession[],
  planLinkLookup: Map<string, FeaturePlanLink>,
): RunEconomyAggregate {
  // Group sessions by task so each feature appears exactly once even if it
  // has multiple autopilot runs (retries, paused-resumed). Without this
  // dedupe, /api/autopilots' one-row-per-session shape produced visible
  // duplicates in the feature list.
  const sessionAggregates = sessions.map((s) => aggregateSession(s, planLinkLookup))
  const grouped = new Map<string, FeatureAggregate[]>()
  for (const a of sessionAggregates) {
    const list = grouped.get(a.task) ?? []
    list.push(a)
    grouped.set(a.task, list)
  }
  const byFeature = Array.from(grouped.values()).map(combineFeatureAggregates)
  const byPhase = aggregateByPhase(sessions)
  const featureCount = byFeature.length
  const totalUpstream = byFeature.reduce((acc, f) => acc + f.upstream, 0)
  const totalOutput = byFeature.reduce((acc, f) => acc + f.output, 0)
  const totalNewTokens = byFeature.reduce((acc, f) => acc + f.newTokens, 0)
  const totalCacheRead = byFeature.reduce((acc, f) =>
    acc + (f.upstream * (f.cacheRate ?? 0)), 0)
  const totalCacheRate = totalUpstream > 0 ? totalCacheRead / totalUpstream : null
  const totalCost = byFeature.reduce((acc, f) => acc + f.cost, 0)
  const totalDuration = byFeature.reduce((acc, f) => acc + f.duration_s, 0)
  const totalTurns = byFeature.reduce((acc, f) => acc + f.turns, 0)
  // Idle only summed across features where it could be computed.
  const idleFeatures = byFeature.filter((f) => f.idleSec != null)
  const totalIdleSec = idleFeatures.length > 0
    ? idleFeatures.reduce((acc, f) => acc + (f.idleSec ?? 0), 0)
    : null
  // byFeature returned in raw collection order; the consumer applies
  // the user-controlled sort (slice 4a).
  return {
    featureCount,
    totalUpstream,
    totalOutput,
    totalNewTokens,
    totalCacheRate,
    totalCost,
    totalDuration,
    totalTurns,
    totalIdleSec,
    idleFeatureCount: idleFeatures.length,
    byFeature,
    byPhase,
  }
}

function formatTokens(n: number): string {
  if (n < 1000) return String(n)
  if (n < 1_000_000) return `${(n / 1000).toFixed(1)}k`
  return `${(n / 1_000_000).toFixed(1)}M`
}

function formatDuration(seconds: number): string {
  if (seconds === 0) return '—'
  const h = Math.floor(seconds / 3600)
  const m = Math.floor((seconds % 3600) / 60)
  if (h > 0) return `${h}h ${m}m`
  return `${m}m`
}

function formatCost(c: number): string {
  return `$${c.toFixed(2)}`
}

/* Cache-tier classifier — drives the color of the cache-rate label in
   feature + phase rows. Thresholds tuned for AGGREGATES (averages
   across many features), not single phase instances:

     >=95% : good — paying ~12% of list price, healthy
     90-94%: neutral — typical, no action needed
     <90%  : bad — systematic inefficiency, this phase type ate fresh
             context across multiple features

   Sidebar (per-phase per-feature) uses a looser <85% threshold because
   a single phase instance has wider variance; an average dips below
   90% only with systematic problems, so 90% is the right alarm bar.

   Returns null when cache rate is unknown (no upstream data). */
type CacheTier = 'good' | 'neutral' | 'bad'

function cacheTier(rate: number | null): CacheTier | null {
  if (rate == null) return null
  if (rate >= 0.95) return 'good'
  if (rate < 0.90) return 'bad'
  return 'neutral'
}

const CACHE_TIER_COLOR: Record<CacheTier, string> = {
  good: 'var(--mui-palette-status-done)',
  neutral: 'var(--mui-palette-wf-fog)',
  bad: 'var(--mui-palette-status-stalled)',
}

/* Estimate-tier classifier — drives the color of the est→actual delta:
     under (-5% or more)   : green (status-done) — beat the estimate
     on    (within +/-5%)  : neutral (wf.bone) — accurate planning
     drift (5-20% over)    : orange (stalled) — slipping
     over  (>20% over)     : red (failed) — significant blow-up
   Returns null when no estimate is linked (standalone features). */
type EstimateTier = 'under' | 'on' | 'drift' | 'over'

function estimateTier(actualSec: number, estimateHours: number | null): EstimateTier | null {
  if (estimateHours == null || estimateHours <= 0) return null
  const delta = (actualSec - estimateHours * 3600) / (estimateHours * 3600)
  if (delta <= -0.05) return 'under'
  if (delta > 0.20) return 'over'
  if (delta > 0.05) return 'drift'
  return 'on'
}

const ESTIMATE_TIER_COLOR: Record<EstimateTier, string> = {
  under: 'var(--mui-palette-status-done)',
  on: 'var(--mui-palette-wf-bone)',
  drift: 'var(--mui-palette-status-stalled)',
  over: 'var(--mui-palette-status-failed)',
}

/* Slice 4a — column sort state. SortColumn corresponds 1:1 with the
   visible by-feature columns; the special `name` value sorts on the
   feature task string. Direction starts desc on every column flip
   (the operator usually wants "biggest first" when picking a metric)
   and only flips to asc on a second click of the same column. */
type SortColumn = 'name' | 'cost' | 'duration' | 'turns' | 'upstream' | 'output' | 'idle' | 'estimate'
type PhaseSortColumn = 'name' | 'count' | 'cost' | 'duration' | 'turns' | 'upstream' | 'output'
type SortDir = 'asc' | 'desc'

function sortPhases(phases: PhaseAggregate[], column: PhaseSortColumn, dir: SortDir): PhaseAggregate[] {
  const key = (p: PhaseAggregate): number | string => {
    switch (column) {
      case 'name': return p.name.toLowerCase()
      case 'count': return p.featureCount
      case 'cost': return p.avgCost
      case 'duration': return p.avgDurationSec
      case 'turns': return p.avgTurns
      case 'upstream': return p.avgUpstream
      case 'output': return p.avgOutput
    }
  }
  const copy = [...phases]
  copy.sort((a, b) => {
    const ka = key(a)
    const kb = key(b)
    if (typeof ka === 'string' && typeof kb === 'string') {
      return dir === 'asc' ? ka.localeCompare(kb) : kb.localeCompare(ka)
    }
    return dir === 'asc' ? (ka as number) - (kb as number) : (kb as number) - (ka as number)
  })
  return copy
}

/* Slice 4c — period filter. Bounded windows compare against
   `now - hours`. "all" disables the filter entirely. */
type Period = '24h' | '7d' | '30d' | 'all'
const PERIOD_HOURS: Record<Exclude<Period, 'all'>, number> = {
  '24h': 24,
  '7d': 24 * 7,
  '30d': 24 * 30,
}

/* Earliest started_at across the session's phases — milliseconds since
   epoch, or null if no phase has a parseable timestamp. */
function sessionStartMs(s: AutopilotSession): number | null {
  let earliest: number | null = null
  for (const p of s.phases) {
    if (!p.started_at) continue
    const t = new Date(p.started_at).getTime()
    if (Number.isNaN(t)) continue
    if (earliest == null || t < earliest) earliest = t
  }
  return earliest
}

function sortFeatures(features: FeatureAggregate[], column: SortColumn, dir: SortDir): FeatureAggregate[] {
  /* Pure key extractor — null/missing values land at the END regardless
     of direction so the operator's eye doesn't have to skip past them. */
  const key = (f: FeatureAggregate): { value: number | string; missing: boolean } => {
    switch (column) {
      case 'name': return { value: f.task.toLowerCase(), missing: false }
      case 'cost': return { value: f.cost, missing: false }
      case 'duration': return { value: f.duration_s, missing: false }
      case 'turns': return { value: f.turns, missing: false }
      case 'upstream': return { value: f.upstream, missing: false }
      case 'output': return { value: f.output, missing: false }
      case 'idle': return { value: f.idleSec ?? 0, missing: f.idleSec == null }
      case 'estimate': {
        if (f.estimateHours == null || f.estimateHours <= 0) return { value: 0, missing: true }
        const delta = (f.duration_s - f.estimateHours * 3600) / (f.estimateHours * 3600)
        return { value: delta, missing: false }
      }
    }
  }
  const copy = [...features]
  copy.sort((a, b) => {
    const ka = key(a)
    const kb = key(b)
    if (ka.missing && !kb.missing) return 1
    if (!ka.missing && kb.missing) return -1
    if (ka.missing && kb.missing) return 0
    if (typeof ka.value === 'string' && typeof kb.value === 'string') {
      return dir === 'asc' ? ka.value.localeCompare(kb.value) : kb.value.localeCompare(ka.value)
    }
    return dir === 'asc' ? (ka.value as number) - (kb.value as number) : (kb.value as number) - (ka.value as number)
  })
  return copy
}

export default function RunEconomy() {
  const { data: sessions } = useAutopilots()
  const { data: features } = useFeatures()
  // Sessions without stream_path have only log-derived data: cost +
  // duration but no token counts, no turns, no per-phase timestamps.
  // Including them produces mixed-cardinality math (some phases
  // counted in cost-avg but not token-avg) - the operator sees
  // skewed numbers. Filter to stream-backed sessions only so every
  // metric shares the same denominator.
  const streamSessions = useMemo(
    () => (sessions ?? []).filter((s) => s.stream_path != null),
    [sessions],
  )
  /* Plan filter — single-select over the unique plan_dir values that
     appear in the feature lookup. "all" is the default; "__standalone__"
     is the sentinel for features without a plan link. Filter applies
     BEFORE aggregation so KPI strip + by-phase + by-feature all reflect
     the same subset. */
  const [planFilter, setPlanFilter] = useState<string>('all')
  const [period, setPeriod] = useState<Period>('all')
  // Build feature.name -> {estimateHours, planDir} lookup for the join.
  // /api/features already populates plan_task_estimate_hours and plan_dir
  // via _apply_plan_link, so a single fetch covers every feature; no
  // per-feature N+1 through /api/plan.
  const planLinkLookup = useMemo(() => {
    const map = new Map<string, FeaturePlanLink>()
    for (const f of features ?? []) {
      const estimateHours = f.plan_task_estimate_hours != null && f.plan_task_estimate_hours > 0
        ? f.plan_task_estimate_hours
        : null
      const planDir = f.plan_dir ?? null
      if (estimateHours != null || planDir != null) {
        map.set(f.name, { estimateHours, planDir })
      }
    }
    return map
  }, [features])
  /* Build the unique-plans list for the dropdown. Sorted alphabetically
     so the menu order is stable regardless of feature ordering. */
  const planOptions = useMemo(() => {
    const seen = new Map<string, string>()  // planDir -> planName
    let hasStandalone = false
    for (const s of streamSessions) {
      const link = planLinkLookup.get(s.task)
      if (link?.planDir) {
        seen.set(link.planDir, planNameFromDir(link.planDir) ?? link.planDir)
      } else {
        hasStandalone = true
      }
    }
    const plans = Array.from(seen.entries())
      .map(([planDir, planName]) => ({ planDir, planName }))
      .sort((a, b) => a.planName.localeCompare(b.planName))
    return { plans, hasStandalone }
  }, [streamSessions, planLinkLookup])

  /* Filter sessions to the selected plan (or standalone) and period
     BEFORE aggregation so the KPI strip + by-phase + by-feature
     surfaces all reflect the same subset. */
  const filteredSessions = useMemo(() => {
    let pool = streamSessions
    if (planFilter !== 'all') {
      if (planFilter === '__standalone__') {
        pool = pool.filter((s) => planLinkLookup.get(s.task)?.planDir == null)
      } else {
        pool = pool.filter((s) => planLinkLookup.get(s.task)?.planDir === planFilter)
      }
    }
    if (period !== 'all') {
      const cutoff = Date.now() - PERIOD_HOURS[period] * 3600_000
      pool = pool.filter((s) => {
        const start = sessionStartMs(s)
        return start != null && start >= cutoff
      })
    }
    return pool
  }, [streamSessions, planLinkLookup, planFilter, period])
  const agg = useMemo(() => aggregate(filteredSessions, planLinkLookup), [filteredSessions, planLinkLookup])
  const [groupMode, setGroupMode] = useState<'flat' | 'plan'>('flat')
  const [sortCol, setSortCol] = useState<SortColumn>('cost')
  const [sortDir, setSortDir] = useState<SortDir>('desc')
  const sortedFeatures = useMemo(
    () => sortFeatures(agg.byFeature, sortCol, sortDir),
    [agg.byFeature, sortCol, sortDir],
  )
  const handleHeaderClick = (col: SortColumn) => {
    if (col === sortCol) {
      setSortDir((d) => (d === 'desc' ? 'asc' : 'desc'))
    } else {
      setSortCol(col)
      setSortDir('desc')
    }
  }
  const [phaseSortCol, setPhaseSortCol] = useState<PhaseSortColumn>('cost')
  const [phaseSortDir, setPhaseSortDir] = useState<SortDir>('desc')
  const sortedPhases = useMemo(
    () => sortPhases(agg.byPhase, phaseSortCol, phaseSortDir),
    [agg.byPhase, phaseSortCol, phaseSortDir],
  )
  const handlePhaseHeaderClick = (col: PhaseSortColumn) => {
    if (col === phaseSortCol) {
      setPhaseSortDir((d) => (d === 'desc' ? 'asc' : 'desc'))
    } else {
      setPhaseSortCol(col)
      setPhaseSortDir('desc')
    }
  }
  const filteredCount = (sessions?.length ?? 0) - streamSessions.length

  if (!sessions) {
    return (
      <Box data-testid="run-economy" sx={{ p: 1 }}>
        <Typography variant="body2" color="text.secondary">
          Loading autopilot runs…
        </Typography>
      </Box>
    )
  }

  if (agg.featureCount === 0) {
    return (
      <Box data-testid="run-economy" sx={{ p: 1 }}>
        <Typography
          data-testid="run-economy-empty-state"
          variant="body2"
          color="text.secondary"
        >
          {sessions.length === 0
            ? 'No autopilot runs yet — kick off an autopilot.sh task and the aggregates will populate here.'
            : `No autopilot runs with stream files yet (${sessions.length} log-only run${sessions.length === 1 ? '' : 's'} skipped — token + turn data needs the NDJSON stream).`}
        </Typography>
      </Box>
    )
  }

  const avgCost = agg.totalCost / agg.featureCount
  const avgUpstream = agg.totalUpstream / agg.featureCount
  const avgOutput = agg.totalOutput / agg.featureCount
  const avgNewTokens = agg.totalNewTokens / agg.featureCount
  const avgDuration = agg.totalDuration / agg.featureCount
  const avgTurns = agg.totalTurns / agg.featureCount
  const avgIdleSec = agg.totalIdleSec != null && agg.idleFeatureCount > 0
    ? agg.totalIdleSec / agg.idleFeatureCount
    : null

  return (
    <Box data-testid="run-economy" sx={{ display: 'flex', flexDirection: 'column', gap: 3 }}>
      {/* Top filter bar — plan dropdown today; date range planned for slice 4c. */}
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 2 }}>
        <Select
          size="small"
          value={planFilter}
          onChange={(e) => setPlanFilter(e.target.value)}
          inputProps={{ 'aria-label': 'Filter by plan' }}
          sx={{
            minWidth: 220,
            borderRadius: 0,
            fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
            fontSize: '11px',
            color: 'wf.bone',
            '& .MuiOutlinedInput-notchedOutline': { borderColor: 'wf.steel' },
            '&:hover .MuiOutlinedInput-notchedOutline': { borderColor: 'wf.signal' },
            '&.Mui-focused .MuiOutlinedInput-notchedOutline': { borderColor: 'wf.signal' },
          }}
          MenuProps={{
            PaperProps: {
              sx: {
                bgcolor: 'wf.ink',
                border: '1px solid',
                borderColor: 'wf.steel',
                borderRadius: 0,
                mt: 0.5,
                '& .MuiMenuItem-root': {
                  fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
                  fontSize: '11px',
                  color: 'wf.bone',
                  '&:hover': { bgcolor: 'rgba(59, 158, 255, 0.08)' },
                  '&.Mui-selected': {
                    bgcolor: 'rgba(59, 158, 255, 0.14)',
                    color: 'wf.signal',
                    '&:hover': { bgcolor: 'rgba(59, 158, 255, 0.18)' },
                  },
                },
              },
            },
          }}
        >
          <MenuItem value="all">All Plans</MenuItem>
          {planOptions.plans.map((p) => (
            <MenuItem key={p.planDir} value={p.planDir}>{p.planName}</MenuItem>
          ))}
          {planOptions.hasStandalone && (
            <MenuItem value="__standalone__">Standalone</MenuItem>
          )}
        </Select>
        <Box sx={{ flex: 1 }} />
        {/* Period toggle — same chrome as the Activity tab time-range
            control so the filter vocabulary stays unified across the
            two metrics sub-views. */}
        <ToggleButtonGroup
          data-testid="run-economy-period-toggle"
          size="small"
          exclusive
          value={period}
          onChange={(_, v: Period | null) => { if (v) setPeriod(v) }}
          aria-label="Filter by period"
          sx={{
            border: '1px solid',
            borderColor: 'wf.steel',
            borderRadius: 0,
            '& .MuiToggleButton-root': {
              fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
              fontSize: '10px',
              fontWeight: 500,
              letterSpacing: '0.08em',
              textTransform: 'uppercase',
              px: 1.25,
              py: 0.5,
              color: 'wf.fog',
              border: 'none',
              borderRadius: 0,
              '&.Mui-selected': {
                bgcolor: 'wf.signal',
                color: 'wf.ink',
                '&:hover': { bgcolor: 'wf.signal' },
              },
              '&:hover': { bgcolor: 'rgba(59, 158, 255, 0.08)' },
            },
          }}
        >
          <ToggleButton value="24h">24h</ToggleButton>
          <ToggleButton value="7d">7d</ToggleButton>
          <ToggleButton value="30d">30d</ToggleButton>
          <ToggleButton value="all">All</ToggleButton>
        </ToggleButtonGroup>
      </Box>
      {filteredCount > 0 && (
        <Typography
          data-testid="run-economy-filter-notice"
          variant="wfCode"
          sx={{ color: 'wf.fog', opacity: 0.7, fontSize: '11px' }}
        >
          {`Showing ${agg.featureCount} stream-backed feature${agg.featureCount === 1 ? '' : 's'} · ${filteredCount} log-only run${filteredCount === 1 ? '' : 's'} skipped (token + turn data needs the NDJSON stream)`}
        </Typography>
      )}
      {/* KPI strip — aggregate totals + averages per feature. Two rows
          of four columns each, matching the brand chrome of the existing
          KpiStrip on the Activity tab (sharp corners, wf.steel hairline
          dividers, JBM mono). */}
      <Box
        data-testid="run-economy-kpi-strip"
        sx={{
          display: 'grid',
          gridTemplateColumns: { xs: '1fr 1fr', md: 'repeat(4, 1fr)' },
          border: '1px solid',
          borderColor: 'wf.steel',
        }}
      >
        <KpiCell label="Tokens"
          primary={`↑ ${formatTokens(agg.totalUpstream)}  ↓ ${formatTokens(agg.totalOutput)}`}
          secondary={[
            agg.totalCacheRate != null ? `${Math.round(agg.totalCacheRate * 100)}% cache` : null,
            `${formatTokens(agg.totalNewTokens)} new`,
          ].filter(Boolean).join(', ')} />
        <KpiCell label="Cost" primary={formatCost(agg.totalCost)} />
        <KpiCell label="Run Time" primary={formatDuration(agg.totalDuration)}
          secondary={agg.totalIdleSec != null && agg.totalIdleSec > 0
            ? `${formatDuration(agg.totalIdleSec)} idle`
            : `${agg.featureCount} features`}
          secondaryTestId="run-economy-total-idle" />
        <KpiCell label="Turns" primary={String(agg.totalTurns)}
          secondary={`${agg.featureCount} features`} />
        <KpiCell label="Avg / Feature"
          primary={`↑ ${formatTokens(avgUpstream)}  ↓ ${formatTokens(avgOutput)}`}
          secondary={[
            agg.totalCacheRate != null ? `${Math.round(agg.totalCacheRate * 100)}% cache` : null,
            `${formatTokens(avgNewTokens)} new`,
          ].filter(Boolean).join(', ')} />
        <KpiCell label="Avg / Feature" primary={formatCost(avgCost)} />
        <KpiCell label="Avg / Feature" primary={formatDuration(avgDuration)}
          secondary={avgIdleSec != null && avgIdleSec > 0
            ? `${formatDuration(avgIdleSec)} idle`
            : null}
          secondaryTestId="run-economy-avg-idle" />
        <KpiCell label="Avg / Feature" primary={String(Math.round(avgTurns))} />
      </Box>

      {/* By-phase aggregate — averages across all features. Answers
          "which phase typically spends the most" so the operator can
          target optimization at the load-bearing stage. Same chrome as
          the by-feature list; sort: avg cost desc. */}
      <Box>
        <Typography variant="wfLabel" sx={{ color: 'wf.fog', mb: 1 }}>
          By Phase  ·  avg across {agg.featureCount} feature{agg.featureCount === 1 ? '' : 's'}
        </Typography>
        <Box
          data-testid="run-economy-by-phase"
          sx={{
            border: '1px solid',
            borderColor: 'wf.steel',
            display: 'grid',
            // 7 cols: Phase | Count | Cost | Duration | Turns | ↑ | ↓
            gridTemplateColumns: '1fr auto auto auto auto auto auto',
            columnGap: 2,
            rowGap: 0.5,
            px: 1.5,
            py: 1,
            fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
            fontSize: '11px',
            fontVariantNumeric: 'tabular-nums',
            color: 'wf.bone',
          }}
        >
          <SortHeader col="name"     align="left"  label="Phase"        activeCol={phaseSortCol} dir={phaseSortDir} onClick={handlePhaseHeaderClick} />
          <SortHeader col="count"    align="right" label="Features"     activeCol={phaseSortCol} dir={phaseSortDir} onClick={handlePhaseHeaderClick} />
          <SortHeader col="cost"     align="right" label="Avg Cost"     activeCol={phaseSortCol} dir={phaseSortDir} onClick={handlePhaseHeaderClick} />
          <SortHeader col="duration" align="right" label="Avg Duration" activeCol={phaseSortCol} dir={phaseSortDir} onClick={handlePhaseHeaderClick} />
          <SortHeader col="turns"    align="right" label="Avg Turns"    activeCol={phaseSortCol} dir={phaseSortDir} onClick={handlePhaseHeaderClick} />
          <SortHeader col="upstream" align="right" label="↑ Up"         activeCol={phaseSortCol} dir={phaseSortDir} onClick={handlePhaseHeaderClick} />
          <SortHeader col="output"   align="right" label="↓ Down"       activeCol={phaseSortCol} dir={phaseSortDir} onClick={handlePhaseHeaderClick} />

          {sortedPhases.map((p) => (
            <PhaseRow key={p.name} p={p} />
          ))}
        </Box>
      </Box>

      {/* By-feature ranked list with optional plan grouping */}
      <Box>
        <Box sx={{ display: 'flex', alignItems: 'center', gap: 2, mb: 1 }}>
          <Typography variant="wfLabel" sx={{ color: 'wf.fog' }}>
            By Feature
          </Typography>
          <Box sx={{ flex: 1 }} />
          <ToggleButtonGroup
            data-testid="run-economy-group-toggle"
            size="small"
            exclusive
            value={groupMode}
            onChange={(_, v: 'flat' | 'plan' | null) => { if (v) setGroupMode(v) }}
            aria-label="Group features"
            sx={{
              border: '1px solid',
              borderColor: 'wf.steel',
              borderRadius: 0,
              '& .MuiToggleButton-root': {
                fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
                fontSize: '10px',
                fontWeight: 500,
                letterSpacing: '0.08em',
                textTransform: 'uppercase',
                px: 1.25,
                py: 0.25,
                color: 'wf.fog',
                border: 'none',
                borderRadius: 0,
                '&.Mui-selected': {
                  bgcolor: 'wf.signal',
                  color: 'wf.ink',
                  '&:hover': { bgcolor: 'wf.signal' },
                },
                '&:hover': { bgcolor: 'rgba(59, 158, 255, 0.08)' },
              },
            }}
          >
            <ToggleButton value="flat">Flat</ToggleButton>
            <ToggleButton value="plan">By Plan</ToggleButton>
          </ToggleButtonGroup>
        </Box>
        <Box
          data-testid="run-economy-feature-list"
          sx={{
            border: '1px solid',
            borderColor: 'wf.steel',
            display: 'grid',
            // 8 columns: Feature (flex) · Cost · Duration · Turns · ↑ · ↓ · Idle · Est→Actual
            // ↑ carries cache % as a subtitle so the cell stays one column wide.
            gridTemplateColumns: '1fr auto auto auto auto auto auto auto',
            columnGap: 2,
            rowGap: 0.5,
            px: 1.5,
            py: 1,
            fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
            fontSize: '11px',
            fontVariantNumeric: 'tabular-nums',
            color: 'wf.bone',
          }}
        >
          {/* Sortable header row — slice 4a. Each header is a button
              that toggles its column's sort. The active column shows
              ▲/▼ next to its label; aria-sort reflects state for SR
              users + jsdom. */}
          <SortHeader col="name" align="left"  label="Feature"      activeCol={sortCol} dir={sortDir} onClick={handleHeaderClick} />
          <SortHeader col="cost" align="right" label="Cost"          activeCol={sortCol} dir={sortDir} onClick={handleHeaderClick} />
          <SortHeader col="duration" align="right" label="Duration"  activeCol={sortCol} dir={sortDir} onClick={handleHeaderClick} />
          <SortHeader col="turns" align="right" label="Turns"        activeCol={sortCol} dir={sortDir} onClick={handleHeaderClick} />
          <SortHeader col="upstream" align="right" label="↑ Up"      activeCol={sortCol} dir={sortDir} onClick={handleHeaderClick} />
          <SortHeader col="output" align="right" label="↓ Down"      activeCol={sortCol} dir={sortDir} onClick={handleHeaderClick} />
          <SortHeader col="idle" align="right" label="Idle"          activeCol={sortCol} dir={sortDir} onClick={handleHeaderClick} />
          <SortHeader col="estimate" align="right" label="Est → Actual" activeCol={sortCol} dir={sortDir} onClick={handleHeaderClick} />

          {groupMode === 'flat' && sortedFeatures.map((f) => (
            <FeatureRow key={f.task} f={f} />
          ))}
          {groupMode === 'plan' && groupByPlan(sortedFeatures).map((group) => (
            <PlanGroup key={group.key} group={group} />
          ))}
        </Box>
      </Box>
    </Box>
  )
}

interface PlanGroupData {
  key: string
  planName: string
  features: FeatureAggregate[]
  totalCost: number
  totalDuration: number
  totalEstimateHours: number | null
}

/* Group features by plan_dir. Standalone features (no plan_dir) collapse
   into a sentinel group at the END so they don't break up the per-plan
   sections. Plans sort by total cost desc; standalone always last. */
function groupByPlan(features: FeatureAggregate[]): PlanGroupData[] {
  const buckets = new Map<string, FeatureAggregate[]>()
  for (const f of features) {
    const key = f.planDir ?? '__standalone__'
    const list = buckets.get(key) ?? []
    list.push(f)
    buckets.set(key, list)
  }
  const groups: PlanGroupData[] = []
  for (const [key, list] of buckets) {
    const isStandalone = key === '__standalone__'
    const planName = isStandalone ? 'Standalone' : (list[0].planName ?? 'Unknown')
    const totalCost = list.reduce((acc, f) => acc + f.cost, 0)
    const totalDuration = list.reduce((acc, f) => acc + f.duration_s, 0)
    const estHoursList = list.map((f) => f.estimateHours).filter((h): h is number => h != null)
    const totalEstimateHours = estHoursList.length > 0
      ? estHoursList.reduce((acc, h) => acc + h, 0)
      : null
    groups.push({ key, planName, features: list, totalCost, totalDuration, totalEstimateHours })
  }
  groups.sort((a, b) => {
    if (a.key === '__standalone__') return 1
    if (b.key === '__standalone__') return -1
    return b.totalCost - a.totalCost
  })
  return groups
}

/* Single header cell — native <button> for the click handler so
   browsers route pointer events the standard way. Box-as-button
   indirection caused the operator's 2026-05-09 screenshot to render
   un-clickable headers (likely an emotion-cascade issue under the
   grid layout). aria-sort reflects state ("ascending" | "descending"
   | "none") so screen readers announce the current ranking direction.

   Inline `style` (not sx) for the click chrome so jsdom + production
   share identical resolved styles — sx via emotion classes can't be
   probed in jsdom (audit-15c #3 quirk). */
function SortHeader<C extends string>({
  col,
  label,
  align,
  activeCol,
  dir,
  onClick,
}: {
  col: C
  label: string
  align: 'left' | 'right'
  activeCol: C
  dir: SortDir
  onClick: (col: C) => void
}) {
  const isActive = col === activeCol
  const ariaSort: 'ascending' | 'descending' | 'none' =
    isActive ? (dir === 'asc' ? 'ascending' : 'descending') : 'none'
  const chevron = isActive ? (dir === 'asc' ? ' ▲' : ' ▼') : ''
  return (
    <button
      type="button"
      aria-sort={ariaSort}
      onClick={() => onClick(col)}
      style={{
        display: 'block',
        width: '100%',
        textAlign: align,
        background: 'transparent',
        border: 'none',
        padding: 0,
        margin: 0,
        cursor: 'pointer',
        font: 'inherit',
        color: isActive
          ? 'var(--mui-palette-wf-bone)'
          : 'var(--mui-palette-wf-fog)',
      }}
    >
      <Typography variant="wfLabel" component="span" sx={{ color: 'inherit' }}>
        {label}{chevron}
      </Typography>
    </button>
  )
}

function PlanGroup({ group }: { group: PlanGroupData }) {
  const tier = group.totalEstimateHours != null
    ? estimateTier(group.totalDuration, group.totalEstimateHours)
    : null
  const estLabel = group.totalEstimateHours != null
    ? `${group.totalEstimateHours}h → ${formatDuration(group.totalDuration)}`
    : null
  return (
    <Box data-testid="run-economy-plan-group" sx={{ display: 'contents' }}>
      {/* Plan header — spans all 8 columns via grid-column: 1 / -1 */}
      <Box
        data-testid="run-economy-plan-header"
        sx={{
          gridColumn: '1 / -1',
          display: 'flex',
          alignItems: 'baseline',
          gap: 2,
          py: 0.5,
          mt: 1,
          borderBottom: '1px solid',
          borderColor: 'wf.steel',
        }}
      >
        <Typography variant="wfLabel" sx={{ color: 'wf.bone', fontWeight: 600 }}>
          {group.planName}
        </Typography>
        <Typography variant="wfCode" sx={{ color: 'wf.fog', fontSize: '10px' }}>
          {`${group.features.length} feature${group.features.length === 1 ? '' : 's'}`}
        </Typography>
        <Box sx={{ flex: 1 }} />
        {estLabel && (
          <Typography
            variant="wfCode"
            style={{ color: tier ? ESTIMATE_TIER_COLOR[tier] : undefined }}
            sx={{ fontSize: '10px' }}
          >
            {estLabel}
          </Typography>
        )}
        <Typography variant="wfCode" sx={{ color: 'wf.bone', fontWeight: 600 }}>
          {formatCost(group.totalCost)}
        </Typography>
      </Box>
      {group.features.map((f) => (
        <FeatureRow key={f.task} f={f} />
      ))}
    </Box>
  )
}

function KpiCell({
  label,
  primary,
  secondary,
  secondaryTestId,
}: {
  label: string
  primary: string
  secondary?: string | null
  secondaryTestId?: string
}) {
  return (
    <Box
      sx={{
        p: 1.5,
        borderRight: '1px solid',
        borderBottom: '1px solid',
        borderColor: 'wf.steel',
        '&:last-of-type': { borderRight: 'none' },
      }}
    >
      <Typography variant="wfLabel" sx={{ color: 'wf.fog', display: 'block', mb: 0.5 }}>
        {label}
      </Typography>
      <Typography
        variant="wfCode"
        sx={{ color: 'wf.bone', fontVariantNumeric: 'tabular-nums', display: 'block' }}
      >
        {primary}
      </Typography>
      {secondary && (
        <Typography
          variant="wfCode"
          data-testid={secondaryTestId}
          sx={{ color: 'wf.fog', opacity: 0.7, fontVariantNumeric: 'tabular-nums', display: 'block', fontSize: '10px' }}
        >
          {secondary}
        </Typography>
      )}
    </Box>
  )
}

function PhaseRow({ p }: { p: PhaseAggregate }) {
  const cachePct = p.avgCacheRate != null ? `${Math.round(p.avgCacheRate * 100)}% cache` : null
  const tier = cacheTier(p.avgCacheRate)
  return (
    <Box
      data-testid="run-economy-phase-row"
      sx={{ display: 'contents' }}
    >
      <Typography
        variant="wfCode"
        data-testid="run-economy-phase-name"
        sx={{ color: 'wf.bone' }}
      >
        {p.name}
      </Typography>
      <Typography
        variant="wfCode"
        data-testid="run-economy-phase-count"
        sx={{ color: 'wf.fog', textAlign: 'right' }}
      >
        {String(p.featureCount)}
      </Typography>
      <Typography
        variant="wfCode"
        data-testid="run-economy-phase-cost"
        sx={{ color: 'wf.bone', textAlign: 'right' }}
      >
        {formatCost(p.avgCost)}
      </Typography>
      <Typography
        variant="wfCode"
        data-testid="run-economy-phase-duration"
        sx={{ color: 'wf.fog', textAlign: 'right' }}
      >
        {formatDuration(p.avgDurationSec)}
      </Typography>
      <Typography
        variant="wfCode"
        data-testid="run-economy-phase-turns"
        sx={{ color: 'wf.fog', textAlign: 'right' }}
      >
        {String(Math.round(p.avgTurns))}
      </Typography>
      <Box
        data-testid="run-economy-phase-upstream"
        data-cache-tier={tier ?? undefined}
        sx={{ textAlign: 'right' }}
      >
        <Typography variant="wfCode" component="div" sx={{ color: 'wf.fog' }}>
          {formatTokens(p.avgUpstream)}
        </Typography>
        {cachePct && (
          <Typography
            variant="wfCode"
            component="div"
            style={{ color: tier ? CACHE_TIER_COLOR[tier] : undefined, opacity: 0.85 }}
            sx={{ fontSize: '10px' }}
          >
            {cachePct}
          </Typography>
        )}
      </Box>
      <Typography
        variant="wfCode"
        data-testid="run-economy-phase-downstream"
        sx={{ color: 'wf.fog', textAlign: 'right' }}
      >
        {formatTokens(p.avgOutput)}
      </Typography>
    </Box>
  )
}

function FeatureRow({ f }: { f: FeatureAggregate }) {
  const cachePct = f.cacheRate != null ? `${Math.round(f.cacheRate * 100)}% cache` : null
  const tier = cacheTier(f.cacheRate)
  return (
    <Box
      data-testid="run-economy-feature-row"
      sx={{ display: 'contents' }}
    >
      {/* Feature name — flex left column */}
      <Typography variant="wfCode" sx={{ color: 'wf.bone' }}>{f.task}</Typography>
      {/* Cost — bone (dominant), right-aligned for vertical $ scanning */}
      <Typography
        variant="wfCode"
        data-testid="run-economy-feature-cost"
        sx={{ color: 'wf.bone', textAlign: 'right' }}
      >
        {formatCost(f.cost)}
      </Typography>
      {/* Duration */}
      <Typography
        variant="wfCode"
        data-testid="run-economy-feature-duration"
        sx={{ color: 'wf.fog', textAlign: 'right' }}
      >
        {formatDuration(f.duration_s)}
      </Typography>
      {/* Turns */}
      <Typography
        variant="wfCode"
        data-testid="run-economy-feature-turns"
        sx={{ color: 'wf.fog', textAlign: 'right' }}
      >
        {String(f.turns)}
      </Typography>
      {/* Upstream + cache % subtitle. Cache-rate label uses the tiered
          color scheme (good=green, bad=orange) so outliers pop. */}
      <Box
        data-testid="run-economy-feature-upstream"
        data-cache-tier={tier ?? undefined}
        sx={{ textAlign: 'right' }}
      >
        <Typography variant="wfCode" component="div" sx={{ color: 'wf.fog' }}>
          {formatTokens(f.upstream)}
        </Typography>
        {cachePct && (
          <Typography
            variant="wfCode"
            component="div"
            style={{ color: tier ? CACHE_TIER_COLOR[tier] : undefined, opacity: 0.85 }}
            sx={{ fontSize: '10px' }}
          >
            {cachePct}
          </Typography>
        )}
      </Box>
      {/* Downstream */}
      <Typography
        variant="wfCode"
        data-testid="run-economy-feature-downstream"
        sx={{ color: 'wf.fog', textAlign: 'right' }}
      >
        {formatTokens(f.output)}
      </Typography>
      {/* Idle — em-dash when not computable (older sessions w/o timestamps) */}
      <Typography
        variant="wfCode"
        data-testid="run-economy-feature-idle"
        sx={{ color: 'wf.fog', textAlign: 'right' }}
      >
        {f.idleSec != null && f.idleSec > 0 ? formatDuration(f.idleSec) : '—'}
      </Typography>
      {/* Estimate -> Actual with delta percentage. Em-dash when no plan
          task estimate is linked (standalone features). */}
      <FeatureEstimateCell f={f} />
    </Box>
  )
}

function FeatureEstimateCell({ f }: { f: FeatureAggregate }) {
  const tier = estimateTier(f.duration_s, f.estimateHours)
  if (f.estimateHours == null || tier == null) {
    return (
      <Typography
        variant="wfCode"
        data-testid="run-economy-feature-estimate"
        sx={{ color: 'wf.fog', textAlign: 'right' }}
      >
        —
      </Typography>
    )
  }
  const estLabel = `${f.estimateHours}h`
  const actualLabel = formatDuration(f.duration_s)
  const delta = (f.duration_s - f.estimateHours * 3600) / (f.estimateHours * 3600)
  const deltaPct = Math.round(Math.abs(delta) * 100)
  const deltaLabel = delta < 0
    ? `${deltaPct}% under`
    : delta > 0
      ? `${deltaPct}% over`
      : 'on target'
  return (
    <Box
      data-testid="run-economy-feature-estimate"
      data-estimate-tier={tier}
      sx={{ textAlign: 'right' }}
    >
      <Typography variant="wfCode" component="div" sx={{ color: 'wf.fog' }}>
        {`${estLabel} → ${actualLabel}`}
      </Typography>
      <Typography
        variant="wfCode"
        component="div"
        style={{ color: ESTIMATE_TIER_COLOR[tier], opacity: 0.85 }}
        sx={{ fontSize: '10px' }}
      >
        {deltaLabel}
      </Typography>
    </Box>
  )
}
