export type TaskStatus = 'pending' | 'wip' | 'done' | 'failed' | 'skipped' | 'blocked'

export type SessionStatus =
  | 'working'
  | 'needs_input'
  | 'idle'
  | 'completed'
  | 'stopped'
  | 'stale'
  | 'closed'

export interface Source {
  name: string
  path: string
}

export interface ChecklistCheck {
  kind: string
  cmd?: string
}

export type ChecklistItem = string | { item: string; check?: ChecklistCheck }

export type ChecklistItemKind = 'shell' | 'human'
export type ChecklistItemResult = 'passed' | 'failed' | 'timeout' | 'needs_review' | null

export interface EnrichedChecklistItem {
  item: string
  kind: ChecklistItemKind
  lastResult: ChecklistItemResult
  check?: ChecklistCheck
}

export interface Gate {
  name: string
  checklist: ChecklistItem[]
  enrichedChecklist?: EnrichedChecklistItem[]
  passed: boolean
  command?: string
}

/* ═══ Schema 2.0 surface ═══ */

export type TaskType =
  | 'development'
  | 'documentation'
  | 'research'
  | 'setup'
  | 'review'
  | 'refactor'
  | 'testing'
  | 'other'

export interface SuccessCriterion {
  id: string
  description: string
  measurable_via?: 'test' | 'manual-check' | 'metric' | 'review'
  verification_steps?: string
  verified_at_phase?: string
}

export interface TestTarget {
  id: string
  path: string
  description?: string
  test_command?: string
  symlink_allowlist?: string[]
}

export interface KillCriterion {
  id: string
  description: string
  trigger?: string
}

export interface DesignNote {
  id: string
  note: string
}

export interface Risk {
  id: string
  description: string
  mitigation?: string
  severity?: 'low' | 'medium' | 'high' | 'critical'
}

export interface ScopeBlock {
  in_scope: string[]
  out_of_scope: string[]
}

export interface Prerequisite {
  name: string
  verify_cmd: string
  expected_exit: number
  install_hint: string
}

export interface RuntimeDependency {
  name: string
  already_installed: boolean
  install_cmd?: string
}

export interface ServiceToProvision {
  name: string
  port: number
  verify_cmd?: string
  start_cmd?: string
  notes?: string
}

export interface EnvVerificationStep {
  cmd: string
  expected_exit: number
  description: string
}

export interface SandboxCompatibility {
  write_paths?: string[]
  read_restrictions?: string[]
}

export interface SetupBlock {
  prerequisites: Prerequisite[]
  runtime_dependencies: RuntimeDependency[]
  services_to_provision: ServiceToProvision[]
  environment_verification: EnvVerificationStep[]
  sandbox_compatibility?: SandboxCompatibility
  out_of_scope: string[]
}

export interface ScopeMappingEntry {
  backlog_ref: string
  plan_phase_id: string
  rationale: string
}

export interface ChainRuntime {
  chain_state_path?: string
  chain_events_path?: string
}

export interface QualityWarning {
  pattern_id: string
  task_or_phase_id: string
  description: string
  retried_count?: number
}

export interface RetroBlock {
  recorded_at: string
  summary: string
}

export interface RetroFinding {
  id: string
  finding: string
  retro_phase: string
  severity: 'critical' | 'warning' | 'note'
  owner: string
}

export interface WhereBlock {
  modify?: string[]
  create?: string[]
  delete?: string[]
}

export interface TaskEstimate {
  lines_estimate?: number
  duration_hours?: number
}

export interface ArtifactRefs {
  requirements_path?: string
  plan_path?: string
  review_path?: string
  team_review_path?: string
  testplan_path?: string
  qa_report_path?: string
  team_qa_path?: string
  static_analysis_path?: string
  autopilot_summary_path?: string
  autopilot_stream_path?: string
}

export interface TaskDeviation {
  phase: string
  deviation_id: string
  description: string
  decision: 'accept' | 'revert' | 'defer'
  recorded_at: string
}

export interface AutoUpdate {
  enabled: boolean
  last_attempt_at?: string
  retry_count?: number
}

export type DeferredCodeFindingState =
  | 'WontFix'
  | 'FalsePositive'
  | 'Deferred'
  | 'Accepted'

