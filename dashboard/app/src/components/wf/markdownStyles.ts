import { pv, pva } from '../../utils/cssVars'

/* Watchfloor brand markdown rendering — single source of truth.
   Consumed by StreamViewer (live phase narrative) and ArtifactDialog
   (opened feature/autopilot artifact). Any future markdown surface
   (plan-view, deferred report, …) imports from here so the brand
   stays unified.

   Spec mapping:
   - tokens.md§Typography:   inline code + tables → JetBrains Mono
   - tokens.md§Spacing:      sharp corners on panels/code blocks
   - atoms.md / status:      signal-blue accents on code + table headers
   - ui-primitives.md§Banner derives from blockquote pattern */
export const wfMarkdownSx = {
  '& h1': { typography: 'wfH1', mt: 2, mb: 1 },
  '& h2': { typography: 'wfH2', mt: 1.5, mb: 0.75 },
  '& h3': { typography: 'wfH3', mt: 1, mb: 0.5 },
  '& p': { typography: 'wfBody', mb: 0.5, lineHeight: 1.5, color: 'text.primary' },
  '& ul, & ol': { pl: 3, mb: 1 },
  '& li': { typography: 'wfBody', mb: 0.25, lineHeight: 1.6 },
  '& code': {
    fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
    fontSize: '0.85em',
    bgcolor: pva('wf-signal', 0.08),
    color: pv('wf-signal'),
    px: 0.75,
    py: 0.25,
    borderRadius: 0,
    fontWeight: 500,
  },
  '& pre': {
    fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
    fontSize: '12px',
    bgcolor: 'wf.ink',
    border: '1px solid',
    borderColor: 'wf.steel',
    p: 2,
    borderRadius: 0,
    overflowX: 'auto',
    mb: 1.5,
    lineHeight: 1.6,
  },
  '& pre code': { bgcolor: 'transparent', color: 'text.primary', p: 0, fontWeight: 400 },
  '& table': {
    width: '100%',
    borderCollapse: 'collapse',
    mb: 1.5,
  },
  '& th, & td': {
    border: '1px solid',
    borderColor: 'wf.steel',
    px: 1.5,
    py: 0.75,
    verticalAlign: 'top',
  },
  '& td': { typography: 'wfCode' },
  '& th': {
    typography: 'wfLabel',
    bgcolor: pva('wf-signal', 0.06),
    textAlign: 'left',
  },
  '& blockquote': {
    borderLeft: '3px solid',
    borderColor: pv('wf-signal'),
    pl: 2,
    ml: 0,
    my: 1,
    color: 'text.secondary',
  },
  '& strong': { fontWeight: 600 },
  '& em': { color: 'text.secondary' },
  '& hr': { border: 'none', borderTop: '1px solid', borderColor: 'wf.steel', my: 2 },
  /* GFM task-list checkboxes (`- [x] ...`) come from react-markdown
     as raw <input type="checkbox" disabled checked={…}>. We can't
     swap in the wf Checkbox primitive (no React tree control), so
     we mirror its CSS chrome via appearance:none + pseudo-elements
     — same 14x14 sharp square, same wf.signal fill + ink checkmark. */
  '& input[type="checkbox"]': {
    appearance: 'none',
    WebkitAppearance: 'none',
    width: 14,
    height: 14,
    margin: '0 8px 0 0',
    padding: 0,
    position: 'relative',
    display: 'inline-block',
    verticalAlign: 'middle',
    bgcolor: 'wf.ink',
    border: '1px solid',
    borderColor: 'wf.graphite',
    borderRadius: 0,
    flexShrink: 0,
  },
  '& input[type="checkbox"]:checked': {
    bgcolor: pv('wf-signal'),
    borderColor: pv('wf-signal'),
  },
  '& input[type="checkbox"]:checked::after': {
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
} as const
