import { createContext, useContext, useState, useCallback, type ReactNode } from 'react'

interface HoverLinkState {
  hoveredTaskId: string | null
  hoveredSessionBranch: string | null
  setHoveredTask: (id: string | null) => void
  setHoveredSession: (branch: string | null) => void
}

const HoverLinkContext = createContext<HoverLinkState>({
  hoveredTaskId: null,
  hoveredSessionBranch: null,
  setHoveredTask: () => {},
  setHoveredSession: () => {},
})

export function HoverLinkProvider({ children }: { children: ReactNode }) {
  const [hoveredTaskId, setHoveredTaskId] = useState<string | null>(null)
  const [hoveredSessionBranch, setHoveredSessionBranch] = useState<string | null>(null)

  const setHoveredTask = useCallback((id: string | null) => setHoveredTaskId(id), [])
  const setHoveredSession = useCallback((branch: string | null) => setHoveredSessionBranch(branch), [])

  return (
    <HoverLinkContext.Provider value={{ hoveredTaskId, hoveredSessionBranch, setHoveredTask, setHoveredSession }}>
      {children}
    </HoverLinkContext.Provider>
  )
}

export function useHoverLink() {
  return useContext(HoverLinkContext)
}
