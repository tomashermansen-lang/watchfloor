import { createTheme } from '@mui/material/styles'

/* ═══ Type Augmentations ═══ */

declare module '@mui/material/styles' {
  interface Palette {
    status: {
      pending: string
      wip: string
      done: string
      failed: string
      skipped: string
      blocked: string
      running: string
      completed: string
      stalled: string
      fault: string
    }
    eventType: {
      tool: string
      error: string
      notification: string
      subagent: string
      session: string
      permission: string
      task: string
      prompt: string
    }
    statusContainer: {
      pending: string
      wip: string
      done: string
      failed: string
      skipped: string
      blocked: string
    }
    onStatusContainer: {
      pending: string
      wip: string
      done: string
      failed: string
      skipped: string
      blocked: string
    }
    surface1: string
    surface2: string
    surface3: string
    surfaceVariant: string
    outline: string
    outlineVariant: string
    wf: {
      ink: string
      carbon: string
      steel: string
      fog: string
      bone: string
      signal: string
      signalDim: string
    }
  }
  interface PaletteOptions {
    status?: {
      pending?: string
      wip?: string
      done?: string
      failed?: string
      skipped?: string
      blocked?: string
      running?: string
      completed?: string
      stalled?: string
      fault?: string
    }
    eventType?: {
      tool?: string
      error?: string
      notification?: string
      subagent?: string
      session?: string
      permission?: string
      task?: string
      prompt?: string
    }
    statusContainer?: {
      pending?: string
      wip?: string
      done?: string
      failed?: string
      skipped?: string
      blocked?: string
    }
    onStatusContainer?: {
      pending?: string
      wip?: string
      done?: string
      failed?: string
      skipped?: string
      blocked?: string
    }
    surface1?: string
    surface2?: string
    surface3?: string
    surfaceVariant?: string
    outline?: string
    outlineVariant?: string
    wf?: {
      ink?: string
      carbon?: string
      steel?: string
      fog?: string
      bone?: string
      signal?: string
      signalDim?: string
    }
  }
  interface TypographyVariants {
    displayMedium: React.CSSProperties
    headlineSmall: React.CSSProperties
    titleLarge: React.CSSProperties
    titleMedium: React.CSSProperties
    titleSmall: React.CSSProperties
    labelLarge: React.CSSProperties
    labelMedium: React.CSSProperties
    labelSmall: React.CSSProperties
    wfDisplay: React.CSSProperties
    wfH1: React.CSSProperties
    wfH2: React.CSSProperties
    wfH3: React.CSSProperties
    wfLabel: React.CSSProperties
    wfBody: React.CSSProperties
    wfCode: React.CSSProperties
  }
  interface TypographyVariantsOptions {
    displayMedium?: React.CSSProperties
    headlineSmall?: React.CSSProperties
    titleLarge?: React.CSSProperties
    titleMedium?: React.CSSProperties
    titleSmall?: React.CSSProperties
    labelLarge?: React.CSSProperties
    labelMedium?: React.CSSProperties
    labelSmall?: React.CSSProperties
    wfDisplay?: React.CSSProperties
    wfH1?: React.CSSProperties
    wfH2?: React.CSSProperties
    wfH3?: React.CSSProperties
    wfLabel?: React.CSSProperties
    wfBody?: React.CSSProperties
    wfCode?: React.CSSProperties
  }
}

declare module '@mui/material/Typography' {
  interface TypographyPropsVariantOverrides {
    displayMedium: true
    headlineSmall: true
    titleLarge: true
    titleMedium: true
    titleSmall: true
    labelLarge: true
    labelMedium: true
    labelSmall: true
    wfDisplay: true
    wfH1: true
    wfH2: true
    wfH3: true
    wfLabel: true
    wfBody: true
    wfCode: true
  }
}

declare module '@mui/material/Chip' {
  interface ChipPropsColorOverrides {
    pending: true
    wip: true
    done: true
    failed: true
    skipped: true
    blocked: true
  }
}

/* ═══ Theme ═══ */

