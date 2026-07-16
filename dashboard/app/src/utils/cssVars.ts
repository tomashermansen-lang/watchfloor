/**
 * Dark-mode-safe CSS variable helpers for MUI palette access.
 *
 * In MUI v7 CSS variables mode, `theme.palette.*` returns static light-mode
 * values for custom palette properties. These helpers return CSS variable
 * references that resolve correctly in both light and dark modes.
 */

/** CSS variable reference for a MUI palette path, e.g. pv('status-done') → var(--mui-palette-status-done) */
export const pv = (path: string): string => `var(--mui-palette-${path})`

/** CSS variable with alpha transparency via color-mix(), e.g. pva('status-done', 0.5) */
export const pva = (path: string, opacity: number): string =>
  `color-mix(in srgb, var(--mui-palette-${path}) ${Math.round(opacity * 100)}%, transparent)`
