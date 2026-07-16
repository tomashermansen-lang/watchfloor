import { useState, useCallback, useRef } from 'react'
import Box from '@mui/material/Box'
import { useAutopilots } from '../../hooks/useAutopilots'
import { useTaskForAutopilot } from '../../hooks/useTaskForAutopilot'
import type { AutopilotSession } from '../../types'
import AutopilotList from './AutopilotList'
import SessionPanel from '../SessionPanel'

export default function AutopilotView() {
  const { data: sessions, isLoading } = useAutopilots()
  const [selectedTask, setSelectedTask] = useState<string | null>(null)
  const listRef = useRef<HTMLDivElement>(null)

  const selectedSession: AutopilotSession | null =
    sessions?.find((s) => s.task === selectedTask) ?? null

  const { task: matchedTask, plan, planDir, projectPath } = useTaskForAutopilot(selectedSession)

  const handleEscape = useCallback(() => {
    setSelectedTask(null)
    // Return focus to the list
    if (listRef.current) {
      const selected = listRef.current.querySelector('[aria-selected="true"]') as HTMLElement
      if (selected) selected.focus()
    }
  }, [])

  return (
    <Box
      sx={{
        flex: 1,
        display: 'flex',
        flexDirection: { xs: 'column', md: 'row' },
        minHeight: 0,
        overflow: 'hidden',
      }}
    >
      {/* Left panel — session list */}
      <Box
        ref={listRef}
        sx={{
          flex: { xs: selectedTask ? 'none' : 1, md: 1 },
          minWidth: 0,
          minHeight: 0,
          display: 'flex',
          flexDirection: 'column',
          borderRight: { md: '1px solid' },
          borderColor: { md: 'divider' },
          maxHeight: { xs: selectedTask ? 200 : '100%', md: '100%' },
        }}
      >
        <AutopilotList
          sessions={sessions}
          isLoading={isLoading}
          selectedTask={selectedTask}
          onSelectTask={setSelectedTask}
        />
      </Box>

      {/* Right panel — unified session panel */}
      <Box
        sx={{
          flex: 2,
          minHeight: 0,
          display: { xs: selectedTask ? 'flex' : 'none', md: 'flex' },
          flexDirection: 'column',
          borderTop: { xs: '1px solid', md: 'none' },
          borderColor: 'divider',
        }}
      >
        <SessionPanel
          task={matchedTask}
          autopilotSession={selectedSession}
          projectPath={projectPath}
          plan={plan}
          planDir={planDir}
          onClose={handleEscape}
        />
      </Box>
    </Box>
  )
}
