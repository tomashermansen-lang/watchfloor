import Table from '@mui/material/Table'
import TableBody from '@mui/material/TableBody'
import TableCell from '@mui/material/TableCell'
import TableHead from '@mui/material/TableHead'
import TableRow from '@mui/material/TableRow'
import Paper from '@mui/material/Paper'
import StatusPill from '../wf/StatusPill'
import { grinderPassStatusToWfStatus } from '../../utils/featureStatusMapping'
import type { GrinderProjectSummary } from '../../types'

function relativeTime(iso: string | null): string {
  if (!iso) return '—'
  const diff = Date.now() - new Date(iso).getTime()
  const mins = Math.floor(diff / 60_000)
  if (mins < 1) return 'just now'
  if (mins < 60) return `${mins}m ago`
  const hours = Math.floor(mins / 60)
  if (hours < 24) return `${hours}h ago`
  return `${Math.floor(hours / 24)}d ago`
}

interface GrinderProjectListProps {
  projects: GrinderProjectSummary[]
  onSelectProject: (project: string) => void
}

export default function GrinderProjectList({ projects, onSelectProject }: GrinderProjectListProps) {
  return (
    <Paper elevation={0} sx={{ border: '1px solid', borderColor: 'divider' }}>
      <Table size="small">
        <TableHead>
          <TableRow>
            <TableCell>Project</TableCell>
            <TableCell>Current Pass</TableCell>
            <TableCell>Progress</TableCell>
            <TableCell align="right">Deferrals</TableCell>
            <TableCell>Last Event</TableCell>
            <TableCell>Status</TableCell>
          </TableRow>
        </TableHead>
        <TableBody>
          {projects.map((p) => {
            const label = p.paused ? 'paused' : p.status.replace('_', ' ')
            const wfStatus = p.paused ? null : grinderPassStatusToWfStatus(p.status)
            return (
              <TableRow
                key={p.project}
                hover
                tabIndex={0}
                sx={{ cursor: 'pointer' }}
                onClick={() => onSelectProject(p.project)}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' || e.key === ' ') {
                    e.preventDefault()
                    onSelectProject(p.project)
                  }
                }}
              >
                <TableCell>{p.project}</TableCell>
                <TableCell>{p.current_pass ?? '—'}</TableCell>
                <TableCell>{p.batches_completed}/{p.batches_total}</TableCell>
                <TableCell align="right">{p.deferrals_count}</TableCell>
                <TableCell>{relativeTime(p.last_event_ts)}</TableCell>
                <TableCell>
                  <StatusPill status={wfStatus} label={label} />
                </TableCell>
              </TableRow>
            )
          })}
        </TableBody>
      </Table>
    </Paper>
  )
}