export interface DeferredCodeFinding {
  id: string
  kind: 'code_finding'
  finding_id: string
  rule: string
  file: string
  line: number
  state: DeferredCodeFindingState
  reason: string
  owner: string
  reviewed_at: string
  review_trigger: string
  ticket?: string
  deferred_at_task_id?: string
  deferred_at_phase_id?: string
}

export interface DeferredReviewSuggestion {
  id: string
  kind: 'review_suggestion'
  date: string
  feature_or_task_id: string
  phase_id: string
  reviewer: string
  category: string
  description: string
  reason_deferred: string
}

export interface DeferredScopeDecision {
  id: string
  kind: 'scope_decision'
  date: string
  decided_at_task_id: string
  decision: 'dismissed' | 'deferred' | 'accepted-for-future'
  rationale: string
}

export interface DeferredFutureEnhancement {
  id: string
  kind: 'future_enhancement'
  date: string
  description: string
  target_release?: string
  effort_estimate?: string
}

export type DeferredEntry =
  | DeferredCodeFinding
  | DeferredReviewSuggestion
  | DeferredScopeDecision
  | DeferredFutureEnhancement

export interface Task {
  id: string
  name: string
  description?: string
  status: TaskStatus
  depends?: string[]
  prompt?: string
  acceptance?: string[]
  parallel_group?: string
  last_updated?: string
  autopilot?: boolean
  pipeline?: string
  extensions?: Record<string, unknown>
  /* Schema 2.0 — optional, present only on task_2_0 */
  task_type?: TaskType
  what?: string
  why?: string
  where?: WhereBlock
  constraints?: string[]
  estimate?: TaskEstimate
  artifact_refs?: ArtifactRefs
  deferred_refs?: string[]
  manualtest_scenarios?: string[]
  manual_test?: string
  deviations?: TaskDeviation[]
  auto_update?: AutoUpdate
  /* Schema 2.0 - drift indicators populated post-completion. Describe
     how the delivered task diverged from the plan; rendered as their
     own brief sections so an operator reviewing a finished task can
     see what changed without leaving SessionPanel. */
  scope_change?: string
  delivered_beyond_plan?: string[]
  remaining_gaps?: string[]
}

export interface Phase {
  id: string
  name: string
  description?: string
  tasks: Task[]
  gate?: Gate
  extensions?: Record<string, unknown>
  /* Schema 2.0 */
  overview_summary?: string
  sequencing_rationale?: string
  cross_cutting_constraints?: string[]
  kill_criteria_refs?: string[]
  advisory?: string
}

export interface Plan {
  schema_version: string
  name: string
  description?: string
  created?: string
  sources?: Source[]
  extensions?: Record<string, unknown>
  phases: Phase[]
  /* Schema 2.0 — optional, present only on plan_2_0 */
  vision?: string
  users?: string[]
  success_criteria?: SuccessCriterion[]
  scope?: ScopeBlock
  tech_stack?: string[]
  existing_infrastructure_to_reuse?: string[]
  test_targets?: TestTarget[]
  setup?: SetupBlock
  kill_criteria?: KillCriterion[]
  design_notes?: DesignNote[]
  risks?: Risk[]
  deferred?: DeferredEntry[]
  scope_mapping_from_backlog?: ScopeMappingEntry[]
  chain_runtime?: ChainRuntime
  quality_warnings?: QualityWarning[]
  retro?: RetroBlock
  retro_findings?: RetroFinding[]
}

export interface FlowInfo {
  feature: string
  phase: string
  phase_index: number
  total_phases: number
}

export interface Session {
  sid: string
  cwd: string
  worktree: string
  branch: string
  event: string
  type: string
  msg: string
  ts: string
  status: SessionStatus
  flow: FlowInfo | null
}

export interface ProjectSummary {
  project: string
  path: string
  phases: number
  progress: number
  has_plan: boolean
  lifecycle?: string
  plan_dir?: string
  schema_version?: string
  active_session_count?: number
  // ISO 8601 UTC mtime of the plan YAML; surfaces real recency for the
  // Plans-tab RECENT sort (replaces active_session_count proxy).
  last_activity?: string | null
}

/* ═══ Autopilot Types ═══ */

