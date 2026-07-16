import RadarMark from './RadarMark'

/* Watchfloor LIVE pill — handoff atoms.md §"LIVE pill".
   12px radar with 2.2s sweep + JetBrains Mono "LIVE" label, on a
   tinted Signal Blue surface with matching border. The single most
   important brand-recall surface — appears on every authenticated
   screen so it gets a fixed shape regardless of consumer context.

   Built from inline styles (no MUI Box / Typography wrappers) so the
   spec values land literally and survive theme overrides — the LIVE
   pill is canonical and must look identical regardless of where it's
   rendered. Padding is top-heavy (4/10/3) to optically centre the
   mono caps, which sit slightly low relative to the cap-line. */

export default function LiveBadge() {
  return (
    <span
      data-testid="wf-live-badge"
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        gap: '6px',
        paddingTop: '4px',
        paddingRight: '10px',
        paddingBottom: '3px',
        paddingLeft: '10px',
        backgroundColor: 'rgba(59, 158, 255, 0.10)',
        border: '1px solid rgba(59, 158, 255, 0.35)',
        borderRadius: '999px',
        lineHeight: 1,
      }}
    >
      <RadarMark size={12} sweep sweepDuration="2.2s" />
      <span
        style={{
          fontFamily: '"JetBrains Mono", ui-monospace, "SFMono-Regular", Menlo, Consolas, monospace',
          fontSize: '10px',
          fontWeight: 500,
          letterSpacing: '0.16em',
          color: '#3B9EFF',
        }}
      >
        LIVE
      </span>
    </span>
  )
}
