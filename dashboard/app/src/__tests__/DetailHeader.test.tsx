import React from 'react'
import { describe, it, expect, vi } from 'vitest'
import { render, screen, within } from '@testing-library/react'
import { ThemeProvider } from '@mui/material/styles'
import theme from '../theme'
import DetailHeader from '../components/wf/DetailHeader'
import StatusPill from '../components/wf/StatusPill'

function renderHeader(ui: React.ReactElement) {
  return render(<ThemeProvider theme={theme}>{ui}</ThemeProvider>)
}

/* ═══ DetailHeader primitive ═══

   Single source of truth for the canonical detail-screen header
   used by SessionPanel + FeatureDetail. Per design_handoff
   screens.md §3 "Header row":
     - × close button (24×24, ghost) at left
     - LIVE pill (atoms.md) when live
     - Session/feature title (Geist Mono via wfH3)
     - Right-aligned project name (JetBrains Mono in wf.fog via wfLabel + text.secondary)
     - Trailing slot for status pills (AUTOPILOT, COMPLETED, etc.)
*/

describe('DetailHeader', () => {
  it('DH-1: renders close button when onClose is provided', () => {
    const onClose = vi.fn()
    renderHeader(<DetailHeader title="x" isLive={false} onClose={onClose} />)
    expect(screen.getByLabelText('Close panel')).toBeInTheDocument()
  })

  it('DH-2: omits close button when onClose is undefined', () => {
    renderHeader(<DetailHeader title="x" isLive={false} />)
    expect(screen.queryByLabelText('Close panel')).not.toBeInTheDocument()
  })

  it('DH-3: renders LiveBadge when isLive=true', () => {
    const { container } = renderHeader(<DetailHeader title="x" isLive />)
    expect(container.querySelector('[data-testid="wf-live-badge"]')).not.toBeNull()
  })

  it('DH-4: omits LiveBadge when isLive=false', () => {
    const { container } = renderHeader(<DetailHeader title="x" isLive={false} />)
    expect(container.querySelector('[data-testid="wf-live-badge"]')).toBeNull()
  })

  it('DH-5: renders title prominently (wfH3)', () => {
    renderHeader(<DetailHeader title="my-feature" isLive={false} />)
    expect(screen.getByText('my-feature')).toBeInTheDocument()
  })

  it('DH-6: renders projectName muted (wfLabel text.secondary) on the right', () => {
    const { container } = renderHeader(
      <DetailHeader title="x" isLive={false} projectName="my-project" />
    )
    const project = screen.getByText('my-project')
    expect(project).toBeInTheDocument()
    /* Visual ordering: title → project. Title has flexGrow:1 so the
       project chip lands at the right edge of the row. */
    const header = container.querySelector('[data-testid="detail-header"]') as HTMLElement
    expect(header).not.toBeNull()
    const titleNode = within(header).getByText('x')
    const projectNode = within(header).getByText('my-project')
    /* In document order, project comes after title (DOM-position). */
    const cmp = titleNode.compareDocumentPosition(projectNode)
    expect(cmp & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })

  it('DH-7: omits projectName slot when not provided', () => {
    renderHeader(<DetailHeader title="x" isLive={false} />)
    expect(screen.queryByText('my-project')).not.toBeInTheDocument()
  })

  it('DH-8: renders trailing slot content (e.g. StatusPill)', () => {
    renderHeader(
      <DetailHeader
        title="x"
        isLive={false}
        trailing={<StatusPill status="completed" label="completed" />}
      />
    )
    expect(screen.getByText('completed')).toBeInTheDocument()
  })

  it('DH-9: header carries data-testid="detail-header" for shell-detection', () => {
    const { container } = renderHeader(<DetailHeader title="x" isLive={false} />)
    expect(container.querySelector('[data-testid="detail-header"]')).not.toBeNull()
  })

  /* DH-10..DH-12 - user-request 2026-05-08: brief / feature-detail headers
     pair task.id (technical identity, primary) with task.name (human
     description, secondary). DetailHeader gains an optional subtitle prop. */
  it('DH-10: renders subtitle below title when provided', () => {
    const { container } = renderHeader(
      <DetailHeader title="filter-hooks-factory" isLive={false} subtitle="Extract createVersionedFilterState factory" />
    )
    expect(screen.getByText('Extract createVersionedFilterState factory')).toBeInTheDocument()
    expect(container.querySelector('[data-testid="detail-header-subtitle"]')).not.toBeNull()
  })

  it('DH-11: omits subtitle when not provided (back-compat)', () => {
    const { container } = renderHeader(<DetailHeader title="x" isLive={false} />)
    expect(container.querySelector('[data-testid="detail-header-subtitle"]')).toBeNull()
  })

  it('DH-12: subtitle sits below title in document order', () => {
    renderHeader(
      <DetailHeader title="primary" isLive={false} subtitle="secondary description" />
    )
    const titleNode = screen.getByText('primary')
    const subtitleNode = screen.getByText('secondary description')
    const cmp = titleNode.compareDocumentPosition(subtitleNode)
    expect(cmp & Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy()
  })
})