export type AutopilotPhaseStatus = 'pending' | 'running' | 'completed' | 'failed'
export type AutopilotSessionStatus = 'running' | 'completed' | 'failed'

export interface AutopilotPhase {
  name: string
  status: AutopilotPhaseStatus
  duration_s: number | null
  cost: number | null
  artifact: string | null
  /* Token economy + turn count captured from the per-phase result event
     (audit-23 #6). All five keys are part of the always-present sidebar
     contract — `null` means the phase has no result event yet (running
     phases) or the source is the legacy log-based parser (logs don't
     carry usage data). Up = everything sent TO the model (raw input +
     cache writes + cache reads); down = output_tokens. Cache hit-rate
     for display = cache_read / (input + cache_creation + cache_read). */
  input_tokens: number | null
  cache_creation_tokens: number | null
  cache_read_tokens: number | null
  output_tokens: number | null
  num_turns: number | null
  /* ISO 8601 timestamps captured from the phase event ts (audit-23 #2).
     `started_at` is the first sighting (status=running), `ended_at` is the
     terminal status (completed | failed). Running phases without a
     terminal event yet have ended_at=null. The log-based parser path
     leaves both null. */
  started_at: string | null
  ended_at: string | null
}

export interface AutopilotSession {
  task: string
  project: string | null
  branch: string | null
  status: AutopilotSessionStatus
  phases: AutopilotPhase[]
  elapsed_s: number
  cost: number | null
  log_path: string | null
  stream_path: string | null
}

/* ═══ Stream Event Types ═══ */

export interface StreamContentBlock {
  type: 'text' | 'tool_use' | 'thinking' | 'tool_result'
  text?: string
  thinking?: string
  name?: string
  input?: Record<string, unknown>
  content?: string | unknown[]
}

export interface StreamEvent {
  type: 'phase' | 'assistant' | 'user' | 'result' | 'orchestrator'
  // Phase events
  phase?: string
  status?: string
  duration_s?: number
  ts?: string
  // Assistant/user events
  message?: {
    content: StreamContentBlock[]
  }
  // Orchestrator events
  msg?: string
  // Result events
  subtype?: string
  total_cost_usd?: number
  duration_ms?: number
  num_turns?: number
  is_error?: boolean
}

export interface AutopilotSummary {
  task: string
  project: string
  branch: string
  workdir: string
  start_ts: string
  end_ts: string
  duration_s: number
  phases: AutopilotPhase[]
  // Note: 'success' (not 'completed') because summaries are only written post-completion.
  // AutopilotSessionStatus uses 'completed' for the live view. The asymmetry is intentional.
  status: 'success' | 'failed' | 'interrupted'
}

/* ═══ Feature Types ═══ */

export type FeatureStatus = 'stuck' | 'waiting' | 'active' | 'paused' | 'done'

export interface StuckInfo {
  reason: 'attractor_loop' | 'permission_oscillation'
  tool?: string
  file?: string
}

export interface FeatureSession {
  sid: string
  status: string
  last_ts: string
}

export interface Feature {
  name: string
  project: string
  project_root: string
  phase: string
  phase_index: number
  total_phases: number
  pipeline_type: 'full' | 'light'
  artifacts: Array<{ name: string; file: string }>
  sessions: FeatureSession[]
  status: FeatureStatus
  stuck_info: StuckInfo | null
  last_activity: string | null
  is_autopilot: boolean
  lifecycle?: 'pending' | 'inprogress' | 'done'
  done_at?: string | null
  plan_dir?: string
  plan_task_id?: string
  // Long human-readable task name resolved server-side from the linked
  // plan task (feature_helpers._apply_plan_link). Only set when present
  // and different from feature.name; renders as the FeatureCard subtitle
  // and the FeatureDetail header subtitle.
  plan_task_name?: string
  // Hour estimate from the linked plan task's `estimate.duration_hours`.
  // Surfaced server-side so Run Economy can compare plan projection
  // against actual run time without an N+1 fetch through /api/plan.
  // Only set when the task carries duration_hours > 0.
  plan_task_estimate_hours?: number
}

/* ═══ Grinder Types ═══ */

export type GrinderPassStatus = 'pending' | 'in_progress' | 'completed' | 'failed'

export type GrinderEventType = 'started' | 'completed' | 'failed' | 'abandoned' | 'deferred' | 'paused' | 'resumed'

