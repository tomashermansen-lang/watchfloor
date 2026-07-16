import { useState, useEffect } from 'react'

interface Artifact {
  name: string
  file: string
}

/**
 * Fetches the list of available doc artifacts for a task in a project.
 * Returns artifact list and loading state. Caches per cwd+task combination.
 */
export function usePlanArtifacts(cwd: string | null, task: string | null): Artifact[] {
  const [artifacts, setArtifacts] = useState<Artifact[]>([])

  useEffect(() => {
    if (!cwd || !task) {
      setArtifacts([])
      return
    }
    let cancelled = false
    fetch(`/api/plan/artifacts?cwd=${encodeURIComponent(cwd)}&task=${encodeURIComponent(task)}`)
      .then((res) => res.ok ? res.json() : [])
      .then((data) => {
        if (!cancelled) setArtifacts(data)
      })
      .catch(() => {
        if (!cancelled) setArtifacts([])
      })
    return () => { cancelled = true }
  }, [cwd, task])

  return artifacts
}
