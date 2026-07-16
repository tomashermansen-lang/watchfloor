// controls-03 #2 — derive the chain target_id from a plan directory.
// Mirrors dashboard/server/control.py:213
// (`label = "INPROGRESS_Plan_"`). The server resolves chain targets by
// joining `docs/INPROGRESS_Plan_<target_id>`; this helper is the
// inverse the frontend needs to send through useSessionControls.
//
// Accepts any of: bare basename, relative path, absolute path, with
// or without a trailing slash. If the basename does not start with
// the `INPROGRESS_Plan_` prefix we return it unchanged — chain start
// is only ever invoked on an in-progress plan, but a deterministic
// passthrough is safer than a silent rewrite for the DONE_/BACKLOG_
// edge cases.

const _PREFIX = 'INPROGRESS_Plan_'

export function planDirToChainId(planDir: string): string {
  const trimmed = planDir.replace(/\/+$/, '')
  const base = trimmed.split('/').pop() ?? ''
  if (base.startsWith(_PREFIX)) {
    return base.slice(_PREFIX.length)
  }
  return base
}
