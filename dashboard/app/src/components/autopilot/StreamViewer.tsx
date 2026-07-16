import { useRef, useEffect, useState, useCallback, useMemo, memo } from 'react'
import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import Chip from '@mui/material/Chip'
import Accordion from '@mui/material/Accordion'
import AccordionSummary from '@mui/material/AccordionSummary'
import AccordionDetails from '@mui/material/AccordionDetails'
import IconButton from '@mui/material/IconButton'
import Stack from '@mui/material/Stack'
import ExpandMoreIcon from '@mui/icons-material/ExpandMore'
import KeyboardArrowDownIcon from '@mui/icons-material/KeyboardArrowDown'
import TerminalIcon from '@mui/icons-material/Terminal'
import Markdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { useAutopilotStream } from '../../hooks/useAutopilotStream'
import type { StreamEvent, StreamContentBlock } from '../../types'
import type { KeyedStreamEvent } from '../../hooks/useStreamPolling'
import { useSessionActivity } from '../../hooks/useSessionActivity'
import type { ToolActivity } from '../../hooks/useSessionActivity'
import { pv, pva } from '../../utils/cssVars'
import StatusDot from '../wf/StatusDot'
import StatusPill from '../wf/StatusPill'
import ToggleChip from '../wf/ToggleChip'
import type { WfStatus } from '../wf/StatusDot'
import { wfMarkdownSx } from '../wf/markdownStyles'
import { brandifyMarkdown, wfMarkdownComponents } from '../wf/markdownComponents'
import { derivePhaseEvents } from '../../utils/derivePhaseEvents'

function phaseStatusToWf(status: string | undefined): WfStatus {
  if (status === 'completed') return 'completed'
  if (status === 'failed') return 'fault'
  return 'running'
}

const SCROLL_THRESHOLD = 50
const TOOL_RESULT_PREVIEW_LINES = 4
const TOOL_RESULT_MAX_HEIGHT = 400

type EventFilter = 'text' | 'tool' | 'result' | 'phase' | 'orchestrator'

// ─── Helpers ────────────────────────────────────────────────────────

function getToolCallDescription(input: Record<string, unknown> | undefined): string | undefined {
  if (!input) return undefined
  if (input.command != null) return String(input.command).slice(0, 140)
  if (input.file_path != null) return String(input.file_path)
  if (input.pattern != null) return String(input.pattern)
  if (input.prompt != null) return String(input.prompt).slice(0, 100)
  return undefined
}

function formatToolResultContent(rawContent: unknown): string {
  if (typeof rawContent === 'string') return rawContent
  if (Array.isArray(rawContent)) {
    return rawContent.map((c: unknown) =>
      (typeof c === 'object' && c !== null && 'text' in c)
        ? (c as { text: string }).text
        : String(c)
    ).join('\n')
  }
  if (rawContent != null) return String(rawContent)
  return ''
}

function formatAge(age: number | null): string {
  if (age === null) return ''
  if (age < 60) return `${age}s`
  return `${Math.floor(age / 60)}m`
}

// ─── Sub-components ─────────────────────────────────────────────────

function formatDuration(seconds: number): string {
  if (seconds >= 60) return `${Math.floor(seconds / 60)}m ${seconds % 60}s`
  return `${seconds}s`
}

function PhaseMarker({ event }: Readonly<{ event: StreamEvent }>) {
  const durationLabel = event.duration_s != null ? formatDuration(event.duration_s) : null
  const wfStatus = phaseStatusToWf(event.status)
  const isRunning = wfStatus === 'running'

  /* Brand atoms per atoms.md:
     [StatusDot] [name]              [duration] [StatusPill]
       ↑ status   ↑ phase name carries the type signal — no icon
                  needed (skærm-9 #3, reverts audit #7's PhaseIcon).
     Bottom hairline is 1px wf.steel per tokens.md§Spacing-Surfaces. */
  return (
    <Box data-testid="wf-phase-header" sx={{ px: 3, py: 1.5, my: 0 }}>
      <Box
        sx={{
          display: 'flex',
          alignItems: 'center',
          gap: 1.5,
          pb: 1,
          borderBottom: '1px solid',
          borderColor: 'wf.steel',
        }}
      >
        <StatusDot status={wfStatus} size={6} pulse={isRunning} />
        <Typography variant="wfH3" sx={{ fontWeight: 600, flex: 1, letterSpacing: '-0.01em' }}>
          {event.phase}
        </Typography>
        {durationLabel && (
          <Typography variant="wfLabel" color="text.secondary" sx={{ fontFamily: 'var(--font-mono)' }}>
            {durationLabel}
          </Typography>
        )}
        <StatusPill
          status={wfStatus}
          label={event.status ?? 'running'}
        />
      </Box>
    </Box>
  )
}


