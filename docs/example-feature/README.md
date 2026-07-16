# Example feature audit trails

Two real features delivered through the Watchfloor pipeline, published exactly as the pipeline committed them. The only edit is path sanitization (`/Users/<name>` → `~`). Each folder holds the complete artifact chain (requirements → plan → test plan → review → QA report → static analysis), the run's machine summary, and the full tool-level stream.

| Example | What it demonstrates |
|---------|----------------------|
| [grinder-auth-recovery](grinder-auth-recovery/) | An unattended run where QA was not a rubber stamp: the verdict passed only after a fix loop that added 13 test scenarios. The feature itself hardens autonomous runs against a real observed failure (expired credentials treated as a transient error). |
| [session-status-endpoint](session-status-endpoint/) | The static-analysis gate biting on real code: SonarQube flagged 2 findings in the branch's own Python, both fixed in a dedicated `fix: resolve static analysis findings` commit and re-scanned to zero. Also shows the brownfield policy: pre-existing project-wide findings are logged and scoped out, never silently absorbed. |

Both runs used the current eight-phase order (test plan before review, static analysis after QA) with every checkpoint auto-approved — the gates did the gatekeeping.
