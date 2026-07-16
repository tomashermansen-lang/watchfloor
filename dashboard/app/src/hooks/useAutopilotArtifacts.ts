import { useState, useEffect } from 'react'

interface Artifact {
  name: string
  file: string
}

/**
 * Fetches the list of available doc artifacts for an autopilot task.
 * Polls every 10s while task is non-null to pick up new docs as phases complete.
 */
export function useAutopilotArtifacts(task: string | null): Artifact[] {
  const [artifacts, setArtifacts] = useState<Artifact[]>([])

  useEffect(() => {
    if (!task) {
      setArtifacts([])
      return
    }
    let cancelled = false

    const fetchArtifacts = () => {
      fetch(`/api/autopilot/artifacts?task=${encodeURIComponent(task)}`)
        .then((res) => res.ok ? res.json() : [])
        .then((data) => {
          if (!cancelled) setArtifacts(data)
        })
        .catch(() => {
          if (!cancelled) setArtifacts([])
        })
    }

    fetchArtifacts()
    const id = setInterval(fetchArtifacts, 10000)
    return () => { cancelled = true; clearInterval(id) }
  }, [task])

  return artifacts
}
