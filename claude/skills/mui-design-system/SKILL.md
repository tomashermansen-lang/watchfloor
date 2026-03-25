---
name: mui-design-system
description: MUI v7 + MUI X + Recharts design system reference for dashboard UX and implementation. Use when designing components, reviewing UI code, or planning dashboard layouts with Material UI.
user-invocable: false
---

# MUI Design System

Design system reference for UX and implementation. Source of truth: `app/src/theme.ts`.

## Tech Stack

| Library | Version | Purpose | License |
|---------|---------|---------|---------|
| `@mui/material` | v7 | Core component library | MIT |
| `@mui/x-data-grid` | v8 Community | Data tables with sort, filter, pagination | MIT |
| `@mui/x-date-pickers` | Community | Date/time selection | MIT |
| `@mui/x-tree-view` | Community | Hierarchical tree display | MIT |
| `@mui/x-charts` | Community | Built-in chart components | MIT |
| `recharts` | v3 | Custom data visualizations | MIT |
| `@mui/icons-material` | v7 | Material icon set | MIT |

## Key Rules

- **Never hardcode hex values** — use theme palette tokens
- **Border-based depth** — elevation 0 everywhere, depth via borders + surface layers
- **`pv()`/`pva()` for custom tokens** — `theme.palette.*` breaks in dark mode for custom properties
- **M3 typography variants** — prefer `titleLarge`, `labelMedium` etc. over `h6`, `subtitle1` for new code

## Reference Files

- **[tokens.md](tokens.md)** — Full palette, status colors, event type colors, surface layers, typography, spacing, motion tokens, breakpoints, CSS variable helpers
- **[components.md](components.md)** — Layout patterns, cards, chips, data tables, charts, navigation, feedback/loading, session status mapping

## Accessibility (WCAG 2.1 AAA)

### Contrast Requirements
- Normal text: 7:1 minimum
- Large text / UI components: 4.5:1 minimum
- Adjacent chart data series: 3:1 minimum

### MUI Built-in Support
- All interactive components are keyboard-navigable
- `Button`, `IconButton`, `Chip` have focus rings
- `DataGrid` supports keyboard navigation
- `Dialog` traps focus automatically
- `Tabs` support arrow-key navigation

### Required Manual Work
- `aria-label` on every `IconButton` (no visible text)
- `aria-live="polite"` on status regions that update dynamically
- Focus management for dialogs and drawers
- No color as sole differentiator — always pair with text labels
- Respect `prefers-reduced-motion` — disable chart animations
- Respect `prefers-color-scheme` — auto dark mode via `CssBaseline`

## Dark Mode

Full separate dark palette (not auto-generated):

```tsx
cssVariables: { colorSchemeSelector: 'data' }
colorSchemes: { light: { palette: {...} }, dark: { palette: {...} } }
```

All custom palette tokens have explicit dark values. Use `pv()`/`pva()` for correct dark mode resolution.

## Performance

- `React.lazy()` + `Suspense` for chart components (Recharts is heavy)
- `DataGrid` virtualizes rows by default — safe for 1000+ rows
- `Accordion` with `unmountOnExit` prevents rendering hidden content
- Avoid `Box` with `sx` prop in tight loops — prefer `styled()` for repeated elements

## Gotchas

- **`theme.palette.status.*` returns static light-mode hex** for custom
  properties. Always use `pv('status-done')` instead — CSS variables resolve
  correctly in both light and dark mode. This is the single most common bug
  in dashboard UI code.
- **Recharts tooltips render outside the MUI theme provider** by default.
  Custom tooltip components must wrap content in `<ThemeProvider>` or use
  inline styles with theme values passed as props.
- **`DataGrid` column `flex` and `width` conflict.** If you set both, the
  behavior is unpredictable across breakpoints. Use `flex` for responsive
  columns, `width` for fixed ones — never both on the same column.
- **MUI v7 `Grid2` is not `Grid`.** Import from `@mui/material/Grid2`, not
  `@mui/material/Grid`. The old Grid uses a different API (item/container
  props vs. size prop).
