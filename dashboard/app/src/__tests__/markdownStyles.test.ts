import { describe, it, expect } from 'vitest'
import { wfMarkdownSx } from '../components/wf/markdownStyles'

describe('wfMarkdownSx', () => {
  it('is the single source of truth for brand markdown rendering', () => {
    expect(wfMarkdownSx).toBeTypeOf('object')
  })

  it('inline code uses JetBrains Mono with signal-blue accent', () => {
    const codeStyle = wfMarkdownSx['& code'] as Record<string, unknown>
    expect(codeStyle).toBeDefined()
    expect(String(codeStyle.fontFamily)).toContain('JetBrains Mono')
    expect(String(codeStyle.color)).toMatch(/wf-signal|wf\.signal/)
    expect(codeStyle.borderRadius).toBe(0)
  })

  it('code blocks use sharp corners (no radius) per tokens.md spec', () => {
    const preStyle = wfMarkdownSx['& pre'] as Record<string, unknown>
    expect(preStyle).toBeDefined()
    expect(preStyle.borderRadius).toBe(0)
  })

  it('tables exist as a styled selector', () => {
    expect(wfMarkdownSx['& table']).toBeDefined()
    expect(wfMarkdownSx['& th, & td']).toBeDefined()
    expect(wfMarkdownSx['& th']).toBeDefined()
  })

  it('table body cells use wfCode (JetBrains Mono per tokens.md type.code)', () => {
    const td = wfMarkdownSx['& td'] as Record<string, unknown>
    expect(td).toBeDefined()
    expect(td.typography).toBe('wfCode')
  })

  it('table header cells use wfLabel (JetBrains Mono uppercase per tokens.md type.label)', () => {
    const th = wfMarkdownSx['& th'] as Record<string, unknown>
    expect(th.typography).toBe('wfLabel')
  })

  it('shared th/td selector no longer hardcodes wfBody (Inter); per-cell typography wins', () => {
    const shared = wfMarkdownSx['& th, & td'] as Record<string, unknown>
    expect(shared.typography).toBeUndefined()
  })

  it('GFM task-list checkboxes restyle to brand square (appearance:none + 14x14 + sharp corners)', () => {
    const cb = wfMarkdownSx['& input[type="checkbox"]'] as Record<string, unknown>
    expect(cb).toBeDefined()
    expect(cb.appearance).toBe('none')
    expect(cb.width).toBe(14)
    expect(cb.height).toBe(14)
    expect(cb.borderRadius).toBe(0)
  })
})
