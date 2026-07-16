import type { Plan } from '../types'

export function isPlan2(plan: Pick<Plan, 'schema_version'> | null | undefined): boolean {
  if (!plan || typeof plan.schema_version !== 'string') return false
  return plan.schema_version.startsWith('2.')
}

export function SCHEMA_MAJOR(plan: Pick<Plan, 'schema_version'>): string {
  const sv = plan.schema_version ?? ''
  return sv.split('.')[0] ?? ''
}
