import type { Task } from '../types'

/* ═══ Constants ═══ */

export const NODE_W = 240
/* 72 = 2 content rows (title + chips/icons, ~42px) + ~16px headroom
   reserved for a future bottom-aligned progress bar. Existing content
   stays vertically centered until that bar is wired in. */
export const NODE_H = 72
export const GAP_X = 28
export const GAP_Y = 24

/* ═══ Types ═══ */

export interface TreeNode {
  task: Task
  col: number
  row: number
  children: string[]
}

export interface CollapsedChain {
  summaryId: string
  names: string[]
  count: number
}

export interface LayoutResult {
  nodes: Map<string, TreeNode>
  maxCol: number
  maxRow: number
}

export interface CollapsedLayoutResult extends LayoutResult {
  chains: Map<string, CollapsedChain>
}

/* ═══ buildTreeLayout ═══ */

export function buildTreeLayout(tasks: Task[]): LayoutResult {
  if (tasks.length === 0) return { nodes: new Map(), maxCol: 0, maxRow: 0 }

  const byId = new Map(tasks.map((t) => [t.id, t]))
  const childrenOf = new Map<string, string[]>()
  const roots: string[] = []

  for (const t of tasks) {
    const deps = (t.depends ?? []).filter((d) => byId.has(d))
    if (deps.length === 0) roots.push(t.id)
    for (const d of deps) {
      childrenOf.set(d, [...(childrenOf.get(d) ?? []), t.id])
    }
  }

  if (roots.length === 0) roots.push(tasks[0].id)

  /* User-request 2026-05-08: when several roots compete for col 0,
     sort by descending descendant-chain depth so the longest chain
     wins row 0. Without this, the OIH POLISH+QA layout placed
     cross-scenario-eval (depth 1) on row 0 and pushed e2e-pipeline
     (depth 2) to row 1, forcing e2e-ui to col 1 row 0 and producing
     visually-confusing connectors. Tie-break preserves YAML order
     (stable sort) so the diamond pattern in watchfloor-list-filters
     keeps its existing layout. */
  const depthOf = new Map<string, number>()
  const computeDepth = (id: string, seen: Set<string>): number => {
    if (depthOf.has(id)) return depthOf.get(id)!
    if (seen.has(id)) return 0
    seen.add(id)
    const kids = childrenOf.get(id) ?? []
    if (kids.length === 0) {
      depthOf.set(id, 0)
      return 0
    }
    let maxKid = 0
    for (const c of kids) {
      const d = computeDepth(c, seen)
      if (d > maxKid) maxKid = d
    }
    seen.delete(id)
    const d = maxKid + 1
    depthOf.set(id, d)
    return d
  }
  for (const r of roots) computeDepth(r, new Set())
  const sortedRoots = [...roots].sort(
    (a, b) => (depthOf.get(b) ?? 0) - (depthOf.get(a) ?? 0),
  )

  const colOf = new Map<string, number>()
  const queue = sortedRoots.map((id) => ({ id, col: 0 }))

  while (queue.length > 0) {
    const { id, col } = queue.shift()!
    const prev = colOf.get(id) ?? -1
    if (col <= prev) continue
    colOf.set(id, col)
    for (const child of childrenOf.get(id) ?? []) {
      queue.push({ id: child, col: col + 1 })
    }
  }

  for (const t of tasks) {
    if (!colOf.has(t.id)) colOf.set(t.id, 0)
  }

  // Identify isolated tasks (no deps AND nothing depends on them)
  const dependedOn = new Set<string>()
  for (const [, kids] of childrenOf) for (const c of kids) dependedOn.add(c)
  const isolated = new Set(
    tasks
      .filter((t) => (t.depends ?? []).filter((d) => byId.has(d)).length === 0)
      .filter((t) => (childrenOf.get(t.id) ?? []).length === 0)
      .map((t) => t.id),
  )

  const colGroups = new Map<number, string[]>()
  for (const [id, col] of colOf) {
    if (!isolated.has(id)) {
      const g = colGroups.get(col) ?? []
      g.push(id)
      colGroups.set(col, g)
    }
  }

  const nodes = new Map<string, TreeNode>()
  let maxCol = 0
  let maxRow = 0

  // Place connected tasks first
  for (const [col, ids] of colGroups) {
    ids.forEach((id, rowIdx) => {
      nodes.set(id, {
        task: byId.get(id)!,
        col,
        row: rowIdx,
        children: (childrenOf.get(id) ?? []).filter((c) => byId.has(c)),
      })
      if (col > maxCol) maxCol = col
      if (rowIdx > maxRow) maxRow = rowIdx
    })
  }

  // Place isolated tasks at col 0, on their own rows below connected tasks.
  // Audit-15c #12 - when there are NO connected tasks, start at row 0 instead
  // of row 1; otherwise an all-isolated phase wastes the top row and the panel
  // renders one row taller than a sibling phase with the same task count chained
  // via depends.
  if (isolated.size > 0) {
    const hasConnected = colGroups.size > 0
    let isoRow = hasConnected ? maxRow + 1 : 0
    for (const id of isolated) {
      nodes.set(id, {
        task: byId.get(id)!,
        col: 0,
        row: isoRow,
        children: [],
      })
      if (isoRow > maxRow) maxRow = isoRow
      isoRow++
    }
  }

  return { nodes, maxCol, maxRow }
}