const theme = createTheme({
  cssVariables: { colorSchemeSelector: 'data' },
  colorSchemes: {
    light: {
      palette: {
        /* Primary carries the brand identity color (signal-blue)
           so selection borders, focused outlines, and link text
           all read as wf brand instead of generic Material green. */
        primary: {
          main: '#3B9EFF',
          light: '#6FB8FF',
          dark: '#1F6FBF',
          contrastText: '#FAFAF7',
        },
        secondary: {
          main: '#8B7355',
          light: '#B09A7C',
          dark: '#5E4D39',
        },
        background: {
          default: '#FAFAF7',
          paper: '#F5F3EE',
        },
        text: {
          primary: '#2C2C2A',
          secondary: '#6B6B65',
        },
        divider: 'rgba(0, 0, 0, 0.08)',
        status: {
          pending: '#9CA3AF',
          wip: '#6B8DB5',
          done: '#6B9E6B',
          failed: '#C07070',
          skipped: '#B8B5AD',
          blocked: '#C4943E',
          running: '#3B9EFF',
          completed: '#5BD68A',
          stalled: '#F2B441',
          fault: '#EF4D4D',
        },
        eventType: {
          tool: '#4A7DB5',
          error: '#C07070',
          notification: '#C4943E',
          subagent: '#8B6BAE',
          session: '#6B9E6B',
          permission: '#C48040',
          task: '#4A9E8E',
          prompt: '#9CA3AF',
        },
        statusContainer: {
          done: '#C4EDBB',
          wip: '#D6E3FF',
          failed: '#FFDAD6',
          pending: '#E2E2E5',
          skipped: '#E3E3DB',
          blocked: '#FFEFD6',
        },
        onStatusContainer: {
          done: '#205017',
          wip: '#004788',
          failed: '#690005',
          pending: '#44474F',
          skipped: '#3F4239',
          blocked: '#5C3D00',
        },
        surface1: '#EFF2EB',
        surface2: '#E7EBE2',
        surface3: '#DFE3DA',
        surfaceVariant: '#DFE4D7',
        outline: '#737870',
        outlineVariant: '#C3C8BB',
        wf: {
          ink: '#0B0E13',
          carbon: '#10141B',
          steel: '#1B2230',
          fog: '#5A6472',
          bone: '#E6EBF2',
          signal: '#3B9EFF',
          signalDim: '#1F6FBF',
        },
      },
    },
    dark: {
      palette: {
        /* Brand identity color (signal-blue) for selection chrome
           in dark mode. Same #3B9EFF as wf.signal so the accent
           reads consistently across selection borders, focused
           outlines, and link text. */
        primary: {
          main: '#3B9EFF',
          light: '#6FB8FF',
          dark: '#1F6FBF',
        },
        secondary: {
          main: '#C4A882',
          light: '#D4BFA0',
          dark: '#A08A68',
        },
        /* Dark mode is the brand canvas per handoff README. Background
           and surface tokens migrate to wf.ink / wf.carbon / wf.steel
           so existing components inherit the brand colors via the
           tokens they already consume — no per-component refactor
           needed. Light mode is kept on the sage-green palette until
           we lock the app to dark-only. */
        background: {
          default: '#0B0E13',
          paper: '#10141B',
        },
        text: {
          primary: '#E6EBF2',
          secondary: '#7A8494',
        },
        divider: 'rgba(230, 235, 242, 0.08)',
        status: {
          pending: '#6B6F76',
          wip: '#7BA3CC',
          done: '#82B882',
          failed: '#D48A8A',
          skipped: '#5C5A55',
          blocked: '#D4A54A',
          running: '#3B9EFF',
          completed: '#5BD68A',
          stalled: '#F2B441',
          fault: '#EF4D4D',
        },
        eventType: {
          tool: '#7BA3CC',
          error: '#D48A8A',
          notification: '#D4A54A',
          subagent: '#A98FCA',
          session: '#82B882',
          permission: '#D4A060',
          task: '#6BBCAC',
          prompt: '#6B6F76',
        },
        statusContainer: {
          done: '#1D3713',
          wip: '#003062',
          failed: '#410002',
          pending: '#2B2F33',
          skipped: '#2C2F28',
          blocked: '#3D2E00',
        },
        onStatusContainer: {
          done: '#A5D199',
          wip: '#ABC7FF',
          failed: '#FFB4AB',
          pending: '#C3C6CF',
          skipped: '#C7C8BF',
          blocked: '#FFD98E',
        },
        surface1: '#10141B',
        surface2: '#161B25',
        surface3: '#1B2230',
        surfaceVariant: '#1B2230',
        outline: '#5A6472',
        outlineVariant: '#1B2230',
        wf: {
          ink: '#0B0E13',
          carbon: '#10141B',
          steel: '#1B2230',
          fog: '#5A6472',
          bone: '#E6EBF2',
          signal: '#3B9EFF',
          signalDim: '#1F6FBF',
        },
      },
    },
  },
  shape: { borderRadius: 8 },
  typography: {
    fontFamily: '"Inter Variable", "Inter", "Roboto", "Helvetica Neue", sans-serif',
    h4: { fontWeight: 400, letterSpacing: '-0.02em', lineHeight: 1.2 },
    h5: { fontWeight: 400, letterSpacing: '-0.01em', lineHeight: 1.3 },
    h6: { fontWeight: 500, letterSpacing: '-0.01em' },
    subtitle1: { fontWeight: 500, fontSize: '0.95rem' },
    subtitle2: { fontWeight: 500, fontSize: '0.8rem', letterSpacing: '0.02em' },
    body2: { lineHeight: 1.6 },
    caption: { fontSize: '0.75rem', letterSpacing: '0.01em' },
    overline: { fontSize: '0.65rem', fontWeight: 500, letterSpacing: '0.1em' },
    displayMedium: { fontSize: '2.8rem', fontWeight: 400, lineHeight: 1.2 },
    headlineSmall: { fontSize: '1.5rem', fontWeight: 500, lineHeight: 1.3 },
    titleLarge: { fontSize: '1.375rem', fontWeight: 500, lineHeight: 1.3 },
    titleMedium: { fontSize: '1rem', fontWeight: 500, lineHeight: 1.4 },
    titleSmall: { fontSize: '0.875rem', fontWeight: 500, lineHeight: 1.4 },
    labelLarge: { fontSize: '0.875rem', fontWeight: 500, lineHeight: 1.4 },
    labelMedium: { fontSize: '0.75rem', fontWeight: 500, lineHeight: 1.3 },
    labelSmall: { fontSize: '0.6875rem', fontWeight: 500, lineHeight: 1.2 },
    /* Watchfloor brand variants — handoff "Typography" table.
       Family-strings keep system-mono fallbacks until real fonts are
       loaded via index.html in the next step. */
    wfDisplay: {
      fontFamily: '"Geist Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
      fontSize: '32px', fontWeight: 500, lineHeight: 1.1,
    },
    wfH1: {
      fontFamily: '"Geist Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
      fontSize: '22px', fontWeight: 500, lineHeight: 1.2, letterSpacing: '-0.005em',
    },
    wfH2: {
      fontFamily: '"Geist Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
      fontSize: '18px', fontWeight: 500, lineHeight: 1.25,
    },
    wfH3: {
      fontFamily: '"Geist Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
      fontSize: '14px', fontWeight: 600, lineHeight: 1.3,
    },
    wfLabel: {
      fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
      fontSize: '10px', fontWeight: 500, lineHeight: 1.2,
      textTransform: 'uppercase', letterSpacing: '0.16em',
    },
    wfBody: {
      fontFamily: '"Inter Variable", "Inter", "Roboto", "Helvetica Neue", sans-serif',
      fontSize: '13px', fontWeight: 400, lineHeight: 1.5,
    },
    wfCode: {
      fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
      fontSize: '11px', fontWeight: 400, lineHeight: 1.4,
    },
  },
  components: {
    MuiCssBaseline: {
      styleOverrides: {
        ':root': {
          '--motion-emphasized': 'cubic-bezier(0.2, 0, 0, 1)',
          '--motion-emphasized-decelerate': 'cubic-bezier(0.05, 0.7, 0.1, 1)',
          '--motion-emphasized-accelerate': 'cubic-bezier(0.3, 0, 0.8, 0.15)',
          '--motion-standard': 'cubic-bezier(0.2, 0, 0, 1)',
          '--motion-short3': '150ms',
          '--motion-short4': '200ms',
          '--motion-medium1': '250ms',
          '--motion-medium2': '300ms',
          '--font-mono': "'ui-monospace', 'SFMono-Regular', 'Menlo', 'Consolas', monospace",
        },
        body: {
          transition: 'background-color 400ms var(--motion-emphasized), color 400ms var(--motion-emphasized)',
        },
        /* Watchfloor brand keyframes — radar sweep (used by RadarMark
           sweep prop and the LIVE pill) and the running-phase pulse. */
        '@keyframes wf-radar-sweep': {
          from: { transform: 'rotate(0deg)' },
          to: { transform: 'rotate(360deg)' },
        },
        '@keyframes wf-pulse': {
          '0%, 100%': { opacity: 1 },
          '50%': { opacity: 0.3 },
        },
      },
    },
    MuiCard: {
      defaultProps: { elevation: 0 },
      styleOverrides: {
        root: {
          /* Sharp 90° matches the radar geometry the rest of
             the brand is built on; instrument-panel chrome. */
          borderRadius: 0,
          border: '1px solid',
          borderColor: 'var(--mui-palette-divider)',
          transition: 'background-color var(--motion-short4) var(--motion-emphasized), border-color var(--motion-short4) var(--motion-emphasized)',
          '&:hover': {
            borderColor: 'var(--mui-palette-primary-light)',
          },
        },
      },
    },
    MuiPaper: {
      defaultProps: { elevation: 0 },
      styleOverrides: {
        root: {
          backgroundImage: 'none',
          /* Sharp 90° brand corners on every Paper surface
             (popovers, dialogs, sheets). Existing surfaces that
             want rounding can override per-instance via sx. */
          borderRadius: 0,
        },
      },
    },
    MuiChip: {
      styleOverrides: {
        root: { fontWeight: 500, borderRadius: 8 },
      },
    },
    /* Watchfloor brand banner — handoff §UI Primitives "Banner/Toast".
       Sharp 90° corners, severity-colored 3px left rail (mirrors
       OverviewView status-header treatment), wf.steel border so
       the banner reads as instrument-panel chrome instead of a
       generic Material toast. Severity color comes through MUI's
       palette mapping (info/warning/error/success → currentColor
       cascades onto the rail via borderLeftColor 'currentColor'). */
    MuiAlert: {
      styleOverrides: {
        root: {
          borderRadius: 0,
          border: '1px solid',
          borderColor: 'var(--mui-palette-wf-steel)',
          borderLeft: '3px solid',
          backgroundColor: 'transparent',
        },
        standardInfo: { borderLeftColor: 'var(--mui-palette-wf-signal)' },
        standardWarning: { borderLeftColor: 'var(--mui-palette-status-stalled)' },
        standardError: { borderLeftColor: 'var(--mui-palette-status-fault)' },
        standardSuccess: { borderLeftColor: 'var(--mui-palette-status-completed)' },
      },
    },
    /* Watchfloor brand chrome buttons — handoff §UI Primitives.
       Sharp 90° corners, JetBrains Mono UPPERCASE 11px / 0.1em
       tracking, no raised shadow. Outlined uses wf.steel border
       lifting to wf.signal on hover; contained tints with
       signal-blue. Theme-level so every existing Button across
       the app inherits without per-call refactors. */
    MuiButton: {
      defaultProps: { disableElevation: true },
      styleOverrides: {
        root: {
          borderRadius: 0,
          textTransform: 'uppercase',
          fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
          fontSize: '11px',
          fontWeight: 500,
          letterSpacing: '0.1em',
          boxShadow: 'none',
          transition:
            'background-color var(--motion-short4) var(--motion-emphasized), border-color var(--motion-short4) var(--motion-emphasized), color var(--motion-short4) var(--motion-emphasized)',
          '&:hover': { boxShadow: 'none' },
        },
        outlined: {
          borderColor: 'var(--mui-palette-wf-steel)',
          color: 'var(--mui-palette-wf-fog)',
          '&:hover': {
            borderColor: 'var(--mui-palette-wf-signal)',
            color: 'var(--mui-palette-wf-bone)',
            backgroundColor: 'transparent',
          },
        },
        contained: {
          backgroundColor: 'rgba(59, 158, 255, 0.12)',
          color: 'var(--mui-palette-wf-signal)',
          '&:hover': {
            backgroundColor: 'rgba(59, 158, 255, 0.2)',
          },
        },
        text: {
          color: 'var(--mui-palette-wf-fog)',
          '&:hover': {
            backgroundColor: 'rgba(59, 158, 255, 0.08)',
            color: 'var(--mui-palette-wf-bone)',
          },
        },
      },
    },
MuiLinearProgress: {
      styleOverrides: {
        root: { borderRadius: 3, height: 6, backgroundColor: 'var(--mui-palette-divider)' },
        bar: { borderRadius: 3, transition: '600ms var(--motion-emphasized)' },
      },
    },
    MuiDrawer: {
      styleOverrides: {
        paper: {
          borderLeft: 'none',
          boxShadow: '-8px 0 32px rgba(0,0,0,0.08)',
          /* Sharp brand corners on slide-out drawers. */
          borderRadius: 0,
        },
      },
    },
  },
})

export default theme
