/* Watchfloor corner reticles — handoff §"instrument panel" chrome.
   Four small L-shaped marks anchored at the four corners of the
   parent container. Borrows the radar-instrument vocabulary
   without filling the whole canvas with grid noise — reticles
   punctuate corners so the surface reads as a deliberate viewport
   rather than a generic card.

   Drop inside a positioned (relative/absolute) container; the
   reticles position themselves with absolute offsets and don't
   block pointer events. */

interface CornerReticlesProps {
  /** Reticle arm length in CSS pixels. Default 12 reads at the
     same scale as the wf StatusDot family. */
  size?: number
  /** Reticle stroke color. Defaults to the wf steel token —
     subtle enough to not compete with content, present enough
     to brand the corner. */
  color?: string
  /** Stroke thickness in CSS pixels. Default 1.5px matches the
     1.5px stroke used on RadarMark inner geometry. */
  thickness?: number
  /** Inset from the container edge in CSS pixels. Default 0
     (flush with the corner); pass a small positive value to
     pull the reticles inward when the container has padding. */
  inset?: number
}

const WF_STEEL = '#2A3340'

/* Each corner names the two borders that draw its L-shape. Uniform
   shape (all four keys present, only two truthy) avoids a TS narrowing
   trap where `as const` produces a discriminated union of distinct
   literal types — the consumer below can no longer access
   `c.borders.borderTop` because TS can't prove it exists on every
   variant of the union. With uniform shape the type is one record. */
type CornerBorders = {
  borderTop?: true
  borderRight?: true
  borderBottom?: true
  borderLeft?: true
}

const CORNERS: ReadonlyArray<{ id: 'tl' | 'tr' | 'bl' | 'br'; borders: CornerBorders }> = [
  { id: 'tl', borders: { borderTop: true, borderLeft: true } },
  { id: 'tr', borders: { borderTop: true, borderRight: true } },
  { id: 'bl', borders: { borderBottom: true, borderLeft: true } },
  { id: 'br', borders: { borderBottom: true, borderRight: true } },
]

export default function CornerReticles({
  size = 12,
  color = WF_STEEL,
  thickness = 1.5,
  inset = 0,
}: Readonly<CornerReticlesProps>) {
  const stroke = `${thickness}px solid ${color}`
  const positionFor = (id: typeof CORNERS[number]['id']) => {
    const v = id[0] === 't' ? 'top' : 'bottom'
    const h = id[1] === 'l' ? 'left' : 'right'
    return { [v]: inset, [h]: inset } as const
  }
  return (
    <>
      {CORNERS.map((c) => (
        <span
          key={c.id}
          data-testid="wf-corner-reticle"
          data-corner={c.id}
          aria-hidden
          style={{
            position: 'absolute',
            width: size,
            height: size,
            pointerEvents: 'none',
            borderTop: c.borders.borderTop ? stroke : undefined,
            borderRight: c.borders.borderRight ? stroke : undefined,
            borderBottom: c.borders.borderBottom ? stroke : undefined,
            borderLeft: c.borders.borderLeft ? stroke : undefined,
            ...positionFor(c.id),
          }}
        />
      ))}
    </>
  )
}
