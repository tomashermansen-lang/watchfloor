import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import DetailSidebar from '../components/wf/DetailSidebar'
import type { AutopilotPhase } from '../types'

function renderSidebar(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

const phases: AutopilotPhase[] = [
  { name: 'ba', status: 'completed', duration_s: 60, cost: 0.94, artifact: null, input_tokens: null, cache_creation_tokens: null, cache_read_tokens: null, output_tokens: null, num_turns: null , started_at: null, ended_at: null},
  { name: 'plan', status: 'running', duration_s: 30, cost: null, artifact: null, input_tokens: null, cache_creation_tokens: null, cache_read_tokens: null, output_tokens: null, num_turns: null , started_at: null, ended_at: null},
  { name: 'review', status: 'pending', duration_s: null, cost: null, artifact: null, input_tokens: null, cache_creation_tokens: null, cache_read_tokens: null, output_tokens: null, num_turns: null , started_at: null, ended_at: null},
]

/* ═══ DetailSidebar primitive ═══

   Canonical 240px sidebar that pairs with DetailHeader to form the
   shared chrome shell consumed by SessionPanel + FeatureDetail.

   Per design_handoff_watchfloor_v2/specs/screens.md §3 "Phase rail":
     - PhaseStepper (full mode) — ✓ checkmark / pulse dot / pending dot
       per phase + name + duration/cost meta + TOTAL footer
     - Documents list — ToggleChip with AppIcon document glyph (the
       brand pattern converged in commit b4fc013)
     - Optional extras slot for surface-specific widgets (Session
       History toggle, gates, dependency lists)
*/

describe('DetailSidebar', () => {
  it('DS-1: renders PhaseStepper-style phase rail when phases provided', () => {
    const { container } = renderSidebar(<DetailSidebar phases={phases} />)
    /* PhaseStepper FullStepper marks each row with data-testid="phase-row" */
    expect(container.querySelectorAll('[data-testid="phase-row"]')).toHaveLength(3)
  })

  it('DS-2: renders the Pipeline Progress label inside the sidebar', () => {
    renderSidebar(<DetailSidebar phases={phases} />)
    expect(screen.getByText('Pipeline Progress')).toBeInTheDocument()
  })

  it('DS-3: omits PhaseStepper when phases is empty', () => {
    const { container } = renderSidebar(<DetailSidebar phases={[]} />)
    expect(container.querySelectorAll('[data-testid="phase-row"]')).toHaveLength(0)
    expect(screen.queryByText('Pipeline Progress')).not.toBeInTheDocument()
  })

  it('DS-4: renders artifact entries via ToggleChip + document AppIcon', () => {
    const onArtifact = vi.fn()
    const { container } = renderSidebar(
      <DetailSidebar
        phases={phases}
        artifacts={[{ name: 'REQUIREMENTS.md', file: 'REQUIREMENTS.md' }]}
        onArtifactClick={onArtifact}
      />
    )
    /* ToggleChip carries data-testid="wf-toggle-chip" */
    const chips = container.querySelectorAll('[data-testid="wf-toggle-chip"]')
    expect(chips.length).toBe(1)
    expect(chips[0].textContent).toContain('REQUIREMENTS')
    /* Each chip embeds an AppIcon (data-icon="document") for visual
       continuity with the brand documents glyph. */
    const icons = chips[0].querySelectorAll('[data-icon="document"]')
    expect(icons.length).toBeGreaterThan(0)
  })

  it('DS-5: clicks on a Document chip invoke onArtifactClick with file id', () => {
    const onArtifact = vi.fn()
    const { container } = renderSidebar(
      <DetailSidebar
        phases={phases}
        artifacts={[{ name: 'PLAN.md', file: 'PLAN.md' }]}
        onArtifactClick={onArtifact}
      />
    )
    const chip = container.querySelector('[data-testid="wf-toggle-chip"]') as HTMLElement
    chip.click()
    expect(onArtifact).toHaveBeenCalledWith('PLAN.md')
  })

  it('DS-6: omits Documents block when artifacts is empty / undefined', () => {
    const { container } = renderSidebar(<DetailSidebar phases={phases} />)
    expect(screen.queryByText('Documents')).not.toBeInTheDocument()
    expect(container.querySelectorAll('[data-testid="wf-toggle-chip"]')).toHaveLength(0)
  })

  it('DS-7: renders extras slot below the artifacts list', () => {
    renderSidebar(
      <DetailSidebar
        phases={phases}
        extras={<div data-testid="custom-extra">extra-content</div>}
      />
    )
    expect(screen.getByTestId('custom-extra')).toBeInTheDocument()
  })

  it('DS-8: sidebar carries data-testid="detail-sidebar" for shell-detection', () => {
    const { container } = renderSidebar(<DetailSidebar phases={phases} />)
    expect(container.querySelector('[data-testid="detail-sidebar"]')).not.toBeNull()
  })

  /* SessionPanel-era tests rely on the wf-doc-pill testid to scope
     "Documents area" assertions — preserve that contract here so
     the SessionPanel migration in the next commit doesn't have to
     update unrelated tests. */
  it('DS-9b: each artifact wrapper carries data-testid="wf-doc-pill"', () => {
    const { container } = renderSidebar(
      <DetailSidebar
        phases={phases}
        artifacts={[
          { name: 'REQUIREMENTS.md', file: 'REQUIREMENTS.md' },
          { name: 'PLAN.md', file: 'PLAN.md' },
        ]}
      />
    )
    expect(container.querySelectorAll('[data-testid="wf-doc-pill"]')).toHaveLength(2)
  })

  it('DS-9: pipeline progress label sits above the rail (visual ordering)', () => {
    const { container } = renderSidebar(<DetailSidebar phases={phases} />)
    const sidebar = container.querySelector('[data-testid="detail-sidebar"]') as HTMLElement
    const label = within(sidebar).getByText('Pipeline Progress')
    const firstRow = within(sidebar).getAllByTestId('phase-row')[0]
    const cmp = label.compareDocumentPosition(firstRow)
    expect(cmp & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })
})
