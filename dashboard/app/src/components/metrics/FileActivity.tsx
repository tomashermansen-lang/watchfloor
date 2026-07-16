import {
  Alert, Table, TableBody, TableCell, TableContainer,
  TableHead, TableRow, Typography,
} from '@mui/material'
import { memo } from 'react'
import type { FileActivityMetrics } from '../../types'
import MetricCard from './MetricCard'
import StatusPill from '../wf/StatusPill'

interface FileActivityProps {
  data: FileActivityMetrics
}

function FileActivityInner({ data }: FileActivityProps) {
  if (!data.has_fp_data) {
    return (
      <MetricCard title="File Activity" isEmpty emptyMessage="">
        <Alert severity="info" variant="standard">
          No file activity data available — hook update required.
        </Alert>
      </MetricCard>
    )
  }

  return (
    <MetricCard
      title="File Activity"
      isEmpty={data.files.length === 0}
      emptyMessage="No file activity"
    >
      {data.conflicts.slice(0, 5).map(c => (
        <Alert key={c.path} severity="warning" sx={{ mb: 1 }} aria-live="assertive">
          {c.path.split('/').pop()} edited by {c.sessions.length} sessions
        </Alert>
      ))}
      {data.conflicts.length > 5 && (
        <Typography variant="wfBody" color="text.secondary" sx={{ mb: 1, display: 'block' }}>
          +{data.conflicts.length - 5} more file conflicts
        </Typography>
      )}
      <TableContainer
        sx={{
          maxHeight: 400,
          /* Brand table chrome — header cells in JBM uppercase 0.16em
             wf.fog (matches DeferredAuditView DataGrid + OverviewView
             portfolio table). Body cells in JBM mono per data-table
             spec. wf.steel hairlines, no borderRadius. */
          '& .MuiTableCell-head': {
            fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
            fontSize: '9px',
            fontWeight: 500,
            letterSpacing: '0.16em',
            textTransform: 'uppercase',
            color: 'wf.fog',
            borderBottom: '1px solid',
            borderColor: 'wf.steel',
            bgcolor: 'transparent',
          },
          '& .MuiTableCell-body': {
            borderBottom: '1px solid',
            borderColor: 'wf.steel',
            color: 'wf.bone',
          },
        }}
      >
        <Table size="small" aria-label="File activity">
          <TableHead>
            <TableRow>
              <TableCell>File</TableCell>
              <TableCell>Sessions</TableCell>
              <TableCell>Access</TableCell>
              <TableCell>Last Activity</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {data.files.map(f => (
              <TableRow key={f.path} hover>
                <TableCell>
                  <Typography variant="wfCode" sx={{ display: 'block' }}>
                    {f.path}
                  </Typography>
                </TableCell>
                <TableCell>
                  <Typography
                    variant="wfCode"
                    sx={{
                      display: 'block',
                      maxWidth: 200, overflow: 'hidden',
                      textOverflow: 'ellipsis', whiteSpace: 'nowrap',
                      color: 'wf.fog',
                    }}
                  >
                    {f.sessions.map(s => s.slice(0, 7)).join(', ')}
                  </Typography>
                </TableCell>
                <TableCell>
                  {/* Access pill — brand StatusPill: edit=stalled
                     (amber, write-conflict prone), read=muted. */}
                  <StatusPill
                    status={f.access === 'edit' ? 'stalled' : null}
                    label={f.access === 'edit' ? 'Edit' : 'Read'}
                  />
                </TableCell>
                <TableCell>
                  <Typography variant="wfCode" sx={{ color: 'wf.fog' }}>
                    {new Date(f.last_ts).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}
                  </Typography>
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      </TableContainer>
      <Typography variant="wfLabel" color="text.secondary" sx={{ mt: 1.5, display: 'block' }}>
        {data.summary.total} files ({data.summary.edited} edited, {data.summary.read_only} read-only)
      </Typography>
    </MetricCard>
  )
}

const FileActivity = memo(FileActivityInner)
export default FileActivity
