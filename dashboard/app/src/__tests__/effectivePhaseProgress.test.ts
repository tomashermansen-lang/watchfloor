import { describe, it, expect } from 'vitest'
import type { Session, AutopilotSession, AutopilotPhase, Task } from '../types'
import { effectivePhaseProgress, autopilotPhaseFraction } from '../utils/effectivePhaseProgress'

const task = (status: Task["status"] = "pending"): Task => ({
  id: "t1", name: "Task", status, dependencies: [],
} as Task)

const phase = (name: string, status: AutopilotPhase["status"]): AutopilotPhase => ({
  name, status, duration_s: null, cost: null, artifact: null,
  input_tokens: null, cache_creation_tokens: null, cache_read_tokens: null,
  output_tokens: null, num_turns: null,
  started_at: null, ended_at: null,
})

const ap = (phases: AutopilotPhase[], status: AutopilotSession["status"] = "running"): AutopilotSession => ({
  task: "Replace foo", project: null, branch: null, status, phases,
  elapsed_s: 0, cost: null, log_path: null, stream_path: null,
})

const sessionWithFlow = (phaseName: string, idx: number, total: number): Session => ({
  sid: "s1", cwd: "/dev", worktree: "/dev", branch: "feature/t1",
  event: "Notification", type: "agent", msg: "", ts: new Date().toISOString(),
  status: "working",
  flow: { feature: "t1", phase: phaseName, phase_index: idx, total_phases: total },
} as Session)

describe("effectivePhaseProgress (audit-12)", () => {
  it("returns null when no signal sources are present", () => {
    expect(effectivePhaseProgress({ task: task("pending") })).toBeNull()
  })

  it("derives from autopilot phases when running, ignoring stale session.flow", () => {
    const phases = [
      phase("BA", "completed"),
      phase("Plan", "completed"),
      phase("Team Review", "running"),
      phase("Implement", "pending"),
    ]
    const result = effectivePhaseProgress({
      task: task("pending"),
      autopilotSession: ap(phases),
      session: sessionWithFlow("plan", 1, 9),
    })
    expect(result).not.toBeNull()
    expect(result?.phase).toBe("Team Review")
    expect(result?.completed).toBe(2)
    /* Audit-15 — canonical floor (9) wins over observed (4) for
       running autopilots. The pipeline still has phases ahead. */
    expect(result?.total).toBe(9)
    expect(result?.isActive).toBe(true)
  })

  it("treats autopilot status=running as active even when task.status is pending", () => {
    const result = effectivePhaseProgress({
      task: task("pending"),
      autopilotSession: ap([phase("BA", "running")]),
    })
    expect(result?.isActive).toBe(true)
  })

  it("falls back to session.flow when autopilot has no phases yet", () => {
    const result = effectivePhaseProgress({
      task: task("wip"),
      autopilotSession: ap([]),
      session: sessionWithFlow("implement", 4, 9),
    })
    expect(result?.phase).toBe("implement")
    expect(result?.completed).toBe(4)
    expect(result?.total).toBe(9)
    expect(result?.isActive).toBe(true)
  })

  it("falls back to session.flow when no autopilot session is provided", () => {
    const result = effectivePhaseProgress({
      task: task("wip"),
      session: sessionWithFlow("plan", 1, 9),
    })
    expect(result?.phase).toBe("plan")
    expect(result?.completed).toBe(1)
    expect(result?.isActive).toBe(true)
  })

  it("isActive is false when autopilot is completed (so the bar can show terminal state via task.status)", () => {
    const phases = [phase("BA", "completed"), phase("Done", "completed")]
    const result = effectivePhaseProgress({
      task: task("done"),
      autopilotSession: ap(phases, "completed"),
    })
    expect(result?.isActive).toBe(false)
    expect(result?.completed).toBe(2)
  })

  /* Audit-15 — autopilot phases[] is emitted incrementally; when only
     BA has been observed the canonical pipeline still has 9 phases
     (FULL) or 8 (LIGHT). Total must use a canonical floor for running
     autopilots so progress doesn't read 50% when work just started. */
  it("uses canonical pipeline length as floor when autopilot is still running with few phases", () => {
    const result = effectivePhaseProgress({
      task: task("pending"),
      autopilotSession: ap([phase("BA", "running")]),
    })
    expect(result?.completed).toBe(0)
    expect(result?.total).toBeGreaterThanOrEqual(9)
    expect(result?.isActive).toBe(true)
  })

  it("midpoint progress for BA-only-running stays under 10% (audit-11 invariant)", () => {
    const result = effectivePhaseProgress({
      task: task("pending"),
      autopilotSession: ap([phase("BA", "running")]),
    })
    const ratio = ((result?.completed ?? 0) + 0.5) / (result?.total ?? 1)
    expect(ratio).toBeLessThan(0.1)
  })

  it("uses observed phases.length once autopilot has emitted more than canonical (no upper cap)", () => {
    const phases = Array.from({ length: 12 }, (_, i) =>
      phase(`P${i}`, i < 5 ? "completed" : i === 5 ? "running" : "pending")
    )
    const result = effectivePhaseProgress({
      task: task("pending"),
      autopilotSession: ap(phases),
    })
    expect(result?.total).toBe(12)
    expect(result?.completed).toBe(5)
  })

  it("completed autopilot uses observed phases.length (data is final, no floor)", () => {
    const phases = [phase("BA", "completed"), phase("Done", "completed")]
    const result = effectivePhaseProgress({
      task: task("done"),
      autopilotSession: ap(phases, "completed"),
    })
    expect(result?.total).toBe(2)
    expect(result?.completed).toBe(2)
    expect(result?.isActive).toBe(false)
  })
})
describe("autopilotPhaseFraction (audit-15)", () => {
  it("returns null when no autopilot session", () => {
    expect(autopilotPhaseFraction(undefined)).toBeNull()
  })

  it("returns null when autopilot has no phases yet", () => {
    expect(autopilotPhaseFraction(ap([]))).toBeNull()
  })

  it("uses canonical floor for running autopilot with single BA phase", () => {
    const ratio = autopilotPhaseFraction(ap([phase("BA", "running")]))
    expect(ratio).not.toBeNull()
    expect(ratio).toBeLessThan(0.1)
  })

  it("midpoint at second phase running stays under 20%", () => {
    const phases = [phase("BA", "completed"), phase("Plan", "running")]
    const ratio = autopilotPhaseFraction(ap(phases))
    expect(ratio).not.toBeNull()
    expect(ratio).toBeLessThan(0.2)
  })

  it("uses observed phases.length for completed autopilot (no floor)", () => {
    const phases = [phase("BA", "completed"), phase("Done", "completed")]
    const ratio = autopilotPhaseFraction(ap(phases, "completed"))
    // (2 + 0.5) / 2 = 1.25 -- intentionally over 1; clamping is the
    // caller's responsibility. We only assert no canonical floor is
    // applied to completed sessions.
    expect(ratio).toBeGreaterThan(1)
  })
})
