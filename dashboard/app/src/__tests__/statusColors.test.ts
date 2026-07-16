import { describe, it, expect } from 'vitest'
import theme from '../theme'
import { getStatusColors } from '../utils/statusColors'

describe('getStatusColors', () => {
  it('returns status, container, and onContainer for done', () => {
    const result = getStatusColors('done', theme)
    expect(result.status).toBe(theme.palette.status.done)
    expect(result.container).toBe(theme.palette.statusContainer.done)
    expect(result.onContainer).toBe(theme.palette.onStatusContainer.done)
  })

  it('returns correct colors for all statuses', () => {
    const statuses = ['pending', 'wip', 'done', 'failed', 'skipped', 'blocked'] as const
    for (const s of statuses) {
      const result = getStatusColors(s, theme)
      expect(result.status).toBeDefined()
      expect(result.container).toBeDefined()
      expect(result.onContainer).toBeDefined()
    }
  })

  it('returns correct colors for blocked status', () => {
    const result = getStatusColors('blocked', theme)
    expect(result.status).toBe(theme.palette.status.blocked)
    expect(result.container).toBe(theme.palette.statusContainer.blocked)
    expect(result.onContainer).toBe(theme.palette.onStatusContainer.blocked)
  })
})
