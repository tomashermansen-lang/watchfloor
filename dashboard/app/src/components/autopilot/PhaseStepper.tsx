import Box from '@mui/material/Box'
import Stack from '@mui/material/Stack'
import Typography from '@mui/material/Typography'
import type { AutopilotPhase, AutopilotPhaseStatus, TaskEstimate } from '../../types'
import { pv } from '../../utils/cssVars'

const reducedMotionQuery = '@media (prefers-reduced-motion: reduce)'

function formatDuration(seconds: number | null): string {
  if (seconds === null || seconds === 0) return ''
  const m = Math.floor(seconds / 60)
  const s = seconds % 60
  return m > 0 ? `${m}m ${s}s` : `${s}s`
}

function formatCost(cost: number | null): string {
  if (cost === null) return '—'
  return `$${cost.toFixed(2)}`
}

/* HH:MM:SS extractor for ISO 8601 timestamps. Returns null if the input is
   null or unparseable (e.g. malformed string from a stale stream). Uses
   toLocaleTimeString with 24h format so it matches the design-handoff
   "09:00:31 → 09:08:02" pattern regardless of the user's locale. */
function formatClockTime(ts: string | null): string | null {
  if (ts == null) return null
  const date = new Date(ts)
  if (Number.isNaN(date.getTime())) return null
  return date.toLocaleTimeString('en-GB', {
    hour: '2-digit',
    minute: '2-digit',
    second: '2-digit',
    hour12: false,
  })
}

/* k/M token formatter — < 1k raw, 1k–1M one-decimal `Nk`, ≥1M one-decimal `NM`.
   Tokens land in the 10k–10M range typically; this keeps the sidebar tabular
   while still distinguishing 4.2M from 9.7M at a glance (audit-23 #7).

   Accepts `undefined` as well as `null` because a stale backend (one that
   shipped before the audit-23 #5 schema bump) returns the keys missing
   entirely; `==` against null catches both and avoids the "NaNM" leak that
   appeared in the field for a 30-minute window after the first deploy. */
function formatTokens(n: number | null | undefined): string {
  if (n == null) return '—'
  if (n < 1000) return String(n)
  if (n < 1_000_000) return `${(n / 1000).toFixed(1)}k`
  return `${(n / 1_000_000).toFixed(1)}M`
}

interface PhaseTokenSummary {
  upstream: number | null
  output: number | null
  cacheRate: number | null
  /* New tokens = input + cache_creation. The chunk that paid near-full price
     (cache_creation is ~1.25× full, input is full). Cache reads are 1/10×
     so they contribute little to actual cost — `newTokens` is the cost-
     driving signal (audit-23 #11). Together with cacheRate it answers
     "was this phase cheap because cache hit, or because prompt was small". */
  newTokens: number | null
}

/* Cache hit-rate threshold below which the cache % is rendered in
   muted-orange (status-stalled). 85% is the sweet spot — most healthy
   phases sit at 90-99%; anything below 85% means the phase ate fresh
   context (test outputs, log dumps, file reads that weren't already
   cached) and you're paying near-full price for a non-trivial slice
   of upstream (audit-23 #9). */
const LOW_CACHE_THRESHOLD = 0.85

/* Cache hit-rate = cache_read / (input + cache_creation + cache_read).
   Returns null when there's no upstream data or the components are all zero
   (avoids 0/0 → NaN). The rate explains *why* a phase is cheap: 95% cache
   means the phase paid ~14.5% of list-price for its input.

   Uses `== null` so a stale backend that omits the keys entirely (returning
   `undefined`) is treated identically to `null`. Output is coerced to `null`
   on the way out so the consumer can do `usage.output != null` uniformly. */
function summarizePhaseTokens(phase: AutopilotPhase): PhaseTokenSummary {
  const { input_tokens, cache_creation_tokens, cache_read_tokens, output_tokens } = phase
  if (
    input_tokens == null
    && cache_creation_tokens == null
    && cache_read_tokens == null
  ) {
    return { upstream: null, output: output_tokens ?? null, cacheRate: null, newTokens: null }
  }
  const i = input_tokens ?? 0
  const c = cache_creation_tokens ?? 0
  const r = cache_read_tokens ?? 0
  const upstream = i + c + r
  const cacheRate = upstream > 0 ? r / upstream : null
  const newTokens = i + c
  return { upstream, output: output_tokens ?? null, cacheRate, newTokens }
}

