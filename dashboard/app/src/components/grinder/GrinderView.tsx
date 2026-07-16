import { useState } from 'react'
import Box from '@mui/material/Box'
import Typography from '@mui/material/Typography'
import Skeleton from '@mui/material/Skeleton'
import { useGrinderList } from '../../hooks/useGrinder'
import GrinderProjectList from './GrinderProjectList'
import GrinderDetail from './GrinderDetail'

export default function GrinderView() {
  const { data: projects, isLoading } = useGrinderList()
  const [selectedProject, setSelectedProject] = useState<string | null>(null)

  const selectedSummary = projects?.find((p) => p.project === selectedProject) ?? null

  if (isLoading) {
    return (
      <Box sx={{ p: 3 }}>
        <Skeleton variant="rectangular" height={48} sx={{ mb: 1.5, borderRadius: 1 }} />
        <Skeleton variant="rectangular" height={200} sx={{ borderRadius: 1 }} />
      </Box>
    )
  }

  if (!projects || projects.length === 0) {
    return (
      <Box sx={{ display: 'flex', alignItems: 'center', justifyContent: 'center', height: '100%', p: 3 }}>
        <Typography variant="body1" color="text.secondary">
          No grinder data found. Run the grinder on a project to see status here.
        </Typography>
      </Box>
    )
  }

  if (selectedProject && selectedSummary) {
    return (
      <Box sx={{ flex: 1, overflow: 'auto' }}>
        <GrinderDetail
          project={selectedProject}
          paused={selectedSummary.paused}
          onBack={() => setSelectedProject(null)}
        />
      </Box>
    )
  }

  return (
    <Box sx={{ flex: 1, overflow: 'auto', p: { xs: 1.5, sm: 2, md: 3 } }}>
      <GrinderProjectList projects={projects} onSelectProject={setSelectedProject} />
    </Box>
  )
}