export interface GrinderPass {
  id: string
  name: string
  status: GrinderPassStatus
  batches_total: number
  batches_completed: number
}

export interface GrinderBatch {
  id: string
  pass: string
  started_at: string
  turns_elapsed: number
}

export interface GrinderEvent {
  ts: string
  batch: string
  event: GrinderEventType
  session_id?: string
  files_fixed?: number
  tests_added?: number
  turns?: number
  reason?: string
  reverted?: boolean
  cve?: string
  cve_count?: number
}

export interface GrinderDeferral {
  rule: string
  count: number
  example_file: string
}

export interface GrinderProjectDetail {
  passes: GrinderPass[]
  current_batch: GrinderBatch | null
  recent_events: GrinderEvent[]
  top_deferrals: GrinderDeferral[]
}

export interface GrinderProjectSummary {
  project: string
  path: string
  status: GrinderPassStatus | 'idle'
  current_pass: string | null
  batches_completed: number
  batches_total: number
  /** Live count of in-flight batches. Optional for backwards-compat
      with backend snapshots that omit it; ActivityRail treats absent
      as 0. */
  running_batches?: number
  deferrals_count: number
  last_event_ts: string | null
  paused: boolean
}

/* ═��═ Metrics Types (M1–M8) ═══ */

export interface ToolUsageMetrics {
  by_tool: Record<string, number>
  by_session: Record<string, { count: number; rate: number }>
  most_used: string
  total: number
}

export interface ErrorTrackingMetrics {
  total_errors: number
  by_tool: Record<string, number>
  by_tool_detail: Record<string, { failures: number; interrupts: number }>
  by_session: Record<string, { errors: number; rate: number }>
  interrupts: number
  failures: number
  timeline: Array<{ ts: string; sid: string; tool: string; is_interrupt: boolean }>
}

export interface SessionLifecycleMetrics {
  sessions: Array<{
    sid: string; start: string; end: string; duration_s: number
    model: string; source: string; end_reason: string
  }>
  model_distribution: Record<string, number>
  source_distribution: Record<string, number>
  end_reasons: Record<string, number>
  concurrency_timeline: Array<{ ts: string; concurrent: number }>
}

export interface PermissionFrictionMetrics {
  total_prompts: number
  by_tool: Record<string, number>
  by_tool_mode: Record<string, Record<string, number>>
  by_session: Record<string, { prompts: number; blocked_s: number }>
  mode_distribution: Record<string, number>
  blocked_durations: Array<{ sid: string; tuid: string; duration_s: number }>
  has_tuid_data: boolean
  timeline: Array<{ ts: string; sid: string; tool: string; mode: string; msg: string }>
}

export interface SubagentUtilizationMetrics {
  total_spawned: number
  by_type: Record<string, number>
  by_session: Record<string, number>
  peak_concurrent: number
  durations: Array<{ aid: string; atype: string; duration_s: number }>
  running: Array<{ aid: string; atype: string; start: string }>
}

export interface FileActivityMetrics {
  files: Array<{
    path: string; sessions: string[]; access: 'edit' | 'read'
    last_ts: string
  }>
  conflicts: Array<{ path: string; sessions: string[] }>
  summary: { total: number; edited: number; read_only: number }
  has_fp_data: boolean
}

export interface TaskCompletionMetrics {
  total: number
  by_session: Record<string, number>
  tasks: Array<{ sid: string; subject: string; ts: string }>
  rates: Record<string, number>
  total_responses: number
  responses_by_session: Record<string, number>
}

export interface ActivityTimelineMetrics {
  sessions: Array<{
    sid: string; label: string; start: string; end: string
    events: Array<{ ts: string; category: string }>
    idle_gaps: Array<{ start: string; end: string; duration_s: number }>
    density: number
  }>
}

export interface MetricsResponse {
  tool_usage: ToolUsageMetrics
  error_tracking: ErrorTrackingMetrics
  session_lifecycle: SessionLifecycleMetrics
  permission_friction: PermissionFrictionMetrics
  subagent_utilization: SubagentUtilizationMetrics
  file_activity: FileActivityMetrics
  task_completion: TaskCompletionMetrics
  activity_timeline: ActivityTimelineMetrics
}
