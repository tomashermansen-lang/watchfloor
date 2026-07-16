import { useState, useEffect } from 'react'
import Box from '@mui/material/Box'
import Dialog from '@mui/material/Dialog'
import DialogTitle from '@mui/material/DialogTitle'
import IconButton from '@mui/material/IconButton'
import Typography from '@mui/material/Typography'
import Skeleton from '@mui/material/Skeleton'
import CloseIcon from '@mui/icons-material/Close'
import Markdown from 'react-markdown'
import remarkGfm from 'remark-gfm'
import { wfMarkdownSx } from '../wf/markdownStyles'
import { brandifyMarkdown, wfMarkdownComponents } from '../wf/markdownComponents'

interface ArtifactDialogProps {
  /** API URL to fetch artifact content. Response must be JSON with a `content` field. */
  url: string | null
  /** Display title for the dialog header */
  title?: string
  onClose: () => void
}

export default function ArtifactDialog({ url, title, onClose }: ArtifactDialogProps) {
  const [content, setContent] = useState<string | null>(null)
  const [loading, setLoading] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    if (!url) {
      setContent(null)
      return
    }
    setLoading(true)
    setError(null)
    fetch(url)
      .then((res) => {
        if (!res.ok) throw new Error(`HTTP ${res.status}`)
        return res.json()
      })
      .then((data) => {
        setContent(data.content)
        setLoading(false)
      })
      .catch((err) => {
        setError(err.message)
        setLoading(false)
      })
  }, [url])

  const isYaml = title?.endsWith('.yaml') || title?.endsWith('.yml')

  return (
    <Dialog
      open={url !== null}
      onClose={onClose}
      /* Operator: artifacts dialog should be wider — md (~900px)
         clipped long lines and tables. lg (~1200px) gives long
         markdown tables and code blocks room to breathe. */
      maxWidth="lg"
      fullWidth
      scroll="paper"
      slotProps={{ paper: { sx: { maxHeight: '90vh' } } }}
    >
      {url && (
        <>
          <DialogTitle sx={{ display: 'flex', alignItems: 'center', gap: 1, pr: 6 }}>
            <Typography variant="wfH3" sx={{ flex: 1 }}>{title ?? 'Artifact'}</Typography>
            <IconButton
              onClick={onClose}
              aria-label="Close artifact"
              sx={{ position: 'absolute', right: 8, top: 8 }}
            >
              <CloseIcon />
            </IconButton>
          </DialogTitle>
          <Box sx={{ px: 3, pb: 3, overflowY: 'auto' }}>
            {loading ? (
              <Box>
                <Skeleton variant="text" width="80%" />
                <Skeleton variant="text" width="60%" />
                <Skeleton variant="rectangular" height={120} sx={{ mt: 1, borderRadius: 1 }} />
              </Box>
            ) : error ? (
              <Typography color="error">Failed to load artifact: {error}</Typography>
            ) : content !== null ? (
              isYaml ? (
                <Box
                  component="pre"
                  sx={{
                    fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
                    fontSize: '12px',
                    lineHeight: 1.6,
                    bgcolor: 'wf.ink',
                    border: '1px solid',
                    borderColor: 'wf.steel',
                    p: 2,
                    borderRadius: 0,
                    overflowX: 'auto',
                    whiteSpace: 'pre-wrap',
                    wordBreak: 'break-word',
                  }}
                >
                  {content}
                </Box>
              ) : (
                <Box sx={wfMarkdownSx}>
                  <Markdown remarkPlugins={[remarkGfm]} components={wfMarkdownComponents}>
                    {brandifyMarkdown(content)}
                  </Markdown>
                </Box>
              )
            ) : null}
          </Box>
        </>
      )}
    </Dialog>
  )
}