/* Brand "PIPELINE PROGRESS" indicator — matches the screen-spec
   phase rail "✓ icon (status.completed)" + the PhaseStateIcon
   pattern shipped to FeatureDetail (commit bc3afe7). Four states
   map to the wf status palette:
     completed → green ✓ checkmark (atoms.md status.completed)
     running   → filled signal-blue dot, pulsing
     failed    → filled fault-red dot
     pending   → hollow steel ring
   Active and pending stay as dots so the row reads as a list of
   states; only the resolved-success state earns the checkmark. */
function ProgressDot({ status }: { status: AutopilotPhaseStatus }) {
  if (status === 'completed') {
    return (
      <Box
        component="span"
        data-testid="wf-phase-state-completed"
        aria-hidden
        sx={{
          display: 'inline-flex',
          alignItems: 'center',
          justifyContent: 'center',
          width: 12,
          height: 12,
          fontSize: '12px',
          fontWeight: 700,
          lineHeight: 1,
          color: pv('status-done'),
          flexShrink: 0,
        }}
      >
        ✓
      </Box>
    )
  }
  const colorMap: Record<Exclude<AutopilotPhaseStatus, 'completed'>, string> = {
    running: pv('status-wip'),
    failed: pv('status-failed'),
    pending: 'transparent',
  }
  const isRunning = status === 'running'
  const isHollow = status === 'pending'
  return (
    <Box
      aria-hidden
      sx={{
        width: 8, height: 8,
        borderRadius: '50%',
        bgcolor: colorMap[status],
        border: isHollow ? `1.5px solid ${pv('wf-fog')}` : 'none',
        flexShrink: 0,
        ...(isRunning ? {
          animation: 'pipelineDotPulse 2s ease-in-out infinite',
          '@keyframes pipelineDotPulse': {
            '0%, 100%': { opacity: 1, transform: 'scale(1)' },
            '50%': { opacity: 0.4, transform: 'scale(0.8)' },
          },
          [reducedMotionQuery]: { animation: 'none' },
        } : {}),
      }}
    />
  )
}

const STATUS_PREFIX: Record<AutopilotPhaseStatus, string> = {
  completed: '✓',
  running: '●',
  pending: '○',
  failed: '✗',
}

/* ═══ Compact Mode (horizontal, in card) ═══ */

function CompactStepper({ phases }: { phases: AutopilotPhase[] }) {
  return (
    <Box sx={{ display: 'flex', alignItems: 'center', flexWrap: 'wrap', gap: 0.25 }}>
      {phases.map((phase, i) => (
        <Box key={phase.name} sx={{ display: 'flex', alignItems: 'center', gap: 0.25 }}>
          {i > 0 && (
            <Typography variant="wfLabel" color="text.secondary" sx={{ mx: 0.25 }}>→</Typography>
          )}
          <Typography
            variant="wfLabel"
            aria-label={`${phase.name} — ${phase.status}${phase.duration_s ? ` in ${formatDuration(phase.duration_s)}` : ''}`}
            sx={{
              color: phase.status === 'running' ? pv('status-wip')
                : phase.status === 'failed' ? pv('status-failed')
                : phase.status === 'completed' ? pv('status-done')
                : 'text.secondary',
              fontWeight: phase.status === 'running' ? 500 : 400,
            }}
          >
            {STATUS_PREFIX[phase.status]} {phase.name}
          </Typography>
        </Box>
      ))}
    </Box>
  )
}

/* ═══ Full Mode — brand "PIPELINE PROGRESS" list ═══ */

interface FullStepperProps {
  phases: AutopilotPhase[]
  estimate?: TaskEstimate
}

