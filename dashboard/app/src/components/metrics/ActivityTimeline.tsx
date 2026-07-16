import { useState, useCallback, useMemo, useRef, memo } from 'react'
import { Box, Button, Typography, Stack } from '@mui/material'
import { useTheme } from '@mui/material/styles'
import {
  ScatterChart, Scatter, XAxis, YAxis, ZAxis,
  ResponsiveContainer, Tooltip as RechartsTooltip,
  ReferenceArea,
} from 'recharts'
import type { ActivityTimelineMetrics } from '../../types'
import MetricCard from './MetricCard'

interface ActivityTimelineProps {
  data: ActivityTimelineMetrics
  selectedSid: string | 'all'
}

interface EventDot {
  ts: number
  row: number
  category: string
  sid: string
}

const CATEGORY_LABELS: Record<string, string> = {
  tool: 'Tool',
  error: 'Error',
  notification: 'Notify',
  subagent: 'Subagent',
  session: 'Session',
  permission: 'Perm',
  task: 'Task',
  prompt: 'Prompt',
}

function ActivityTimelineInner({ data, selectedSid }: ActivityTimelineProps) {
  const theme = useTheme()
  const et = theme.palette.eventType

  const categoryColors: Record<string, string> = useMemo(() => ({
    tool: et.tool,
    error: et.error,
    notification: et.notification,
    subagent: et.subagent,
    session: et.session,
    permission: et.permission,
    task: et.task,
    prompt: et.prompt,
  }), [et])

  const sessions = selectedSid !== 'all'
    ? data.sessions.filter(s => s.sid === selectedSid)
    : data.sessions

  // Build scatter data: one dot per event, row index = session index
  const dots: EventDot[] = useMemo(() => {
    const result: EventDot[] = []
    sessions.forEach((sess, rowIdx) => {
      sess.events.forEach(ev => {
        result.push({
          ts: new Date(ev.ts).getTime(),
          row: rowIdx,
          category: ev.category,
          sid: sess.sid,
        })
      })
    })
    return result
  }, [sessions])

  // Group dots by category for separate Scatter series (each gets its own color)
  const dotsByCategory = useMemo(() => {
    const map: Record<string, EventDot[]> = {}
    for (const dot of dots) {
      if (!map[dot.category]) map[dot.category] = []
      map[dot.category].push(dot)
    }
    return map
  }, [dots])

  // Idle gap rectangles as scatter points (rendered differently)
  const idleGaps = useMemo(() => {
    const gaps: Array<{ start: number; end: number; row: number; duration_s: number }> = []
    sessions.forEach((sess, rowIdx) => {
      sess.idle_gaps.forEach(g => {
        gaps.push({
          start: new Date(g.start).getTime(),
          end: new Date(g.end).getTime(),
          row: rowIdx,
          duration_s: g.duration_s,
        })
      })
    })
    return gaps
  }, [sessions])

  // Compute actual time bounds from data
  const timeBounds = useMemo(() => {
    let min = Infinity
    let max = -Infinity
    for (const d of dots) {
      if (d.ts < min) min = d.ts
      if (d.ts > max) max = d.ts
    }
    return { min: min === Infinity ? 0 : min, max: max === -Infinity ? 0 : max }
  }, [dots])

  // Zoom state
  const [zoomLeft, setZoomLeft] = useState<number | null>(null)
  const [zoomRight, setZoomRight] = useState<number | null>(null)
  const [refAreaLeft, setRefAreaLeft] = useState<number | null>(null)
  const [refAreaRight, setRefAreaRight] = useState<number | null>(null)
  const [dragging, setDragging] = useState(false)
  const containerRef = useRef<HTMLDivElement>(null)

  const MARGIN_LEFT = 80
  const MARGIN_RIGHT = 16

  const domain: [number, number] = useMemo(() => {
    if (zoomLeft !== null && zoomRight !== null) {
      return [zoomLeft, zoomRight]
    }
    // Add 1% padding to prevent clipping
    const pad = (timeBounds.max - timeBounds.min) * 0.01 || 60000
    return [timeBounds.min - pad, timeBounds.max + pad]
  }, [zoomLeft, zoomRight, timeBounds])

  // Convert pixel X position to timestamp using the current domain
  const pxToTs = useCallback((clientX: number): number | null => {
    const el = containerRef.current
    if (!el) return null
    const rect = el.getBoundingClientRect()
    const plotWidth = rect.width - MARGIN_LEFT - MARGIN_RIGHT
    if (plotWidth <= 0) return null
    const px = clientX - rect.left - MARGIN_LEFT
    const ratio = Math.max(0, Math.min(1, px / plotWidth))
    return domain[0] + ratio * (domain[1] - domain[0])
  }, [domain])

  const handleMouseDown = useCallback((e: React.MouseEvent) => {
    const ts = pxToTs(e.clientX)
    if (ts === null) return
    setRefAreaLeft(ts)
    setDragging(true)
  }, [pxToTs])

  const handleMouseMove = useCallback((e: React.MouseEvent) => {
    if (!dragging) return
    const ts = pxToTs(e.clientX)
    if (ts !== null) setRefAreaRight(ts)
  }, [dragging, pxToTs])

  const handleMouseUp = useCallback(() => {
    if (!dragging) return
    setDragging(false)
    if (refAreaLeft !== null && refAreaRight !== null) {
      const left = Math.min(refAreaLeft, refAreaRight)
      const right = Math.max(refAreaLeft, refAreaRight)
      if (right - left > 1000) {
        setZoomLeft(left)
        setZoomRight(right)
      }
    }
    setRefAreaLeft(null)
    setRefAreaRight(null)
  }, [dragging, refAreaLeft, refAreaRight])

  const handleResetZoom = useCallback(() => {
    setZoomLeft(null)
    setZoomRight(null)
  }, [])

  const chartHeight = Math.min(500, Math.max(200, sessions.length * 32 + 60))
  const isZoomed = zoomLeft !== null

  const tickFormatter = (v: number) =>
    new Date(v).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })

  const yLabels = sessions.map(s => s.label)

  return (
    <MetricCard
      title="Activity Timeline"
      isEmpty={sessions.length === 0}
      emptyMessage="No session activity data"
    >
      <Box sx={{ position: 'relative' }}>
        {isZoomed && (
          <Button size="small" variant="text" onClick={handleResetZoom} sx={{ mb: 0.5 }}>
            Reset zoom
          </Button>
        )}
        {!isZoomed && sessions.length > 0 && (
          <Typography variant="wfLabel" color="text.secondary" sx={{ mb: 0.5, display: 'block' }}>
            Click and drag to zoom
          </Typography>
        )}
        <Box
          ref={containerRef}
          onMouseDown={handleMouseDown}
          onMouseMove={handleMouseMove}
          onMouseUp={handleMouseUp}
          onMouseLeave={handleMouseUp}
          sx={{ cursor: dragging ? 'col-resize' : 'crosshair', userSelect: 'none' }}
        >
        <ResponsiveContainer width="100%" height={chartHeight}>
          <ScatterChart
            margin={{ top: 8, right: MARGIN_RIGHT, bottom: 8, left: MARGIN_LEFT }}
          >
            <XAxis
              type="number"
              dataKey="ts"
              domain={domain}
              tickFormatter={tickFormatter}
              tick={{ fontSize: 10 }}
              name="Time"
            />
            <YAxis
              type="number"
              dataKey="row"
              domain={[-0.5, sessions.length - 0.5]}
              ticks={sessions.map((_, i) => i)}
              tickFormatter={(v: number) => yLabels[v] ?? ''}
              tick={{ fontSize: 10 }}
              width={75}
            />
            <ZAxis range={[30, 30]} />
            <RechartsTooltip
              content={({ payload }) => {
                if (!payload?.[0]) return null
                const d = payload[0].payload as EventDot
                return (
                  <Box sx={{ bgcolor: 'background.paper', p: 1, border: '1px solid', borderColor: 'divider', borderRadius: 1 }}>
                    <Typography variant="caption" display="block">
                      {new Date(d.ts).toLocaleTimeString()}
                    </Typography>
                    <Typography variant="caption" display="block">
                      {CATEGORY_LABELS[d.category] ?? d.category}
                    </Typography>
                  </Box>
                )
              }}
            />
            {/* Idle gap reference areas */}
            {idleGaps.map((g, i) => (
              <ReferenceArea
                key={`idle-${i}`}
                x1={g.start}
                x2={g.end}
                y1={g.row - 0.4}
                y2={g.row + 0.4}
                fill={theme.palette.divider}
                fillOpacity={0.3}
                stroke="none"
              />
            ))}
            {/* Zoom selection area */}
            {refAreaLeft !== null && refAreaRight !== null && (
              <ReferenceArea
                x1={refAreaLeft}
                x2={refAreaRight}
                strokeOpacity={0.3}
                fill={theme.palette.primary.main}
                fillOpacity={0.1}
              />
            )}
            {/* One Scatter per category for color coding */}
            {Object.entries(dotsByCategory).map(([cat, catDots]) => (
              <Scatter
                key={cat}
                data={catDots}
                fill={categoryColors[cat] ?? theme.palette.text.secondary}
                name={CATEGORY_LABELS[cat] ?? cat}
              />
            ))}
          </ScatterChart>
        </ResponsiveContainer>
        </Box>
        {/* Legend — brand "dot + label" pattern: 6px category-color
            dot followed by JBM uppercase mono label in wf.fog. Drops
            the previous coloured-fill chips that fought the
            single-chromatic-accent rule and read as marketing pills
            rather than instrument graticule. */}
        <Stack direction="row" spacing={1.5} flexWrap="wrap" sx={{ mt: 1.5 }} useFlexGap>
          {Object.entries(CATEGORY_LABELS).map(([cat, label]) => (
            <Box key={cat} sx={{ display: 'inline-flex', alignItems: 'center', gap: 0.75 }}>
              <Box
                sx={{
                  width: 6, height: 6, borderRadius: '50%',
                  bgcolor: categoryColors[cat],
                }}
              />
              <Typography variant="wfLabel" sx={{ color: 'wf.fog' }}>
                {label}
              </Typography>
            </Box>
          ))}
          <Box sx={{ display: 'inline-flex', alignItems: 'center', gap: 0.75 }}>
            <Box
              sx={{
                width: 6, height: 6, borderRadius: '50%',
                border: '1px solid', borderColor: 'wf.fog', bgcolor: 'transparent',
              }}
            />
            <Typography variant="wfLabel" sx={{ color: 'wf.fog' }}>
              Idle
            </Typography>
          </Box>
        </Stack>
      </Box>
    </MetricCard>
  )
}

const ActivityTimeline = memo(ActivityTimelineInner)
export default ActivityTimeline
