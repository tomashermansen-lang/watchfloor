import useSWR from 'swr'

interface FeatureArtifact {
  name: string
  file: string
}

const fetcher = (url: string) => fetch(url).then((r) => {
  if (!r.ok) throw new Error(`HTTP ${r.status}`)
  return r.json()
})

export function useFeatureArtifacts(feature: string | null, projectRoot: string | null) {
  const key = feature && projectRoot
    ? `/api/feature/artifacts?feature=${encodeURIComponent(feature)}&project_root=${encodeURIComponent(projectRoot)}`
    : null
  return useSWR<FeatureArtifact[]>(key, fetcher)
}
