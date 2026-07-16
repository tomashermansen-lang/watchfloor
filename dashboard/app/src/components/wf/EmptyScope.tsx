import RadarMark from './RadarMark'

/* Watchfloor empty state — handoff §"the watchfloor is listening".
   The biggest brand moment in the app: a slow-rotating radar scope
   stamped with the listening headline, used when there is genuinely
   nothing to monitor (no projects discovered, no sessions, no
   features). The animation reads as deliberate stillness, not
   loading — sweep at 6s communicates "we're watching, just nothing
   to report yet". Kept presentational; the consumer decides where
   it slots into the layout. */

interface EmptyScopeProps {
  /** Headline beneath the scope. Defaults to the brand line. */
  title?: string
  /** Subtext under the headline — typically the specific zero
     state ("no projects discovered yet" / "no sessions today"). */
  subtitle?: string
  /** Rendered scope size in CSS pixels. 320 is the brand hero size. */
  size?: number
}

const WF_BONE = '#E6EBF2'
const WF_FOG = '#5A6472'

export default function EmptyScope({
  title = 'The watchfloor is listening',
  subtitle,
  size = 320,
}: Readonly<EmptyScopeProps>) {
  return (
    <div
      data-testid="wf-empty-scope"
      style={{
        display: 'flex',
        flexDirection: 'column',
        alignItems: 'center',
        justifyContent: 'center',
        gap: '24px',
        padding: '48px 24px',
        textAlign: 'center',
      }}
    >
      <RadarMark size={size} sweep sweepDuration="6s" />
      <div style={{ display: 'flex', flexDirection: 'column', gap: '8px' }}>
        <div
          style={{
            fontFamily: '"Geist Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
            fontSize: '14px',
            fontWeight: 500,
            letterSpacing: '0.18em',
            textTransform: 'uppercase',
            color: WF_BONE,
          }}
        >
          {title}
        </div>
        {subtitle && (
          <div
            style={{
              fontFamily: '"Inter", system-ui, -apple-system, sans-serif',
              fontSize: '13px',
              fontWeight: 400,
              color: WF_FOG,
            }}
          >
            {subtitle}
          </div>
        )}
      </div>
    </div>
  )
}