function FullStepper({ phases, estimate }: FullStepperProps) {
  const totalDuration = phases.reduce((acc, p) => acc + (p.duration_s ?? 0), 0)
  const phaseCosts = phases.filter((p) => p.cost !== null)
  const totalCost = phaseCosts.length > 0 ? phaseCosts.reduce((acc, p) => acc + (p.cost ?? 0), 0) : null
  // Token/turn aggregates use `!= null` so stale backends that omit the
  // audit-23 #5 keys entirely (delivered as `undefined`) are skipped the
  // same way `null` would be — no `0t`, no `↑ 0` in the TOTAL row.
  const phasesWithTurns = phases.filter((p) => p.num_turns != null)
  const totalTurns = phasesWithTurns.length > 0
    ? phasesWithTurns.reduce((acc, p) => acc + (p.num_turns ?? 0), 0)
    : null
  const phasesWithUsage = phases.filter((p) => p.input_tokens != null
    || p.cache_creation_tokens != null || p.cache_read_tokens != null)
  const totalUpstream = phasesWithUsage.length > 0
    ? phasesWithUsage.reduce((acc, p) => acc
      + (p.input_tokens ?? 0) + (p.cache_creation_tokens ?? 0) + (p.cache_read_tokens ?? 0), 0)
    : null
  const totalCacheRead = phasesWithUsage.length > 0
    ? phasesWithUsage.reduce((acc, p) => acc + (p.cache_read_tokens ?? 0), 0)
    : 0
  const totalOutput = phases.some((p) => p.output_tokens != null)
    ? phases.reduce((acc, p) => acc + (p.output_tokens ?? 0), 0)
    : null
  const totalCacheRate = totalUpstream !== null && totalUpstream > 0
    ? totalCacheRead / totalUpstream
    : null

  const estimateHours = estimate?.duration_hours ?? null
  const estimateDelta = estimateHours !== null && estimateHours > 0 && totalDuration > 0
    ? (totalDuration - estimateHours * 3600) / (estimateHours * 3600)
    : null

  /* Audit-23 #15 - session-level timestamps for the TOTAL row. Derived
     from the earliest started_at across phases, paired with either the
     latest ended_at (if every started phase is also ended) or "live"
     when any phase is still in flight. Pending phases without started_at
     are skipped — only phases that actually ran contribute. */
  const phasesWithStart = phases.filter((p) => p.started_at != null)
  const sessionStart = phasesWithStart.length > 0
    ? phasesWithStart.map((p) => p.started_at!).sort()[0]
    : null
  const anyPhaseRunning = phases.some((p) => p.status === 'running')
  const allStartedPhasesEnded = phasesWithStart.length > 0
    && phasesWithStart.every((p) => p.ended_at != null)
  const sessionEnd = allStartedPhasesEnded && !anyPhaseRunning
    ? phasesWithStart.map((p) => p.ended_at!).sort().slice(-1)[0]
    : null
  const sessionStartClock = formatClockTime(sessionStart)
  const sessionEndClock = formatClockTime(sessionEnd)
  // Audit-23 #16+#17 - wall-clock elapsed and idle gap. Only computed
  // when the session has ended; the live ticker would need a setInterval
  // to stay accurate. Idle = wall-clock - sum(phase durations) → time
  // spent between phases (manual gates, queue wait, dashboard latency).
  const sessionWallClockSec = sessionStart != null && sessionEnd != null && !anyPhaseRunning
    ? Math.floor((new Date(sessionEnd).getTime() - new Date(sessionStart).getTime()) / 1000)
    : null
  const sessionIdleSec = sessionWallClockSec != null && totalDuration > 0
    ? sessionWallClockSec - totalDuration
    : null

  return (
    <Box>
      <Typography
        variant="wfLabel"
        sx={{ color: 'text.secondary', display: 'block', mb: 1.25 }}
      >
        Pipeline Progress
      </Typography>
      <Stack spacing={0.5}>
        {phases.map((phase) => {
          const isActive = phase.status === 'running'
          const isPending = phase.status === 'pending'
          const turnsLabel = phase.num_turns != null ? `${phase.num_turns} turns` : null
          const durationLabel = phase.duration_s !== null ? formatDuration(phase.duration_s) : null
          const costLabel = phase.cost !== null ? formatCost(phase.cost) : null
          const leftMeta = [durationLabel, turnsLabel].filter(Boolean).join(' · ')
          const hasMeta = leftMeta || costLabel
          const startedClock = formatClockTime(phase.started_at)
          const endedClock = formatClockTime(phase.ended_at)
          // Show timestamp block when at least started_at exists. A running
          // phase shows "09:46:32 → live"; pending phases stay silent.
          const hasTimestamps = startedClock != null
          // Audit-23 #16 - elapsed derived from timestamps (not duration_s)
          // so the appended "5m 41s" always matches the visible "12:33:49 →
          // 12:39:30" delta. duration_s and timestamp-delta should agree in
          // production, but we trust what we display.
          const phaseElapsedSec = phase.started_at != null && phase.ended_at != null
            ? Math.floor(
                (new Date(phase.ended_at).getTime() - new Date(phase.started_at).getTime()) / 1000,
              )
            : null
          const usage = summarizePhaseTokens(phase)
          const showTokens = usage.upstream !== null || usage.output !== null
          const isLowCache = usage.cacheRate !== null && usage.cacheRate < LOW_CACHE_THRESHOLD
          return (
            <Box
              key={phase.name}
              data-testid="phase-row"
              data-status={phase.status}
              data-active={isActive ? 'true' : 'false'}
              aria-label={`${phase.name} — ${phase.status}${phase.duration_s ? ` in ${formatDuration(phase.duration_s)}` : ''}`}
              sx={{ display: 'flex', alignItems: 'flex-start', gap: 1.25, py: 0.25 }}
            >
              {/* Dot sits flush with the wfLabel line-box of row 1. */}
              <Box sx={{ height: '14px', display: 'flex', alignItems: 'center', flexShrink: 0 }}>
                <ProgressDot status={phase.status} />
              </Box>
              <Box sx={{ minWidth: 0, flex: 1 }}>
                <Typography
                  variant="wfLabel"
                  noWrap
                  data-testid="wf-phase-name"
                  /* Audit-23 #13 - completed phase names get wf.bone so
                     they pop above the muted meta lines. Pending stays
                     dim via wf.fog + opacity. Inline style so jsdom can
                     read the resolved palette ref deterministically. */
                  style={{
                    display: 'block',
                    color: isPending
                      ? 'var(--mui-palette-wf-fog)'
                      : 'var(--mui-palette-wf-bone)',
                    opacity: isPending ? 0.6 : 1,
                    fontWeight: isActive ? 600 : 500,
                  }}
                >
                  {phase.name}
                </Typography>
                {hasTimestamps && (
                  /* Audit-23 #1+#16 - clock timestamps + elapsed duration.
                     "12:33:49 → 12:39:30 · 5m 41s" when both endpoints
                     exist; "12:33:49 → live" while running (no elapsed
                     append since end is unknown). */
                  <Typography
                    variant="wfCode"
                    component="div"
                    noWrap
                    data-testid="wf-phase-timestamps"
                    sx={{
                      color: 'wf.fog',
                      opacity: isPending ? 0.6 : 0.7,
                      fontVariantNumeric: 'tabular-nums',
                      mt: 0.25,
                    }}
                  >
                    {`${startedClock} → ${isActive ? 'live' : (endedClock ?? '—')}`}
                    {!isActive && phaseElapsedSec != null && phaseElapsedSec > 0
                      && ` · ${formatDuration(phaseElapsedSec)}`}
                  </Typography>
                )}
                {hasMeta && (
                  /* Audit-23 #10 - 2-col grid lets the cost flush right
                     so the eye can scan a vertical money column across
                     phases. Left col holds duration · turns. */
                  <Box
                    sx={{
                      display: 'grid',
                      gridTemplateColumns: '1fr auto',
                      columnGap: 1,
                      color: 'wf.fog',
                      opacity: isPending ? 0.6 : 0.85,
                      fontVariantNumeric: 'tabular-nums',
                      mt: 0.125,
                    }}
                  >
                    <Typography variant="wfCode" component="span" noWrap sx={{ minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis' }}>
                      {leftMeta}
                    </Typography>
                    <Typography
                      variant="wfCode"
                      component="span"
                      noWrap
                      data-testid="wf-phase-meta-cost"
                      style={{ textAlign: 'right' }}
                    >
                      {costLabel}
                    </Typography>
                  </Box>
                )}
                {showTokens && (
                  /* Audit-23 #11+#12 - upstream and downstream split onto
                     separate lines so the upstream segment with its parens
                     never truncates in the 240px sidebar. The cache % gets
                     a data-low-cache attribute (audit-23 #9) so jsdom can
                     probe it; when below LOW_CACHE_THRESHOLD it paints in
                     status-stalled (muted orange) inline. */
                  <Box
                    data-testid="wf-phase-token-line"
                    sx={{
                      color: 'wf.fog',
                      opacity: 0.7,
                      fontVariantNumeric: 'tabular-nums',
                      mt: 0.125,
                    }}
                  >
                    {usage.upstream != null && (
                      /* Audit-23 #14 - noWrap removed so "(X% cache,
                         Yk new)" wraps gracefully in 240px sidebar
                         instead of truncating with ellipsis. */
                      <Typography
                        variant="wfCode"
                        component="div"
                        data-testid="wf-phase-token-up"
                      >
                        {`↑ ${formatTokens(usage.upstream)}`}
                        {usage.cacheRate != null && (
                          <>
                            {' ('}
                            <Box
                              component="span"
                              data-testid="wf-cache-rate"
                              data-low-cache={isLowCache ? 'true' : 'false'}
                              style={{
                                color: isLowCache ? 'var(--mui-palette-status-stalled)' : undefined,
                              }}
                            >
                              {`${Math.round(usage.cacheRate * 100)}% cache`}
                            </Box>
                            {usage.newTokens != null && `, ${formatTokens(usage.newTokens)} new`}
                            {')'}
                          </>
                        )}
                      </Typography>
                    )}
                    {usage.output != null && (
                      <Typography
                        variant="wfCode"
                        component="div"
                        noWrap
                        data-testid="wf-phase-token-down"
                      >
                        {`↓ ${formatTokens(usage.output)}`}
                      </Typography>
                    )}
                  </Box>
                )}
              </Box>
            </Box>
          )
        })}
      </Stack>

      {/* Aggregate footer — duration · turns · cost on line 1, tokens on
          line 2, estimate-delta on line 3. Each line independently
          conditional so a stream with no usage data doesn't render
          empty placeholder lines. */}
      <Box sx={{ mt: 1.5, pt: 1.5, borderTop: '1px solid', borderColor: 'wf.steel' }}>
        <Typography variant="wfLabel" color="text.secondary" sx={{ display: 'block', mb: 0.25 }}>
          Total
        </Typography>
        {sessionStartClock != null && (
          /* Audit-23 #15 - session start -> end (or live). Sits below the
             "Total" label and above the duration/cost row, mirroring the
             per-phase pattern from #1. */
          <Typography
            variant="wfCode"
            component="div"
            noWrap
            data-testid="wf-total-timestamps"
            sx={{
              color: 'wf.fog',
              opacity: 0.7,
              fontVariantNumeric: 'tabular-nums',
              mb: 0.25,
            }}
          >
            {`${sessionStartClock} → ${anyPhaseRunning ? 'live' : (sessionEndClock ?? '—')}`}
            {sessionWallClockSec != null && sessionWallClockSec > 0
              && ` · ${formatDuration(sessionWallClockSec)}`}
          </Typography>
        )}
        {/* Audit-23 #10 - same 2-col grid as phase rows so the TOTAL
            cost lines up with the phase costs above it. */}
        <Box
          sx={{
            display: 'grid',
            gridTemplateColumns: '1fr auto',
            columnGap: 1,
            color: 'wf.bone',
            fontVariantNumeric: 'tabular-nums',
          }}
        >
          <Typography variant="wfCode" component="span" noWrap sx={{ minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis' }}>
            {[formatDuration(totalDuration), totalTurns !== null ? `${totalTurns} turns` : null].filter(Boolean).join(' · ')}
            {sessionIdleSec != null && sessionIdleSec >= 1 && (
              /* Audit-23 #17 - idle marker. Sits after turns so the
                 cost stays right-flushed; matches the existing meta
                 rhythm of "primary · secondary · tertiary". */
              <Box
                component="span"
                data-testid="wf-total-idle"
                sx={{ color: 'wf.fog', opacity: 0.85, ml: 1 }}
              >
                {`· ${formatDuration(sessionIdleSec)} idle`}
              </Box>
            )}
          </Typography>
          <Typography variant="wfCode" component="span" noWrap data-testid="wf-total-cost" style={{ textAlign: 'right' }}>
            {formatCost(totalCost)}
          </Typography>
        </Box>
        {(totalUpstream !== null || totalOutput !== null) && (() => {
          const isTotalLowCache = totalCacheRate !== null && totalCacheRate < LOW_CACHE_THRESHOLD
          // Sum new tokens (input + cache_creation) across phases that have
          // any usage data. Mirror the per-phase summarizePhaseTokens logic.
          const totalNewTokens = phasesWithUsage.length > 0
            ? phasesWithUsage.reduce((acc, p) => acc + (p.input_tokens ?? 0) + (p.cache_creation_tokens ?? 0), 0)
            : null
          return (
            <Box
              data-testid="wf-total-token-line"
              sx={{
                color: 'wf.fog',
                opacity: 0.85,
                fontVariantNumeric: 'tabular-nums',
                mt: 0.25,
              }}
            >
              {totalUpstream != null && (
                <Typography
                  variant="wfCode"
                  component="div"
                  noWrap
                  data-testid="wf-total-token-up"
                  sx={{ minWidth: 0, overflow: 'hidden', textOverflow: 'ellipsis' }}
                >
                  {`↑ ${formatTokens(totalUpstream)}`}
                  {totalCacheRate != null && (
                    <>
                      {' ('}
                      <Box
                        component="span"
                        data-testid="wf-total-cache-rate"
                        data-low-cache={isTotalLowCache ? 'true' : 'false'}
                        style={{
                          color: isTotalLowCache ? 'var(--mui-palette-status-stalled)' : undefined,
                        }}
                      >
                        {`${Math.round(totalCacheRate * 100)}% cache`}
                      </Box>
                      {totalNewTokens != null && `, ${formatTokens(totalNewTokens)} new`}
                      {')'}
                    </>
                  )}
                </Typography>
              )}
              {totalOutput != null && (
                <Typography
                  variant="wfCode"
                  component="div"
                  noWrap
                  data-testid="wf-total-token-down"
                >
                  {`↓ ${formatTokens(totalOutput)}`}
                </Typography>
              )}
            </Box>
          )
        })()}
        {estimateHours !== null && (
          <Typography
            variant="wfCode"
            data-testid="wf-total-estimate-delta"
            sx={{
              display: 'block',
              color: estimateDelta === null ? 'wf.fog'
                : estimateDelta < -0.05 ? pv('status-done')
                : estimateDelta > 0.2 ? pv('status-failed')
                : 'wf.bone',
              opacity: 0.85,
              fontVariantNumeric: 'tabular-nums',
              mt: 0.25,
            }}
          >
            {`est. ${estimateHours}h`}
            {estimateDelta !== null && (
              <>
                {' · '}
                {estimateDelta < 0
                  ? `${Math.abs(Math.round(estimateDelta * 100))}% under`
                  : estimateDelta > 0
                    ? `${Math.round(estimateDelta * 100)}% over`
                    : 'on target'}
              </>
            )}
          </Typography>
        )}
      </Box>
    </Box>
  )
}

/* ═══ Exported Component ═══ */

interface PhaseStepperProps {
  phases: AutopilotPhase[]
  mode?: 'compact' | 'full'
  estimate?: TaskEstimate
}

export default function PhaseStepper({ phases, mode = 'compact', estimate }: PhaseStepperProps) {
  if (mode === 'full') return <FullStepper phases={phases} estimate={estimate} />
  return <CompactStepper phases={phases} />
}
