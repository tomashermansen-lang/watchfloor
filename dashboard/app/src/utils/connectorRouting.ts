/* SVG connector routing for the Pipeline phase tree.

   User-request 2026-05-08: connectors used to draw their horizontal
   segments at the source / target row's midY, which visually crossed
   any task box that happened to sit on that row between them. Two
   common patterns produced the through-box appearance:

   1. Multi-parent same-row diamond — qa-rapport in OIH's POLISH+QA
      phase has cross-scenario-eval (col 0) AND e2e-ui (col 1) as
      direct parents, both on row 0. The cross→qa connector at row 0
      midY visually pierces e2e-ui in col 1.

   2. Transitive-redundancy multi-row — baseline-quality-gate in OIH's
      BASELINE QUALITY phase listed coverage-infrastructure explicitly
      as a dep even though it was reachable transitively via the chain.
      The connector elbow landed on the row of an intermediate sibling.
      We patched the OIH plan to remove the redundant edge, but the
      structural risk remains (other plans may write the same pattern
      and the layout cannot disambiguate).

   These helpers detect both patterns and route the path through the
   gap between rows (or just below the source row for same-row through-
   box) using a U-shaped detour. Brand-aesthetic kept: every segment is
   a sharp 90° elbow, no curves. */

export interface NodeRect {
  id: string
  left: number
  right: number
  top: number
  bottom: number
}

/** True when a horizontal segment from (xA, y) to (xB, y) intersects
 *  any rectangle in `rects`. `excludeIds` skips source/target self-hits. */
export function segmentCrossesAnyBox(
  xA: number,
  xB: number,
  y: number,
  rects: readonly NodeRect[],
  excludeIds: ReadonlySet<string>,
): boolean {
  const xMin = Math.min(xA, xB)
  const xMax = Math.max(xA, xB)
  for (const r of rects) {
    if (excludeIds.has(r.id)) continue
    if (y < r.top || y > r.bottom) continue
    if (r.right < xMin || r.left > xMax) continue
    return true
  }
  return false
}

export interface RoutePathArgs {
  x1: number
  y1: number
  x2: number
  y2: number
  /** Multi-parent convergence X (used by TreeConnectors so several
   *  lines into the same target child share a single vertical pipe). */
  viaX?: number
  /** All node rectangles in the same coordinate space as the line
   *  endpoints. Used to detect through-box collisions. */
  rects: readonly NodeRect[]
  /** Source + target node IDs — skipped during collision tests so the
   *  connector's own endpoints aren't counted as collisions. */
  excludeIds: ReadonlySet<string>
  /** Task node height in pixels — used to compute the same-row
   *  detour Y just below the source's bottom edge. */
  nodeH: number
  /** Vertical gap between rows in pixels — half this value lands the
   *  detour Y in the visual gap. */
  gapY: number
}

/** Compose an orthogonal SVG path from source (x1, y1) to target
 *  (x2, y2). When the simple 1- or 3-segment path would cross an
 *  intermediate box, a U-shaped detour through the row gap is used. */
export function routePath(args: RoutePathArgs): string {
  const { x1, y1, x2, y2, viaX, rects, excludeIds, nodeH, gapY } = args
  const sameRow = Math.abs(y2 - y1) < 1

  if (sameRow) {
    if (!segmentCrossesAnyBox(x1, x2, y1, rects, excludeIds)) {
      return `M ${x1} ${y1} H ${x2}`
    }
    /* Detour through the gap directly below the source row. */
    const detourY = y1 + nodeH / 2 + gapY / 2
    return `M ${x1} ${y1} V ${detourY} H ${x2} V ${y2}`
  }

  const mx = viaX ?? (x1 + x2) / 2
  const seg1Crosses = segmentCrossesAnyBox(x1, mx, y1, rects, excludeIds)
  const seg2Crosses = segmentCrossesAnyBox(mx, x2, y2, rects, excludeIds)
  if (!seg1Crosses && !seg2Crosses) {
    return `M ${x1} ${y1} H ${mx} V ${y2} H ${x2}`
  }

  /* Detour through the gap between source and target rows. */
  const detourY = (y1 + y2) / 2
  return `M ${x1} ${y1} V ${detourY} H ${x2} V ${y2}`
}