function OrchestratorMessage({ event }: { event: StreamEvent }) {
  if (!event.msg) return null
  return (
    <Box
      sx={{
        mx: 6,
        my: 0.5,
        px: 2,
        py: 0.75,
        borderLeft: '3px solid',
        borderColor: pva('primary-main', 0.3),
        bgcolor: pva('primary-main', 0.04),
        borderRadius: '0 6px 6px 0',
      }}
    >
      <Typography
        variant="wfBody"
        sx={{
          fontFamily: 'var(--font-mono)',
          fontSize: '0.78rem',
          color: 'text.secondary',
          whiteSpace: 'pre-wrap',
        }}
      >
        {event.msg}
      </Typography>
    </Box>
  )
}

const TextBlock = memo(function TextBlock({ text }: { text: string }) {
  return (
    <Box
      sx={{
        mx: 6,
        my: 0.75,
        py: 0.25,
        ...wfMarkdownSx,
        '& p:last-child': { mb: 0 },
      }}
    >
      <Markdown remarkPlugins={[remarkGfm]} components={wfMarkdownComponents}>{brandifyMarkdown(text)}</Markdown>
    </Box>
  )
})

function ToolCallBlock({ block }: { block: StreamContentBlock }) {
  const toolName = block.name ?? 'tool'
  const description = getToolCallDescription(block.input as Record<string, unknown> | undefined)

  return (
    <Accordion
      disableGutters
      elevation={0}
      sx={{
        mx: 6,
        my: 0.75,
        border: '1px solid',
        borderColor: 'divider',
        borderRadius: 0,
        '&::before': { display: 'none' },
        overflow: 'hidden',
        transition: 'border-color 0.15s ease',
        '&:hover': {
          borderColor: pva('primary-main', 0.3),
        },
      }}
    >
      <AccordionSummary
        expandIcon={<ExpandMoreIcon sx={{ fontSize: 18, color: 'text.disabled' }} />}
        sx={{
          minHeight: 42,
          '& .MuiAccordionSummary-content': { my: 0.5, gap: 1, alignItems: 'center', minWidth: 0 },
        }}
      >
        <TerminalIcon sx={{ fontSize: 16, color: 'text.disabled', flexShrink: 0 }} />
        <Chip
          label={toolName}
          size="small"
          sx={{
            fontFamily: 'var(--font-mono)',
            fontSize: '0.72rem',
            fontWeight: 600,
            height: 22,
            bgcolor: pva('primary-main', 0.08),
            color: pv('primary-main'),
            flexShrink: 0,
          }}
        />
        {description && (
          <Typography
            variant="caption"
            sx={{
              fontFamily: 'var(--font-mono)',
              color: 'text.secondary',
              overflow: 'hidden',
              textOverflow: 'ellipsis',
              whiteSpace: 'nowrap',
              minWidth: 0,
              fontSize: '0.72rem',
            }}
          >
            {description}
          </Typography>
        )}
      </AccordionSummary>
      <AccordionDetails sx={{ pt: 0, pb: 1.5 }}>
        <Box
          component="pre"
          sx={{
            fontFamily: 'var(--font-mono)',
            fontSize: '0.72rem',
            bgcolor: 'background.default',
            border: '1px solid',
            borderColor: 'divider',
            p: 1.5,
            borderRadius: 0,
            overflowX: 'auto',
            whiteSpace: 'pre-wrap',
            wordBreak: 'break-word',
            m: 0,
            lineHeight: 1.6,
          }}
        >
          {JSON.stringify(block.input, null, 2)}
        </Box>
      </AccordionDetails>
    </Accordion>
  )
}

