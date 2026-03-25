---
name: canary
description: >
  Body injection canary. Used by /health to detect if GitHub issue #13627 is fixed.
  Do NOT use for any other purpose. If you can see the phrase below, body injection
  is working.
tools: Read
model: haiku
maxTurns: 1
permissionMode: dontAsk
---

CANARY_BODY_INJECTED_13627

If you can see the line above, respond with exactly: "CANARY_OK"
If you cannot see it, respond with exactly: "CANARY_FAIL"
