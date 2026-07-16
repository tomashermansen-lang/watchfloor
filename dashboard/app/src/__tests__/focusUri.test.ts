import { describe, it, expect } from 'vitest'
import { buildFocusUri, buildLaunchCommand } from '../utils/focusUri'

describe('buildFocusUri', () => {
  it('builds valid vscode URI for absolute path', () => {
    expect(buildFocusUri('/Users/test/project')).toBe('vscode://file/Users/test/project')
  })

  it('rejects path traversal', () => {
    expect(buildFocusUri('/Users/../etc/passwd')).toBeNull()
  })

  it('rejects empty string', () => {
    expect(buildFocusUri('')).toBeNull()
  })

  it('rejects relative path', () => {
    expect(buildFocusUri('relative/path')).toBeNull()
  })
})

describe('buildLaunchCommand', () => {
  it('builds cd + autopilot command', () => {
    expect(buildLaunchCommand('/Users/test/OIH', 'my-task')).toBe(
      'cd "/Users/test/OIH" && bash ~/.claude/tools/autopilot.sh --full my-task'
    )
  })

  it('rejects path traversal', () => {
    expect(buildLaunchCommand('/Users/../etc', 'task')).toBeNull()
  })

  it('rejects empty project path', () => {
    expect(buildLaunchCommand('', 'task')).toBeNull()
  })

  it('rejects empty task id', () => {
    expect(buildLaunchCommand('/Users/test', '')).toBeNull()
  })

  it('rejects relative path', () => {
    expect(buildLaunchCommand('relative/path', 'task')).toBeNull()
  })

  it('includes --light flag for light pipeline', () => {
    expect(buildLaunchCommand('/Users/test/OIH', 'my-task', 'light')).toBe(
      'cd "/Users/test/OIH" && bash ~/.claude/tools/autopilot.sh --full --pipeline light my-task'
    )
  })

  it('uses full pipeline by default', () => {
    expect(buildLaunchCommand('/Users/test/OIH', 'my-task', 'full')).toBe(
      'cd "/Users/test/OIH" && bash ~/.claude/tools/autopilot.sh --full my-task'
    )
  })
})
