/// <reference types="vitest/config" />
import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'

export default defineConfig({
  plugins: [react()],
  server: {
    proxy: {
      '/api': 'http://127.0.0.1:8787',
      '/data': 'http://127.0.0.1:8787',
      // controls-06 #16 — proxy the WebSocket terminal route to
      // FastAPI on 8787. Vite-dev's default proxy only forwards
      // HTTP; `ws: true` is required for the WS upgrade. Without
      // this, the browser's `ws://localhost:5174/ws/chain/terminal`
      // 404s at Vite before reaching the backend and the
      // useTerminalSocket reconnect chain exhausts → status='lost'.
      '/ws': {
        target: 'ws://127.0.0.1:8787',
        ws: true,
        changeOrigin: true,
      },
    },
  },
  build: {
    outDir: 'dist',
    rollupOptions: {
      output: {
        manualChunks: {
          recharts: ['recharts'],
        },
      },
    },
  },
  test: {
    environment: 'jsdom',
    globals: true,
    unstubGlobals: true,
    setupFiles: './src/test-setup.ts',
    coverage: {
      provider: 'v8',
      reporter: ['lcov', 'text'],
      reportsDirectory: './coverage',
      // Vitest 4.x default is false: any test-file failure skips
      // coverage write entirely. With 87 test files and 1803 tests,
      // one xterm-in-jsdom failure (ProjectSubviewTab.test.tsx) would
      // hide ~99.5% real coverage from Sonar. Set true so partial
      // coverage still reaches the report — this is what the local-LLM
      // autopilot loop needs to see honest gradients on broken branches.
      reportOnFailure: true,
      include: ['src/**/*.{ts,tsx}'],
      exclude: [
        'src/**/*.test.*',
        'src/**/*.spec.*',
        'src/**/__tests__/**',
        'src/test-setup.ts',
        'src/main.tsx',
      ],
    },
  },
})
