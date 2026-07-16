# Theme Tokens Reference

Source of truth: `app/src/theme.ts`

## Palette

Nature-inspired palette — never hardcode hex values in components.

```
Primary:   #4A6741 (sage green) — brand actions, active states, links
Secondary: #8B7355 (warm brown) — secondary actions, accents
Background.default: #FAFAF7 (warm white)
Background.paper:   #F5F3EE (warm off-white)
Text.primary:   #2C2C2A
Text.secondary: #6B6B65
Divider: rgba(0, 0, 0, 0.08)
```

## Status Colors (3-tier system)

Three tiers for status display — use `pv()` helper for CSS variable access:

| Tier | Token pattern | Purpose |
|------|--------------|---------|
| Text | `palette.status.*` | Standalone status text color |
| Container | `palette.statusContainer.*` | Tonal chip/card background |
| On-container | `palette.onStatusContainer.*` | Text on tonal background |

Status keys: `pending`, `wip`, `done`, `failed`, `skipped`, `blocked`

Usage:
```
sx={{ bgcolor: pv('statusContainer-done'), color: pv('onStatusContainer-done') }}
```

## Event Type Colors

`palette.eventType.*` for tool call visualization:

```
tool         #4A7DB5 (blue)    — tool calls
error        #C07070 (red)     — errors
notification #C4943E (amber)   — notifications
subagent     #8B6BAE (purple)  — subagent activity
session      #6B9E6B (green)   — session lifecycle
permission   #C48040 (orange)  — permission requests
task         #4A9E8E (teal)    — task completions
prompt       #9CA3AF (gray)    — user prompts
```

## Surface Layers

Border-based depth instead of elevation — use surface tokens for hierarchy:

```
surface1:        #EFF2EB — slight emphasis (headers, sidebars)
surface2:        #E7EBE2 — medium emphasis
surface3:        #DFE3DA — high emphasis
surfaceVariant:  #DFE4D7 — variant surface
outline:         #737870 — high emphasis borders
outlineVariant:  #C3C8BB — low emphasis borders
```

## Typography

Font: **Inter Variable** + fallbacks.

**Standard MUI variants** (tuned weights):
```
h4:        400 / -0.02em / 1.2  — Page title
h5:        400 / -0.01em / 1.3  — Section heading
h6:        500 / -0.01em        — Subsection heading
subtitle1: 500 / 0.95rem        — Emphasized secondary
subtitle2: 500 / 0.8rem         — Smaller emphasized
body1:     default               — Default body
body2:     1.6 line-height       — Secondary body
caption:   0.75rem               — Timestamps, helper text
overline:  0.65rem / 500 / 0.1em — Category labels
```

**M3 custom variants** (prefer these for new code):
```
displayMedium:  2.8rem / 400 / 1.2   — Hero numbers, large KPIs
headlineSmall:  1.5rem / 500 / 1.3   — Section headings
titleLarge:     1.375rem / 500 / 1.3  — Card titles, panel headers
titleMedium:    1rem / 500 / 1.4      — Emphasized body, list item titles
titleSmall:     0.875rem / 500 / 1.4  — Small headers
labelLarge:     0.875rem / 500 / 1.4  — Button text, tab labels
labelMedium:    0.75rem / 500 / 1.3   — Secondary labels, metadata
labelSmall:     0.6875rem / 500 / 1.2 — Tiny labels, badges
```

## Spacing

8px base grid: `theme.spacing(1)` = 8px.

```
spacing(0.5)  = 4px   — tight padding (chips, badges)
spacing(1)    = 8px   — default inner padding
spacing(1.5)  = 12px  — card padding (preferred for dense layouts)
spacing(2)    = 16px  — gap between related items
spacing(3)    = 24px  — section spacing
spacing(4)    = 32px  — major section breaks
```

## Border Radius

```
shape.borderRadius: 8px  — default (cards, chips, inputs)
Dialog:             28px — M3 Extra-Large (set via component override)
```

## CSS Variable Helpers

From `app/src/utils/cssVars.ts` — required for custom palette tokens in dark mode:

```tsx
import { pv, pva } from '../utils/cssVars'

pv('status-done')          → var(--mui-palette-status-done)
pva('status-done', 0.14)   → color-mix(in srgb, var(--mui-palette-status-done) 14%, transparent)
```

Why: `theme.palette.*` returns static light-mode values for custom properties. CSS variables resolve correctly in both modes.

## Motion Tokens

CSS custom properties on `:root`:

```
Easing:
  --motion-emphasized:            cubic-bezier(0.2, 0, 0, 1)
  --motion-emphasized-decelerate: cubic-bezier(0.05, 0.7, 0.1, 1)
  --motion-emphasized-accelerate: cubic-bezier(0.3, 0, 0.8, 0.15)
  --motion-standard:              cubic-bezier(0.2, 0, 0, 1)

Duration:
  --motion-short3:  150ms    --motion-short4:  200ms
  --motion-medium1: 250ms    --motion-medium2: 300ms

Usage: transition: all var(--motion-short4) var(--motion-emphasized)
```

## Breakpoints

```
xs: 0px      — mobile
sm: 600px    — tablet portrait
md: 900px    — tablet landscape / small desktop
lg: 1200px   — desktop
xl: 1536px   — wide desktop
```
