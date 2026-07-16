import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest'
import {
  readCsrfFromCookie,
  readCsrfFromMeta,
  readCsrfFromCache,
  readCsrfToken,
  fetchCsrfBodyToken,
  resolveCsrfToken,
  _resetCsrfBodyTokenCache,
} from '../hooks/csrfToken'

// === Test fixtures =====================================================

function stubCookie(value: string): void {
  Object.defineProperty(document, 'cookie', {
    configurable: true,
    get: () => value,
    set: () => {},
  })
}

function stubMeta(content: string | null): void {
  document.head
    .querySelectorAll('meta[name="csrf-token"]')
    .forEach((n) => n.remove())
  if (content === null) return
  const meta = document.createElement('meta')
  meta.setAttribute('name', 'csrf-token')
  meta.setAttribute('content', content)
  document.head.appendChild(meta)
}

beforeEach(() => {
  _resetCsrfBodyTokenCache()
  stubCookie('')
  stubMeta(null)
  vi.unstubAllGlobals()
})

afterEach(() => {
  vi.unstubAllGlobals()
})

// === C1: synchronous readers ===========================================

describe('csrfToken — sync readers', () => {
  it('C1.1: readCsrfFromCookie returns the value when present', () => {
    stubCookie('csrf_token=ABC123')
    expect(readCsrfFromCookie()).toBe('ABC123')
  })

  it('C1.2: readCsrfFromCookie returns null when absent', () => {
    stubCookie('other=foo')
    expect(readCsrfFromCookie()).toBeNull()
  })

  it('C1.3: readCsrfFromCookie returns null when document.cookie throws', () => {
    Object.defineProperty(document, 'cookie', {
      configurable: true,
      get: () => {
        throw new Error('blocked')
      },
    })
    expect(readCsrfFromCookie()).toBeNull()
  })

  it('C1.4: readCsrfFromMeta returns the meta tag content', () => {
    stubMeta('META-TOKEN')
    expect(readCsrfFromMeta()).toBe('META-TOKEN')
  })

  it('C1.5: readCsrfFromMeta returns null when meta absent', () => {
    stubMeta(null)
    expect(readCsrfFromMeta()).toBeNull()
  })

  it('C1.6: readCsrfFromCache returns null until fetchCsrfBodyToken populates it', () => {
    expect(readCsrfFromCache()).toBeNull()
  })

  it('C1.7: readCsrfToken chain — cookie wins over meta and cache', () => {
    stubCookie('csrf_token=COOKIE')
    stubMeta('META')
    expect(readCsrfToken()).toBe('COOKIE')
  })

  it('C1.8: readCsrfToken chain — meta wins over cache when cookie empty', () => {
    stubCookie('')
    stubMeta('META')
    expect(readCsrfToken()).toBe('META')
  })
})

// === C2: body-token fallback ===========================================