function ToolResultBlock({ block }: { block: StreamContentBlock }) {
  const [expanded, setExpanded] = useState(false)
  const content = formatToolResultContent(block.content)
  const lines = content.split('\n')
  const needsTruncation = lines.length > TOOL_RESULT_PREVIEW_LINES
  const displayContent = expanded || !needsTruncation
    ? content
    : lines.slice(0, TOOL_RESULT_PREVIEW_LINES).join('\n')

  return (
    <Accordion
      disableGutters
      elevation={0}
      expanded={expanded}
      onChange={(_, isExpanded) => setExpanded(isExpanded)}
      sx={{
        mx: 6,
        my: 0.25,
        border: '1px solid',
        borderColor: pva('text-primary', 0.06),
        borderRadius: 0,
        '&::before': { display: 'none' },
        overflow: 'hidden',
        opacity: 0.6,
        transition: 'opacity 0.15s ease',
        '&:hover': { opacity: 0.9 },
      }}
    >
      <AccordionSummary
        expandIcon={<ExpandMoreIcon sx={{ fontSize: 16 }} />}
        sx={{ minHeight: 28, '& .MuiAccordionSummary-content': { my: 0.25 } }}
      >
        <Typography variant="caption" color="text.disabled" sx={{ fontSize: '0.68rem', fontFamily: 'var(--font-mono)' }}>
          output · {lines.length} lines{needsTruncation && !expanded ? ' (truncated)' : ''}
        </Typography>
      </AccordionSummary>
      <AccordionDetails sx={{ pt: 0 }}>
        <Box
          component="pre"
          sx={{
            fontFamily: 'var(--font-mono)',
            fontSize: '0.72rem',
            bgcolor: 'background.default',
            p: 1.5,
            borderRadius: 0,
            overflowX: 'auto',
            whiteSpace: 'pre-wrap',
            wordBreak: 'break-word',
            m: 0,
            maxHeight: expanded ? TOOL_RESULT_MAX_HEIGHT : undefined,
            overflowY: expanded ? 'auto' : undefined,
            lineHeight: 1.6,
            color: 'text.secondary',
          }}
        >
          {displayContent}
        </Box>
      </AccordionDetails>
    </Accordion>
  )
}

function ResultSummary({ event }: { event: StreamEvent }) {
  const isSuccess = event.subtype === 'success'
  const durationMin = event.duration_ms != null ? (event.duration_ms / 60000).toFixed(1) : null

  return (
    <Box
      sx={{
        mx: 6,
        my: 1,
        display: 'flex',
        alignItems: 'center',
        gap: 1,
      }}
    >
      <Box sx={{ flex: 1, borderTop: '1px solid', borderColor: 'divider' }} />
      <Stack direction="row" spacing={0.5} sx={{ flexShrink: 0 }}>
        {event.num_turns != null && (
          <Typography variant="caption" color="text.disabled" sx={{ fontSize: '0.68rem', fontFamily: 'var(--font-mono)' }}>
            {event.num_turns} turns
          </Typography>
        )}
        {durationMin != null && (
          <Typography variant="caption" color="text.disabled" sx={{ fontSize: '0.68rem', fontFamily: 'var(--font-mono)' }}>
            · {durationMin}m
          </Typography>
        )}
        {event.total_cost_usd != null && (
          <Typography variant="caption" sx={{ fontSize: '0.68rem', fontFamily: 'var(--font-mono)', fontWeight: 500, color: isSuccess ? pv('status-done') : pv('status-failed') }}>
            · ${event.total_cost_usd.toFixed(2)}
          </Typography>
        )}
      </Stack>
      <Box sx={{ flex: 1, borderTop: '1px solid', borderColor: 'divider' }} />
    </Box>
  )
}

// ─── Event filter helpers ────────────────────────────────────────────

function getEventFilter(event: StreamEvent): EventFilter | null {
  if (event.type === 'phase') return 'phase'
  if (event.type === 'orchestrator') return 'orchestrator'
  if (event.type === 'result') return 'result'
  if (event.type === 'assistant' && event.message?.content) {
    const hasText = event.message.content.some((b) => b.type === 'text')
    const hasTool = event.message.content.some((b) => b.type === 'tool_use')
    if (hasTool) return 'tool'
    if (hasText) return 'text'
  }
  if (event.type === 'user') return 'tool'
  return null
}

const FILTER_ORDER: EventFilter[] = ['phase', 'orchestrator', 'text', 'result', 'tool']
const FILTER_LABELS: Record<EventFilter, string> = {
  phase: 'Phases',
  text: 'Narrative',
  tool: 'Tool calls',
  result: 'Results',
  orchestrator: 'Pipeline',
}

// ─── Event renderer ─────────────────────────────────────────────────

