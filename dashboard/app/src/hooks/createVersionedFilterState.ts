import { useCallback, useEffect, useMemo, useRef, useState } from 'react'

const SEARCH_DEBOUNCE_MS = 300

export interface VersionedFilterDefaults<
  L extends string,
  S extends string,
> {
  lifecycle: ReadonlySet<L>
  project: ReadonlySet<string>
  search: string
  sort: S
}

export interface VersionedFilterStateConfig<
  L extends string,
  S extends string,
> {
  storageKey: string
  lifecycleValues: readonly L[]
  sortValues: readonly S[]
  defaults: VersionedFilterDefaults<L, S>
}

export interface VersionedFilterState<L extends string, S extends string> {
  lifecycle: ReadonlySet<L>
  project: ReadonlySet<string>
  search: string
  sort: S
  setLifecycle: (next: ReadonlySet<L>) => void
  setProject: (next: ReadonlySet<string>) => void
  setSearch: (next: string) => void
  setSort: (next: S) => void
}

interface StateValues<L extends string, S extends string> {
  lifecycle: ReadonlySet<L>
  project: ReadonlySet<string>
  search: string
  sort: S
}

function isMember<T extends string>(values: readonly T[], v: unknown): v is T {
  return typeof v === 'string' && (values as readonly string[]).includes(v)
}

function parseStored<L extends string, S extends string>(
  raw: string,
  config: VersionedFilterStateConfig<L, S>,
): StateValues<L, S> | null {
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return null
  }
  if (parsed === null || typeof parsed !== 'object' || Array.isArray(parsed)) {
    return null
  }
  const obj = parsed as Record<string, unknown>
  if (
    !('lifecycle' in obj) ||
    !('project' in obj) ||
    !('search' in obj) ||
    !('sort' in obj)
  ) {
    return null
  }
  const { lifecycle, project, search, sort } = obj
  if (
    !Array.isArray(lifecycle) ||
    !lifecycle.every((v): v is L => isMember(config.lifecycleValues, v))
  ) {
    return null
  }
  if (
    !Array.isArray(project) ||
    !project.every((p): p is string => typeof p === 'string')
  ) {
    return null
  }
  if (typeof search !== 'string') return null
  if (!isMember(config.sortValues, sort)) return null
  return {
    lifecycle: new Set<L>(lifecycle),
    project: new Set<string>(project),
    search,
    sort,
  }
}

function cloneDefaults<L extends string, S extends string>(
  d: VersionedFilterDefaults<L, S>,
): StateValues<L, S> {
  return {
    lifecycle: new Set(d.lifecycle),
    project: new Set(d.project),
    search: d.search,
    sort: d.sort,
  }
}

function safeRead<L extends string, S extends string>(
  config: VersionedFilterStateConfig<L, S>,
): StateValues<L, S> {
  let raw: string | null
  try {
    raw = globalThis.localStorage.getItem(config.storageKey)
  } catch {
    return cloneDefaults(config.defaults)
  }
  if (raw === null) return cloneDefaults(config.defaults)
  return parseStored(raw, config) ?? cloneDefaults(config.defaults)
}

function serialize<L extends string, S extends string>(
  state: StateValues<L, S>,
): string {
  return JSON.stringify({
    lifecycle: Array.from(state.lifecycle),
    project: Array.from(state.project),
    search: state.search,
    sort: state.sort,
  })
}

function safeWrite<L extends string, S extends string>(
  config: VersionedFilterStateConfig<L, S>,
  state: StateValues<L, S>,
): void {
  try {
    globalThis.localStorage.setItem(config.storageKey, serialize(state))
  } catch {
    // fail-closed per REQ-8
  }
}

/**
 * Build a versioned-localStorage filter-state hook from a config.
 *
 * The returned hook owns hydration (with structural validation against
 * `config.lifecycleValues` / `config.sortValues`), same-render-cycle
 * persistence for non-search slices, 300 ms debounced persistence for
 * search, fail-silent localStorage handling, stable setter and composite
 * references, and unmount cleanup of any pending debounce timer. The
 * factory adopts a skip-initial-mount-write convention via
 * `isInitialMountRef` so cold-start renders do not produce a redundant
 * `setItem` of the just-read state.
 */
export function createVersionedFilterState<
  L extends string,
  S extends string,
>(
  config: VersionedFilterStateConfig<L, S>,
): () => VersionedFilterState<L, S> {
  return function useVersionedFilterState(): VersionedFilterState<L, S> {
    const [state, setState] = useState<StateValues<L, S>>(() => safeRead(config))

    const stateRef = useRef(state)
    useEffect(() => {
      stateRef.current = state
    })

    const isInitialMountRef = useRef(true)

    const setLifecycle = useCallback((next: ReadonlySet<L>) => {
      setState((prev) =>
        next === prev.lifecycle
          ? prev
          : { ...prev, lifecycle: new Set(next) },
      )
    }, [])

    const setProject = useCallback((next: ReadonlySet<string>) => {
      setState((prev) =>
        next === prev.project ? prev : { ...prev, project: new Set(next) },
      )
    }, [])

    const setSearch = useCallback((next: string) => {
      setState((prev) =>
        next === prev.search ? prev : { ...prev, search: next },
      )
    }, [])

    const setSort = useCallback((next: S) => {
      setState((prev) => (next === prev.sort ? prev : { ...prev, sort: next }))
    }, [])

    useEffect(() => {
      if (isInitialMountRef.current) return
      // Closure-captured state is the current commit's snapshot, which
      // already includes the latest search value. stateRef is reserved
      // for Effect B (the debounced search timer fires from the
      // macrotask queue, after subsequent commits may have updated
      // state). See PLAN.md R6 / EC-14.
      safeWrite(config, state)
      // search is intentionally excluded — debounced in Effect B below.
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [state.lifecycle, state.project, state.sort])

    useEffect(() => {
      if (isInitialMountRef.current) return
      const id = setTimeout(() => {
        safeWrite(config, stateRef.current)
      }, SEARCH_DEBOUNCE_MS)
      return () => clearTimeout(id)
    }, [state.search])

    useEffect(() => {
      isInitialMountRef.current = false
      return () => {
        isInitialMountRef.current = true
      }
    }, [])

    return useMemo<VersionedFilterState<L, S>>(
      () => ({
        lifecycle: state.lifecycle,
        project: state.project,
        search: state.search,
        sort: state.sort,
        setLifecycle,
        setProject,
        setSearch,
        setSort,
      }),
      [state, setLifecycle, setProject, setSearch, setSort],
    )
  }
}
