import type { WhereBlock } from '../types'

export function whereSummary(where: WhereBlock | undefined | null): string | null {
  if (!where) return null
  const m = where.modify?.length ?? 0
  const c = where.create?.length ?? 0
  const d = where.delete?.length ?? 0
  if (m === 0 && c === 0 && d === 0) return null
  const parts: string[] = []
  if (m > 0) parts.push(`modify ${m}`)
  if (c > 0) parts.push(`create ${c}`)
  if (d > 0) parts.push(`delete ${d}`)
  return parts.join(' · ')
}
