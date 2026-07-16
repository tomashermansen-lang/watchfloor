import { describe, it, expect } from 'vitest'
import { render, screen } from '@testing-library/react'
import PhaseStepper from '../components/autopilot/PhaseStepper'
import type { AutopilotPhase, TaskEstimate } from '../types'

const phases: AutopilotPhase[] = [
  {
    name: 'Business Analysis', status: 'completed', duration_s: 29, cost: 0.72, artifact: 'REQUIREMENTS.md',
    input_tokens: 32, cache_creation_tokens: 30129, cache_read_tokens: 4148262, output_tokens: 19485, num_turns: 33,
    started_at: '2026-05-09T09:00:31Z', ended_at: '2026-05-09T09:08:02Z',
  },
  {
    name: 'Architecture Plan', status: 'completed', duration_s: 10, cost: 4.73, artifact: 'PLAN.md',
    input_tokens: 12, cache_creation_tokens: 8000, cache_read_tokens: 920000, output_tokens: 4200, num_turns: 11,
    started_at: '2026-05-09T09:08:02Z', ended_at: '2026-05-09T09:23:34Z',
  },
  {
    name: 'Team Review', status: 'completed', duration_s: 1381, cost: 12.54, artifact: 'TEAM_REVIEW.md',
    input_tokens: 100, cache_creation_tokens: 50000, cache_read_tokens: 9000000, output_tokens: 60000, num_turns: 80,
    started_at: '2026-05-09T09:23:34Z', ended_at: '2026-05-09T09:46:32Z',
  },
  {
    name: 'Implementation (TDD)', status: 'running', duration_s: 1198, cost: null, artifact: null,
    input_tokens: null, cache_creation_tokens: null, cache_read_tokens: null, output_tokens: null, num_turns: null,
    started_at: '2026-05-09T09:46:32Z', ended_at: null,
  },
  {
    name: 'Static Analysis', status: 'pending', duration_s: null, cost: null, artifact: null,
    input_tokens: null, cache_creation_tokens: null, cache_read_tokens: null, output_tokens: null, num_turns: null,
    started_at: null, ended_at: null,
  },
]

