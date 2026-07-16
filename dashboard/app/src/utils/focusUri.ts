/**
 * Build a vscode:// URI for click-to-focus, with path validation.
 * Returns null if the path is invalid.
 */
export function buildFocusUri(worktreePath: string): string | null {
  if (!worktreePath || typeof worktreePath !== 'string') return null
  if (worktreePath.includes('..')) return null
  if (!worktreePath.startsWith('/')) return null
  return `vscode://file${worktreePath}`
}

/**
 * Build the shell command to launch an autopilot task.
 * Returns the full cd + autopilot command string.
 * Pipeline 'light' adds --light flag; 'full' or undefined uses default (full).
 */
export function buildLaunchCommand(projectPath: string, taskId: string, pipeline?: string): string | null {
  if (!projectPath || !taskId) return null
  if (projectPath.includes('..') || !projectPath.startsWith('/')) return null
  const pipelineFlag = pipeline === 'light' ? ' --pipeline light' : ''
  return `cd "${projectPath}" && bash ~/.claude/tools/autopilot.sh --full${pipelineFlag} ${taskId}`
}
