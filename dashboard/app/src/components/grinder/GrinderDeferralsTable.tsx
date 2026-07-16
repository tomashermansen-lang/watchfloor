import Paper from '@mui/material/Paper'
import Typography from '@mui/material/Typography'
import Table from '@mui/material/Table'
import TableBody from '@mui/material/TableBody'
import TableCell from '@mui/material/TableCell'
import TableHead from '@mui/material/TableHead'
import TableRow from '@mui/material/TableRow'
import type { GrinderDeferral } from '../../types'

export default function GrinderDeferralsTable({ deferrals }: { deferrals: GrinderDeferral[] }) {
  return (
    <Paper elevation={0} sx={{ border: '1px solid', borderColor: 'divider', p: 2 }}>
      <Typography variant="titleMedium" sx={{ mb: 1 }}>Top Deferrals</Typography>
      {deferrals.length === 0 ? (
        <Typography variant="body2" color="text.secondary">No deferred findings</Typography>
      ) : (
        <Table size="small">
          <TableHead>
            <TableRow>
              <TableCell>Rule</TableCell>
              <TableCell align="right">Count</TableCell>
              <TableCell>Example File</TableCell>
            </TableRow>
          </TableHead>
          <TableBody>
            {deferrals.map((d) => (
              <TableRow key={d.rule}>
                <TableCell sx={{ maxWidth: 280, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {d.rule}
                </TableCell>
                <TableCell align="right">
                  <span aria-live="polite">{d.count}</span>
                </TableCell>
                <TableCell sx={{ maxWidth: 280, overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                  {d.example_file}
                </TableCell>
              </TableRow>
            ))}
          </TableBody>
        </Table>
      )}
    </Paper>
  )
}
