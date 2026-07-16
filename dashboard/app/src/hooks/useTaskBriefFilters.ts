import { useCallback, useEffect, useMemo, useRef, useState } from 'react'

export type BriefMode = 'stream' | 'brief'

export type BriefSection =
  | 'task_type'
  | 'what'
  | 'why'
  | 'where'
  | 'constraints'
  | 'acceptance'
  | 'manualtest_scenarios'
  | 'manual_test'
  | 'estimate'
  | 'description'
  | 'scope_change'
  | 'delivered_beyond_plan'
  | 'remaining_gaps'

const STORAGE_KEY = 'wf.taskBriefFilters.v1'

const MODE_VALUES = ['stream', 'brief'] as const satisfies readonly BriefMode[]

/* Audit-19 #11 - 'artifacts' removed: sidebar Documents already lists
   every artifact with a click link, so a brief chip + section would
   duplicate the affordance. */
const SECTION_VALUES = [
  'task_type',
  'what',
  'why',
  'where',
  'constraints',
  'acceptance',
  'manualtest_scenarios',
  'manual_test',
  'estimate',
  'description',
  'scope_change',
  'delivered_beyond_plan',
  'remaining_gaps',
] as const satisfies readonly BriefSection[]

const DEFAULT_MODE: BriefMode = 'brief'
const DEFAULT_SECTIONS: ReadonlySet<BriefSection> = new Set<BriefSection>(SECTION_VALUES)

export interface TaskBriefFiltersState {
  mode: BriefMode
  visibleSections: ReadonlySet<BriefSection>
  setMode: (next: BriefMode) => void
  setVisibleSections: (next: ReadonlySet<BriefSection>) => void
}

interface StoredShape {
  mode: BriefMode
  visibleSections: ReadonlySet<BriefSection>
}

function isMode(v: unknown): v is BriefMode {
  return typeof v === 'string' && (MODE_VALUES as readonly string[]).includes(v)
}

function isSection(v: unknown): v is BriefSection {
  return typeof v === 'string' && (SECTION_VALUES as readonly string[]).includes(v)
}

function parseStored(raw: string): StoredShape | null {
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
  if (!isMode(obj.mode)) return null
  if (!Array.isArray(obj.visibleSections)) return null
  const sections = new Set<BriefSection>()
  for (const item of obj.visibleSections) {
    if (!isSection(item)) return null
    sections.add(item)
  }
  return { mode: obj.mode, visibleSections: sections }
}

function readInitial(): StoredShape {
  let raw: string | null = null
  try {
    raw = localStorage.getItem(STORAGE_KEY)
  } catch {
    return { mode: DEFAULT_MODE, visibleSections: DEFAULT_SECTIONS }
  }
  if (raw === null) {
    return { mode: DEFAULT_MODE, visibleSections: DEFAULT_SECTIONS }
  }
  const parsed = parseStored(raw)
  if (parsed === null) {
    return { mode: DEFAULT_MODE, visibleSections: DEFAULT_SECTIONS }
  }
  return parsed
}

function persist(snapshot: StoredShape): void {
  try {
    localStorage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        mode: snapshot.mode,
        visibleSections: [...snapshot.visibleSections],
      }),
    )
  } catch {
    // swallow quota / security errors — in-memory state is the source of truth
  }
}

export function useTaskBriefFilters(): TaskBriefFiltersState {
  const initial = useRef<StoredShape | null>(null)
  if (initial.current === null) {
    initial.current = readInitial()
  }
  const [mode, setModeState] = useState<BriefMode>(initial.current.mode)
  const [visibleSections, setVisibleSectionsState] = useState<ReadonlySet<BriefSection>>(
    initial.current.visibleSections,
  )

  const stateRef = useRef<StoredShape>({ mode, visibleSections })
  useEffect(() => {
    stateRef.current = { mode, visibleSections }
  }, [mode, visibleSections])

  const setMode = useCallback((next: BriefMode) => {
    setModeState(next)
    persist({ mode: next, visibleSections: stateRef.current.visibleSections })
  }, [])

  const setVisibleSections = useCallback((next: ReadonlySet<BriefSection>) => {
    setVisibleSectionsState(next)
    persist({ mode: stateRef.current.mode, visibleSections: next })
  }, [])

  return useMemo(
    () => ({ mode, visibleSections, setMode, setVisibleSections }),
    [mode, visibleSections, setMode, setVisibleSections],
  )
}
