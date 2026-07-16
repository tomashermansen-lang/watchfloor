import type { Plan } from '../types'

export type ArtifactRefResolution =
  | { resolved: true; url: string }
  | { resolved: false; tooltip: string }

export interface ResolveArgs {
  value: string
  plan: Plan
  planDir: string | null
  taskId: string
}

function joinPath(base: string, rel: string): string {
  if (rel.startsWith('/')) return rel
  if (!base) return rel
  const trimmedBase = base.replace(/\/+$/, '')
  return `${trimmedBase}/${rel}`
}

export function resolveArtifactRef({ value, plan, planDir, taskId }: ResolveArgs): ArtifactRefResolution {
  if (!value) {
    return { resolved: false, tooltip: 'Empty artifact reference' }
  }

  const colonIdx = value.indexOf(':')
  if (colonIdx > 0) {
    const projectId = value.slice(0, colonIdx)
    const relPath = value.slice(colonIdx + 1)
    const target = (plan.test_targets ?? []).find((t) => t.id === projectId)
    if (!target) {
      return { resolved: false, tooltip: `Unknown project '${projectId}'` }
    }
    const projectRoot = planDir ? joinPath(planDir, target.path) : target.path
    if (projectRoot.split('/').some((seg) => seg === '..')) {
      return { resolved: false, tooltip: 'Unsafe project path in test_targets' }
    }
    const url =
      `/api/plan/artifact?cwd=${encodeURIComponent(projectRoot)}` +
      `&task=${encodeURIComponent(taskId)}` +
      `&file=${encodeURIComponent(relPath)}`
    return { resolved: true, url }
  }

  if (!planDir) {
    return { resolved: false, tooltip: 'No plan directory available' }
  }

  const url =
    `/api/plan/artifact?plan_dir=${encodeURIComponent(planDir)}` +
    `&file=${encodeURIComponent(value)}`
  return { resolved: true, url }
}
