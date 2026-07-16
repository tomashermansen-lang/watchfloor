import { describe, it, expect } from 'vitest'
import {
  segmentCrossesAnyBox,
  routePath,
  type NodeRect,
} from '../utils/connectorRouting'

/* ═══ connectorRouting helpers ═══

   User-request 2026-05-08: route SVG path connectors so they avoid
   passing through intermediate task boxes when source and target are
   on the same row (qa-rapport case) or multi-row with a viaX that
   puts the elbow inside an occupied cell (transitive-redundancy case).
   See the OIH plan analysis: docs/INPROGRESS_Plan_oih shows both
   patterns; we already fixed the transitive-redundancy case via plan
   edit, but the multi-parent-same-row case is structural and needs
   the routing-layer fix below. */

const SRC: NodeRect = { id: 'src', left: 0, right: 100, top: 0, bottom: 50 }
const TGT: NodeRect = { id: 'tgt', left: 400, right: 500, top: 0, bottom: 50 }
const MIDDLE: NodeRect = {
  id: 'middle', left: 200, right: 300, top: 0, bottom: 50,
}

describe('segmentCrossesAnyBox', () => {
  it('returns true when a horizontal segment passes through a box', () => {
    expect(
      segmentCrossesAnyBox(0, 500, 25, [MIDDLE], new Set()),
    ).toBe(true)
  })

  it('returns false when the segment is above the box', () => {
    expect(
      segmentCrossesAnyBox(0, 500, -10, [MIDDLE], new Set()),
    ).toBe(false)
  })

  it('returns false when the segment is below the box', () => {
    expect(
      segmentCrossesAnyBox(0, 500, 100, [MIDDLE], new Set()),
    ).toBe(false)
  })

  it('returns false when the segment ends before the box left edge', () => {
    expect(
      segmentCrossesAnyBox(0, 150, 25, [MIDDLE], new Set()),
    ).toBe(false)
  })

  it('returns false when the segment starts after the box right edge', () => {
    expect(
      segmentCrossesAnyBox(350, 500, 25, [MIDDLE], new Set()),
    ).toBe(false)
  })

  it('respects excluded ids (source/target self-skip)', () => {
    expect(
      segmentCrossesAnyBox(
        0, 500, 25, [SRC, MIDDLE, TGT], new Set(['src', 'tgt']),
      ),
    ).toBe(true)
    expect(
      segmentCrossesAnyBox(
        0, 500, 25, [SRC, MIDDLE, TGT],
        new Set(['src', 'middle', 'tgt']),
      ),
    ).toBe(false)
  })

  it('handles reversed x-order (xA > xB) by normalising', () => {
    expect(
      segmentCrossesAnyBox(500, 0, 25, [MIDDLE], new Set()),
    ).toBe(true)
  })
})

describe('routePath', () => {
  const NODE_H = 50
  const GAP_Y = 40
  const SAME_ROW_Y = 25

  it('same-row with no intermediate box returns straight horizontal', () => {
    /* coverage→reliability adjacent: simple H. */
    const path = routePath({
      x1: 100, y1: SAME_ROW_Y, x2: 200, y2: SAME_ROW_Y,
      rects: [SRC, TGT],
      excludeIds: new Set(['src', 'tgt']),
      nodeH: NODE_H, gapY: GAP_Y,
    })
    expect(path).toBe('M 100 25 H 200')
  })

  it('same-row with intermediate box detours through gap below', () => {
    /* qa-rapport case: cross-scenario-eval (col 0) → qa-rapport (col 2)
       crosses e2e-ui (col 1). Must route through the gap below row 0. */
    const path = routePath({
      x1: 100, y1: SAME_ROW_Y, x2: 400, y2: SAME_ROW_Y,
      rects: [SRC, MIDDLE, TGT],
      excludeIds: new Set(['src', 'tgt']),
      nodeH: NODE_H, gapY: GAP_Y,
    })
    /* detour Y = source midY + nodeH/2 + gapY/2 = 25 + 25 + 20 = 70. */
    expect(path).toBe('M 100 25 V 70 H 400 V 25')
  })

  it('multi-row with no intermediate-box collision uses 3-segment path', () => {
    const TGT_ROW1: NodeRect = {
      id: 'tgt', left: 400, right: 500, top: 90, bottom: 140,
    }
    const path = routePath({
      x1: 100, y1: 25, x2: 400, y2: 115,
      rects: [SRC, TGT_ROW1],
      excludeIds: new Set(['src', 'tgt']),
      nodeH: NODE_H, gapY: GAP_Y,
    })
    /* 3-segment: H to mx, V to y2, H to x2. mx default = (100+400)/2 = 250. */
    expect(path).toBe('M 100 25 H 250 V 115 H 400')
  })

  it('multi-row with intermediate box on horizontal segment detours through gap', () => {
    /* Transitive-redundancy case: parent on row 0 col 0, child on row 1
       col 2, with a sibling on row 0 col 1 between them. */
    const TGT_ROW1: NodeRect = {
      id: 'tgt', left: 400, right: 500, top: 90, bottom: 140,
    }
    const path = routePath({
      x1: 100, y1: 25, x2: 400, y2: 115,
      rects: [SRC, MIDDLE, TGT_ROW1],
      excludeIds: new Set(['src', 'tgt']),
      nodeH: NODE_H, gapY: GAP_Y,
    })
    /* Detour Y = (25 + 115) / 2 = 70 (gap between rows). */
    expect(path).toBe('M 100 25 V 70 H 400 V 115')
  })

  it('respects viaX when no through-box collision', () => {
    /* Multi-parent convergence supplies viaX explicitly. */
    const TGT_ROW1: NodeRect = {
      id: 'tgt', left: 400, right: 500, top: 90, bottom: 140,
    }
    const path = routePath({
      x1: 100, y1: 25, x2: 400, y2: 115,
      viaX: 380,
      rects: [SRC, TGT_ROW1],
      excludeIds: new Set(['src', 'tgt']),
      nodeH: NODE_H, gapY: GAP_Y,
    })
    expect(path).toBe('M 100 25 H 380 V 115 H 400')
  })
})
