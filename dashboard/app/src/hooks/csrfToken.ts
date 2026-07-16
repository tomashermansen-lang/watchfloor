// Shared CSRF token plumbing — single source of truth for every hook
// that needs to authenticate against the dashboard server. Both
// `useSessionControls` (POST /api/{kind}/{action}) and
// `useTerminalSocket` (WebSocket /ws/{kind}/terminal?csrf=...)
// consume this module so the body-token fallback added in
// controls-06 #11 is honoured uniformly.
//
// Read chain:
//   1. `document.cookie` (the canonical double-submit cookie)
//   2. `<meta name="csrf-token">` (server-rendered SPA fallback —
//      currently unused but kept for the dist served straight from
//      FastAPI without Vite)
//   3. Module-level cache populated by `/api/csrf` (controls-06 #11
//      Vite-dev fallback; SameSite=Strict + proxy hop keeps cookies
//      out of document.cookie on some browsers)
//
// The cache is module-singleton so two hook instances sharing a
// page never burn two `/api/csrf` round-trips. The in-flight Promise
// singleton (`_csrfFetchPromise`) collapses concurrent calls into
// one network request.

const _CSRF_COOKIE_NAME = 'csrf_token'
const _CSRF_META_NAME = 'csrf-token'

let _csrfBodyTokenCache: string | null = null
let _csrfFetchPromise: Promise<string | null> | null = null

export function readCsrfFromCookie(): string | null {
  let cookieStr = ''
  try {
    cookieStr = document.cookie
  } catch {
    return null
  }
  if (!cookieStr) return null
  const entries = cookieStr.split(';').map((s) => s.trim())
  for (const entry of entries) {
    const eq = entry.indexOf('=')
    if (eq < 0) continue
    const name = entry.slice(0, eq)
    if (name !== _CSRF_COOKIE_NAME) continue
    const raw = entry.slice(eq + 1)
    try {
      const decoded = decodeURIComponent(raw)
      if (decoded) return decoded
    } catch {
      // malformed encoding — fall through
    }
    return null
  }
  return null
}

export function readCsrfFromMeta(): string | null {
  const meta = document.querySelector(`meta[name="${_CSRF_META_NAME}"]`)
  const content = meta?.getAttribute('content') ?? null
  return content || null
}

export function readCsrfFromCache(): string | null {
  return _csrfBodyTokenCache
}

/** Synchronous token lookup. Returns null when none of the three
   layers (cookie, meta, in-memory cache) have a value. Callers that
   want a fallback to `/api/csrf` should use `resolveCsrfToken`. */
export function readCsrfToken(): string | null {
  return readCsrfFromCookie() ?? readCsrfFromMeta() ?? readCsrfFromCache()
}

/** Fire-once `/api/csrf` fetch that populates the module cache.
   Subsequent calls return the cached value; concurrent calls share
   the in-flight Promise so the round-trip is never duplicated.
   Returns null on any failure (non-200, malformed body, network
   exception) without poisoning the cache — the next call retries.
   controls-07 #2 — failure cases also emit a single console.warn so
   the operator's devtools surface the real transport-level cause
   when the upstream Alert reads "CSRF token unavailable — reload
   the page". Silent swallowing turned cycle-7 audit into a guessing
   game; cookies blocked / 502 from a stale proxy / extension
   interference each produce a distinct, actionable warning. */
export async function fetchCsrfBodyToken(): Promise<string | null> {
  if (_csrfBodyTokenCache !== null) return _csrfBodyTokenCache
  if (_csrfFetchPromise !== null) return _csrfFetchPromise
  _csrfFetchPromise = (async () => {
    try {
      const res = await fetch('/api/csrf', { credentials: 'same-origin' })
      if (!res.ok) {
        console.warn(
          `csrfToken: /api/csrf returned HTTP ${res.status}. The next mutation will show a "CSRF token unavailable" Alert; reload will not fix this. Check the server is reachable and the response body shape.`,
        )
        return null
      }
      const data = (await res.json()) as { token?: unknown }
      if (typeof data.token === 'string' && data.token.length > 0) {
        _csrfBodyTokenCache = data.token
        return data.token
      }
      console.warn(
        'csrfToken: /api/csrf returned 200 but body did not contain a non-empty token string. Server contract changed?',
      )
      return null
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err)
      console.warn(
        `csrfToken: /api/csrf fetch threw — ${msg}. Likely network/CORS/extension; reload will not fix this.`,
      )
      return null
    } finally {
      _csrfFetchPromise = null
    }
  })()
  return _csrfFetchPromise
}

/** Async resolver: sync read first, then body-token fallback. */
export async function resolveCsrfToken(): Promise<string | null> {
  const sync = readCsrfToken()
  if (sync !== null) return sync
  return fetchCsrfBodyToken()
}

// Test-only — reset the module-level cache between cases so a value
// populated by an earlier test doesn't leak into the next one's
// assertion path.
export function _resetCsrfBodyTokenCache(): void {
  _csrfBodyTokenCache = null
  _csrfFetchPromise = null
}