describe('PhaseStepper', () => {
  describe('full mode (brand "PIPELINE PROGRESS" list)', () => {
    it('does not render artifact chips inline — artifacts belong in the Documents section', () => {
      render(<PhaseStepper phases={phases} mode="full" />)

      // Phase names should be visible
      expect(screen.getByText('Business Analysis')).toBeInTheDocument()
      expect(screen.getByText('Team Review')).toBeInTheDocument()

      // Artifact filenames should NOT appear as chips in the stepper
      expect(screen.queryByText('REQUIREMENTS.md')).not.toBeInTheDocument()
      expect(screen.queryByText('PLAN.md')).not.toBeInTheDocument()
      expect(screen.queryByText('TEAM_REVIEW.md')).not.toBeInTheDocument()
    })

    it('renders the brand "Pipeline Progress" section header', () => {
      render(<PhaseStepper phases={phases} mode="full" />)
      const header = screen.getByText(/Pipeline Progress/i)
      /* Brand chrome: header sits in wfLabel UPPERCASE vocabulary. */
      expect(header.className).toMatch(/MuiTypography-wfLabel/)
    })

    it('phase rows render with the wfLabel brand variant', () => {
      render(<PhaseStepper phases={phases} mode="full" />)
      const name = screen.getByText('Business Analysis')
      expect(name.className).toMatch(/MuiTypography-wfLabel/)
    })

    it('exposes the active (running) phase via data-active', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const active = Array.from(rows).find((r) => r.getAttribute('data-active') === 'true')
      expect(active).toBeDefined()
      expect(active?.textContent).toMatch(/Implementation/i)
    })

    /* Brand atom: completed phases must show ✓ checkmark, not a
       filled dot — matches design_handoff_watchfloor_v2 screens.md
       §3 phase rail "✓ icon (status.completed)" and the
       PhaseStateIcon pattern shipped to FeatureDetail in bc3afe7.
       Without this sync the active-autopilot view (PhaseStepper)
       and the paused-feature view (FeatureDetail) display
       different completed-phase glyphs for the same conceptual
       state, breaking visual continuity across screens. */
    it('completed phases render a brand checkmark (testid wf-phase-state-completed)', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const checks = container.querySelectorAll('[data-testid="wf-phase-state-completed"]')
      // 3 of the 5 fixture phases are completed
      expect(checks.length).toBe(3)
      expect(checks[0].textContent).toContain('✓')
    })

    it('Total row aggregates duration + cost across phases', () => {
      render(<PhaseStepper phases={phases} mode="full" />)
      expect(screen.getByText('Total')).toBeInTheDocument()
    })

    /* Audit-23 #7 — phase rows surface token economy + turn count.
       The first meta line gains a `Nt` turns token (parallel to the
       cost token). A second meta line appears only when the phase has
       resolved usage data: `↑ {input} ({cache%}) · ↓ {output}`.
       Pending and running phases without a result event yet keep the
       single meta line — no `↑ —` placeholder noise.

       The fixture's first phase (Business Analysis) has:
         input=32, cache_creation=30129, cache_read=4148262, output=19485
       Total upstream = 4 178 423; cache rate = 4148262/4178423 ≈ 99%.
       Output 19485 → "19.5k" via the k/M formatter. */
    it('phase rows render the turn count with the word "turns" (not bare t)', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const firstMeta = rows[0].textContent ?? ''
      expect(firstMeta).toMatch(/33\s*turns/)
      expect(firstMeta).not.toMatch(/33t\b/)
    })

    it('phase rows render a token line with cache rate when usage is present', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const firstText = rows[0].textContent ?? ''
      expect(firstText).toMatch(/↑\s*4\.2M/)
      expect(firstText).toMatch(/99%\s*cache/)
      expect(firstText).toMatch(/↓\s*19\.5k/)
    })

    it('phases without usage data do not render an empty token line', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const runningRow = Array.from(rows).find((r) => r.getAttribute('data-active') === 'true')
      expect(runningRow?.textContent ?? '').not.toMatch(/↑/)
    })

    /* Audit-23 #7 — TOTAL footer aggregates tokens across phases.
       Sum of input+cache_creation+cache_read across the 3 completed
       phases: (32+30129+4148262) + (12+8000+920000) + (100+50000+9000000)
       = 4178423 + 928012 + 9050100 = 14156535 → "14.2M".
       Output sum: 19485 + 4200 + 60000 = 83685 → "83.7k".
       Turns: 33 + 11 + 80 = 124. */
    it('Total row aggregates tokens (upstream + downstream) and turns', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const text = container.textContent ?? ''
      expect(text).toMatch(/124\s*turns/)
      expect(text).not.toMatch(/124t\b/)
      expect(text).toMatch(/↑\s*14\.2M/)
      expect(text).toMatch(/↓\s*83\.7k/)
    })

    /* Audit-23 #8 — TOTAL carries an estimate-vs-actual delta line when
       a TaskEstimate.duration_hours is supplied via prop. The fixture
       sums duration_s = 29+10+1381+1198 = 2618s ≈ 43m 38s.
       3h estimate (10800s) → delta = (2618-10800)/10800 ≈ -75.8%
       → "76% under" (or "75% under" depending on rounding). */
    it('Total row shows estimate label when estimate prop is given', () => {
      const estimate: TaskEstimate = { duration_hours: 3 }
      render(<PhaseStepper phases={phases} mode="full" estimate={estimate} />)
      expect(screen.getByText(/est\.?\s*3h/i)).toBeInTheDocument()
    })

    it('Total row shows percent-delta vs estimate', () => {
      const estimate: TaskEstimate = { duration_hours: 3 }
      const { container } = render(<PhaseStepper phases={phases} mode="full" estimate={estimate} />)
      const delta = container.querySelector('[data-testid="wf-total-estimate-delta"]')
      expect(delta).not.toBeNull()
      expect(delta?.textContent ?? '').toMatch(/7[56]%\s*under/i)
    })

    it('Total row omits estimate line when no estimate prop is given', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      expect(container.querySelector('[data-testid="wf-total-estimate-delta"]')).toBeNull()
    })

    it('Total row omits estimate line when estimate has no duration_hours', () => {
      const estimate: TaskEstimate = { lines_estimate: 50 }
      const { container } = render(<PhaseStepper phases={phases} mode="full" estimate={estimate} />)
      expect(container.querySelector('[data-testid="wf-total-estimate-delta"]')).toBeNull()
    })

    /* Audit-23 #7 defensive — when the dashboard backend hasn't been
       restarted after the schema bump (or any future API mismatch),
       the new token/turn keys arrive as JS `undefined` instead of
       `null`. The renderer must treat undefined the same as null —
       no "undefinedt" / "NaNM" artifacts in the sidebar. */
    it('phase rows handle undefined token/turn fields like null (no NaN/undefined leakage)', () => {
      const stalePhase = {
        name: 'Stale Phase',
        status: 'completed',
        duration_s: 60,
        cost: 1.0,
        artifact: null,
      } as unknown as AutopilotPhase
      const { container } = render(<PhaseStepper phases={[stalePhase]} mode="full" />)
      const text = container.textContent ?? ''
      expect(text).not.toMatch(/undefined/)
      expect(text).not.toMatch(/NaN/)
      // The token line must not render at all when no usage data is present.
      expect(container.querySelector('[data-testid="wf-phase-token-line"]')).toBeNull()
    })

    /* Audit-23 #9 - cache rate < 85% renders in muted-orange (status-stalled)
       so a phase that ate fresh context (low cache hit-rate, e.g. QA reading
       new test outputs) visually pops out of an otherwise green-or-fog row.
       Threshold is 85% - anything at or above is "healthy", anything below
       is flagged. Probed via data-low-cache attribute (jsdom does not resolve
       sx emotion classes; data-attribute is the deterministic test surface
       per the audit-15c #3 pattern). */
    it('cache rate below 85% flags the cache element with data-low-cache=true', () => {
      const lowCachePhase: AutopilotPhase = {
        name: 'Cache-Cold', status: 'completed', duration_s: 60, cost: 1.0, artifact: null,
        // input + creation = 300010, cache_read = 700000 -> total 1000010, cache 70%
        input_tokens: 10, cache_creation_tokens: 300000, cache_read_tokens: 700000,
        output_tokens: 5000, num_turns: 10, started_at: null, ended_at: null,
      }
      const { container } = render(<PhaseStepper phases={[lowCachePhase]} mode="full" />)
      const cacheEl = container.querySelector('[data-testid="wf-cache-rate"]')
      expect(cacheEl).not.toBeNull()
      expect(cacheEl?.getAttribute('data-low-cache')).toBe('true')
      expect(cacheEl?.textContent ?? '').toMatch(/70%/)
    })

    it('cache rate at or above 85% leaves data-low-cache=false', () => {
      // BA fixture has 99% cache rate.
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const cacheEl = rows[0].querySelector('[data-testid="wf-cache-rate"]')
      expect(cacheEl?.getAttribute('data-low-cache')).toBe('false')
    })

    /* Audit-23 #10 - tabular align: meta line splits into duration+turns
       (left) and cost (right) so the eye can scan the cost column
       vertically across rows. Each row cost element gets right-text-align
       inline so jsdom can introspect it. */
    it('phase meta line right-aligns the cost column for vertical scanning', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const costEl = rows[0].querySelector('[data-testid="wf-phase-meta-cost"]') as HTMLElement | null
      expect(costEl).not.toBeNull()
      expect(costEl?.style.textAlign).toBe('right')
      expect(costEl?.textContent ?? '').toMatch(/\$0\.72/)
    })

    /* Audit-23 #11 - token line shows new tokens (input + cache_creation),
       i.e. the chunk that paid near-full price. Cache rate alone signals
       efficiency; new tokens signal absolute spend. Together they answer
       "was this phase cheap because the cache hit, or because the prompt
       was small?".

       BA fixture: input=32 + cache_creation=30129 = 30161 -> "30.2k". */
    it('phase token line shows new tokens (input + cache_creation) alongside cache rate', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const text = rows[0].textContent ?? ''
      expect(text).toMatch(/30\.2k\s*new/)
    })

    it('Total row token line shows aggregated new tokens', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      // BA new = 30161, Plan new = 8012, Review new = 50100. Sum = 88273 -> "88.3k".
      const totalLine = container.querySelector('[data-testid="wf-total-token-line"]')
      expect(totalLine?.textContent ?? '').toMatch(/88\.3k\s*new/)
    })

    /* Audit-23 #1+#4 - phase rows show start -> end timestamps so the
       operator can correlate phases with time-of-day events ("the
       review-server crashed at 09:23, that explains why TEAM REVIEW
       took longer"). Format is HH:MM:SS local. Running phases without
       a terminal event yet show "live" on the right side; the timestamp
       block sits BETWEEN the phase name and the duration meta line so
       it doesn't compete with cost-column alignment.

       Fixture BA: 2026-05-09T09:00:31Z -> 09:08:02Z. */
    it('phase rows render start -> end timestamps when started_at + ended_at are set', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const tsEl = rows[0].querySelector('[data-testid="wf-phase-timestamps"]')
      expect(tsEl).not.toBeNull()
      // Time formatted to HH:MM:SS, no date. The arrow separates start from end.
      expect(tsEl?.textContent ?? '').toMatch(/\d{2}:\d{2}:\d{2}\s*→\s*\d{2}:\d{2}:\d{2}/)
    })

    it('running phase timestamp block shows "live" on the right side', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const runningRow = Array.from(rows).find((r) => r.getAttribute('data-active') === 'true')
      const tsEl = runningRow?.querySelector('[data-testid="wf-phase-timestamps"]')
      expect(tsEl?.textContent ?? '').toMatch(/\d{2}:\d{2}:\d{2}\s*→\s*live/i)
    })

    it('pending phase without timestamps does not render the timestamp block', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const pendingRow = rows[rows.length - 1]
      expect(pendingRow.querySelector('[data-testid="wf-phase-timestamps"]')).toBeNull()
    })

    /* Audit-23 #12 - upstream and downstream split onto separate lines so
       the upstream segment "↑ Nk (X% cache, Yk new)" never truncates in
       the 240px sidebar. Operator screenshot 2026-05-09 showed the new-
       tokens info getting clipped: "↑ 4.1M (95% cache, 2... ↓ 24.7k". */
    it('phase token block exposes upstream and downstream as separate elements', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const up = rows[0].querySelector('[data-testid="wf-phase-token-up"]')
      const down = rows[0].querySelector('[data-testid="wf-phase-token-down"]')
      expect(up).not.toBeNull()
      expect(down).not.toBeNull()
      expect(up?.textContent ?? '').toMatch(/4\.2M/)
      expect(up?.textContent ?? '').toMatch(/99%\s*cache/)
      expect(up?.textContent ?? '').toMatch(/30\.2k\s*new/)
      expect(down?.textContent ?? '').toMatch(/19\.5k/)
      expect(down?.textContent ?? '').not.toMatch(/cache/)
    })

    it('Total row token block also splits upstream and downstream', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const up = container.querySelector('[data-testid="wf-total-token-up"]')
      const down = container.querySelector('[data-testid="wf-total-token-down"]')
      expect(up).not.toBeNull()
      expect(down).not.toBeNull()
      expect(up?.textContent ?? '').toMatch(/14\.2M/)
      expect(up?.textContent ?? '').toMatch(/88\.3k\s*new/)
      expect(down?.textContent ?? '').toMatch(/83\.7k/)
      expect(down?.textContent ?? '').not.toMatch(/cache/)
    })

    /* Audit-23 #13 - phase name visual hierarchy. Completed phase names
       previously rendered in wf.fog (same color as their meta data) so
       the eye could not easily skip between phases. Bump completed to
       wf.bone (dominant brand white) so the row "header" pops above
       the muted meta lines. Running already had bone; pending stays
       dim. The probe pattern uses inline style on the Typography so
       jsdom can read the resolved color (sx alone is invisible to
       jsdom getComputedStyle per the audit-15c #3 quirk). */
    it('completed phase name renders in dominant wf.bone color', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const completedNameEl = rows[0].querySelector('[data-testid="wf-phase-name"]') as HTMLElement | null
      expect(completedNameEl).not.toBeNull()
      expect(completedNameEl?.style.color ?? '').toMatch(/wf\.bone|--mui-palette-wf-bone/)
    })

    it('pending phase name stays muted (no bone treatment)', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const pendingRow = rows[rows.length - 1]
      const pendingNameEl = pendingRow.querySelector('[data-testid="wf-phase-name"]') as HTMLElement | null
      expect(pendingNameEl?.style.color ?? '').not.toMatch(/wf\.bone|--mui-palette-wf-bone/)
    })

    /* Audit-23 #14 - upstream token line allows wrap so the parens
       content "(X% cache, Yk new)" never truncates with ellipsis. The
       2026-05-09 screenshot showed "(95% cache, 217.9k ne..." even
       after #12 split it onto its own line - noWrap was still active.
       Removing noWrap lets it spill onto a 2nd line. */
    it('upstream token line is allowed to wrap (noWrap is OFF)', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const upEl = rows[0].querySelector('[data-testid="wf-phase-token-up"]') as HTMLElement | null
      expect(upEl).not.toBeNull()
      expect(upEl?.className ?? '').not.toMatch(/MuiTypography-noWrap/)
    })

    it('downstream token line keeps noWrap (single short value)', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const downEl = rows[0].querySelector('[data-testid="wf-phase-token-down"]') as HTMLElement | null
      expect(downEl?.className ?? '').toMatch(/MuiTypography-noWrap/)
    })

    /* Audit-23 #15 - TOTAL row gets session start -> end timestamps too,
       derived from the min(started_at) and max(ended_at) across phases.
       Mirrors the per-phase pattern from #1: completed session shows
       "HH:MM:SS -> HH:MM:SS"; if any phase is still running, the right
       side shows "live". Fixture has BA started 09:00:31 and the running
       Implementation phase started 09:46:32 -> session right side is
       "live" since Implementation has no ended_at. */
    it('Total row renders session start -> live timestamps', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const tsEl = container.querySelector('[data-testid="wf-total-timestamps"]')
      expect(tsEl).not.toBeNull()
      expect(tsEl?.textContent ?? '').toMatch(/\d{2}:\d{2}:\d{2}\s*→\s*live/i)
    })

    it('Total row shows start -> end when all phases are completed', () => {
      const allDone: AutopilotPhase[] = phases.slice(0, 3).map((p, i) => ({
        ...p,
        status: 'completed' as const,
        started_at: i === 0 ? '2026-05-09T09:00:31Z' : '2026-05-09T09:08:02Z',
        ended_at: i === 2 ? '2026-05-09T09:46:32Z' : '2026-05-09T09:23:34Z',
      }))
      const { container } = render(<PhaseStepper phases={allDone} mode="full" />)
      const tsEl = container.querySelector('[data-testid="wf-total-timestamps"]')
      expect(tsEl?.textContent ?? '').toMatch(/\d{2}:\d{2}:\d{2}\s*→\s*\d{2}:\d{2}:\d{2}/)
      expect(tsEl?.textContent ?? '').not.toMatch(/live/i)
    })

    it('Total row hides timestamps when no phase has started_at', () => {
      const noTs = phases.map((p) => ({ ...p, started_at: null, ended_at: null }))
      const { container } = render(<PhaseStepper phases={noTs} mode="full" />)
      expect(container.querySelector('[data-testid="wf-total-timestamps"]')).toBeNull()
    })

    /* Audit-23 #16 - elapsed duration appended to timestamps so the
       operator can see "from-to" + "how long" in one glance. Phase
       rows show "12:33:49 -> 12:39:30 . 5m 41s" when both start and
       end exist. Running phases stay as "12:33:49 -> live" without
       duration (end is unknown without a live ticker). TOTAL shows
       wall-clock from min(started_at) to max(ended_at), which can
       differ from the sum-of-phase-durations when there are gaps
       between phases. */
    it('phase timestamps append elapsed duration when both start and end exist', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const tsEl = rows[0].querySelector('[data-testid="wf-phase-timestamps"]')
      expect(tsEl?.textContent ?? '').toMatch(/7m\s*31s/)
    })

    it('running phase timestamps do NOT append elapsed (no end yet)', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const rows = container.querySelectorAll('[data-testid="phase-row"]')
      const runningRow = Array.from(rows).find((r) => r.getAttribute('data-active') === 'true')
      const tsEl = runningRow?.querySelector('[data-testid="wf-phase-timestamps"]')
      expect(tsEl?.textContent ?? '').toMatch(/→\s*live/i)
      expect(tsEl?.textContent ?? '').not.toMatch(/live.*\d+m/i)
    })

    it('Total row appends wall-clock elapsed when all started phases ended', () => {
      const allDone: AutopilotPhase[] = [
        { ...phases[0], status: 'completed', started_at: '2026-05-09T09:00:00Z', ended_at: '2026-05-09T09:10:00Z' },
        { ...phases[1], status: 'completed', started_at: '2026-05-09T09:12:00Z', ended_at: '2026-05-09T09:30:00Z' },
      ]
      const { container } = render(<PhaseStepper phases={allDone} mode="full" />)
      const tsEl = container.querySelector('[data-testid="wf-total-timestamps"]')
      expect(tsEl?.textContent ?? '').toMatch(/30m/)
    })

    it('Total row does NOT append elapsed while a phase is still live', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      const tsEl = container.querySelector('[data-testid="wf-total-timestamps"]')
      expect(tsEl?.textContent ?? '').toMatch(/→\s*live/i)
      expect(tsEl?.textContent ?? '').not.toMatch(/live.*\d+m/i)
    })

    /* Audit-23 #17 - idle time on TOTAL = wall-clock minus sum of
       phase durations. Visible signal of "how much time was spent
       between phases" (manual approval gates, queue wait, dashboard
       latency). Only shown when the session has ended and idle is
       at least 1 second. */
    it('Total duration row appends idle time when wall-clock exceeds phase sum', () => {
      // Wall-clock 30 min, phase sum 28 min, idle 2 min.
      const phasesWithIdle: AutopilotPhase[] = [
        { ...phases[0], status: 'completed', duration_s: 600,
          started_at: '2026-05-09T09:00:00Z', ended_at: '2026-05-09T09:10:00Z' },
        { ...phases[1], status: 'completed', duration_s: 1080,
          started_at: '2026-05-09T09:12:00Z', ended_at: '2026-05-09T09:30:00Z' },
      ]
      const { container } = render(<PhaseStepper phases={phasesWithIdle} mode="full" />)
      const idleEl = container.querySelector('[data-testid="wf-total-idle"]')
      expect(idleEl).not.toBeNull()
      expect(idleEl?.textContent ?? '').toMatch(/2m\s*0s\s*idle/)
    })

    it('Total duration row hides idle when wall-clock equals phase sum', () => {
      const tight: AutopilotPhase[] = [
        { ...phases[0], status: 'completed', duration_s: 600,
          started_at: '2026-05-09T09:00:00Z', ended_at: '2026-05-09T09:10:00Z' },
      ]
      const { container } = render(<PhaseStepper phases={tight} mode="full" />)
      expect(container.querySelector('[data-testid="wf-total-idle"]')).toBeNull()
    })

    it('Total duration row hides idle while session is still live', () => {
      const { container } = render(<PhaseStepper phases={phases} mode="full" />)
      expect(container.querySelector('[data-testid="wf-total-idle"]')).toBeNull()
    })
  })

  describe('compact mode', () => {
    it('renders phase names with status prefixes', () => {
      render(<PhaseStepper phases={phases} mode="compact" />)

      expect(screen.getByText(/Business Analysis/)).toBeInTheDocument()
      expect(screen.getByText(/Implementation/)).toBeInTheDocument()
    })
  })
})
