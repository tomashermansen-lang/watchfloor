import { describe, it, expect } from 'vitest'
import theme from '../theme'

describe('theme', () => {
  it('defines all 6 status colors in palette', () => {
    expect(theme.palette.status).toBeDefined()
    expect(theme.palette.status.pending).toBeDefined()
    expect(theme.palette.status.wip).toBeDefined()
    expect(theme.palette.status.done).toBeDefined()
    expect(theme.palette.status.failed).toBeDefined()
    expect(theme.palette.status.skipped).toBeDefined()
    expect(theme.palette.status.blocked).toBeDefined()
  })

  it('uses Inter font family', () => {
    expect(theme.typography.fontFamily).toContain('Inter')
  })

  it('has uniform border radius (8) matching chip rounding', () => {
    expect(theme.shape.borderRadius).toBe(8)
  })

  it('theme palette has mode defined', () => {
    expect(theme.palette.mode).toBeDefined()
  })

  /* M3 tonal surface tokens */
  it('defines tonal surface palette tokens', () => {
    expect(theme.palette.surface1).toBeDefined()
    expect(theme.palette.surface2).toBeDefined()
    expect(theme.palette.surface3).toBeDefined()
    expect(theme.palette.surfaceVariant).toBeDefined()
    expect(theme.palette.outline).toBeDefined()
    expect(theme.palette.outlineVariant).toBeDefined()
  })

  /* Container color roles */
  it('defines statusContainer palette', () => {
    const sc = theme.palette.statusContainer
    expect(sc).toBeDefined()
    expect(sc.done).toBeDefined()
    expect(sc.wip).toBeDefined()
    expect(sc.failed).toBeDefined()
    expect(sc.pending).toBeDefined()
    expect(sc.skipped).toBeDefined()
    expect(sc.blocked).toBeDefined()
  })

  it('defines onStatusContainer palette', () => {
    const osc = theme.palette.onStatusContainer
    expect(osc).toBeDefined()
    expect(osc.done).toBeDefined()
    expect(osc.wip).toBeDefined()
    expect(osc.failed).toBeDefined()
    expect(osc.pending).toBeDefined()
    expect(osc.skipped).toBeDefined()
    expect(osc.blocked).toBeDefined()
  })

  /* M3 typography weights: 400-500 instead of 600-700 */
  it('uses M3 lighter typography weights', () => {
    expect(theme.typography.h4.fontWeight).toBeLessThanOrEqual(500)
    expect(theme.typography.h5.fontWeight).toBeLessThanOrEqual(500)
    expect(theme.typography.h6.fontWeight).toBeLessThanOrEqual(500)
  })

  /* M3 custom variants */
  it('defines M3 custom typography variants', () => {
    expect(theme.typography.displayMedium).toBeDefined()
    expect(theme.typography.headlineSmall).toBeDefined()
    expect(theme.typography.titleLarge).toBeDefined()
    expect(theme.typography.titleMedium).toBeDefined()
    expect(theme.typography.titleSmall).toBeDefined()
    expect(theme.typography.labelLarge).toBeDefined()
    expect(theme.typography.labelMedium).toBeDefined()
    expect(theme.typography.labelSmall).toBeDefined()
  })

  /* Motion tokens via CSS variables */
  it('defines motion token CSS variables in CssBaseline', () => {
    const baseline = theme.components?.MuiCssBaseline?.styleOverrides as Record<string, unknown>
    expect(baseline).toBeDefined()
    const root = baseline[':root'] as Record<string, string>
    expect(root['--motion-emphasized']).toBeDefined()
    expect(root['--motion-short4']).toBeDefined()
    expect(root['--motion-medium2']).toBeDefined()
  })

  /* Watchfloor brand canvas palette — handoff README "Color · Canvas".
     Single source of truth for the rebrand; all chrome/components
     consume these instead of ad-hoc hex values. */
  it('defines wf brand canvas tokens with handoff hex values', () => {
    const wf = theme.palette.wf
    expect(wf).toBeDefined()
    expect(wf.ink).toBe('#0B0E13')
    expect(wf.carbon).toBe('#10141B')
    expect(wf.steel).toBe('#1B2230')
    expect(wf.fog).toBe('#5A6472')
    expect(wf.bone).toBe('#E6EBF2')
    expect(wf.signal).toBe('#3B9EFF')
    expect(wf.signalDim).toBe('#1F6FBF')
  })

  /* Watchfloor product status palette — handoff README "Color · Status".
     Four canonical product-only colors with exact hex values. Coexists
     with the legacy 6-key status palette (pending/wip/done/failed/
     skipped/blocked) until components migrate. running === wf.signal
     by design — single brand accent doubles as "agent running". */
  it('defines wf status tokens with handoff hex values', () => {
    const status = theme.palette.status
    expect(status.running).toBe('#3B9EFF')
    expect(status.completed).toBe('#5BD68A')
    expect(status.stalled).toBe('#F2B441')
    expect(status.fault).toBe('#EF4D4D')
  })

  it('keeps status.running aligned with wf.signal accent', () => {
    expect(theme.palette.status.running).toBe(theme.palette.wf.signal)
  })

  /* MUI primary.main carries the brand identity color so selection
     borders, link text, focused outlines all read as signal-blue
     instead of generic Material green. Dark mode in particular
     was leaking #8BAF82 into selected-box borders. */
  it('aligns palette.primary.main with the wf.signal brand accent', () => {
    expect(theme.palette.primary.main).toBe('#3B9EFF')
  })

  /* Watchfloor typography tokens — handoff README "Typography" table.
     Seven brand-named variants coexist with existing M3 variants
     (displayMedium/headlineSmall/etc.) so legacy components keep
     working while migration happens piece by piece. Font families
     reference 'Geist Mono' / 'JetBrains Mono' / 'Inter' — fonts get
     loaded via index.html in a later step; until then mono variants
     fall back to system mono. */
  it('defines wfDisplay variant — 32px/500 Geist Mono for KPI numbers', () => {
    const v = theme.typography.wfDisplay
    expect(v).toBeDefined()
    expect(v.fontSize).toBe('32px')
    expect(v.fontWeight).toBe(500)
    expect(v.fontFamily).toContain('Geist Mono')
  })

  it('defines wfH1 variant — 22px/500 Geist Mono for page titles', () => {
    const v = theme.typography.wfH1
    expect(v.fontSize).toBe('22px')
    expect(v.fontWeight).toBe(500)
    expect(v.fontFamily).toContain('Geist Mono')
  })

  it('defines wfH2 variant — 18px/500 Geist Mono for section titles', () => {
    const v = theme.typography.wfH2
    expect(v.fontSize).toBe('18px')
    expect(v.fontWeight).toBe(500)
    expect(v.fontFamily).toContain('Geist Mono')
  })

  it('defines wfH3 variant — 14px/600 Geist Mono for drawer headers', () => {
    const v = theme.typography.wfH3
    expect(v.fontSize).toBe('14px')
    expect(v.fontWeight).toBe(600)
    expect(v.fontFamily).toContain('Geist Mono')
  })

  it('defines wfLabel variant — 10px/500 JetBrains Mono uppercase 0.16em', () => {
    const v = theme.typography.wfLabel
    expect(v.fontSize).toBe('10px')
    expect(v.fontWeight).toBe(500)
    expect(v.fontFamily).toContain('JetBrains Mono')
    expect(v.textTransform).toBe('uppercase')
    expect(v.letterSpacing).toBe('0.16em')
  })

  it('defines wfBody variant — 13px/400 Inter for prose', () => {
    const v = theme.typography.wfBody
    expect(v.fontSize).toBe('13px')
    expect(v.fontWeight).toBe(400)
    expect(v.fontFamily).toContain('Inter')
  })

  it('defines wfCode variant — 11px/400 JetBrains Mono for log lines', () => {
    const v = theme.typography.wfCode
    expect(v.fontSize).toBe('11px')
    expect(v.fontWeight).toBe(400)
    expect(v.fontFamily).toContain('JetBrains Mono')
  })

  /* Brand-aware MUI Card override — sharp 90° corners matching the
     radar geometry the rest of the brand is built on. */
  it('overrides MuiCard with sharp 90° corners', () => {
    const root = theme.components?.MuiCard?.styleOverrides?.root as Record<string, unknown>
    expect(root.borderRadius).toBe(0)
  })

  it('overrides MuiPaper with sharp 90° corners (popovers, dialogs)', () => {
    const root = theme.components?.MuiPaper?.styleOverrides?.root as Record<string, unknown>
    expect(root.borderRadius).toBe(0)
  })

  it('overrides MuiDrawer paper with sharp 90° corners', () => {
    const paper = theme.components?.MuiDrawer?.styleOverrides?.paper as Record<string, unknown>
    expect(paper.borderRadius).toBe(0)
  })

  /* Brand-aware MUI Alert override — banner chrome per
     handoff §UI Primitives "Banner/Toast". Sharp corners + a
     severity-colored 3px left rail (mirrors the OverviewView
     status-header treatment) so banners read as instrument-
     panel chrome instead of generic Material toasts. */
  it('overrides MuiAlert with brand chrome (sharp + severity rail)', () => {
    const root = theme.components?.MuiAlert?.styleOverrides?.root as Record<string, unknown>
    expect(root).toBeDefined()
    expect(root.borderRadius).toBe(0)
    expect(root.borderLeft).toContain('3px solid')
  })

  /* Brand-aware MUI Button override — handoff §UI Primitives "Buttons".
     Theme-level so every existing Button across the app inherits the
     brand chrome (sharp 90° corners, JetBrains Mono UPPERCASE,
     0.1em tracking, no shadow) without per-call refactors. */
  it('overrides MuiButton with brand chrome (sharp corners + mono UPPERCASE)', () => {
    const overrides = theme.components?.MuiButton?.styleOverrides
    expect(overrides).toBeDefined()
    const root = overrides?.root as Record<string, unknown>
    expect(root.borderRadius).toBe(0)
    expect(root.textTransform).toBe('uppercase')
    expect(root.fontFamily).toContain('JetBrains Mono')
    expect(root.letterSpacing).toBe('0.1em')
    /* Brand chrome is flat — no shadow on raised buttons. */
    expect(root.boxShadow).toBe('none')
  })
})
