import { describe, it, expect } from 'vitest'
import type { StreamEvent } from '../types'
import { derivePhaseEvents } from '../utils/derivePhaseEvents'

const phase = (name: string, status?: 'running' | 'completed' | 'failed', extras: Partial<StreamEvent> = {}): StreamEvent =>
  ({ type: 'phase', phase: name, status, ...extras } as StreamEvent)

const text = (s: string): StreamEvent =>
  ({ type: 'assistant', message: { content: [{ type: 'text', text: s }] } } as StreamEvent)

describe('derivePhaseEvents (skarm-9 #1)', () => {
  it('returns empty array for empty input', () => {
    expect(derivePhaseEvents([])).toEqual([])
  })

  it('passes non-phase events through unchanged', () => {
    const events = [text('a'), text('b')]
    expect(derivePhaseEvents(events)).toEqual(events)
  })

  it('suppresses superseded phase event when later event for SAME phase exists', () => {
    const events = [phase('BA', 'running'), text('working'), phase('BA', 'completed', { duration_s: 90 })]
    const out = derivePhaseEvents(events)
    expect(out).toHaveLength(2)
    expect(out[0]).toEqual(text('working'))
    expect(out[1]).toMatchObject({ type: 'phase', phase: 'BA', status: 'completed' })
  })

  it('overrides running phase to completed when a later DIFFERENT phase exists', () => {
    const events = [phase('BA', 'running'), phase('AP', 'running')]
    const out = derivePhaseEvents(events)
    expect(out).toHaveLength(2)
    expect(out[0]).toMatchObject({ phase: 'BA', status: 'completed' })
    expect(out[1]).toMatchObject({ phase: 'AP', status: 'running' })
  })

  it('keeps the latest phase running when nothing follows', () => {
    const events = [phase('BA', 'completed'), phase('AP', 'running')]
    const out = derivePhaseEvents(events)
    expect(out[1]).toMatchObject({ phase: 'AP', status: 'running' })
  })

  it('does NOT touch failed status (preserves orchestrator-reported failures)', () => {
    const events = [phase('BA', 'failed'), phase('AP', 'running')]
    const out = derivePhaseEvents(events)
    expect(out[0]).toMatchObject({ phase: 'BA', status: 'failed' })
  })

  it('handles undefined status as running and overrides to completed if successor exists', () => {
    const events = [phase('BA'), phase('AP', 'running')]
    const out = derivePhaseEvents(events)
    expect(out[0]).toMatchObject({ phase: 'BA', status: 'completed' })
  })

  it('combined: BA-running, BA-completed, AP-running -> BA-completed kept, AP-running kept', () => {
    const events = [phase('BA', 'running'), phase('BA', 'completed'), phase('AP', 'running')]
    const out = derivePhaseEvents(events)
    expect(out).toHaveLength(2)
    expect(out[0]).toMatchObject({ phase: 'BA', status: 'completed' })
    expect(out[1]).toMatchObject({ phase: 'AP', status: 'running' })
  })
})
