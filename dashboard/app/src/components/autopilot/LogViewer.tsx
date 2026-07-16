import { useRef, useEffect, useState, useCallback } from 'react'
import Box from '@mui/material/Box'
import IconButton from '@mui/material/IconButton'
import KeyboardArrowDownIcon from '@mui/icons-material/KeyboardArrowDown'
import { useAutopilotLog } from '../../hooks/useAutopilotLog'
import type { LogLine } from '../../hooks/useAutopilotLog'

const SCROLL_THRESHOLD = 50

function getLineStyle(line: string): React.CSSProperties | undefined {
  if (line.includes('━━━ Phase:')) return { color: 'var(--mui-palette-primary-main)', fontWeight: 500 }
  if (line.startsWith('✓')) return { color: `var(--mui-palette-status-done)` }
  if (line.startsWith('⚠')) return { color: `var(--mui-palette-status-blocked)` }
  return undefined
}

function extractAnnouncement(lines: LogLine[]): string | null {
  if (lines.length === 0) return null
  const last = lines[lines.length - 1].text
  if (last.includes('━━━ Phase:')) {
    const match = last.match(/Phase: (.+?) ━━━/)
    return match ? `Phase ${match[1]} started` : null
  }
  if (last.includes('AUTOPILOT COMPLETE')) return 'Autopilot completed'
  if (last.includes('AUTOPILOT FAILED')) return 'Autopilot failed'
  return null
}

export default function LogViewer({ task }: { task: string }) {
  const { lines } = useAutopilotLog(task)
  const containerRef = useRef<HTMLDivElement>(null)
  const [autoScroll, setAutoScroll] = useState(true)
  const [srAnnouncement, setSrAnnouncement] = useState('')

  const handleScroll = useCallback(() => {
    const el = containerRef.current
    if (!el) return
    const atBottom = el.scrollTop + el.clientHeight >= el.scrollHeight - SCROLL_THRESHOLD
    setAutoScroll(atBottom)
  }, [])

  const jumpToBottom = useCallback(() => {
    const el = containerRef.current
    if (el) {
      el.scrollTop = el.scrollHeight
      setAutoScroll(true)
    }
  }, [])

  // Auto-scroll on new content
  useEffect(() => {
    if (autoScroll && containerRef.current) {
      containerRef.current.scrollTop = containerRef.current.scrollHeight
    }
  }, [lines, autoScroll])

  // Screen reader announcements for phase transitions
  useEffect(() => {
    const announcement = extractAnnouncement(lines)
    if (announcement) setSrAnnouncement(announcement)
  }, [lines])

  return (
    <Box sx={{ flex: 1, position: 'relative', display: 'flex', flexDirection: 'column', minHeight: 0 }}>
      <Box
        ref={containerRef}
        onScroll={handleScroll}
        aria-label={`Live log output for ${task}`}
        sx={{
          flex: 1,
          overflowY: 'auto',
          p: 2,
          bgcolor: 'background.default',
          fontFamily: 'var(--font-mono)',
          fontSize: '0.8rem',
          lineHeight: 1.6,
          whiteSpace: 'pre-wrap',
          wordBreak: 'break-word',
          color: 'text.primary',
        }}
      >
        {lines.map((line) => (
          <span key={line.id} style={getLineStyle(line.text)}>{line.text}{'\n'}</span>
        ))}
      </Box>

      {/* Jump to bottom button */}
      {!autoScroll && (
        <IconButton
          size="medium"
          onClick={jumpToBottom}
          aria-label="Jump to bottom"
          sx={{
            position: 'absolute',
            bottom: 16,
            right: 16,
            bgcolor: 'surface2',
            border: '1px solid',
            borderColor: 'divider',
            '&:hover': { bgcolor: 'surface3' },
          }}
        >
          <KeyboardArrowDownIcon />
        </IconButton>
      )}

      {/* Screen reader status region */}
      <Box
        role="status"
        aria-live="polite"
        aria-atomic="true"
        sx={{ position: 'absolute', width: 1, height: 1, overflow: 'hidden', clip: 'rect(0,0,0,0)', whiteSpace: 'nowrap' }}
      >
        {srAnnouncement}
      </Box>
    </Box>
  )
}
