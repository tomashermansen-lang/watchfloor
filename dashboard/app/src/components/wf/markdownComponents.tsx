import Box from '@mui/material/Box'
import type { Components } from 'react-markdown'
import { pv } from '../../utils/cssVars'

/* Watchfloor markdown component overrides — single source of truth.

   Two responsibilities:
   1. brandifyMarkdown(): pre-process markdown source to replace
      literal "check emoji" (skarm-9 #2) with a sentinel inline code
      token `wf:check`. Agents and humans alike write this glyph in
      narrative text to mean "complete / done"; we render it via
      the brand Checkbox-checked glyph instead of the system emoji
      so it matches ui-primitives.md§Checkbox/Radio.
   2. wfMarkdownComponents: react-markdown component overrides:
        - <a>     no-op click + signal-blue underline (matches the
                  former local override in StreamViewer)
        - <code>  if children === 'wf:check' render WfInlineCheck;
                  else pass through to a plain <code> element so the
                  inherited wfMarkdownSx code styling applies. */

const CHECK_EMOJI = String.fromCodePoint(0x2705)
const CHECK_SENTINEL = '`wf:check`'

export function brandifyMarkdown(source: string): string {
  if (!source.includes(CHECK_EMOJI)) return source
  return source.split(CHECK_EMOJI).join(CHECK_SENTINEL)
}

function WfInlineCheck() {
  /* 14×14 inline glyph mirroring the wf Checkbox primitive in
     checked state — wf.signal fill + wf.ink 2px checkmark via
     ::after pseudo. Kept as a Box span for inline flow. */
  return (
    <Box
      component="span"
      data-testid="wf-inline-check"
      aria-label="checked"
      sx={{
        display: 'inline-block',
        verticalAlign: 'middle',
        position: 'relative',
        width: 14,
        height: 14,
        bgcolor: pv('wf-signal'),
        flexShrink: 0,
        mx: 0.25,
        '&::after': {
          content: '""',
          position: 'absolute',
          left: '4px',
          top: '0px',
          width: '3px',
          height: '7px',
          borderStyle: 'solid',
          borderColor: 'wf.ink',
          borderWidth: '0 2px 2px 0',
          transform: 'rotate(45deg)',
        },
      }}
    />
  )
}

function isCheckSentinel(children: unknown): boolean {
  if (typeof children === 'string') return children === 'wf:check'
  if (Array.isArray(children) && children.length === 1) return children[0] === 'wf:check'
  return false
}

export const wfMarkdownComponents: Components = {
  a: ({ href, children, ...props }) => (
    <a
      {...props}
      href={href}
      onClick={(e) => { e.preventDefault() }}
      style={{ color: 'var(--mui-palette-primary-main)', textDecoration: 'none', borderBottom: '1px dotted currentColor' }}
    >
      {children}
    </a>
  ),
  code: ({ children, className, ...rest }) => {
    if (!className && isCheckSentinel(children)) {
      return <WfInlineCheck />
    }
    return <code {...rest} className={className}>{children}</code>
  },
}
