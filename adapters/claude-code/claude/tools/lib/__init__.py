"""Python helpers for the Claude Code CLI pipeline.

Modules here are invoked by bash orchestrators (autopilot.sh,
commit-preflight.sh, commit-finalize.sh) via `python3 -m` or direct
script calls. Keeping them as proper modules (not heredoc'd snippets)
makes them testable with pytest and type-checkable with mypy.
"""
