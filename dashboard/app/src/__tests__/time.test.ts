import { describe, it, expect } from 'vitest'
import { relativeTime } from '../utils/time'

describe('relativeTime', () => {
  it('returns empty string for empty input', () => {
    expect(relativeTime('')).toBe('')
  })

  it('formats seconds ago', () => {
    const ts = new Date(Date.now() - 30_000).toISOString()
    expect(relativeTime(ts)).toBe('30s ago')
  })

  it('formats minutes ago', () => {
    const ts = new Date(Date.now() - 5 * 60_000).toISOString()
    expect(relativeTime(ts)).toBe('5m ago')
  })

  it('formats hours ago', () => {
    const ts = new Date(Date.now() - 3 * 3600_000).toISOString()
    expect(relativeTime(ts)).toBe('3h ago')
  })

  it('formats days ago', () => {
    const ts = new Date(Date.now() - 2 * 86400_000).toISOString()
    expect(relativeTime(ts)).toBe('2d ago')
  })
})