// Perf (dashboard-perf 2026-06-02 #2): memoised so a 1.5s poll that appends a
// few new events does NOT re-render every existing row. Accumulated event
// objects keep a stable identity across polls (eventsRef.concat preserves old
// references), so the default shallow prop compare is a correct, cheap guard
// against the O(n)-rows-per-poll re-render that pegged the tab on long streams.
const StreamEventRenderer = memo(function StreamEventRenderer({ event, index }: { event: StreamEvent; index: number }) {
  if (event.type === 'phase') return <PhaseMarker event={event} />
  if (event.type === 'result') return <ResultSummary event={event} />
  if (event.type === 'orchestrator') return <OrchestratorMessage event={event} />

  if (event.type === 'assistant' && event.message?.content) {
    return (
      <>
        {event.message.content.map((block, bi) => {
          if (block.type === 'thinking') return null
          if (block.type === 'text' && block.text) return <TextBlock key={`${index}-${bi}`} text={block.text} />
          if (block.type === 'tool_use') return <ToolCallBlock key={`${index}-${bi}`} block={block} />
          return null
        })}
      </>
    )
  }

  if (event.type === 'user' && event.message?.content) {
    return (
      <>
        {event.message.content.map((block, bi) => {
          if (block.type === 'tool_result') return <ToolResultBlock key={`${index}-${bi}`} block={block} />
          return null
        })}
      </>
    )
  }

  return null
})

// ─── Activity feed (from sessions.jsonl when stream is stale) ────────

const reducedMotionQuery = '@media (prefers-reduced-motion: reduce)'

export function ActivityStrip({ events, isActive }: { events: ToolActivity[]; isActive: boolean }) {
  if (events.length === 0) return null

  return (
    <Box
      sx={{
        flexShrink: 0,
        borderTop: '1px solid',
        borderColor: 'divider',
        bgcolor: pva('primary-main', 0.02),
        maxHeight: 120,
        overflowY: 'auto',
        px: 2,
        py: 0.75,
      }}
    >
      <Box sx={{ display: 'flex', alignItems: 'center', gap: 0.75, mb: 0.5 }}>
        {isActive && (
          <Box
            sx={{
              width: 6,
              height: 6,
              borderRadius: '50%',
              bgcolor: pv('status-done'),
              animation: 'activityPulse 2s ease-in-out infinite',
              '@keyframes activityPulse': {
                '0%, 100%': { opacity: 1 },
                '50%': { opacity: 0.3 },
              },
              [reducedMotionQuery]: { animation: 'none' },
            }}
          />
        )}
        <Typography variant="wfLabel" color="text.disabled" sx={{ fontSize: '0.65rem', textTransform: 'uppercase', letterSpacing: '0.05em' }}>
          Live activity
        </Typography>
      </Box>
      {events.slice(0, 8).map((evt, i) => {
        const age = evt.ts ? Math.floor((Date.now() - new Date(evt.ts).getTime()) / 1000) : null
        const ageLabel = formatAge(age)
        return (
          <Box
            key={`${evt.ts}-${i}`}
            sx={{
              display: 'flex',
              alignItems: 'center',
              gap: 0.75,
              py: 0.125,
              opacity: i === 0 ? 0.9 : Math.max(0.25, 0.9 - i * 0.1),
            }}
          >
            <Typography
              variant="caption"
              sx={{
                fontFamily: 'var(--font-mono)',
                fontSize: '0.62rem',
                fontWeight: 600,
                color: pv('primary-main'),
                flexShrink: 0,
                width: 32,
              }}
            >
              {evt.tool}
            </Typography>
            <Typography
              variant="caption"
              sx={{
                fontFamily: 'var(--font-mono)',
                fontSize: '0.62rem',
                color: 'text.secondary',
                overflow: 'hidden',
                textOverflow: 'ellipsis',
                whiteSpace: 'nowrap',
                flex: 1,
                minWidth: 0,
              }}
            >
              {evt.summary}
            </Typography>
            <Typography
              variant="caption"
              sx={{
                fontFamily: 'var(--font-mono)',
                fontSize: '0.58rem',
                color: 'text.disabled',
                flexShrink: 0,
              }}
            >
              {ageLabel}
            </Typography>
          </Box>
        )
      })}
    </Box>
  )
}

// ─── StreamViewer — pure rendering component ─────────────────────────

export interface StreamViewerProps {
  events: KeyedStreamEvent[]
  hasStream: boolean | null
  label?: string
}

