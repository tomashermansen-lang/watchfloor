import Box from '@mui/material/Box'
import { useRelativeTimer } from '../hooks/useRelativeTimer'

/* Watchfloor data-freshness indicator — handoff §App Chrome "Title bar":
   LIVE pill carries the brand-recall signal, this element is the small
   mono freshness timestamp on its right. Three states map to brand
   colors and the existing 4-state status palette:

     fresh  (<10s)  — fog, no dot (silent default)
     aging  (<30s)  — fog, no dot (still acceptable)
     stale  (≥30s)  — stalled amber dot prefix + amber label
     paused / connecting — fog dot prefix + fog label

   Elapsed time is the meaningful info; the dot only appears when
   something needs attention so the chrome stays calm. */

interface DataFreshnessChipProps {
  lastFetchTime: number | null
  isTabVisible: boolean
}

const MONO_STACK =
  '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace'

export default function DataFreshnessChip({
  lastFetchTime,
  isTabVisible,
}: Readonly<DataFreshnessChipProps>) {
  const elapsed = useRelativeTimer(lastFetchTime)

  let label: string
  let dotColor: string | null
  let textColor: string

  if (!isTabVisible) {
    label = 'paused'
    dotColor = '#5A6472'
    textColor = '#5A6472'
  } else if (lastFetchTime === null) {
    label = 'connecting…'
    dotColor = '#5A6472'
    textColor = '#5A6472'
  } else {
    const age = Date.now() - lastFetchTime
    if (age < 30_000) {
      label = elapsed
      dotColor = null
      textColor = '#5A6472'
    } else {
      label = `stale · ${elapsed}`
      dotColor = '#F2B441'
      textColor = '#F2B441'
    }
  }

  return (
    <Box
      data-testid="wf-freshness"
      aria-live="polite"
      sx={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: 0.75,
        fontFamily: MONO_STACK,
        fontSize: '10px',
        lineHeight: 1,
        letterSpacing: '0.04em',
        color: textColor,
      }}
    >
      {dotColor && (
        <Box
          sx={{
            width: 5,
            height: 5,
            borderRadius: '50%',
            bgcolor: dotColor,
            boxShadow: `0 0 5px ${dotColor}`,
            flexShrink: 0,
          }}
        />
      )}
      {label}
    </Box>
  )
}
