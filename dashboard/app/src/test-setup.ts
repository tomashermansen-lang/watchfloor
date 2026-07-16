import '@testing-library/jest-dom/vitest'
import { vi } from 'vitest'

Element.prototype.scrollIntoView = vi.fn()

// jsdom doesn't ship ResizeObserver
globalThis.ResizeObserver ??= class {
  observe() {}
  unobserve() {}
  disconnect() {}
} as unknown as typeof ResizeObserver

// jsdom doesn't implement matchMedia — MUI's responsive hooks (useMediaQuery,
// useTheme breakpoints) call it on render and throw without this. Standard
// vitest+jsdom+MUI polyfill. (Fixes ProjectSubviewTab.test.tsx: 9 cases that
// mount MUI-responsive components — caught when run-all.sh finally ran the
// frontend suite, 2026-06-02.)
if (typeof window !== 'undefined' && typeof window.matchMedia !== 'function') {
  Object.defineProperty(window, 'matchMedia', {
    writable: true,
    value: (query: string) => ({
      matches: false,
      media: query,
      onchange: null,
      addEventListener: () => {},
      removeEventListener: () => {},
      addListener: () => {},
      removeListener: () => {},
      dispatchEvent: () => false,
    }),
  })
}
