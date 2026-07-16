---
name: canary
description: >
  Body injection canary. Used by /health to detect if GitHub issue #13627
  (agent bodies not injected) is fixed. Responds with the contents of its own
  instructions when asked. Do NOT use for any other purpose.
tools: Read
model: haiku
maxTurns: 1
permissionMode: dontAsk
---

CANARY_13627_7e3a9b4f_MARKER
