---
name: security-checklist
description: Security audit checklist — OWASP Top 10, auth patterns, input validation, secrets management. Used by security-auditor agent.
user-invocable: false
---

# Security Checklist

## Thinking Framework

Before auditing, identify:
1. **Trust boundaries** — Where does untrusted input enter? (HTTP endpoints, CLI args, file uploads, webhook payloads)
2. **Data sensitivity** — What's the worst-case leak? (session tokens, user data, API keys)
3. **Attack surface** — What's internet-facing vs. internal-only?

## Stack-Specific Vectors

Focus audit effort here — these are the vectors Claude tends to miss:

| Stack | Vector | What to look for |
|-------|--------|-----------------|
| FastAPI | Command injection | `subprocess.run(shell=True)` with user input, `os.system()` |
| FastAPI | Path traversal | File operations with user-supplied paths not resolved against a root |
| FastAPI | CORS | `allow_origins=["*"]` in production |
| Python | Deserialization | `pickle.loads()` on untrusted data, `yaml.load()` without `SafeLoader` |
| MUI/React | XSS | `dangerouslySetInnerHTML`, unescaped user content in tooltips/labels |
| Shell hooks | Injection | Unquoted variables in bash (`$VAR` vs `"$VAR"`), eval on hook input |
| JSONL/JSON | Injection | User-controlled strings written to JSONL without escaping newlines |

## Input Validation Boundaries

Validate at **system boundaries only** (not internal calls):

- [ ] All user input sanitized before use
- [ ] All external API responses validated
- [ ] All file paths checked for traversal (`../`)
- [ ] All URLs validated against allowlist
- [ ] All query parameters typed and bounded
- [ ] No raw user input in SQL, shell commands, or HTML

## Auth Flow Patterns

- [ ] Authentication before authorization (never skip auth check)
- [ ] Token expiry and refresh implemented
- [ ] Session invalidation on logout/password change
- [ ] Rate limiting on auth endpoints
- [ ] No sensitive data in JWTs or URL parameters

## Secrets Management

- [ ] No hardcoded secrets, API keys, or passwords in source
- [ ] Secrets loaded from environment variables or secret store
- [ ] `.env` files in `.gitignore`
- [ ] No secrets in logs, error messages, or client responses
- [ ] Credential rotation plan documented

## Severity Rules

- **All security findings are WARNING minimum** — never SUGGESTION
- Missing auth/authz → CRITICAL
- Injection vectors → CRITICAL
- Hardcoded secrets → CRITICAL
- Missing input validation at boundary → WARNING
- Missing rate limiting → WARNING
- Missing security headers → WARNING

## Gotchas

- **OWASP table is noise.** Claude already knows OWASP Top 10 cold. The
  stack-specific vectors table above is where real bugs hide — audit that first.
- **Shell hook scripts are the #1 injection risk** in this repo. Every hook
  receives JSON on stdin — if parsed with string manipulation instead of `jq`,
  crafted input can break out. Always use `jq -r` for field extraction.
- **Sandbox gives false confidence.** The macOS Seatbelt sandbox blocks
  credential reads at the kernel level, but sandbox restrictions don't apply
  to production deployments. Don't skip input validation because "the sandbox
  catches it."
