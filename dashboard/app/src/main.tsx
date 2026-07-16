import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { ThemeProvider } from '@mui/material/styles'
import CssBaseline from '@mui/material/CssBaseline'
import { SWRConfig } from 'swr'
// @ts-expect-error fontsource has no type declarations
import '@fontsource-variable/inter'
import theme from './theme'
import App from './App'

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <ThemeProvider theme={theme} defaultMode="system">
      <CssBaseline enableColorScheme />
      <SWRConfig value={{ revalidateOnFocus: true }}>
        <App />
      </SWRConfig>
    </ThemeProvider>
  </StrictMode>,
)
