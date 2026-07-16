import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { resolve } from 'node:path'

/* index.html contract — fonts the watchfloor brand depends on must
   be linked here (Inter ships via @fontsource-variable/inter, the two
   mono families come from Google Fonts). Asserting the markup keeps
   the dependency visible in the test surface so a stray edit can't
   silently revert chrome to system mono. */

const html = readFileSync(resolve(__dirname, '../../index.html'), 'utf8')

describe('index.html font loading', () => {
  it('preconnects to Google Fonts host', () => {
    expect(html).toMatch(/rel="preconnect"\s+href="https:\/\/fonts\.googleapis\.com"/)
    expect(html).toMatch(/rel="preconnect"\s+href="https:\/\/fonts\.gstatic\.com"/)
  })

  it('loads Geist Mono with weights 400/500/600', () => {
    expect(html).toMatch(/Geist\+Mono:wght@400;500;600/)
  })

  it('loads JetBrains Mono with weights 400/500', () => {
    expect(html).toMatch(/JetBrains\+Mono:wght@400;500/)
  })

  it('uses display=swap to avoid invisible text during font load', () => {
    expect(html).toContain('display=swap')
  })

  it('browser tab title is the watchfloor wordmark, not the legacy product name', () => {
    expect(html).toMatch(/<title>\s*watchfloor\s*<\/title>/)
  })
})
