import type { Plan } from '../types'
import { isPlan2 } from './planVersion'

export interface PlanValidity {
  valid: boolean
  errors: string[]
  totalCount: number
}

const REQUIRED_2_0_FIELDS: ReadonlyArray<keyof Plan> = [
  'schema_version', 'name', 'vision', 'users', 'success_criteria', 'scope',
  'tech_stack', 'existing_infrastructure_to_reuse', 'test_targets', 'setup',
  'kill_criteria', 'design_notes', 'risks', 'phases',
]

const ERROR_CAP = 5

export function planValidity(plan: Plan | null | undefined): PlanValidity {
  if (!plan) {
    return { valid: false, errors: ['Plan is missing'], totalCount: 1 }
  }
  const errors: string[] = []
  if (isPlan2(plan)) {
    const planRec = plan as unknown as Record<string, unknown>
    for (const field of REQUIRED_2_0_FIELDS) {
      const v = planRec[field as string]
      if (v === undefined || v === null || v === '') {
        errors.push(`missing required field '${String(field)}'`)
      }
    }
  } else {
    if (!plan.name) errors.push("missing required field 'name'")
    if (!plan.phases) errors.push("missing required field 'phases'")
  }
  return {
    valid: errors.length === 0,
    errors: errors.slice(0, ERROR_CAP),
    totalCount: errors.length,
  }
}
