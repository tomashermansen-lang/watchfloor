import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

/* Brand-regression guard for StreamViewer tool blocks (audit #4).
   Per docs/design_handoff_watchfloor_v2/specs/tokens.md sec Spacing-Surfaces:
     - "Sharp corners on panels, cards, inputs, buttons"
     - "Radius reserved for pills (999px) and toggle tracks"
     - "No drop shadows. Glow only on status indicators"
   Computed-style assertions on emotion sx are fragile in jsdom, so
   we lock the source against the specific anti-pattern strings. */
const SOURCE_PATH = resolve(
  dirname(fileURLToPath(import.meta.url)),
  '../components/autopilot/StreamViewer.tsx',
)
const source = readFileSync(SOURCE_PATH, 'utf8')

describe('StreamViewer brand-regression (audit #4)', () => {
  it('does not declare a 10px borderRadius (sharp corners on accordions)', () => {
    expect(source).not.toMatch(/borderRadius:\s*'10px/)
  })

  it('does not declare a non-zero borderRadius numeric (1.5 = MUI 12px shorthand)', () => {
    expect(source).not.toMatch(/borderRadius:\s*1\.5\b/)
  })

  it('does not declare a blurred drop shadow (0 4px 12px ...)', () => {
    expect(source).not.toMatch(/boxShadow:\s*'0 4px 12px/)
  })
})
