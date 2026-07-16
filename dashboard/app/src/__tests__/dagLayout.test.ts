import { describe, it, expect } from 'vitest'
import { buildTreeLayout, collapseCompletedChains, NODE_W, NODE_H, GAP_X, GAP_Y } from '../utils/dagLayout'
import type { Task } from '../types'

function task(id: string, status: string = 'pending', depends: string[] = []): Task {
  return { id, name: id, status: status as Task['status'], depends }
}

describe('buildTreeLayout', () => {
  it('returns empty result for no tasks', () => {
    const result = buildTreeLayout([])
    expect(result.nodes.size).toBe(0)
    expect(result.maxCol).toBe(0)
  })

  it('assigns col 0 to root tasks', () => {
    const result = buildTreeLayout([task('a'), task('b')])
    expect(result.nodes.get('a')!.col).toBe(0)
    expect(result.nodes.get('b')!.col).toBe(0)
  })

  it('assigns sequential columns for linear dependencies', () => {
    const result = buildTreeLayout([
      task('a'),
      task('b', 'pending', ['a']),
      task('c', 'pending', ['b']),
    ])
    expect(result.nodes.get('a')!.col).toBe(0)
    expect(result.nodes.get('b')!.col).toBe(1)
    expect(result.nodes.get('c')!.col).toBe(2)
    expect(result.maxCol).toBe(2)
  })

  it('assigns rows within the same column', () => {
    const result = buildTreeLayout([task('a'), task('b'), task('c')])
    const rows = [
      result.nodes.get('a')!.row,
      result.nodes.get('b')!.row,
      result.nodes.get('c')!.row,
    ]
    expect(new Set(rows).size).toBe(3)
  })

  it('tracks children references', () => {
    const result = buildTreeLayout([task('a'), task('b', 'pending', ['a'])])
    expect(result.nodes.get('a')!.children).toContain('b')
  })

  it('places isolated tasks at col 0 on their own rows below connected tasks', () => {
    // db-indexes is isolated (no deps, nothing depends on it)
    // absence-aware-capacity → two-layer-allocation is a connected chain
    const result = buildTreeLayout([
      task('absence-aware-capacity'),
      task('two-layer-allocation', 'pending', ['absence-aware-capacity']),
      task('db-indexes'),
    ])
    expect(result.nodes.get('absence-aware-capacity')!.col).toBe(0)
    expect(result.nodes.get('absence-aware-capacity')!.row).toBe(0)
    expect(result.nodes.get('two-layer-allocation')!.col).toBe(1)
    // db-indexes stays at col 0 but on its own row below connected tasks
    expect(result.nodes.get('db-indexes')!.col).toBe(0)
    expect(result.nodes.get('db-indexes')!.row).toBeGreaterThan(
      result.nodes.get('absence-aware-capacity')!.row,
    )
  })

  it('keeps all-independent tasks at col 0', () => {
    // When ALL tasks are independent (all isolated), keep at col 0
    const result = buildTreeLayout([task('a'), task('b'), task('c')])
    expect(result.nodes.get('a')!.col).toBe(0)
    expect(result.nodes.get('b')!.col).toBe(0)
    expect(result.nodes.get('c')!.col).toBe(0)
  })

  /* Audit-15c #12 - when there are NO connected tasks at all,
     isolated tasks should fill the layout starting from row 0
     (not row 1). Phases with N isolated tasks otherwise rendered
     as a tree of N+1 rows (one blank row at the top). */
  it('places isolated tasks starting at row 0 when there are no connected tasks', () => {
    const result = buildTreeLayout([task('a'), task('b'), task('c')])
    const rows = ['a', 'b', 'c'].map((id) => result.nodes.get(id)!.row).sort((x, y) => x - y)
    expect(rows).toEqual([0, 1, 2])
    expect(result.maxRow).toBe(2)
  })

  it('mixed connected + isolated still keeps isolated below connected', () => {
    const result = buildTreeLayout([
      task('a'),
      task('b', 'pending', ['a']),
      task('iso'),
    ])
    const connectedRow = result.nodes.get('a')!.row
    const isoRow = result.nodes.get('iso')!.row
    expect(connectedRow).toBe(0)
    expect(isoRow).toBeGreaterThan(connectedRow)
  })
})

