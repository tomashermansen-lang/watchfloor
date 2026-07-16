import { describe, it, expect } from 'vitest'
import { render } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import Markdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import wfTheme from '../theme'
import { brandifyMarkdown, wfMarkdownComponents } from '../components/wf/markdownComponents'

function renderMd(source: string) {
  return render(
    <ThemeProvider theme={wfTheme}>
      <Markdown remarkPlugins={[remarkGfm]} components={wfMarkdownComponents}>
        {brandifyMarkdown(source)}
      </Markdown>
    </ThemeProvider>,
  )
}

describe('brandifyMarkdown (skarm-9 #2)', () => {
  it('passes plain text through unchanged', () => {
    expect(brandifyMarkdown('Plain text')).toBe('Plain text')
  })

  it('replaces a literal check emoji with the wf:check sentinel inline code', () => {
    expect(brandifyMarkdown('Plan complete: ' + String.fromCodePoint(0x2705))).toBe('Plan complete: `wf:check`')
  })

  it('replaces multiple occurrences', () => {
    const tick = String.fromCodePoint(0x2705)
    expect(brandifyMarkdown('a ' + tick + ' b ' + tick)).toBe('a `wf:check` b `wf:check`')
  })

  it('does not touch the ASCII checkmark or unicode heavy check', () => {
    expect(brandifyMarkdown('done: ' + String.fromCodePoint(0x2713))).toContain(String.fromCodePoint(0x2713))
  })
})

describe('wfMarkdownComponents code override renders brand check glyph', () => {
  it('renders the brand inline check when source contains the check emoji', () => {
    const { container } = renderMd('Plan complete: ' + String.fromCodePoint(0x2705))
    const glyph = container.querySelector('[data-testid="wf-inline-check"]')
    expect(glyph).not.toBeNull()
  })

  it('does NOT render the brand check for ordinary inline code', () => {
    const { container } = renderMd('Try the `npm test` command')
    const glyph = container.querySelector('[data-testid="wf-inline-check"]')
    expect(glyph).toBeNull()
    expect(container.querySelector('code')?.textContent).toBe('npm test')
  })
})
