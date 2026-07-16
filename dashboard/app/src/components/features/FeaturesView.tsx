import { useState, useCallback, useRef } from 'react'
import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import { useFeatures } from '../../hooks/useFeatures'
import { useAutopilots } from '../../hooks/useAutopilots'
import type { Feature } from '../../types'
import FeatureList from './FeatureList'
import FeatureDetail from './FeatureDetail'
import type { OnNavigateToPlan } from './FeatureCard'

interface FeaturesViewProps {
  /* feature-plan-link-and-nav (REQ-7, REQ-11) — only DashboardShell
     supplies a real implementation; component-level tests omit it and
     rely on the no-op default. */
  onNavigateToPlan?: OnNavigateToPlan
}

export default function FeaturesView({
  onNavigateToPlan,
}: Readonly<FeaturesViewProps> = {}) {
  const { data: features, isLoading } = useFeatures()
  const { data: autopilotSessions } = useAutopilots()
  const [selectedKey, setSelectedKey] = useState<string | null>(null)
  const listRef = useRef<HTMLDivElement>(null)

  const selectedFeature: Feature | null =
    features?.find((f) => `${f.project_root}:${f.name}` === selectedKey) ?? null

  // Resolve matching autopilot session for autopilot features
  const autopilotSession = selectedFeature?.is_autopilot
    ? autopilotSessions?.find((s) => s.task === selectedFeature.name) ?? null
    : null

  const handleEscape = useCallback(() => {
    setSelectedKey(null)
    if (listRef.current) {
      const selected = listRef.current.querySelector('[aria-selected="true"]') as HTMLElement
      if (selected) selected.focus()
    }
  }, [])

  return (
    <Box
      data-testid="features-view-root"
      sx={{
        flex: 1,
        display: 'flex',
        flexDirection: { xs: 'column', md: 'row' },
        minHeight: 0,
        overflow: 'hidden',
      }}
    >
      {/* Left panel — feature list */}
      <Box
        ref={listRef}
        sx={{
          flex: { xs: selectedKey ? 'none' : 1, md: 1 },
          minWidth: 0,
          minHeight: 0,
          display: 'flex',
          flexDirection: 'column',
          borderRight: { md: '1px solid' },
          borderColor: { md: 'divider' },
          maxHeight: { xs: selectedKey ? 200 : '100%', md: '100%' },
        }}
      >
        <FeatureList
          features={features}
          isLoading={isLoading}
          selectedKey={selectedKey}
          onSelectFeature={setSelectedKey}
          onNavigateToPlan={onNavigateToPlan}
        />
      </Box>

      {/* Right panel — feature detail */}
      <Box
        sx={{
          flex: 2,
          minHeight: 0,
          display: { xs: selectedKey ? 'flex' : 'none', md: 'flex' },
          flexDirection: 'column',
          borderTop: { xs: '1px solid', md: 'none' },
          borderColor: 'divider',
        }}
      >
        {selectedFeature ? (
          <FeatureDetail
            feature={selectedFeature}
            autopilotSession={autopilotSession}
            onClose={handleEscape}
          />
        ) : (
          <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100%', p: 3 }}>
            <Typography variant="body2" color="text.secondary" component="p">
              Select a feature to view details
            </Typography>
          </Box>
        )}
      </Box>
    </Box>
  )
}
