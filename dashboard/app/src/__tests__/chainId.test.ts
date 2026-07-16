import { describe, it, expect } from 'vitest'
import { planDirToChainId } from '../utils/chainId'

// controls-03 #2 — chain target_id is the dir-basename minus the
// `INPROGRESS_Plan_` prefix. Mirrors dashboard/server/control.py:213
// (`label = "INPROGRESS_Plan_"`). The server resolves the chain
// target by joining `docs/INPROGRESS_Plan_<target_id>` so this helper
// is the inverse on the client.

describe('planDirToChainId', () => {
  it('strips INPROGRESS_Plan_ prefix from a bare basename', () => {
    expect(planDirToChainId('INPROGRESS_Plan_autopilot-cost-efficiency')).toBe(
      'autopilot-cost-efficiency',
    )
  })

  it('extracts basename from an absolute path then strips the prefix', () => {
    expect(
      planDirToChainId(
        '/Users/tomas/Projekter/dotfiles/docs/INPROGRESS_Plan_autopilot-cost-efficiency',
      ),
    ).toBe('autopilot-cost-efficiency')
  })

  it('handles a relative docs/ path', () => {
    expect(planDirToChainId('docs/INPROGRESS_Plan_watchfloor-controls-ui')).toBe(
      'watchfloor-controls-ui',
    )
  })

  it('strips a trailing slash before reading the basename', () => {
    expect(
      planDirToChainId('docs/INPROGRESS_Plan_autopilot-cost-efficiency/'),
    ).toBe('autopilot-cost-efficiency')
  })

  it('returns basename unchanged when the prefix is missing', () => {
    // A DONE_Plan_X or BACKLOG_Plan_X path should never reach this
    // helper (chain start only fires on INPROGRESS_Plan_*), but if it
    // does we want a deterministic value, not a surprise rewrite.
    expect(planDirToChainId('docs/DONE_Plan_watchfloor')).toBe(
      'DONE_Plan_watchfloor',
    )
    expect(planDirToChainId('some-other-dir')).toBe('some-other-dir')
  })

  it('returns empty string for empty input', () => {
    expect(planDirToChainId('')).toBe('')
  })
})