export function StreamViewer({ events, hasStream, label }: StreamViewerProps) {
  const containerRef = useRef<HTMLDivElement>(null)
  const [autoScroll, setAutoScroll] = useState(true)
  const [hiddenFilters, setHiddenFilters] = useState<Set<EventFilter>>(new Set(['tool']))

  const toggleFilter = useCallback((filter: EventFilter) => {
    setHiddenFilters((prev) => {
      const next = new Set(prev)
      if (next.has(filter)) next.delete(filter)
      else next.add(filter)
      return next
    })
  }, [])

  /* Derive effective phase status (skarm-9 #1) — dedupe superseded
     phase events and override running→completed when a different
     phase has started. Done before filtering so the user-controlled
     filter chips operate on the cleaned event list. */
  const derivedEvents = useMemo(() => derivePhaseEvents(events), [events])

  const filteredEvents = useMemo(() =>
    derivedEvents.filter((event) => {
      const f = getEventFilter(event)
      return f === null || !hiddenFilters.has(f)
    }),
    [derivedEvents, hiddenFilters]
  )

  const handleScroll = useCallback(() => {
    const el = containerRef.current
    if (!el) return
    setAutoScroll(el.scrollTop + el.clientHeight >= el.scrollHeight - SCROLL_THRESHOLD)
  }, [])

  const jumpToBottom = useCallback(() => {
    const el = containerRef.current
    if (el) {
      el.scrollTop = el.scrollHeight
      setAutoScroll(true)
    }
  }, [])

  useEffect(() => {
    if (autoScroll && containerRef.current) {
      containerRef.current.scrollTop = containerRef.current.scrollHeight
    }
  }, [filteredEvents, autoScroll])

  if (hasStream === false) {
    return (
      <Box sx={{ flex: 1, display: 'flex', alignItems: 'center', justifyContent: 'center' }}>
        <Typography variant="wfBody" color="text.secondary">No stream data available</Typography>
      </Box>
    )
  }

  return (
    <Box sx={{ flex: 1, position: 'relative', display: 'flex', flexDirection: 'column', minHeight: 0 }}>
      {/* Filter bar */}
      <Box sx={{
        px: 3, py: 1,
        borderBottom: '1px solid', borderColor: 'divider',
        flexShrink: 0,
        display: 'flex', alignItems: 'center', gap: 1,
      }}>
        <Typography variant="wfLabel" color="text.disabled" sx={{ mr: 0.5 }}>
          Show
        </Typography>
        {FILTER_ORDER.map((f) => {
          const active = !hiddenFilters.has(f)
          return (
            <ToggleChip
              key={f}
              label={FILTER_LABELS[f]}
              active={active}
              onClick={() => toggleFilter(f)}
            />
          )
        })}
      </Box>

      {/* Event stream */}
      <Box
        ref={containerRef}
        onScroll={handleScroll}
        aria-label={label ? `Live stream output for ${label}` : 'Live stream output'}
        sx={{
          flex: 1,
          overflowY: 'auto',
          pt: 1,
          pb: 4,
          color: 'text.primary',
        }}
      >
        {filteredEvents.map((event) => (
          /* Perf (#2): content-visibility lets the browser skip layout + paint
             for rows scrolled out of view, so cold-loading a long stream no
             longer renders thousands of off-screen markdown/accordion subtrees.
             `auto 64px` is the placeholder size before first render; the
             browser remembers each row's real height once painted. */
          <Box
            key={event._seq}
            sx={{ contentVisibility: 'auto', containIntrinsicSize: 'auto 64px' }}
          >
            <StreamEventRenderer event={event} index={event._seq} />
          </Box>
        ))}
      </Box>

      {/* Jump to bottom */}
      {!autoScroll && (
        <IconButton
          size="medium"
          onClick={jumpToBottom}
          aria-label="Jump to bottom"
          sx={{
            position: 'absolute',
            bottom: 20,
            right: 20,
            bgcolor: 'surface2',
            border: '1px solid',
            borderColor: 'divider',
            borderRadius: 0,
            backdropFilter: 'blur(8px)',
            '&:hover': { bgcolor: 'surface3' },
          }}
        >
          <KeyboardArrowDownIcon />
        </IconButton>
      )}
    </Box>
  )
}

// ─── AutopilotStreamViewer — wrapper with data fetching ─────────────

interface AutopilotStreamViewerProps {
  task: string
  onLivenessChange?: (isLive: boolean) => void
}

function AutopilotStreamViewer({ task, onLivenessChange }: AutopilotStreamViewerProps) {
  const { events, isLive, hasStream } = useAutopilotStream(task)
  const { events: activityEvents, isActive: activityIsActive } = useSessionActivity(task, !isLive)

  // Notify parent when liveness changes
  useEffect(() => {
    onLivenessChange?.(isLive)
  }, [isLive, onLivenessChange])

  return (
    <Box sx={{ flex: 1, display: 'flex', flexDirection: 'column', minHeight: 0 }}>
      <StreamViewer events={events} hasStream={hasStream} label={task} />
      <ActivityStrip events={activityEvents} isActive={activityIsActive} />
    </Box>
  )
}

export default AutopilotStreamViewer
