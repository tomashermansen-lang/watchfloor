import { describe, it, expect } from 'vitest'
import { featureToWfStatus, toneToWfStatus, autopilotToTone, isAutopilotActive, taskStatusToWfStatus, sessionStatusToWfStatus } from '../utils/featureStatusMapping'

/* Maps the feature lifecycle states (active/waiting/stuck/paused/done)
   reported by /api/features into the four wf product-status colors.
   Status-strings come from the backend so the mapper is the single
   point that knows the translation — keeps the rebrand local. */

describe('featureToWfStatus', () => {
  it('active → running (signal blue, agent at work)', () => {
    expect(featureToWfStatus('active')).toBe('running')
  })

  it('waiting → stalled (amber, awaits review)', () => {
    expect(featureToWfStatus('waiting')).toBe('stalled')
  })

  it('stuck → fault (red, blocked / failed)', () => {
    expect(featureToWfStatus('stuck')).toBe('fault')
  })

  it('done → completed (green)', () => {
    expect(featureToWfStatus('done')).toBe('completed')
  })

  it('paused → null (no live state — render grey fallback)', () => {
    expect(featureToWfStatus('paused')).toBeNull()
  })

  it('unknown values → null (defensive — never throws)', () => {
    expect(featureToWfStatus('whatever')).toBeNull()
    expect(featureToWfStatus('')).toBeNull()
  })
})

/* ActivityRail's RailRow already abstracts status into a 5-state
   "tone" vocabulary (info/warning/error/success/muted). Rather than
   replumb every caller, route that abstraction to WfStatus too so
   sessions/plans/grinders inherit the brand glow with a one-line
   change. muted → null (grey fallback) for the same reason as
   featureToWfStatus. */
describe('toneToWfStatus', () => {
  it('info → running', () => {
    expect(toneToWfStatus('info')).toBe('running')
  })
  it('warning → stalled', () => {
    expect(toneToWfStatus('warning')).toBe('stalled')
  })
  it('error → fault', () => {
    expect(toneToWfStatus('error')).toBe('fault')
  })
  it('success → completed', () => {
    expect(toneToWfStatus('success')).toBe('completed')
  })
  it('muted → null (no live state)', () => {
    expect(toneToWfStatus('muted')).toBeNull()
  })
})

/* Autopilot lifecycle vocabulary differs from feature/session — its
   states are { running, completed, failed, stopped }. Two helpers:
   isAutopilotActive decides whether the row belongs in ACTIVE PLANS
   at all (only running ones), autopilotToTone maps the status to a
   RailRow tone for the cases where one is rendered anyway. */
describe('autopilot helpers', () => {
  it('isAutopilotActive: only running counts as active', () => {
    expect(isAutopilotActive('running')).toBe(true)
    expect(isAutopilotActive('completed')).toBe(false)
    expect(isAutopilotActive('failed')).toBe(false)
    expect(isAutopilotActive('stopped')).toBe(false)
    expect(isAutopilotActive('done')).toBe(false)
  })

  it('autopilotToTone: running → info', () => {
    expect(autopilotToTone('running')).toBe('info')
  })
  it('autopilotToTone: completed → success', () => {
    expect(autopilotToTone('completed')).toBe('success')
  })
  it('autopilotToTone: failed → error', () => {
    expect(autopilotToTone('failed')).toBe('error')
  })
  it('autopilotToTone: stopped → muted', () => {
    expect(autopilotToTone('stopped')).toBe('muted')
  })
})

/* Plan task lifecycle uses { pending, wip, done, failed, skipped, blocked }.
   Same wf 4-color palette + muted for the two intentional non-states
   (pending = hasn't started yet; skipped = deliberately not run). */
describe('taskStatusToWfStatus', () => {
  it('wip → running', () => {
    expect(taskStatusToWfStatus('wip')).toBe('running')
  })
  it('done → completed', () => {
    expect(taskStatusToWfStatus('done')).toBe('completed')
  })
  it('blocked → stalled (waiting for unblock)', () => {
    expect(taskStatusToWfStatus('blocked')).toBe('stalled')
  })
  it('failed → fault', () => {
    expect(taskStatusToWfStatus('failed')).toBe('fault')
  })
  it('pending → null (not started — muted)', () => {
    expect(taskStatusToWfStatus('pending')).toBeNull()
  })
  it('skipped → null (intentionally not run — muted)', () => {
    expect(taskStatusToWfStatus('skipped')).toBeNull()
  })
})

/* Session lifecycle: working/needs_input/idle/completed/stopped/stale/closed.
   stale = the session hasn't reported in too long — operationally a
   fault signal (something needs attention). idle/stopped/closed are
   intentional non-states → muted. */
describe('sessionStatusToWfStatus', () => {
  it('working → running', () => {
    expect(sessionStatusToWfStatus('working')).toBe('running')
  })
  it('needs_input → stalled (awaits operator)', () => {
    expect(sessionStatusToWfStatus('needs_input')).toBe('stalled')
  })
  it('completed → completed', () => {
    expect(sessionStatusToWfStatus('completed')).toBe('completed')
  })
  it('stale → fault (no recent activity, needs attention)', () => {
    expect(sessionStatusToWfStatus('stale')).toBe('fault')
  })
  it('idle → null (muted, intentional non-state)', () => {
    expect(sessionStatusToWfStatus('idle')).toBeNull()
  })
  it('stopped → null (muted)', () => {
    expect(sessionStatusToWfStatus('stopped')).toBeNull()
  })
  it('closed → null (muted)', () => {
    expect(sessionStatusToWfStatus('closed')).toBeNull()
  })
})