/* ═══ collapseCompletedChains ═══ */

export function collapseCompletedChains(
  nodes: Map<string, TreeNode>,
  maxCol: number,
): CollapsedLayoutResult {
  const parentOf = new Map<string, string>()
  for (const [id, node] of nodes) {
    for (const childId of node.children) {
      parentOf.set(childId, id)
    }
  }

  const visited = new Set<string>()
  const chainsToCollapse: string[][] = []

  for (const [id, node] of nodes) {
    if (visited.has(id)) continue
    if (node.task.status !== 'done') continue
    if (node.children.length !== 1) continue

    const chain: string[] = [id]
    let current = id
    while (true) {
      const curNode = nodes.get(current)!
      if (curNode.children.length !== 1) break
      const next = curNode.children[0]
      const nextNode = nodes.get(next)
      if (!nextNode || nextNode.task.status !== 'done') break
      const nextParent = parentOf.get(next)
      if (nextParent !== current) break
      chain.push(next)
      current = next
    }

    if (chain.length >= 3) {
      for (const cid of chain) visited.add(cid)
      chainsToCollapse.push(chain)
    }
  }

  if (chainsToCollapse.length === 0) {
    let mRow = 0
    for (const [, n] of nodes) if (n.row > mRow) mRow = n.row
    return { nodes, maxCol, maxRow: mRow, chains: new Map() }
  }

  const newNodes = new Map<string, TreeNode>()
  const removedIds = new Set<string>()
  const chains = new Map<string, CollapsedChain>()

  for (const chain of chainsToCollapse) {
    for (const cid of chain) removedIds.add(cid)
    const firstNode = nodes.get(chain[0])!
    const lastNode = nodes.get(chain[chain.length - 1])!
    const summaryId = `__collapsed_${chain[0]}`
    const names = chain.map((cid) => nodes.get(cid)!.task.name)

    chains.set(summaryId, { summaryId, names, count: chain.length })

    newNodes.set(summaryId, {
      task: {
        id: summaryId,
        name: `${chain.length} completed steps`,
        status: 'done',
      },
      col: firstNode.col,
      row: firstNode.row,
      children: lastNode.children.filter((c) => !removedIds.has(c)),
    })
  }

  for (const [id, node] of nodes) {
    if (removedIds.has(id)) continue
    const newChildren = node.children.map((cid) => {
      if (removedIds.has(cid)) {
        for (const chain of chainsToCollapse) {
          if (chain[0] === cid) return `__collapsed_${chain[0]}`
        }
      }
      return cid
    }).filter((c) => !removedIds.has(c) || c.startsWith('__collapsed_'))
    newNodes.set(id, { ...node, children: newChildren })
  }

  for (const [id, node] of newNodes) {
    if (id.startsWith('__collapsed_')) continue
    const fixed = node.children.map((cid) => {
      if (removedIds.has(cid)) {
        for (const chain of chainsToCollapse) {
          if (chain.includes(cid)) return `__collapsed_${chain[0]}`
        }
      }
      return cid
    })
    newNodes.set(id, { ...node, children: [...new Set(fixed)] })
  }

  const roots: string[] = []
  const allChildren = new Set<string>()
  for (const [, n] of newNodes) for (const c of n.children) allChildren.add(c)
  for (const [nid] of newNodes) if (!allChildren.has(nid)) roots.push(nid)
  if (roots.length === 0 && newNodes.size > 0) roots.push(newNodes.keys().next().value!)

  const colOf = new Map<string, number>()
  const bfsQueue = roots.map((nid) => ({ id: nid, col: 0 }))
  while (bfsQueue.length > 0) {
    const { id, col } = bfsQueue.shift()!
    const prev = colOf.get(id) ?? -1
    if (col <= prev) continue
    colOf.set(id, col)
    const n = newNodes.get(id)
    if (n) for (const child of n.children) bfsQueue.push({ id: child, col: col + 1 })
  }

  const colGroups = new Map<number, string[]>()
  for (const [id, col] of colOf) {
    const g = colGroups.get(col) ?? []
    g.push(id)
    colGroups.set(col, g)
  }

  let newMaxCol = 0
  let newMaxRow = 0
  for (const [col, ids] of colGroups) {
    ids.forEach((id, rowIdx) => {
      const existing = newNodes.get(id)!
      newNodes.set(id, { ...existing, col, row: rowIdx })
      if (col > newMaxCol) newMaxCol = col
      if (rowIdx > newMaxRow) newMaxRow = rowIdx
    })
  }

  return { nodes: newNodes, maxCol: newMaxCol, maxRow: newMaxRow, chains }
}