describe('csrfToken — body-token fallback', () => {
  it('C2.1: fetchCsrfBodyToken hits /api/csrf and caches the value', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ token: 'BODY-TOKEN' }),
    })
    vi.stubGlobal('fetch', fetchMock)

    const token = await fetchCsrfBodyToken()
    expect(token).toBe('BODY-TOKEN')
    expect(fetchMock).toHaveBeenCalledTimes(1)
    /* Second call hits the cache, NOT the network. */
    expect(await fetchCsrfBodyToken()).toBe('BODY-TOKEN')
    expect(fetchMock).toHaveBeenCalledTimes(1)
    expect(readCsrfFromCache()).toBe('BODY-TOKEN')
  })

  it('C2.2: concurrent calls share the in-flight Promise', async () => {
    let resolveFetch: (v: { ok: boolean; json: () => Promise<unknown> }) => void = () => {}
    const fetchMock = vi.fn().mockImplementation(
      () =>
        new Promise((resolve) => {
          resolveFetch = resolve
        }),
    )
    vi.stubGlobal('fetch', fetchMock)

    const p1 = fetchCsrfBodyToken()
    const p2 = fetchCsrfBodyToken()
    resolveFetch({ ok: true, json: () => Promise.resolve({ token: 'X' }) })
    const [a, b] = await Promise.all([p1, p2])
    expect(a).toBe('X')
    expect(b).toBe('X')
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('C2.3: failed fetch returns null and does NOT poison the cache', async () => {
    const fetchMock = vi.fn().mockResolvedValue({
      ok: false,
      json: () => Promise.resolve({ detail: 'oops' }),
    })
    vi.stubGlobal('fetch', fetchMock)
    expect(await fetchCsrfBodyToken()).toBeNull()
    /* Failure clears the in-flight Promise so the NEXT call retries
       (operator hit reload, server is healthy again). */
    expect(await fetchCsrfBodyToken()).toBeNull()
    expect(fetchMock).toHaveBeenCalledTimes(2)
  })

  it('C2.4: network exception is swallowed, returns null', async () => {
    const fetchMock = vi.fn().mockRejectedValue(new TypeError('Network down'))
    vi.stubGlobal('fetch', fetchMock)
    expect(await fetchCsrfBodyToken()).toBeNull()
  })

  it('C2.5: resolveCsrfToken short-circuits when cookie is present', async () => {
    stubCookie('csrf_token=COOKIE')
    const fetchMock = vi.fn()
    vi.stubGlobal('fetch', fetchMock)
    expect(await resolveCsrfToken()).toBe('COOKIE')
    expect(fetchMock).not.toHaveBeenCalled()
  })

  it('C2.6: resolveCsrfToken falls through to fetchCsrfBodyToken', async () => {
    stubCookie('')
    stubMeta(null)
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ token: 'BODY' }),
    })
    vi.stubGlobal('fetch', fetchMock)
    expect(await resolveCsrfToken()).toBe('BODY')
    expect(fetchMock).toHaveBeenCalledTimes(1)
  })

  it('C2.7: non-OK /api/csrf response logs a console.warn with status (controls-07 #2)', async () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const fetchMock = vi.fn().mockResolvedValue({
      ok: false,
      status: 502,
      json: () => Promise.resolve({}),
    })
    vi.stubGlobal('fetch', fetchMock)
    expect(await fetchCsrfBodyToken()).toBeNull()
    /* The whole point: operator-facing Alert says "reload the page",
       but reload won't help when /api/csrf itself returns 502. The
       diagnostic surfaces the real cause in the console so the next
       triaging step knows where to look. */
    expect(warnSpy).toHaveBeenCalledTimes(1)
    const message = String(warnSpy.mock.calls[0]?.[0] ?? '')
    expect(message).toMatch(/csrfToken/i)
    expect(message).toContain('502')
    warnSpy.mockRestore()
  })

  it('C2.8: network exception logs a console.warn with the error message (controls-07 #2)', async () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const fetchMock = vi.fn().mockRejectedValue(new TypeError('Failed to fetch'))
    vi.stubGlobal('fetch', fetchMock)
    expect(await fetchCsrfBodyToken()).toBeNull()
    expect(warnSpy).toHaveBeenCalledTimes(1)
    const message = String(warnSpy.mock.calls[0]?.[0] ?? '')
    expect(message).toMatch(/csrfToken/i)
    expect(message).toContain('Failed to fetch')
    warnSpy.mockRestore()
  })

  it('C2.9: successful fetch does NOT log (controls-07 #2)', async () => {
    const warnSpy = vi.spyOn(console, 'warn').mockImplementation(() => {})
    const fetchMock = vi.fn().mockResolvedValue({
      ok: true,
      json: () => Promise.resolve({ token: 'OK-TOKEN' }),
    })
    vi.stubGlobal('fetch', fetchMock)
    expect(await fetchCsrfBodyToken()).toBe('OK-TOKEN')
    expect(warnSpy).not.toHaveBeenCalled()
    warnSpy.mockRestore()
  })
})