describe('collapseCompletedChains', () => {
  it('does not collapse chains shorter than 3', () => {
    const { nodes } = buildTreeLayout([
      task('a', 'done'),
      task('b', 'done', ['a']),
    ])
    const result = collapseCompletedChains(nodes, 1)
    expect(result.chains.size).toBe(0)
    expect(result.nodes.size).toBe(2)
  })

  it('collapses a chain of 3+ done nodes into a summary', () => {
    const { nodes, maxCol } = buildTreeLayout([
      task('a', 'done'),
      task('b', 'done', ['a']),
      task('c', 'done', ['b']),
    ])
    const result = collapseCompletedChains(nodes, maxCol)
    expect(result.chains.size).toBe(1)
    const chain = result.chains.values().next().value!
    expect(chain.count).toBe(3)
    expect(chain.names).toEqual(['a', 'b', 'c'])
  })
})

/* User-request 2026-05-08: when several roots compete for col 0, the
   one with the LONGEST descendant chain wins row 0 so its chain stays
   horizontal. The OIH POLISH+QA case had cross-scenario-eval (depth 1)
   on row 0 and e2e-pipeline (depth 2) on row 1, which forced e2e-ui
   on row 0 col 1 — visually a mess because e2e-pipeline→e2e-ui had to
   elbow up across the gap. Putting the deeper chain on row 0 keeps
   each chain on a single horizontal row with cleaner connectors. */
describe('buildTreeLayout - longest-chain-on-row-0 ordering', () => {
  it('places the root with the longest descendant chain on row 0', () => {
    const result = buildTreeLayout([
      task('cross-scenario-eval'),
      task('e2e-pipeline'),
      task('e2e-ui', 'pending', ['e2e-pipeline']),
      task('readme'),
      task('ai-act-reflection'),
      task('qa-rapport', 'pending', ['cross-scenario-eval', 'e2e-ui']),
      task('eval-dashboard'),
    ])
    /* e2e-pipeline (depth 2) wins row 0 over cross-scenario-eval (depth 1). */
    expect(result.nodes.get('e2e-pipeline')!.row).toBe(0)
    expect(result.nodes.get('cross-scenario-eval')!.row).toBe(1)
    /* e2e-ui chains horizontally from e2e-pipeline on row 0. */
    expect(result.nodes.get('e2e-ui')!.row).toBe(0)
    expect(result.nodes.get('e2e-ui')!.col).toBe(1)
    /* qa-rapport ends the chain at row 0 col 2. */
    expect(result.nodes.get('qa-rapport')!.row).toBe(0)
    expect(result.nodes.get('qa-rapport')!.col).toBe(2)
  })

  it('preserves YAML order when chain depths tie', () => {
    /* Diamond-without-skip pattern (watchfloor-list-filters Phase 3):
       both roots have depth 1, so tie-break by YAML insertion order. */
    const result = buildTreeLayout([
      task('feature-filter-state-hook'),
      task('plans-filter-state-hook'),
      task('filter-hooks-factory', 'pending', [
        'feature-filter-state-hook',
        'plans-filter-state-hook',
      ]),
    ])
    expect(result.nodes.get('feature-filter-state-hook')!.row).toBe(0)
    expect(result.nodes.get('plans-filter-state-hook')!.row).toBe(1)
  })

  it('sorts a 3-root scenario by descending chain depth', () => {
    const result = buildTreeLayout([
      task('shallow'),
      task('medium'),
      task('deep'),
      task('m-child', 'pending', ['medium']),
      task('d-child', 'pending', ['deep']),
      task('d-grand', 'pending', ['d-child']),
    ])
    expect(result.nodes.get('deep')!.row).toBe(0)
    expect(result.nodes.get('medium')!.row).toBe(1)
    expect(result.nodes.get('shallow')!.row).toBe(2)
  })
})

describe('constants', () => {
  /* NODE_H=72 leaves ~16px headroom below the existing 2-row content
     (title + chips/icons) so a future progress bar can drop in
     without forcing another layout pass on every consumer of NODE_H. */
  it('exports layout constants', () => {
    expect(NODE_W).toBe(240)
    expect(NODE_H).toBe(72)
    expect(GAP_X).toBe(28)
    expect(GAP_Y).toBe(24)
  })
})
